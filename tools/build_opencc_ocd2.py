#!/usr/bin/env python3
"""把 opencc/ 下的文本字典预编译成 .ocd2（运行时加载更快）。

用法：
    python3 tools/build_opencc_ocd2.py .            # 生成/更新
    python3 tools/build_opencc_ocd2.py . --check    # 只检查产物是否存在

依赖 OpenCC 的 opencc_dict 工具（macOS: brew install opencc；
Windows/Linux 需把 opencc_dict 放进 PATH，或用 --opencc-dict 指定路径）。

注意：改动了 opencc/*.txt 之后必须重新执行本脚本，否则 .ocd2 会和源表漂移。
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

DICTS = ("emoji", "PYPhrases", "PYCharacters")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", nargs="?", default=".", help="仓库根目录")
    parser.add_argument("--opencc-dict", help="opencc_dict 可执行文件路径")
    parser.add_argument("--check", action="store_true", help="只检查产物，不重新生成")
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    opencc_dir = repo / "opencc"
    if not opencc_dir.is_dir():
        sys.exit(f"✗ 找不到目录：{opencc_dir}")

    targets = []
    for name in DICTS:
        src = opencc_dir / f"{name}.txt"
        dst = opencc_dir / f"{name}.ocd2"
        if not src.exists():
            sys.exit(f"✗ 缺少源字典：{src}")
        targets.append((src, dst))

    if args.check:
        failed = False
        for src, dst in targets:
            if not dst.exists() or dst.stat().st_size == 0:
                print(f"✗ 缺少产物：{dst}")
                failed = True
            elif dst.stat().st_mtime < src.stat().st_mtime:
                print(f"✗ 产物比源文件旧，需要重新生成：{dst}")
                failed = True
            else:
                print(f"✓ {dst.name}  {dst.stat().st_size} bytes")
        sys.exit(1 if failed else 0)

    tool = args.opencc_dict or shutil.which("opencc_dict")
    if not tool:
        sys.exit("✗ 找不到 opencc_dict；请安装 OpenCC 或用 --opencc-dict 指定路径")

    for src, dst in targets:
        print(f"生成 {dst.name} ...")
        subprocess.run([tool, "-i", str(src), "-o", str(dst), "-f", "text", "-t", "ocd2"],
                       check=True)
        if not dst.exists() or dst.stat().st_size == 0:
            sys.exit(f"✗ 生成失败：{dst}")
        print(f"  {dst.name}  {dst.stat().st_size} bytes")


if __name__ == "__main__":
    main()
