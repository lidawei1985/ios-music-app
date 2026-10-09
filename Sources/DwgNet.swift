//
//  DwgNet.swift
//  大伟歌 · 原生代发桥
//
//  为什么必须走原生：
//    网易云的高码率接口（api/song/enhance/player/url）和歌词接口
//    都不返回 Access-Control-Allow-Origin，file:// 页面里 fetch 会被 WKWebView 直接拦死。
//    把这两类请求交给原生 URLSession 代发，结果 base64(JSON) 回灌给 window.__dwgCb，
//    页面拿到的就是一份普通 JSON —— 页面代码不用为跨域做任何妥协。
//
//  实测（2026-10-05，匿名）：
//    level=standard → 128kbps / higher → 192kbps / exhigh → 320kbps（匿名最高档）
//    直链 20 分钟有效，所以每次播放实时解析、页面侧缓存 10 分钟。
//

import Foundation

final class DwgNet {

    static let shared = DwgNet()
    private let q = DispatchQueue(label: "dwg.net", qos: .userInitiated, attributes: .concurrent)
    private let UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
                   + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// 统一入口：method + params → 结果字典（失败返回 nil → 页面自动回落标准音质）
    func handle(method: String, params: [String: Any], done: @escaping ([String: Any]?) -> Void) {
        q.async {
            var out: [String: Any]?
            switch method {
            case "stream": out = self.stream(params)
            case "lyric":  out = self.lyric(params)
            // ★★★ 2026-10-09 新增：通用 GET 通道 —— MV/演唱会取流就卡在这一条上。
            //   内核 mvUrl() 早就写成 Native.call("fetch", …)，但本类一直只实现了
            //   stream / lyric 两个 method，default 直接返回 nil →
            //   iOS 上 MV 取流**必然失败**（页面提示「取流失败，请稍后再试」）。
            //   补上之后，凡是「file:// 页面自己 fetch 会被 WKWebView 跨源拦死」的
            //  接口都能走这里，以后再加此类接口**不用再重装 App**（内核热更即可）。
            case "fetch":  out = self.fetch(params)
            default:       out = nil
            }
            DispatchQueue.main.async { done(out) }
        }
    }

    // MARK: - HTTP（同步取回，跑在并发队列上）

    private func get(_ url: String, referer: String) -> Data? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = 12
        req.setValue(UA, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        URLSession.shared.dataTask(with: req) { d, _, _ in data = d; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 14)
        return data
    }

    private func json(_ url: String, referer: String) -> [String: Any]? {
        guard let d = get(url, referer: referer) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    // MARK: - 通用 GET（给页面取任意跨源接口）

    /// params: {url, headers?} → {status, text}
    /// text 是响应体的 UTF-8 文本，页面侧自行 JSON.parse（内核 _mvPick 已兼容 text / json / body）。
    private func fetch(_ p: [String: Any]) -> [String: Any]? {
        guard let url = p["url"] as? String, !url.isEmpty, let u = URL(string: url) else { return nil }
        // Referer：优先用页面传的（网易云接口不带会被判未授权），否则给个默认
        var referer = "https://music.163.com/"
        if let hs = p["headers"] as? [String: Any] {
            if let r = hs["Referer"] as? String, !r.isEmpty { referer = r }
            else if let r = hs["referer"] as? String, !r.isEmpty { referer = r }
        }
        var req = URLRequest(url: u)
        req.timeoutInterval = 12
        req.setValue(UA, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        var code = 0
        URLSession.shared.dataTask(with: req) { d, resp, _ in
            if let h = resp as? HTTPURLResponse { code = h.statusCode }
            data = d
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 14)
        guard let d = data else { return nil }
        return ["status": code, "text": String(decoding: d, as: UTF8.self)]
    }

    // MARK: - 高码率直链

    private func stream(_ p: [String: Any]) -> [String: Any]? {
        guard let sid = intOf(p["id"]) else { return nil }
        let level = (p["level"] as? String) ?? "exhigh"
        let url = "https://music.163.com/api/song/enhance/player/url/v1"
                + "?ids=%5B\(sid)%5D&level=\(level)&encodeType=mp3"
        guard let j = json(url, referer: "https://music.163.com/"),
              let arr = j["data"] as? [[String: Any]],
              let x = arr.first,
              let u = x["url"] as? String, !u.isEmpty
        else { return nil }
        return ["url": u,
                "br": intOf(x["br"]) ?? 0,
                "size": intOf(x["size"]) ?? 0,
                "type": (x["type"] as? String) ?? "mp3"]
    }

    // MARK: - 歌词（含翻译）

    private func lyric(_ p: [String: Any]) -> [String: Any]? {
        guard let sid = intOf(p["id"]) else { return nil }
        let url = "https://music.163.com/api/song/lyric?id=\(sid)&lv=1&kv=1&tv=-1"
        guard let j = json(url, referer: "https://music.163.com/") else { return nil }
        let l = ((j["lrc"] as? [String: Any])?["lyric"] as? String) ?? ""
        let t = ((j["tlyric"] as? [String: Any])?["lyric"] as? String) ?? ""
        if l.isEmpty && t.isEmpty { return nil }
        return ["l": l, "t": t, "src": "wy"]
    }

    // MARK: - 工具

    private func intOf(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
