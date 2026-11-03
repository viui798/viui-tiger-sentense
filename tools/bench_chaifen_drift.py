#!/usr/bin/env python3
"""拆字滤镜 A/B 长会话漂移对比：检验「Lua 滤镜累积 GC 债务」假设。

每个样本 = 独立进程内一次性连打 ~1500 键（rounds × 码流），探针按每
segments=N 键输出分段中位数。若 Lua 滤镜的分配随会话变长而放大
（堆增长 → GC 扫描变贵），A 版分段中位数应相对 B 版持续上漂；
两版都平则说明「少 Lua/少 GC」在本机没有可测的累积收益。

拆字开关全程开启（被测对象就是滤镜本身的长期行为）。
交错 A/B 并交替先后顺序，抵消机器负载漂移。

用法：
  python3 tools/bench_chaifen_drift.py --user /tmp/cf_test/user \
      --bench /tmp/bench_chaifen [--repeat 5] [--rounds 100] [--segments 200] \
      [--json /tmp/cf_drift.json]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from bench_chaifen import (DEFAULT_PLUGIN, DEFAULT_SHARED, GROUPS, run,  # noqa: E402
                           set_option)


def slope_us_per_100keys(segments: list[float], segment_size: int) -> float:
    """最小二乘斜率，换算成每 100 键的中位数变化（微秒）。"""
    n = len(segments)
    if n < 2:
        return 0.0
    xs = [(i + 0.5) * segment_size for i in range(n)]
    mx, my = sum(xs) / n, sum(segments) / n
    denom = sum((x - mx) ** 2 for x in xs)
    if denom == 0:
        return 0.0
    k = sum((x - mx) * (y - my) for x, y in zip(xs, segments)) / denom
    return k * 100.0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", default="/tmp/cf_test/user")
    ap.add_argument("--shared", default=DEFAULT_SHARED)
    ap.add_argument("--plugin", default=DEFAULT_PLUGIN)
    ap.add_argument("--bench", default="/tmp/bench_chaifen")
    ap.add_argument("--rounds", type=int, default=100)
    ap.add_argument("--segments", type=int, default=200)
    ap.add_argument("--repeat", type=int, default=5)
    ap.add_argument("--json", default="")
    args = ap.parse_args()

    if not pathlib.Path(args.bench).exists():
        sys.exit("缺少 bench_chaifen 探针（先编译：g++ -std=c++17 -O2 "
                 "tools/bench_chaifen.cpp -I<rime头文件> -lrime.1 …）")
    user = pathlib.Path(args.user)
    originals = {p.name: p.read_text(encoding="utf-8")
                 for p in user.glob("*.options.yaml")}
    samples: dict[str, dict[str, list]] = {}
    try:
        for a, b, keys, label in GROUPS:
            for schema in (a, b):
                samples.setdefault(schema, {"segs": [], "first": []})
            for i in range(args.repeat):
                order = (a, b) if i % 2 == 0 else (b, a)
                for schema in order:
                    set_option(user, schema, True)  # 拆字开：测滤镜本身
                    r = run(args.bench, args.user, args.shared, args.plugin,
                            schema, keys, args.rounds, args.segments)
                    samples[schema]["segs"].append(r["segments"])
                    samples[schema]["first"].append(r["first_key_us"])
    finally:
        for name, content in originals.items():
            (user / name).write_text(content, encoding="utf-8")

    total_keys = args.rounds * len(GROUPS[0][2])  # 近似，用于说明
    print(f"每样本 ≈ {args.rounds} 轮码流；分段 {args.segments} 键；"
          f"重复 {args.repeat}；拆字开启\n")
    print(f"{'场景':<14}{'版本':<8}{'首段中位':>10}{'末段中位':>10}"
          f"{'漂移(us/百键)':>14}{'段间波动':>14}")
    rows = []
    for a, b, keys, label in GROUPS:
        for schema, tag in ((a, "Lua"), (b, "OpenCC")):
            runs = samples[schema]["segs"]
            n = min(len(s) for s in runs)
            med = [statistics.median(s[i] for s in runs) for i in range(n)]
            slopes = [slope_us_per_100keys(s, args.segments) for s in runs]
            rows.append({
                "group": label, "schema": schema, "version": tag,
                "first_seg": round(med[0], 1),
                "last_seg": round(med[-1], 1),
                "drift_us_per_100keys": round(statistics.median(slopes), 2),
                "segment_medians": [round(v, 1) for v in med],
                "first_key_us": round(statistics.median(samples[schema]["first"]), 1),
            })
            print(f"{label:<14}{tag:<8}{med[0]:>10.1f}{med[-1]:>10.1f}"
                  f"{statistics.median(slopes):>14.2f}"
                  f"{f'{min(med):.0f}~{max(med):.0f}':>14}")
    print("\nA/B 漂移差（OpenCC − Lua，负值 = OpenCC 更平）：")
    for a, b, _, label in GROUPS:
        ra = next(r for r in rows if r["schema"] == a)
        rb = next(r for r in rows if r["schema"] == b)
        diff = rb["drift_us_per_100keys"] - ra["drift_us_per_100keys"]
        trend_a = "上漂" if ra["drift_us_per_100keys"] > 5 else (
            "下漂" if ra["drift_us_per_100keys"] < -5 else "平稳")
        trend_b = "上漂" if rb["drift_us_per_100keys"] > 5 else (
            "下漂" if rb["drift_us_per_100keys"] < -5 else "平稳")
        print(f"  {label}: Lua {ra['drift_us_per_100keys']:+.2f}（{trend_a}）"
              f" OpenCC {rb['drift_us_per_100keys']:+.2f}（{trend_b}）"
              f" → 差 {diff:+.2f} us/百键")
    if args.json:
        pathlib.Path(args.json).write_text(
            json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"\n数据 → {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
