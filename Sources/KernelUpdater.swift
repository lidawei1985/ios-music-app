//
//  KernelUpdater.swift
//  大伟歌 · 内核自动更新器
//
//  职责：问云端「内核最新版是哪一版」→ 比本地新 → 下载 → 校验 → 交 KernelStore 落盘。
//  全程静默：失败一律不打扰用户（网络不通、CDN 挂了、格式变了都只是「这次没更成」）。
//
//  为什么不在页面里做：file:// 页面的 fetch 跨源被 WebView 拦死，页面根本拿不到
//  CDN 上的 kernel.json / app.html。所以取清单 + 下载必须由原生代发。
//
//  拿什么节点：jsDelivr 的 gcore 节点（实测国内 855KB/s，而 cdn 节点回源 raw.githubusercontent
//  被墙，25s 只下到 176KB）。base 由页面传入，便于以后换节点不用改壳。
//

import Foundation

enum KernelUpdater {

    /// 检查并拉取。done 回调在主线程，结果为可直接回给页面的字典。
    static func checkAndPull(base: String, done: @escaping ([String: Any]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var baseURL = base
            if !baseURL.hasSuffix("/") { baseURL += "/" }

            // ① 取清单 kernel.json → {version, file, bytes, sha256?}
            guard let manURL = URL(string: baseURL + "kernel.json"),
                  let manData = httpGet(manURL, timeout: 15),
                  let man = (try? JSONSerialization.jsonObject(with: manData)) as? [String: Any],
                  let ver = man["version"] as? String, !ver.isEmpty else {
                finish(done, ["ok": false, "msg": "清单取不到", "urged": false]); return
            }
            let file = (man["file"] as? String) ?? "app.html"

            // ② 版本没变 → 什么都不做
            let cur = KernelStore.currentVersion()
            if !cur.isEmpty && cur == ver {
                finish(done, ["ok": true, "updated": false, "version": ver, "msg": "已是最新"]); return
            }
            // 首次热更（本地无版本号）时，若包内已经是这一版就没必要下 —— 由页面传入 bundleVer 比对
            let wantMB = (man["bytes"] as? NSNumber)?.intValue ?? 0

            // ③ 下载内核本体（大文件给足超时）
            guard let kURL = URL(string: baseURL + file),
                  let data = httpGet(kURL, timeout: 90) else {
                finish(done, ["ok": false, "msg": "内核下载失败", "urged": false]); return
            }
            // ④ 落盘（KernelStore.save 内部会校验大小/壳标记/闭合 + 原子替换 + 备份）
            let r = KernelStore.save(data, version: ver)
            var out: [String: Any] = ["ok": r.ok, "msg": r.msg, "version": ver,
                                      "bytes": data.count, "wantMB": wantMB]
            out["updated"] = r.ok
            finish(done, out)
        }
    }

    private static func finish(_ cb: @escaping ([String: Any]) -> Void, _ d: [String: Any]) {
        DispatchQueue.main.async { cb(d) }
    }

    /// 同步 GET（跑在后台队列，带 UA 防被 CDN 拒）
    private static func httpGet(_ url: URL, timeout: TimeInterval) -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
                     + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                     forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: req) { d, resp, _ in
            if let h = resp as? HTTPURLResponse, h.statusCode == 200 { out = d }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 5)
        return out
    }
}
