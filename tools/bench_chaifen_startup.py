#!/usr/bin/env python3
"""拆字滤镜 A/B 冷启动耗时对比：进程墙钟 + 探针记录的首键耗时。

「收益」假设里有一条「少一个 Lua 滤镜 → 启动更轻」，代价假设是 OpenCC
3.2MB 字典加载。两个口径：
  wall_s   探针进程总耗时（librime 初始化 + 维护检查 + schema 加载 + 打字）
           —— rounds 固定，墙钟差即加载差。
  first_us 探针内预热后第一键耗时（OpenCC 字典首次 Apply / Lua 滤镜首次
           init 的残余部分；不是完整加载口径，仅作参考）。

交错 A/B、交替先后顺序、独立进程，取中位数。

用法：
  python3 tools/bench_chaifen_startup.py --user /tmp/cf_test/user \
      --bench /tmp/bench_chaifen [--repeat 7] [--json /tmp/cf_startup.json]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from bench_chaifen import (DEFAULT_PLUGIN, DEFAULT_SHARED, GROUPS, run,  # noqa: E402
                           set_option)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", default="/tmp/cf_test/user")
    ap.add_argument("--shared", default=DEFAULT_SHARED)
    ap.add_argument("--plugin", default=DEFAULT_PLUGIN)
    ap.add_argument("--bench", default="/tmp/bench_chaifen")
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--repeat", type=int, default=7)
    ap.add_argument("--json", default="")
    args = ap.parse_args()

    if not pathlib.Path(args.bench).exists():
        sys.exit("缺少 bench_chaifen 探针")
    user = pathlib.Path(args.user)
    originals = {p.name: p.read_text(encoding="utf-8")
                 for p in user.glob("*.options.yaml")}
    samples: dict[str, dict[str, list[float]]] = {}
    try:
        for a, b, keys, label in GROUPS:
            for schema in (a, b):
                samples.setdefault(schema, {"wall": [], "first": []})
            for i in range(args.repeat):
                order = (a, b) if i % 2 == 0 else (b, a)
                for schema in order:
                    set_option(user, schema, True)
                    t0 = time.perf_counter()
                    r = run(args.bench, args.user, args.shared, args.plugin,
                            schema, keys, args.rounds)
                    samples[schema]["wall"].append(
                        (time.perf_counter() - t0) * 1000)
                    samples[schema]["first"].append(r["first_key_us"])
    finally:
        for name, content in originals.items():
            (user / name).write_text(content, encoding="utf-8")

    print(f"{'场景':<14}{'版本':<8}{'墙钟中位(ms)':>12}{'墙钟区间':>16}"
          f"{'首键中位(us)':>12}")
    rows = []
    for a, b, _, label in GROUPS:
        for schema, tag in ((a, "Lua"), (b, "OpenCC")):
            wall = samples[schema]["wall"]
            first = samples[schema]["first"]
            rows.append({
                "group": label, "schema": schema, "version": tag,
                "wall_ms_median": round(statistics.median(wall), 1),
                "wall_ms_range": [round(min(wall), 1), round(max(wall), 1)],
                "first_key_us_median": round(statistics.median(first), 1),
                "runs": len(wall),
            })
            print(f"{label:<14}{tag:<8}{statistics.median(wall):>12.1f}"
                  f"{f'{min(wall):.0f}~{max(wall):.0f}':>16}"
                  f"{statistics.median(first):>12.1f}")
    print("\nA/B 启动对比（负值 = OpenCC 更快）：")
    for a, b, _, label in GROUPS:
        ra = next(r for r in rows if r["schema"] == a)
        rb = next(r for r in rows if r["schema"] == b)
        print(f"  {label}: 墙钟差 {rb['wall_ms_median'] - ra['wall_ms_median']:+.1f}ms"
              f"（Lua {ra['wall_ms_median']:.0f} → OpenCC {rb['wall_ms_median']:.0f}）")
    if args.json:
        pathlib.Path(args.json).write_text(
            json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"\n数据 → {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
