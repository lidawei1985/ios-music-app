# 大伟歌 · iOS 版（DWGMusic）

与 **Android 版共用同一份 HTML 内核** 的 WKWebView 壳。改一处内核，两端同步，UI 零出入。

## 结构

```
kernel/app.html             内核唯一真源（由本机 musicdl/prototype/app.html 同步）
App/Info.plist              后台播放 / ATS 放开 / 竖屏 / 深色
App/MainApp.swift           启动入口
Sources/ShellViewController.swift   WKWebView 壳（内联播放、localStorage、沉浸式）
Assets.xcassets/            1024 图标
scripts/pack.py             打壳：内核 → Resources/app.html（data-shell="ios" + 平台标识）
project.yml                 XcodeGen 工程描述
```

## A. Mac 上本地构建

```bash
brew install xcodegen
python3 scripts/pack.py     # 生成 Resources/app.html
xcodegen generate
open DWGMusic.xcodeproj     # Xcode 选真机 → Run
```

## B. 无 Mac：云端出裸包（本仓库已配好）

推代码到 `main` 即自动构建，产物 `DWGMusic-unsigned.ipa`（未签名）在 Actions → Artifacts。
拿到后二选一装机：

1. **爱思助手**（Windows 即可）：工具箱 → IPA 签名 → 选 ipa → 登录 Apple ID → 签装。
2. **LiveContainer**：把 ipa 推进壳的 `Documents/`，壳内导入运行。

## 硬门禁（CI 强制，防「编出来是空壳」）

- 内核 < 2 MB → 红灯
- 内核缺 `data-shell="ios"` 或平台标识 → 红灯
