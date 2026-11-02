#!/usr/bin/env python3
"""把 pinyin.qp.codes.txt 导出为分页索引（原型）。

产物（写到 models/，不进测试夹具副本）：
  models/pinyin.codes.idx   排序 code 表 + 每段在 dat 中的起点/条数
  models/pinyin.codes.dat   每条 8 字节：text_off(u32) text_len(u16) flags(u8)
  models/pinyin.codes.pool  所有候选文本拼接（UTF-8）

flags: bit0 = optimal_single，bit1 = primary_single。拼音实例没有 char_ranks /
whitelist，因此 whole_single_reward_eligible 恒为 true，不占位。

idx 格式：
  8s magic "PCOD0001"
  I4 code_count
  I4 entry_count
  H  max_code_len
  H  lengths_count
  B* lengths_count          # 1..max_code_len 中存在的长度
  记录 code_count 条，每条 32 字节：
    24s key（NUL 填充）
    I4  entry_offset
    H   entry_count
"""
import argparse
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
KEY_LEN = 24


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default=str(REPO / "pinyin.qp.codes.txt"))
    parser.add_argument("--out-dir", default=str(REPO / "models"))
    args = parser.parse_args()
    source = Path(args.source)
    out = Path(args.out_dir)
    lines = []
    for line in source.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        word, code = parts[0], parts[1].lower()
        if not code.isascii() or not code.isalpha():
            continue
        if len(code) > KEY_LEN:
            continue
        lines.append((word, code))
    if not lines:
        sys.exit("empty code table")

    by_code = {}
    dict_first = {}
    codes_by_character = {}
    for word, code in lines:
        by_code.setdefault(code, []).append(word)
        if dict_first.get(code) is None:
            dict_first[code] = word
        if len(word) == 1:
            codes_by_character.setdefault(word, []).append(code)

    primary = {}
    optimal = {}
    for character, codes in codes_by_character.items():
        best_first = best_any = None
        for code in codes:
            if len(code) >= 2:
                if best_any is None or len(code) < len(best_any):
                    best_any = code
                if dict_first.get(code) == character:
                    if best_first is None or len(code) < len(best_first):
                        best_first = code
        chosen = best_first or best_any
        if chosen:
            primary[character] = chosen
        shortest = None
        for code in codes:
            if shortest is None or len(code) < len(shortest):
                shortest = code
        if shortest:
            optimal[character] = shortest

    assert max(len(code) for _, code in lines) <= KEY_LEN, "code longer than key slot"

    codes = sorted(by_code)
    lengths = sorted({len(code) for code in codes})
    dat = bytearray()
    pool = bytearray()
    records = []
    for code in codes:
        words = by_code[code]
        records.append((code, len(dat) // 8, len(words)))
        for word in words:
            flags = 0
            if optimal.get(word) == code:
                flags |= 1
            if primary.get(word) == code:
                flags |= 2
            dat += struct.pack("<IHBx", len(pool), len(word.encode("utf-8")), flags)
            pool += word.encode("utf-8")

    header = b"PCOD0001" + struct.pack("<IIHH", len(codes), len(dat) // 8,
                                       max(lengths), len(lengths))
    header += bytes(lengths)
    body = bytearray()
    for code, offset, count in records:
        body += code.encode("latin-1").ljust(KEY_LEN, b"\0")
        body += struct.pack("<IH", offset, count)
        body += b"\0\0"  # pad to 32

    out.mkdir(parents=True, exist_ok=True)
    (out / "pinyin.codes.idx").write_bytes(header + body)
    (out / "pinyin.codes.dat").write_bytes(dat)
    (out / "pinyin.codes.pool").write_bytes(pool)
    print(f"codes={len(codes)} entries={len(dat)//8} "
          f"idx={len(header)+len(body)} dat={len(dat)} pool={len(pool)}")


if __name__ == "__main__":
    main()
