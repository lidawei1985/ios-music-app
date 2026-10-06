//
//  KernelStore.swift
//  大伟歌 · 内核热更新存储层
//
//  为什么需要它：
//    App bundle 是只读的（Bundle.main 里的 app.html 改不了），所以「免推机更新内核」
//    唯一的办法是：把新内核写进沙盒（Documents/kernel/），启动时优先从沙盒加载。
//    页面侧负责下载，本类负责【校验 + 原子落盘 + 版本记账 + 回退】。
//
//  安全铁律（宁可不更，也不能开不了 App）：
//    1. 落盘前必须过校验（大小下限 / 壳标记 / 结构闭合）——半截下载绝不写盘
//    2. 原子写：先写 .tmp，再 replaceItem —— 断电/被杀不会留半截文件
//    3. 写盘前把当前版备份成 app.bak.html
//    4. 启动时若沙盒版校验不过 → 直接用包内版，并把坏文件删掉（自动回退）
//

import Foundation

enum KernelStore {

    /// 沙盒内核目录：Documents/kernel/
    static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kernel", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }
    static var liveURL: URL { dir.appendingPathComponent("app.html") }
    static var bakURL:  URL { dir.appendingPathComponent("app.bak.html") }
    static var metaURL: URL { dir.appendingPathComponent("meta.json") }

    /// 内核体积下限（字节）。真内核 6MB+，低于此值必是半截下载或被裁剪。
    private static let MIN_BYTES = 2_000_000

    // MARK: - 校验
    /// 一段数据是否是「像样的 iOS 内核」。
    /// 只做与主题无关的硬结构判断，避免内核改版后此处误判把好包拒了。
    static func looksValid(_ data: Data) -> Bool {
        guard data.count >= MIN_BYTES else { return false }
        // 只看头 4KB 找壳标记、尾 2KB 找闭合 —— 不必把 6MB 全文解码成字符串（省内存/省时间）
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        guard head.contains("data-shell=\"ios\"") || head.contains("data-shell='ios'") else { return false }
        guard head.contains("<html") else { return false }
        let tail = String(decoding: data.suffix(2048), as: UTF8.self)
        guard tail.contains("</html>") else { return false }
        return true
    }

    // MARK: - 启动时挑选要加载的内核
    /// 返回应该加载的文件 URL，以及来源标记（"sandbox" / "bundle"）。
    /// 沙盒版校验不过 → 删掉它，回退包内版（自动回退，用户无感）。
    static func resolveBootKernel() -> (url: URL, source: String)? {
        // 1) 沙盒版优先
        if let d = try? Data(contentsOf: liveURL), looksValid(d) {
            return (liveURL, "sandbox")
        }
        // 2) 沙盒版坏了/不存在 → 清掉，回退包内
        if FileManager.default.fileExists(atPath: liveURL.path) {
            NSLog("[DWG] 沙盒内核校验不过，已丢弃并回退包内版")
            try? FileManager.default.removeItem(at: liveURL)
        }
        // 3) 包内版（真机 bundle 里 app.html 在根；兼容历史 app/ 子目录）
        if let u = Bundle.main.url(forResource: "app", withExtension: "html", subdirectory: "app")
            ?? Bundle.main.url(forResource: "app", withExtension: "html") {
            return (u, "bundle")
        }
        return nil
    }

    // MARK: - 落盘
    /// 把下载来的内核写进沙盒。返回 (成功, 说明)。
    /// 失败一律不动现有沙盒版 —— 保证「更坏了也能用旧的」。
    @discardableResult
    static func save(_ data: Data, version: String) -> (ok: Bool, msg: String) {
        guard looksValid(data) else {
            return (false, "校验不过（大小/壳标记/闭合）")
        }
        let fm = FileManager.default
        let tmp = dir.appendingPathComponent("app.tmp.html")
        do {
            // ① 先写临时文件
            try data.write(to: tmp, options: .atomic)
            // ② 旧版备份一份（若存在）
            if fm.fileExists(atPath: liveURL.path) {
                try? fm.removeItem(at: bakURL)
                try? fm.copyItem(at: liveURL, to: bakURL)
            }
            // ③ 原子替换
            if fm.fileExists(atPath: liveURL.path) {
                _ = try fm.replaceItemAt(liveURL, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: liveURL)
            }
            // ④ 记版本号
            let meta = ["version": version,
                        "savedAt": ISO8601DateFormatter().string(from: Date()),
                        "bytes": String(data.count)]
            if let j = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) {
                try? j.write(to: metaURL, options: .atomic)
            }
            return (true, "已落盘 \(data.count) 字节")
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return (false, "写盘失败: \(error.localizedDescription)")
        }
    }

    /// 当前沙盒内核的版本号（没有则空串）
    static func currentVersion() -> String {
        guard let d = try? Data(contentsOf: metaURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let v = o["version"] as? String else { return "" }
        return v
    }

    /// 诊断用：内核来源与版本（供设置页展示）
    static func statusText() -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: liveURL.path) else { return "包内内核（未热更过）" }
        let attrs = try? fm.attributesOfItem(atPath: liveURL.path)
        let sz = (attrs?[.size] as? Int) ?? 0
        return "沙盒内核 v\(currentVersion()) · \(sz / 1024)KB"
    }
}
