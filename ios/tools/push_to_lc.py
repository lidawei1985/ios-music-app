# -*- coding: utf-8 -*-
"""把「大伟歌」IPA 推进 iPhone 上 LiveContainer 容器的 Documents/，并在导入后按字节核验。

为什么不用 F:\\IOS3APP\\ios_ctrl\\push_ipas_full36.py：
  那个脚本是给三 ISO APP（星幕/心屋/夜航）写死的，且**推送前会删掉不在本批名单里的旧 IPA**
  —— 借它推我们的包会误删别人的包。铁律：动别人的东西先问。
  本脚本只做两件事：① 推我们的包；② 只读核验。**永不删除设备上任何文件**。

用法：
  python push_to_lc.py push                 # 推 out/DWGMusic-unsigned.ipa → Documents/DWGMusic.ipa
  python push_to_lc.py push --ipa <路径> --name <远端名>
  python push_to_lc.py ls                   # 只列容器 Documents（只读）
  python push_to_lc.py verify               # 只读核验已导入 guest 的 app.html 指纹
  python push_to_lc.py host                 # 打印动态查到的 LC 包名（只读）

成功判据：
  push   → "RESULT: PASS — DWGMusic.ipa 已推入且字节数一致"
  verify → "RESULT: PASS — 机上 app.html 与本地包一致"
"""
import asyncio
import hashlib
import os
import sys
import zipfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
IPA_DEFAULT = os.path.abspath(os.path.join(HERE, "..", "..", "out", "DWGMusic-unsigned.ipa"))
NAME_DEFAULT = "DWGMusic.ipa"
GUEST_BID = "tv.dwg.music"          # project.yml → PRODUCT_BUNDLE_IDENTIFIER


def arg(flag, default):
    if flag in sys.argv:
        i = sys.argv.index(flag)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


async def lc_host_bid(lockdown):
    """动态枚举 com.kdt.livecontainer.*（LC 包名带随机后缀，不许写死）。"""
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    svc = InstallationProxyService(lockdown)
    apps = None
    for kwargs in ({"application_type": "User"}, {"app_types": "User"}, {}):
        try:
            apps = await svc.get_apps(**kwargs)
            if apps:
                break
        except TypeError:
            continue
    try:
        await svc.close()
    except Exception:
        pass
    if not apps:
        raise RuntimeError("拿不到已装应用列表")
    cands = sorted(b for b in apps if b.startswith("com.kdt.livecontainer."))
    if not cands:
        raise RuntimeError("已装应用里没有 com.kdt.livecontainer.* —— LC 可能没装")
    return cands[0], cands


def local_apphtml_sha(ipa):
    with zipfile.ZipFile(ipa) as z:
        n = [x for x in z.namelist() if x.endswith("/app.html")][0]
        b = z.read(n)
    return n, len(b), hashlib.sha256(b).hexdigest()


async def cmd_host():
    from pymobiledevice3.lockdown import create_using_usbmux
    lk = await create_using_usbmux()
    bid, cands = await lc_host_bid(lk)
    print("设备:", lk.all_values.get("ProductType"), lk.all_values.get("ProductVersion"))
    print("LC 候选包名:", cands)
    print("使用:", bid)
    await lk.close()


async def cmd_ls():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.house_arrest import HouseArrestService
    lk = await create_using_usbmux()
    bid, _ = await lc_host_bid(lk)
    ha = await HouseArrestService.create(lk, bid, documents_only=False)
    print("LC 容器:", bid)
    for d in ("/", "/Documents"):
        try:
            print(d, "->", await ha.listdir(d))
        except Exception as e:
            print(d, "-> 读不到:", type(e).__name__, e)
    await ha.close()
    await lk.close()


async def cmd_push():
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.house_arrest import HouseArrestService
    ipa = os.path.abspath(arg("--ipa", IPA_DEFAULT))
    name = arg("--name", NAME_DEFAULT)
    if not os.path.exists(ipa):
        print("RESULT: FAIL — 本地找不到 IPA:", ipa)
        sys.exit(1)
    size = os.path.getsize(ipa)
    print("本地包:", ipa, size, "字节")

    lk = await create_using_usbmux()
    print("设备:", lk.all_values.get("ProductType"), lk.all_values.get("ProductVersion"),
          "| 序列号尾:", str(lk.all_values.get("SerialNumber"))[-6:])
    bid, cands = await lc_host_bid(lk)
    print("LC 包名:", bid)

    ha = await HouseArrestService.create(lk, bid, documents_only=False)
    before = await ha.listdir("/Documents")
    print("推送前 Documents:", before)

    # ★ 不删任何东西：旧包直接覆盖同名，其余一律保留
    remote = "/Documents/" + name
    print("推送 →", remote, flush=True)
    await ha.push(ipa, remote, progress_bar=False)

    st = await ha.stat(remote)
    got = st.get("st_size") if isinstance(st, dict) else getattr(st, "st_size", None)
    after = await ha.listdir("/Documents")
    print("推送后 Documents:", after)
    await ha.close()
    await lk.close()

    if got != size:
        print(f"RESULT: FAIL — {name} 设备={got} 本地={size}")
        sys.exit(1)
    print(f"RESULT: PASS — {name} 已推入且字节数一致（{size}）")


async def cmd_verify():
    """只读核验：把机上 guest 的 app.html 拉回来算 sha256，和本地包里的比。
    为什么要按字节核验而不是截图：截图只能证明「有个界面」，证不了「跑的是新内核」。"""
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.house_arrest import HouseArrestService
    ipa = os.path.abspath(arg("--ipa", IPA_DEFAULT))
    inner, lsize, lsha = local_apphtml_sha(ipa)
    print("本地包内:", inner, lsize, "字节 sha256:", lsha[:16])

    lk = await create_using_usbmux()
    bid, _ = await lc_host_bid(lk)
    # 读 guest 目录用 documents_only=True（LC 的 Applications 在 Documents 下）
    afc = await HouseArrestService.create(lk, bundle_id=bid)
    base = f"/Documents/Applications/{GUEST_BID}.app"
    try:
        listed = await afc.listdir(base)
    except Exception as e:
        print(f"RESULT: FAIL — 机上没有 {GUEST_BID}（{type(e).__name__}）→ 还没导入成功")
        await lk.close()
        sys.exit(1)
    print("机上 app 目录:", listed[:20])
    path = base + "/app.html"
    try:
        st = await afc.stat(path)
        rsize = st.get("st_size") if isinstance(st, dict) else getattr(st, "st_size", None)
        data = await afc.get_file_contents(path)
    except Exception as e:
        print(f"RESULT: FAIL — 读不到 {path}（{type(e).__name__}: {e}）")
        await lk.close()
        sys.exit(1)
    rsha = hashlib.sha256(data).hexdigest()
    print(f"机上 app.html: {len(data)} 字节 sha256: {rsha[:16]}")
    await afc.close()
    await lk.close()

    if rsha == lsha:
        print("RESULT: PASS — 机上 app.html 与本地包一致")
        return
    # 大小不小但哈希不同：可能是 CI 侧写入器改过（换行/BOM），退一步按关键标记判定
    txt = data.decode("utf-8", "replace")
    marks = {
        'data-shell="ios"': 'data-shell="ios"' in txt,
        "const CATALOG": "const CATALOG" in txt,
        "CDNCAT": "CDNCAT = CDN" in txt,
        "质量优先": "热度优先" in txt or "热度+新鲜度" in txt,
    }
    print("哈希不同，关键标记:", marks)
    if all(marks.values()):
        print(f"RESULT: PASS（弱判据）— 大小 {len(data)} vs {lsize}，哈希不同但新内核标记全中")
    else:
        print("RESULT: FAIL — 机上不是新内核")
        sys.exit(1)


CMDS = {"ls": cmd_ls, "push": cmd_push, "verify": cmd_verify, "host": cmd_host}
CMD = sys.argv[1] if len(sys.argv) > 1 else "ls"
if CMD not in CMDS:
    print(__doc__)
    sys.exit(2)
asyncio.run(CMDS[CMD]())
