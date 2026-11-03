#!/usr/bin/env python3
"""从 tiger_lookup 词库导出 OpenCC 拆字字典，供 simplifier@chaifen 使用。

背景见 docs/想法-拆字滤镜改用OpenCC.md。

Lua 版（lua/chaifen.lua）对多字候选是「逐字查 tiger_lookup，再用单个空格连接」。
OpenCC 字典值不能含裸空格（空格是 OpenCC 多值分隔符），所以：
  - 值 = tiger_lookup 原文 + 尾随 "&nbsp;" 作为字间分隔；
  - schema 的 comment_format 依次执行 "xform/&nbsp;$//"（去掉最后一个分隔）
    与 "xform/&nbsp;/ /"（其余还原为空格）。
这样单字与多字的注释都与 Lua 版逐字一致，且 · 两侧保持无空格（本仓库数据原样）。

用法：
    python3 tools/export_chaifen_opencc.py [--source tiger_lookup.dict.yaml]
                                           [--out-dir opencc]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

SEP = "&nbsp;"
DICT_NAME = "hu_cf"

# 与秃版一致的结构：分词与转换共用同一份文本字典。
OPENCC_JSON = {
    "name": DICT_NAME,
    "segmentation": {"type": "mmseg", "dict": {"type": "text", "file": f"{DICT_NAME}.txt"}},
    "conversion_chain": [{"dict": {"type": "text", "file": f"{DICT_NAME}.txt"}}],
}


def read_lookup(path: pathlib.Path) -> list[tuple[str, str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.strip() == "...") + 1
    except StopIteration:
        sys.exit(f"{path}: 找不到 YAML 结束标记 ...")
    rows: list[tuple[str, str]] = []
    for line in lines[start:]:
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            sys.exit(f"{path}: 无法解析的行 {line!r}")
        char, comment = parts[0], parts[1]
        if len(char) != 1:
            sys.exit(f"{path}: {DICT_NAME} 应为纯单字词库，遇到 {char!r}")
        if " " in comment or "\t" in comment:
            sys.exit(f"{path}: {char} 的拆字含空白，OpenCC 字典不支持：{comment!r}")
        if SEP in comment:
            sys.exit(f"{path}: {char} 的拆字含保留串 {SEP}：{comment!r}")
        rows.append((char, comment))
    return rows


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default=str(root / "tiger_lookup.dict.yaml"))
    parser.add_argument("--out-dir", default=str(root / "opencc"))
    args = parser.parse_args()

    source = pathlib.Path(args.source)
    out_dir = pathlib.Path(args.out_dir)
    rows = read_lookup(source)

    seen: set[str] = set()
    dup: list[str] = []
    for char, _ in rows:
        if char in seen:
            dup.append(char)
        seen.add(char)
    if dup:
        # OpenCC 文本字典同 key 后行覆盖前行，静默覆盖会掩盖数据问题。
        sys.exit(f"{source}: 单字条目重复 {len(dup)} 个：{dup[:5]}")

    out_dir.mkdir(parents=True, exist_ok=True)
    txt_path = out_dir / f"{DICT_NAME}.txt"
    json_path = out_dir / f"{DICT_NAME}.json"

    # 固定顺序（沿用词库顺序）与 LF，保证可重复生成。
    with txt_path.open("w", encoding="utf-8", newline="\n") as fh:
        for char, comment in rows:
            fh.write(f"{char}\t{comment}{SEP}\n")
    json_path.write_text(
        json.dumps(OPENCC_JSON, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    total = txt_path.stat().st_size
    print(f"导出 {len(rows)} 条 → {txt_path} ({total / 1024:.1f} KiB)")
    print(f"OpenCC 配置 → {json_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
