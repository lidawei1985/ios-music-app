#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""内核仓时效锚点：把「内核提交的 sha」写成一个 **10 分钟窗口命名**的 .js。

=======================================================================
为什么需要它（2026-10-06 判决性实测定案）
=======================================================================
jsDelivr 是「**按 URL** 缓存」，不是「按分支」：
  已被缓存过的 URL（@main / @latest）→ 硬缓存（分支 12 小时 / 别名 7 天），
      purge 打不动、挂 ?t= 也打不动（实测纹丝不动）。
  **全新的 URL**（新文件名 / 新 commit sha / 新 tag）→ **立即回源**。

判决性实测（真值取 api.github.com，零缓存；同一时刻并发对比）：
    真值                version=0a4a3eb50f03   ← 最新
    @latest             version=38fbc94aaf49   ← 旧
    @main               version=4963b79d8e55   ← 更旧
    @v1.0.21            version=0a4a3eb50f03   ← 立即生效 ✅
    @<commit-sha>       version=b2ac26b157e7   ← 立即生效 ✅

★ 顺带反证了「真凭据推送触发 webhook」这个假设：
  cloud 仓改用 deploy key 推后，`data/probe.json`（**全新文件名**）7 秒即取到 ✅，
  但同一次提交里的 `data/assets/cv.json`（**老 URL**）纹丝不动 ——
  → 不是凭据的问题，就是「新 URL 才秒回」。

于是端上要「推完内核手机立刻更到」，就不能读 @main，得先拿一个**刚推上去的 sha**：
     kernel/win/<YYYYMMDDHHMM>.js  →  window.__DWG_TIDE={"sha":"<sha>",...}
这个 URL 天生是新出现的 → 必然回源、秒级可得。端上 probeTideIos() 拿到 sha 后，
把 kcheck 的 base 换成 `@<sha>/kernel/`（同样是全新 URL）→ 原生立刻比出版本差并下载。
探不到就回落 @main：慢 12 小时，但功能不受影响（原则：宁可慢，不能断）。

=======================================================================
为什么必须「两段提交」
=======================================================================
锚点里要写的是**内核提交的 sha**，而 sha 只有提交完才知道 —— 先有鸡先有蛋。所以：
    ① 提交 kernel/dist.html + kernel/kernel.json  → git rev-parse HEAD 得 sha A（+ [skip ci]）
    ② python3 scripts/mktide.py --sha <sha A> --prune → 再提交 kernel/win/（+ [skip ci]）
端上探到 sha A → 用 @<sha A>/kernel/ 拉内核 —— 而 sha A 正是带着新内核的那个提交。

用法：
    python3 scripts/mktide.py                 # 用 git HEAD 的 sha 写当前窗口
    python3 scripts/mktide.py --sha abc1234   # 显式指定
    python3 scripts/mktide.py --prune         # 只保留最近 KEEP 个窗口
"""
import argparse, json, os, subprocess, sys, time

CD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEEP = 48            # 保留 48 个窗口 = 8 小时（端上最多追 2 小时，余量充足）


def win_name(dt=None):
    """10 分钟粒度的窗口名：YYYYMMDDHHM0（UTC）。必须与端上 probeTideAny() 逐字符一致。"""
    t = dt or time.gmtime()
    return "%04d%02d%02d%02d%1d0" % (t.tm_year, t.tm_mon, t.tm_mday,
                                     t.tm_hour, t.tm_min // 10)


def git_head_sha():
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=CD,
                                       text=True, stderr=subprocess.DEVNULL).strip()
    except Exception as e:
        print("[mktide] 取 git HEAD 失败：%s" % e, file=sys.stderr)
        return ""


def prune(outdir, keep=KEEP):
    if not os.path.isdir(outdir):
        return 0
    wins = sorted([f[:-3] for f in os.listdir(outdir)
                   if f.endswith(".js") and len(f) == 15 and f[:-3].isdigit()])
    n = 0
    for w in (wins[:-keep] if len(wins) > keep else []):
        try:
            os.remove(os.path.join(outdir, w + ".js")); n += 1
        except Exception:
            pass
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sha", default="")
    ap.add_argument("--dir", default="kernel/win")
    ap.add_argument("--version", default="")
    ap.add_argument("--prune", action="store_true")
    ap.add_argument("--back", type=int, default=1)
    a = ap.parse_args()

    outdir = a.dir if os.path.isabs(a.dir) else os.path.join(CD, a.dir)
    os.makedirs(outdir, exist_ok=True)

    sha = a.sha.strip() or git_head_sha()
    if len(sha) < 7:
        print("[mktide] 没有可用 sha，放弃（不影响出包）", file=sys.stderr)
        return 1

    now = time.time()
    wrote = []
    for i in range(max(1, a.back)):
        t = time.gmtime(now - i * 600)
        payload = {"sha": sha, "t": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))}
        if a.version:
            payload["v"] = a.version
        dst = os.path.join(outdir, win_name(t) + ".js")
        tmp = dst + ".tmp"
        body = "window.__DWG_TIDE=%s;" % json.dumps(payload, ensure_ascii=False,
                                                    separators=(",", ":"))
        with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(body)
        os.replace(tmp, dst)        # 原子替换：端上绝不会读到半个文件
        wrote.append((os.path.basename(dst), len(body.encode("utf-8"))))

    removed = prune(outdir) if a.prune else 0
    for n, sz in wrote:
        print("  %s  %d B" % (n, sz))
    print("[mktide] 锚点 sha=%s  写入 %d 个%s"
          % (sha[:12], len(wrote), ("  清理 %d 个旧窗口" % removed) if removed else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
