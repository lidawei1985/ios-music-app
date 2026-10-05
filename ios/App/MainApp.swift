//
//  MainApp.swift
//  大伟歌 · iOS 版
//
//  与 Android 版共用同一份 HTML 内核（Resources/app.html），保证两端 UI 零出入。
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let win = UIWindow(frame: UIScreen.main.bounds)
        win.rootViewController = ShellViewController()
        win.makeKeyAndVisible()
        window = win
        return true
    }
}
