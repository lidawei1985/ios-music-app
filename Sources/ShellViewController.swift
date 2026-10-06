//
//  ShellViewController.swift
//  大伟歌 · iOS 版
//
//  WKWebView 壳：加载与 Android 版完全相同的 app.html。
//  - 内联自动播放（点海报即播，不要求二次手势）
//  - localStorage 持久化（收藏 / 最近播放 / 搜索历史）
//  - 后台播放（UIBackgroundModes=audio + AVAudioSession .playback）
//  - 状态栏浅色、全屏沉浸，页面自己吃 env(safe-area-inset-*)
//  - MV/演唱会：SFSafariViewController 全屏播 B 站（file:// 主文档里跨源 iframe
//    的媒体层在 WKWebView 被限制 = 真机黑屏；Safari 容器是确定性可播方案），
//    关闭后回调页面 __dwgMvClosed() 恢复音乐断点续播
//  - 横竖屏：页面经 dwg 桥发 orient {all:1|0}，MV 页允许旋转，其余锁竖屏
//  - 内核热更新：优先加载沙盒内核（Documents/kernel/app.html，由页面下载+原生落盘），
//    没有/坏了就回退包内 —— 于是「改内核」不再需要重新出包推机
//

import UIKit
import WebKit
import AVFoundation
import SafariServices

final class ShellViewController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler, SFSafariViewControllerDelegate {

    private var web: WKWebView!
    private var allowAllOrient = false
    private var safariVC: SFSafariViewController?

    override func viewDidLoad() {
        super.viewDidLoad()

        // 后台继续出声
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []   // 不要求手势即可播放
        cfg.websiteDataStore = .default()               // localStorage 落盘
        cfg.allowsPictureInPictureMediaPlayback = false
        // 平台标识：先于页面任何脚本执行（与 Android 的打包期注入对齐）
        cfg.userContentController.addUserScript(
            WKUserScript(source: "window.__PLATFORM__='ios';",
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true))
        // 包内资源目录（绝对值）：当内核从沙盒加载时，曲库分块 cat-*.js 仍在 App 包内，
        // 页面相对路径会指向沙盒目录而 404 —— 把包内目录告诉页面，让它优先用这里的资源。
        if let bundleDir = Bundle.main.resourceURL {
            let u = bundleDir.absoluteString
            cfg.userContentController.addUserScript(
                WKUserScript(source: "window.__DWG_RES__='\(u)';",
                             injectionTime: .atDocumentStart,
                             forMainFrameOnly: true))
        }
        // 原生代发通道：页面用 window.webkit.messageHandlers.dwg.postMessage({id,method,params})
        cfg.userContentController.add(self, name: "dwg")

        web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0x06/255.0, green: 0x06/255.0, blue: 0x09/255.0, alpha: 1)
        web.scrollView.contentInsetAdjustmentBehavior = .never   // 沉浸式：页面用 safe-area 自适应
        web.scrollView.bounces = false
        view = web

        if let picked = KernelStore.resolveBootKernel() {
            NSLog("[DWG] 内核来源: \(picked.source) → \(picked.url.lastPathComponent)")
            web.loadFileURL(picked.url, allowingReadAccessTo: picked.url.deletingLastPathComponent())
        } else {
            let lb = UILabel()
            lb.text = "内核缺失：Resources/app.html 未打包进 App"
            lb.textColor = .white
            lb.textAlignment = .center
            lb.frame = view.bounds
            lb.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(lb)
        }
    }

    // 横竖屏：MV 打开时页面会发 orient{all:1} 放开旋转，关闭发 {all:0} 收回竖屏
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        allowAllOrient ? .allButUpsideDown : .portrait
    }
    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - 原生代发桥（高码率直链 / 歌词 / MV 播放 / 横竖屏）
    // 页面 → 原生：{id, method, params}
    // 原生 → 页面：window.__dwgCb(id, base64(JSON))  —— base64 避免任何转义坑
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "dwg", let body = message.body as? [String: Any] else { return }
        let id = (body["id"] as? NSNumber)?.intValue ?? 0
        let method = (body["method"] as? String) ?? ""
        let params = (body["params"] as? [String: Any]) ?? [:]

        switch method {
        case "openurl":
            // MV/演唱会：SFSafariViewController 全屏播放（确定性可播）
            if let u = params["url"] as? String, let url = URL(string: u) {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    let vc = SFSafariViewController(url: url)
                    vc.delegate = self
                    vc.modalPresentationStyle = .fullScreen
                    self.safariVC = vc
                    self.present(vc, animated: true)
                }
            }
            reply(id: id, obj: ["ok": true])
        case "orient":
            allowAllOrient = (params["all"] as? NSNumber)?.intValue == 1
            if #available(iOS 16.0, *) {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.setNeedsUpdateOfSupportedInterfaceOrientations()
                    // 已在横屏时收回竖屏：把设备转回人像，避免界面停在横屏
                    if !self.allowAllOrient,
                       UIDevice.current.orientation.isLandscape {
                        UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
                    }
                }
            }
            reply(id: id, obj: ["ok": true])

        // MARK: 内核热更新
        //
        //  为什么整个下载都放原生：file:// 页面里 fetch/XHR 跨源会被 WKWebView 拦死
        //  （与歌词/高码率同一个原因），页面既读不到 CDN 的 kernel.json，也拉不动 app.html。
        //  所以页面只负责「问一下有没有新版」，真正的取清单 + 下载 + 校验 + 落盘全在原生做。
        //  这也顺带避免了把 6MB 内核在 JS 与原生之间来回搬的内存峰值。
        case "kcheck":
            // params: { base: "<CDN base url>" }，例如 https://gcore.jsdelivr.net/gh/xxx@main/data/kernel/
            guard let base = params["base"] as? String, !base.isEmpty else {
                reply(id: id, obj: ["ok": false, "msg": "缺 base"])
                return
            }
            KernelUpdater.checkAndPull(base: base) { [weak self] r in
                self?.reply(id: id, obj: r)
            }

        case "kinfo":
            reply(id: id, obj: ["ok": true, "status": KernelStore.statusText(),
                                "version": KernelStore.currentVersion()])

        default:
            DwgNet.shared.handle(method: method, params: params) { [weak self] obj in
                self?.reply(id: id, obj: obj)
            }
        }
    }

    // 用户点「完成」关掉 Safari 容器 → 通知页面恢复音乐断点续播
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        safariVC = nil
        web.evaluateJavaScript("window.__dwgMvClosed && window.__dwgMvClosed();", completionHandler: nil)
    }

    private func reply(id: Int, obj: [String: Any]?) {
        var json = "null"
        if let o = obj,
           let d = try? JSONSerialization.data(withJSONObject: o),
           let s = String(data: d, encoding: .utf8) {
            json = s
        }
        let b64 = Data(json.utf8).base64EncodedString()
        let js = "window.__dwgCb && window.__dwgCb(\(id), \"\(b64)\");"
        DispatchQueue.main.async { [weak self] in
            self?.web.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
