#!/usr/bin/env python3
"""贴近真实使用的补充检查：多滤镜注释叠加、关开关行为、冷启动首键。

compare_chaifen.py 只开 chaifen 一个开关，而实际输入时用户可能同时开
拼音提示 / emoji / 字符集提示。本脚本把这些一起打开，检查 A/B 是否仍等价，
并顺带测量「部署后第一键」的冷启动耗时。

用法：
  python3 tools/check_chaifen_realuse.py --user /tmp/cf_test/user \
      --snapshot /tmp/snapshot --bench /tmp/bench_chaifen [--repeat 3]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import subprocess
import sys

from compare_chaifen import DEFAULT_SHARED, DEFAULT_PLUGIN, compare, run_snapshot

CASES = [
    ("虎单 单字", "tiger", "tiger_cc", "unid"),
    ("虎词 多字词", "tigress", "tigress_cc", "tuja"),
    ("反查", "tiger", "tiger_cc", "`nihao"),
    ("虎整句 长句", "tiger_sentence", "tiger_sentence_cc", "unidotstujafijgkrnv"),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", default="/tmp/cf_test/user")
    ap.add_argument("--shared", default=DEFAULT_SHARED)
    ap.add_argument("--plugin", default=DEFAULT_PLUGIN)
    ap.add_argument("--snapshot", default="/tmp/snapshot")
    ap.add_argument("--bench", default="/tmp/bench_chaifen")
    ap.add_argument("--repeat", type=int, default=3)
    args = ap.parse_args()

    user = pathlib.Path(args.user)
    originals = {p.name: p.read_text(encoding="utf-8")
                 for p in user.glob("*.options.yaml")}

    def set_options(schema: str, opts: dict) -> None:
        body = "options:\n" + "".join(
            f"  {k}: {'true' if v else 'false'}\n" for k, v in opts.items())
        (user / f"{schema}.options.yaml").write_text(body, encoding="utf-8")

    total = 0
    try:
        on = dict(chaifen=True, pinyin=True, emoji_cn=True,
                  charset_comment_filter=True)
        off = dict(on, chaifen=False)
        for title, opts in [("多滤镜叠加（拆字+拼音+emoji+字符集）", on),
                            ("拆字开关关闭（其余保持开）", off)]:
            print(f"\n========== {title} ==========")
            for label, a, b, keys in CASES:
                for schema in (a, b):
                    set_options(schema, opts)
                la = run_snapshot(args.snapshot, args.user, args.shared,
                                  args.plugin, a, keys)
                lb = run_snapshot(args.snapshot, args.user, args.shared,
                                  args.plugin, b, keys)
                diffs = compare(la, lb)
                total += len(diffs)
                print(f"\n### {label}  差异={len(diffs)}")
                for name, line in (("A/Lua ", la[-1]), ("B/CC  ", lb[-1])):
                    for text, comment in line["candidates"][:3]:
                        print(f"  {name} {text!r} → {comment!r}")
                for d in diffs[:6]:
                    print("  DIFF", d)

        print("\n========== 冷启动首键（μs，各取中位） ==========")
        for label, a, b, keys in CASES:
            vals = {}
            for schema in (a, b):
                set_options(schema, dict(chaifen=True))
                samples = []
                for _ in range(args.repeat):
                    p = subprocess.run(
                        [args.bench, args.user, args.shared, args.plugin,
                         schema, keys, "6"],
                        capture_output=True, text=True, timeout=600)
                    samples.append(json.loads(p.stdout.strip())["first_key_us"])
                vals[schema] = round(statistics.median(samples))
            print(f"  {label:<16} A/Lua {vals[a]:>8}   B/CC {vals[b]:>8}   "
                  f"差 {vals[b] - vals[a]:+}")
        print(f"\n叠加场景总差异 = {total}")
    finally:
        for name, content in originals.items():
            (user / name).write_text(content, encoding="utf-8")
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main())
