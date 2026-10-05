//
//  ShellViewController.swift
//  大伟歌 · iOS 版
//
//  WKWebView 壳：加载与 Android 版完全相同的 app.html。
//  - 内联自动播放（点海报即播，不要求二次手势）
//  - localStorage 持久化（收藏 / 最近播放 / 搜索历史）
//  - 后台播放（UIBackgroundModes=audio + AVAudioSession .playback）
//  - 状态栏浅色、全屏沉浸，页面自己吃 env(safe-area-inset-*)
//

import UIKit
import WebKit
import AVFoundation

final class ShellViewController: UIViewController, WKNavigationDelegate {

    private var web: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()

        // 后台继续出声
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserAction = []          // 不要求手势即可播放
        cfg.websiteDataStore = .default()               // localStorage 落盘
        cfg.allowsPictureInPictureMediaPlayback = false
        // 平台标识：先于页面任何脚本执行（与 Android 的打包期注入对齐）
        cfg.userContentController.addUserScript(
            WKUserScript(source: "window.__PLATFORM__='ios';",
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true))

        web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0x06/255.0, green: 0x06/255.0, blue: 0x09/255.0, alpha: 1)
        web.scrollView.contentInsetAdjustmentBehavior = .never   // 沉浸式：页面用 safe-area 自适应
        web.scrollView.bounces = false
        view = web

        if let url = Bundle.main.url(forResource: "app", withExtension: "html", subdirectory: "app") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else if let url = Bundle.main.url(forResource: "app", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
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

    // 屏幕旋转锁定竖屏（与两端定版一致）
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var prefersStatusBarHidden: Bool { false }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}
