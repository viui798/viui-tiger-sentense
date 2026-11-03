#!/usr/bin/env python3
"""阶段1A：tiger_sentence 滤镜/开关逐个成本矩阵。

基线 = 现网默认（辅助滤镜全关）；每轮单独打开一个开关测增量。
开关写 tiger_sentence.options.yaml（M.options 每键重放，无需重部署）。
探针 = /tmp/bench_chaifen（链接鼠须管 librime 1.16）。
"""
import json, pathlib, statistics, subprocess, sys

USER = "/tmp/audit2411/user"
SHARED = "/Library/Input Methods/Squirrel.app/Contents/SharedSupport"
PLUGIN = "/Library/Input Methods/Squirrel.app/Contents/Frameworks/rime-plugins/librime-lua.dylib"
BENCH = "/tmp/bench_chaifen"
SCHEMA = "tiger_sentence"

STREAMS = [
    ("单字流", "unidotstuja"),
    ("词流", "tujafijgkrnv"),
    ("整句流", "jaefmonyftuderlmljgbmnvs"),
]

# (options.yaml 键, 值, 说明)；s2t 走 tiger_sentence_hans
CONFIGS = [
    ("基线（全关）", None, None),
    ("拆字注释", "chaifen", True),
    ("拼音注释", "pinyin", True),
    ("emoji", "emoji_cn", True),
    ("U区提示", "charset_comment_filter", True),
    ("U编显示", "udpf_switch", True),
    ("简繁通繁", "tiger_sentence_hans", "s2t"),
]

OPT_PATH = pathlib.Path(USER, "tiger_sentence.options.yaml")


def run_probe(keys: str, rounds: int = 50) -> dict:
    proc = subprocess.run(
        [BENCH, USER, SHARED, PLUGIN, SCHEMA, keys, str(rounds)],
        capture_output=True, text=True, timeout=600)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr[-300:])
    return json.loads(proc.stdout.strip().splitlines()[-1])


def main() -> int:
    original = OPT_PATH.read_text(encoding="utf-8")
    base_opts = original
    rows = []
    try:
        for label, key, value in CONFIGS:
            if key is None:
                OPT_PATH.write_text(base_opts, encoding="utf-8")
            else:
                # 在基线上只改一个键
                lines = [l for l in base_opts.splitlines()
                         if not l.startswith(f"  {key}:")]
                lines.insert(1, f"  {key}: {json.dumps(value, ensure_ascii=False)}")
                OPT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
            for stream_label, keys in STREAMS:
                # 预热一轮（super_replacer 首次建 LevelDB 缓存等）
                run_probe(keys, rounds=3)
                runs = [run_probe(keys, rounds=50) for _ in range(3)]
                med = statistics.median(r["median_us"] for r in runs)
                p95 = statistics.median(r["p95_us"] for r in runs)
                rows.append({"config": label, "key": key, "stream": stream_label,
                             "median_us": round(med, 1), "p95_us": round(p95, 1),
                             "runs": [round(r["median_us"], 1) for r in runs]})
                print(f"{label:<12} {stream_label:<6} {med:>9.1f} us/键 "
                      f"(p95 {p95:.0f})", flush=True)
    finally:
        OPT_PATH.write_text(original, encoding="utf-8")
    pathlib.Path("/tmp/audit2411/filter_matrix.json").write_text(
        json.dumps(rows, ensure_ascii=False, indent=1), encoding="utf-8")

    print("\n=== 相对基线增量（中位，μs/键）===")
    for stream_label, _ in STREAMS:
        base = next(r["median_us"] for r in rows
                    if r["config"] == "基线（全关）" and r["stream"] == stream_label)
        print(f"[{stream_label}] 基线 {base:.0f}")
        for label, key, value in CONFIGS[1:]:
            cur = next(r["median_us"] for r in rows
                       if r["config"] == label and r["stream"] == stream_label)
            print(f"  +{label:<8} {cur - base:+8.1f}  ({(cur-base)/base*100:+5.1f}%)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
