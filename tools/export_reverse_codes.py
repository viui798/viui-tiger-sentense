#!/usr/bin/env python3
"""把第三方拼音词库导成虎整句拼音反查码表（pinyin.qp.codes.txt）。

来源：dicts/pinyin_reverse.dict.yaml（text / 多音节 code / weight，按词频排序）。
产出：pinyin.qp.codes.txt（text<TAB>code，行序 = 组内 rank）。

规则：
  · 全拼：把多音节 code 的空格去掉（jiu shi -> jiushi）；
  · 简拼：多字词额外生成词首字母码（你好 -> nh，计算机 -> jsj）；
  · 不含辅助码；
  · 单字不做单键简拼（引擎结构性边界：多键输入中的单键边不参与组句）；
  · code 超过 24 字母的条目不导出（索引 key 槽位限制，原型已知取舍）。

用法: python3 tools/export_reverse_codes.py [repo_root]
"""
import sys
from pathlib import Path

REPO = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
SOURCE = REPO / "dicts/pinyin_reverse.dict.yaml"
OUTPUT = REPO / "pinyin.qp.codes.txt"
KEY_LEN = 24


def main():
    rows = []
    dropped_long = 0
    in_body = False
    for line in SOURCE.read_text(encoding="utf-8").splitlines():
        if not in_body:
            if line.strip() == "...":
                in_body = True
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        word, raw = parts[0].strip(), parts[1].strip().lower()
        if not word or not raw:
            continue
        syllables = [s for s in raw.split(" ") if s]
        if not syllables or not all(s.isascii() and s.isalpha() for s in syllables):
            continue
        full = "".join(syllables)
        codes = [full]
        if len(syllables) >= 2:
            initials = "".join(s[0] for s in syllables)
            if initials != full:
                codes.append(initials)
        for code in codes:
            if len(code) <= KEY_LEN:
                rows.append((word, code))
            else:
                dropped_long += 1
    if not in_body:
        sys.exit(f"missing '...' body marker in {SOURCE}")

    seen = set()
    entries = []
    dropped_long = 0
    for word, code in rows:
        key = (word, code)
        if key in seen:
            continue
        seen.add(key)
        entries.append(f"{word}\t{code}")
    # 上面已在生成时过滤超长 code；这里只是统计来源规模。
    total = len(rows)

    header = [
        "# 拼音反查引擎码表（tools/export_reverse_codes.py 生成，勿手改）",
        "# 来源：dicts/pinyin_reverse.dict.yaml（第三方拼音词库）",
        "# 全拼（音节拼接）+ 多字词首字母简拼；不含辅助码。行序 = 组内 rank。",
    ]
    OUTPUT.write_text("\n".join(header + entries) + "\n", encoding="utf-8")
    print(f"source rows: {total} | unique entries: {len(entries)} | "
          f"dropped-long: {dropped_long} -> {OUTPUT}")


if __name__ == "__main__":
    main()
