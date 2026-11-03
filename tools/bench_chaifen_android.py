#!/usr/bin/env python3
"""拆字滤镜 A/B 性能对比——安卓端（同文/芝版同文模拟器）。

与 tools/bench_chaifen.py（macOS 鼠须管）同一方法论：A 版 Lua 滤镜、B 版
simplifier@chaifen（_cc 方案），交错 A/B 交替先后、独立进程取中位数。
区别：
  * 探针与数据通过 adb 推到 /data/local/tmp/cf（见评估文档 §8），探针静态
    链接、dlopen 同文的 librime_jni.so（librime + Lua 5.4 插件 + OpenCC 内嵌）。
  * 开关仍写 *.options.yaml（option_persist 每键重放，set_option 压不住）。
  * 只跑 tiger / tigress 两组：虎整句的 405MB 模型不进这次实验——安卓上引擎
    开销只会更彻底地淹没滤镜成本，单字/词组两组足以回答「滤镜本身贵不贵」。

设备侧准备（一次性）：
  adb push <探针 arm64> /data/local/tmp/cf/bench_chaifen
  adb push <librime_jni.so> /data/local/tmp/cf/
  adb push <shared/> <user/>   # user = cf_test/user 去掉 build/models/docs 并实体化

用法：
  python3 tools/bench_chaifen_android.py --repeat 5 --json /tmp/cf_android_perf.json
"""

from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import subprocess
import sys

ADB = str(next(iter(sorted(
    pathlib.Path.home().glob("Desktop/芝版同文/toolchain/android-sdk/platform-tools/adb")))))

DEVICE_DIR = "/data/local/tmp/cf"
DEFAULT_PLUGIN_DEVICE = f"{DEVICE_DIR}/librime_jni.so"

# (A 方案, B 方案, 回放按键串, 说明)；不含 tiger_sentence，理由见模块注释。
GROUPS = [
    ("tiger", "tiger_cc", "unidotstuja", "虎单：单字码流"),
    ("tigress", "tigress_cc", "tujafijgkrnv", "虎词：多字词码流"),
]


def adb_lines(cmd: str, timeout: int = 600) -> list[str]:
    proc = subprocess.run([ADB, "shell", cmd], capture_output=True, text=True,
                          timeout=timeout)
    if proc.returncode != 0:
        raise RuntimeError(f"adb shell 失败: {cmd}\n{proc.stderr[-300:]}")
    return proc.stdout.splitlines()


def device_run(schema: str, keys: str, rounds: int) -> dict:
    cmd = (f"cd {DEVICE_DIR} && LD_LIBRARY_PATH={DEVICE_DIR} "
           f"./bench_chaifen {DEVICE_DIR}/user {DEVICE_DIR}/shared "
           f"{DEFAULT_PLUGIN_DEVICE} {schema} '{keys}' {rounds}")
    out = adb_lines(cmd)
    json_lines = [l for l in out if l.strip().startswith("{")]
    if not json_lines:
        raise RuntimeError(f"{schema}: 无 JSON 输出\n" + "\n".join(out[-5:]))
    return json.loads(json_lines[-1])


def set_option(schema: str, on: bool) -> None:
    value = "true" if on else "false"
    adb_lines(f"printf 'options:\\n  chaifen: {value}\\n' > "
              f"{DEVICE_DIR}/user/{schema}.options.yaml")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rounds", type=int, default=50)
    ap.add_argument("--repeat", type=int, default=5)
    ap.add_argument("--json", default="")
    args = ap.parse_args()

    rows = []
    for a, b, keys, label in GROUPS:
        for on in (True, False):
            samples: dict[str, list[dict]] = {a: [], b: []}
            for i in range(args.repeat):
                order = (a, b) if i % 2 == 0 else (b, a)
                for schema in order:
                    set_option(schema, on)
                    samples[schema].append(device_run(schema, keys, args.rounds))
            for schema in (a, b):
                runs = samples[schema]
                rows.append({
                    "group": label, "schema": schema, "on": on, "keys": keys,
                    "median_us": round(statistics.median(r["median_us"] for r in runs), 1),
                    "p95_us": round(statistics.median(r["p95_us"] for r in runs), 1),
                    "mean_us": round(statistics.median(r["mean_us"] for r in runs), 1),
                    "spread_us": [round(min(r["median_us"] for r in runs), 1),
                                  round(max(r["median_us"] for r in runs), 1)],
                    "runs": len(runs),
                })

    print(f"{'场景':<14}{'方案':<12}{'开关':<6}{'中位(us)':>10}{'p95(us)':>10}"
          f"{'波动区间':>18}")
    for r in rows:
        lo, hi = r["spread_us"]
        print(f"{r['group']:<14}{r['schema']:<12}{'开' if r['on'] else '关':<6}"
              f"{r['median_us']:>10.1f}{r['p95_us']:>10.1f}"
              f"{f'{lo:.0f}~{hi:.0f}':>18}")
    print("\nA/B 对比（拆字开启，安卓 arm64 模拟器）：")
    for a, b, _, label in GROUPS:
        ra = next(r for r in rows if r["schema"] == a and r["on"])
        rb = next(r for r in rows if r["schema"] == b and r["on"])
        delta = (rb["median_us"] - ra["median_us"]) / ra["median_us"] * 100
        off = next(r for r in rows if r["schema"] == a and not r["on"])
        cost_a = ra["median_us"] - off["median_us"]
        cost_b = rb["median_us"] - next(
            r["median_us"] for r in rows if r["schema"] == b and not r["on"])
        print(f"  {label}: Lua {ra['median_us']:.0f}us → OpenCC {rb['median_us']:.0f}us "
              f"({delta:+.1f}%)；开-关差 Lua {cost_a:+.0f}us / OpenCC {cost_b:+.0f}us")
    if args.json:
        pathlib.Path(args.json).write_text(
            json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"\n数据 → {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
