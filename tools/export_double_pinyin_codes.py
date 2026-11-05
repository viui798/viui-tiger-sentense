#!/usr/bin/env python3
"""生成双拼专用反查码表（键串 -> 全拼码），只含整音节词条。

来源：dicts/pinyin_reverse.dict.yaml（code 列是空格分隔的音节）
输出：pinyin.<scheme>.codes.txt（keys<TAB>全拼码<TAB>权重）

为什么不用运行时转换：运行时把按键转成全拼时，任何“残余字母兜底”都会把
简拼/全拼词混进双拼候选。查表则是精确匹配，结构上不可能出现。

用法：python3 tools/export_double_pinyin_codes.py flypy
"""
import argparse
import collections
import re
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
KEYMAPS = REPO / "lua" / "pinyin_keymaps.lua"
SOURCE = REPO / "dicts" / "pinyin_reverse.dict.yaml"


def load_units(scheme):
    text = KEYMAPS.read_text(encoding="utf-8")
    m = re.search(rf"{scheme}\s*=\s*\{{(.*?)\n  \}},", text, re.S)
    if not m:
        raise SystemExit(f"找不到 {scheme} 的 units")
    return dict(re.findall(r'\["([^"]+)"\]="([^"]+)"', m.group(1)))


def canonical_map(units):
    """音节 -> 唯一的双拍键。规则：优先两键、优先首字母与音节相同的写法。"""
    grouped = collections.defaultdict(list)
    for key, syl in units.items():
        grouped[syl].append(key)

    chosen = {}
    for syl, keys in grouped.items():
        def rank(k):
            return (len(k) != 2, not k.startswith(syl[:1]), k)
        chosen[syl] = sorted(keys, key=rank)[0]
    return chosen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scheme", choices=["flypy", "zrm", "mspy", "sogou", "qp"])
    parser.add_argument("--out", default=None)
    args = parser.parse_args()
    scheme = args.scheme
    if scheme == "qp":
        raise SystemExit("全拼不需要专用表（沿用 pinyin.qp.codes.txt）")

    units = load_units(scheme)
    key_of = canonical_map(units)
    out_path = Path(args.out) if args.out else REPO / f"pinyin.{scheme}.codes.txt"

    rows = {}
    skipped = 0
    for line in SOURCE.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#") or line.startswith("---"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        text, code = parts[0], parts[1]
        if not re.fullmatch(r"[a-z ]+", code):
            continue
        syllables = code.split()
        keys = []
        ok = True
        for syl in syllables:
            k = key_of.get(syl)
            if not k:
                ok = False
                break
            keys.append(k)
        if not ok:
            skipped += 1
            continue
        weight = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0
        key = "".join(keys)
        full = "".join(syllables)
        prev = rows.get((key, full))
        if prev is None or weight > prev:
            rows[(key, full)] = weight

    ordered = sorted(rows.items(), key=lambda kv: (-kv[1], kv[0][0], kv[0][1]))
    with out_path.open("w", encoding="utf-8") as fh:
        fh.write(f"# {scheme} 双拼专用反查码表（tools/export_double_pinyin_codes.py 生成，勿手改）\n")
        fh.write("# 来源：dicts/pinyin_reverse.dict.yaml；只含整音节词条，无简拼行。\n")
        fh.write("# 格式：全拼码<TAB>双拼键串<TAB>权重（与 pinyin.qp.codes.txt 同结构，\n")
        fh.write("# 便于 build_pinyin_codes_index.py 直接建索引；双拼键串就是索引的 code）。\n")
        for (key, full), weight in ordered:
            fh.write(f"{full}\t{key}\t{weight}\n")
    print(f"{scheme}: {len(ordered)} 条 -> {out_path}（跳过 {skipped} 条缺音节词条）")


if __name__ == "__main__":
    main()
