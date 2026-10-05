#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
大伟歌 · iOS 版打包准备（在 Mac 上构建前跑一次，或在本机跑完同步过去）

与 android/build.py 的 step_html 完全对齐：同一份 HTML 内核，
打 data-shell="ios" 壳标记 + 注入 window.__PLATFORM__，并准备 App 图标。
"""
import os, re, shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # .../musicdl/ios
PROJ = os.path.dirname(ROOT)                                          # .../musicdl
HTML_DST = os.path.join(ROOT, "Resources", "app.html")
ICON_DST = os.path.join(ROOT, "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png")

# 内核来源：本机工程优先用 prototype/（与 Android 端同一份）；CI 克隆出来没有 prototype/
# 时退回仓库自带的 kernel/ 副本 —— 保证「本机改一处、云端出的包同步」不靠手工拷贝。
_candidates = [
    os.path.join(PROJ, "prototype", "app.html"),
    os.path.join(ROOT, "kernel", "app.html"),
]
HTML_SRC = next((p for p in _candidates if os.path.exists(p)), _candidates[0])

_icon_candidates = [
    os.path.join(PROJ, "assets", "appicon", "icon-1024.png"),
    ICON_DST,
]
ICON_SRC = next((p for p in _icon_candidates if os.path.exists(p)), _icon_candidates[0])


def inject_shell(html, plat):
    """打壳标记 + 注入平台标识（在 <head> 最前面，先于任何脚本执行）"""
    if 'data-shell=' not in html.split('>', 1)[0]:
        html = re.sub(r'<html([^>]*)>', r'<html\1 data-shell="%s">' % plat, html, count=1)
    boot = '<script>window.__PLATFORM__=%s;</script>' % ('"%s"' % plat)
    html = re.sub(r'(<head[^>]*>)', r'\1' + boot, html, count=1)
    return html


def main():
    print("=== 大伟歌 · iOS 版打包准备 ===")
    print("  内核来源:", HTML_SRC)
    raw = open(HTML_SRC, encoding="utf-8").read()
    out = inject_shell(raw, "ios")
    os.makedirs(os.path.dirname(HTML_DST), exist_ok=True)
    with open(HTML_DST, "w", encoding="utf-8") as f:
        f.write(out)
    print("  Resources/app.html  %.2f MB  (data-shell=ios)" % (len(out.encode("utf-8")) / 1048576))

    if not os.path.exists(ICON_SRC):
        print("  [警告] 找不到 AppIcon 源，沿用仓库内已有图标")
    elif os.path.abspath(ICON_SRC) == os.path.abspath(ICON_DST):
        print("  AppIcon 已在位 (1024)")
    else:
        shutil.copyfile(ICON_SRC, ICON_DST)
        print("  AppIcon 已就位 (1024)")

    print("\n下一步（Mac 上）:")
    print("  1. brew install xcodegen")
    print("  2. cd ios && xcodegen && open DWGMusic.xcodeproj")
    print("  3. Xcode 选真机 → Run（或在 Signing 里配好团队后 Product > Archive）")


if __name__ == "__main__":
    main()
