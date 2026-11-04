#!/usr/bin/env python3
"""生成两个 tag 之间的增量更新包（只含运行时文件）。

用法：
    python3 tools/make_release_delta.py <from_ref> <to_ref> <out_zip>

例：
    python3 tools/make_release_delta.py v0.3.22 v0.3.23 /tmp/cheese-tiger-v0.3.23-update.zip

输出 zip 结构：
    update/DELTA.json
    update/<变更的运行时文件...>

规则：
  · 只打包运行时资产（lua/ opencc/ models/ dicts/ 等 + 根目录 yaml/txt/json），
    不含 docs/ tools/ sync/ validation/ 手机精简版/ 等开发资料；
  · 删除的文件只写入 DELTA.json 的 deletions，不打包；
  · 若变更涉及 Git LFS 大模型，标记 full_required，不把 400MB 模型塞进增量包；
  · 用户数据（*.userdb、*.options.yaml、user.yaml、统计等）不进增量包。
"""

import hashlib
import json
import os
import subprocess
import sys
import time
import zipfile
from pathlib import PurePosixPath

RUNTIME_DIRS = ("lua/", "opencc/", "models/", "dicts/", "tiger_dicts/", "zuci/")
EXCLUDE_DIRS = ("tools/", "docs/", "sync/", "validation/", "手机精简版/", "build/")
EXCLUDE_FILES = {
    "AGENTS.md", "README.md", "CHANGELOG.md", "LICENSE", "安装说明.txt",
    "安装与更新说明.txt", "RELEASE.json", "SHA256SUMS.txt",
    "SOURCE_BASELINE.md", "RIME_CORRECTNESS.md", "IOS_TEST_README.md",
}
EXCLUDE_SEGMENTS = (
    "wanxiang_pro", "dicts/jichu.pro", "dicts/lianxiang.pro", "dicts/shici.pro",
    "dicts/diming.pro", "dicts/duoyin.pro", "dicts/zi.pro", "dicts/cuoyin.pro",
    "zuci/moegirl", "zuci/ext", "opencc/hu_cf",
)
USER_DATA_SUFFIXES = (".userdb", ".options.yaml", ".log")
USER_DATA_FILES = {"user.yaml", "installation.yaml", "reverse_freq.txt", "custom_phrase.txt"}


def git(*args):
    return subprocess.run(["git", "-c", "core.quotepath=false", *args],
                          capture_output=True, text=True, check=True).stdout


def is_runtime(path):
    p = PurePosixPath(path)
    if str(p).startswith(EXCLUDE_DIRS):
        return False
    if str(p) in EXCLUDE_FILES or p.name in EXCLUDE_FILES:
        return False
    if any(seg in path for seg in EXCLUDE_SEGMENTS):
        return False
    if any(part.endswith(".userdb") for part in p.parts):
        return False
    if p.name in USER_DATA_FILES or p.name.endswith(USER_DATA_SUFFIXES):
        return False
    if p.parent == PurePosixPath("lua") and p.name.startswith("input_stats_") and p.suffix == ".lua":
        return False
    if p.parent == PurePosixPath("lua") and p.name in {"kc_count.txt", "kc_total.txt"}:
        return False
    if p.suffix in {".md", ".zip", ".sha256"}:
        return False
    if str(p).startswith(RUNTIME_DIRS):
        return True
    # 根目录运行资产：schema / dict / custom / yaml / txt / json / lua
    return p.suffix in {".yaml", ".txt", ".json", ".lua"}


def lfs_paths(paths):
    if not paths:
        return set()
    proc = subprocess.run(["git", "-c", "core.quotepath=false",
                           "check-attr", "-z", "filter", "--", *paths],
                          capture_output=True, check=True)
    fields = proc.stdout.decode("utf-8", "surrogateescape").split("\0")
    found = set()
    for i in range(0, len(fields) - 2, 3):
        if fields[i + 1] == "filter" and fields[i + 2] == "lfs":
            found.add(fields[i])
    return found


def changed_entries(from_ref, to_ref):
    raw = subprocess.run(
        ["git", "-c", "core.quotepath=false", "diff", "--name-status", "-z", from_ref, to_ref],
        capture_output=True, check=True,
    ).stdout.decode("utf-8", "surrogateescape").split("\0")
    entries = []
    i = 0
    while i < len(raw):
        if not raw[i]:
            i += 1
            continue
        status = raw[i]
        if status.startswith("R") or status.startswith("C"):
            entries.append((status, raw[i + 1], raw[i + 2]))
            i += 3
        elif status.startswith("D"):
            entries.append((status, raw[i + 1], None))
            i += 2
        else:
            entries.append((status, raw[i + 1], raw[i + 1]))
            i += 2
    return entries


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    from_ref, to_ref, out_zip = sys.argv[1], sys.argv[2], os.path.abspath(sys.argv[3])
    repo = git("rev-parse", "--show-toplevel").strip()
    os.chdir(repo)

    entries = changed_entries(from_ref, to_ref)
    runtime = [(s, old, new) for s, old, new in entries
               if is_runtime(old) or (new and is_runtime(new))]
    lfs = lfs_paths([new or old for _, old, new in runtime])

    deletions = []
    files = []
    full_required = False

    for status, old, new in runtime:
        if status.startswith("D"):
            deletions.append(old)
            continue
        if status.startswith("R") or status.startswith("C"):
            if is_runtime(old):
                deletions.append(old)
        if new in lfs:
            # 大模型变更：增量包不塞 400MB，交给完整包
            full_required = True
            continue
        if is_runtime(new):
            files.append(new)

    files = sorted(set(files))
    deletions = sorted(set(deletions))

    stage = "/tmp/cheese-tiger-delta-stage"
    os.makedirs(stage, exist_ok=True)
    os.makedirs(os.path.join(stage, "update"), exist_ok=True)

    for rel in files:
        data = subprocess.run(["git", "show", f"{to_ref}:{rel}"],
                              capture_output=True, check=True).stdout
        dst = os.path.join(stage, "update", rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as fh:
            fh.write(data)

    manifest = {
        "from": from_ref,
        "to": to_ref,
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "full_required": full_required,
        "deletions": deletions,
        "files": files,
    }
    with open(os.path.join(stage, "update", "DELTA.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)

    os.makedirs(os.path.dirname(out_zip) or ".", exist_ok=True)
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for rel in files:
            z.write(os.path.join(stage, "update", rel), "update/" + rel)
        z.write(os.path.join(stage, "update", "DELTA.json"), "update/DELTA.json")

    digest = hashlib.sha256(open(out_zip, "rb").read()).hexdigest()
    with open(out_zip + ".sha256", "w", encoding="utf-8") as fh:
        fh.write(f"{digest}  {os.path.basename(out_zip)}\n")
    size = os.path.getsize(out_zip)
    print(f"{from_ref} -> {to_ref}")
    print(f"运行时文件 {len(files)} 个，删除 {len(deletions)} 个，full_required={full_required}")
    for rel in files:
        print(f"  + {rel}")
    for rel in deletions:
        print(f"  - {rel}")
    print(f"输出: {out_zip}")
    print(f"大小: {size} 字节")
    print(f"SHA256: {digest}")


if __name__ == "__main__":
    main()
