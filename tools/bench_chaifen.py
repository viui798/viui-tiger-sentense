#!/usr/bin/env python3
"""拆字滤镜 A/B 性能对比驱动：调 tools/bench_chaifen.cpp 编译出的探针。

每个组合独立进程（避免 OpenCC 字典缓存与 Lua GC 状态互相污染），
重复若干次取 median 的中位数。开关通过隔离目录的 *.options.yaml 切换，
因为 option_persist 会在每次按键前重放，set_option 压不住。

用法：
  python3 tools/bench_chaifen.py --user /tmp/cf_test/user \
      --bench /tmp/bench_chaifen [--repeat 3] [--json /tmp/cf_perf.json]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import subprocess
import sys

DEFAULT_SHARED = "/Library/Input Methods/Squirrel.app/Contents/SharedSupport"
DEFAULT_PLUGIN = (
    "/Library/Input Methods/Squirrel.app/Contents/Frameworks/"
    "rime-plugins/librime-lua.dylib"
)

# (A 方案, B 方案, 回放按键串, 说明)
GROUPS = [
    ("tiger", "tiger_cc", "unidotstuja", "虎单：单字码流"),
    ("tigress", "tigress_cc", "tujafijgkrnv", "虎词：多字词码流"),
    ("tiger_sentence", "tiger_sentence_cc", "unidotstujafijg", "虎整句：连续码流"),
]


def set_option(user: pathlib.Path, schema: str, on: bool) -> None:
    (user / f"{schema}.options.yaml").write_text(
        f"options:\n  chaifen: {'true' if on else 'false'}\n", encoding="utf-8")


def run(bench: str, user: str, shared: str, plugin: str,
        schema: str, keys: str, rounds: int, segments: int | None = None) -> dict:
    cmd = [bench, user, shared, plugin, schema, keys, str(rounds)]
    if segments:
        cmd.append(f"segments={segments}")
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if proc.returncode != 0:
        raise RuntimeError(f"{schema}: {proc.stderr[-300:]}")
    return json.loads(proc.stdout.strip().splitlines()[-1])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", default="/tmp/cf_test/user")
    ap.add_argument("--shared", default=DEFAULT_SHARED)
    ap.add_argument("--plugin", default=DEFAULT_PLUGIN)
    ap.add_argument("--bench", default="/tmp/bench_chaifen")
    ap.add_argument("--rounds", type=int, default=50)
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--json", default="")
    args = ap.parse_args()

    user = pathlib.Path(args.user)
    if not pathlib.Path(args.bench).exists():
        sys.exit("缺少 bench_chaifen 探针")
    # 记录原有开关状态，结束后恢复。
    originals = {p.name: p.read_text(encoding="utf-8")
                 for p in user.glob("*.options.yaml")}
    rows = []
    try:
        for a, b, keys, label in GROUPS:
            for on in (True, False):
                # 交错 A/B 并交替先后顺序，抵消机器负载随时间漂移。
                samples: dict[str, list[dict]] = {a: [], b: []}
                for i in range(args.repeat):
                    order = (a, b) if i % 2 == 0 else (b, a)
                    for schema in order:
                        set_option(user, schema, on)
                        samples[schema].append(
                            run(args.bench, args.user, args.shared, args.plugin,
                                schema, keys, args.rounds))
                for schema in (a, b):
                    runs = samples[schema]
                    rows.append({
                        "group": label, "schema": schema, "on": on,
                        "keys": keys,
                        "median_us": round(statistics.median(r["median_us"] for r in runs), 1),
                        "p95_us": round(statistics.median(r["p95_us"] for r in runs), 1),
                        "mean_us": round(statistics.median(r["mean_us"] for r in runs), 1),
                        "spread_us": [round(min(r["median_us"] for r in runs), 1),
                                      round(max(r["median_us"] for r in runs), 1)],
                        "runs": len(runs),
                    })
    finally:
        for name, content in originals.items():
            (user / name).write_text(content, encoding="utf-8")

    print(f"{'场景':<16}{'方案':<22}{'开关':<6}{'中位(us)':>10}{'p95(us)':>10}"
          f"{'波动区间':>18}")
    for r in rows:
        lo, hi = r["spread_us"]
        print(f"{r['group']:<16}{r['schema']:<22}{'开' if r['on'] else '关':<6}"
              f"{r['median_us']:>10.1f}{r['p95_us']:>10.1f}"
              f"{f'{lo:.0f}~{hi:.0f}':>18}")
    print("\nA/B 对比（拆字开启）：")
    for a, b, _, label in GROUPS:
        ra = next(r for r in rows if r["schema"] == a and r["on"])
        rb = next(r for r in rows if r["schema"] == b and r["on"])
        delta = (rb["median_us"] - ra["median_us"]) / ra["median_us"] * 100
        off = next(r for r in rows if r["schema"] == a and not r["on"])
        cost_a = ra["median_us"] - off["median_us"]
        print(f"  {label}: Lua {ra['median_us']:.0f}us → OpenCC {rb['median_us']:.0f}us "
              f"({delta:+.1f}%)；Lua 滤镜自身约 {cost_a:+.0f}us/键")
    if args.json:
        pathlib.Path(args.json).write_text(
            json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"\n数据 → {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
