#!/usr/bin/env python3
"""阶段1A v2：滤镜开关成本矩阵——配对交错法（抗机器漂移）。

每个配置与基线在同一时间窗内交替跑 4 对，取「配置-基线」配对差的中位数。
同时用 /usr/bin/time -l 采峰值内存。
"""
import json, pathlib, re, statistics, subprocess, sys

USER = "/tmp/audit2411/user"
SHARED = "/Library/Input Methods/Squirrel.app/Contents/SharedSupport"
PLUGIN = "/Library/Input Methods/Squirrel.app/Contents/Frameworks/rime-plugins/librime-lua.dylib"
BENCH = "/tmp/bench_chaifen"
SCHEMA = "tiger_sentence"
PAIRS = 4

STREAMS = [
    ("单字流", "unidotstuja"),
    ("词流", "tujafijgkrnv"),
    ("整句流", "jaefmonyftuderlmljgbmnvs"),
]
CONFIGS = [
    ("拆字注释", "chaifen", True),
    ("拼音注释", "pinyin", True),
    ("emoji", "emoji_cn", True),
    ("U区提示", "charset_comment_filter", True),
    ("简繁通繁", "tiger_sentence_hans", "s2t"),
]
OPT_PATH = pathlib.Path(USER, "tiger_sentence.options.yaml")


def run_probe(keys: str, rounds: int = 40, with_mem: bool = False):
    cmd = [BENCH, USER, SHARED, PLUGIN, SCHEMA, keys, str(rounds)]
    if with_mem:
        proc = subprocess.run(["/usr/bin/time", "-l"] + cmd,
                              capture_output=True, text=True, timeout=600)
        mem = re.search(r"(\d+) bytes resident", proc.stderr)
        data = proc.stdout.strip().splitlines()[-1]
        r = json.loads(data)
        r["peak_mib"] = round(int(mem.group(1)) / 1048576, 1) if mem else None
        return r
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr[-300:])
    return json.loads(proc.stdout.strip().splitlines()[-1])


def set_opts(key=None, value=None):
    base = {"chaifen": False, "pinyin": False, "emoji_cn": False,
            "charset_comment_filter": False, "udpf_switch": False,
            "tiger_sentence_hans": "s2s"}
    if key:
        base[key] = value
    OPT_PATH.write_text("options:\n" + "".join(
        f"  {k}: {json.dumps(v, ensure_ascii=False)}\n" for k, v in base.items()),
        encoding="utf-8")


def main() -> int:
    original = OPT_PATH.read_text(encoding="utf-8")
    rows = []
    try:
        set_opts()  # 预热：s2t 的 LevelDB 缓存等
        run_probe(STREAMS[2][1], rounds=3)
        for stream_label, keys in STREAMS:
            for label, key, value in CONFIGS:
                deltas, cfg_med, base_med, mem_cfg, mem_base = [], [], [], [], []
                for _ in range(PAIRS):
                    set_opts()
                    b = run_probe(keys)
                    set_opts(key, value)
                    c = run_probe(keys)
                    deltas.append(c["median_us"] - b["median_us"])
                    base_med.append(b["median_us"]); cfg_med.append(c["median_us"])
                mem = run_probe(keys, with_mem=True) if stream_label == "单字流" else {}
                rows.append({
                    "stream": stream_label, "config": label,
                    "delta_us": round(statistics.median(deltas), 1),
                    "delta_range": [round(min(deltas), 1), round(max(deltas), 1)],
                    "baseline_us": round(statistics.median(base_med), 1),
                    "config_us": round(statistics.median(cfg_med), 1),
                    "peak_mib": mem.get("peak_mib"),
                })
                print(f"[{stream_label}] +{label:<6} Δ {statistics.median(deltas):+8.1f} "
                      f"μs/键  (配对差范围 {min(deltas):+.0f}~{max(deltas):+.0f})"
                      + (f"  峰值内存 {mem.get('peak_mib')}MiB" if mem.get("peak_mib") else ""),
                      flush=True)
    finally:
        OPT_PATH.write_text(original, encoding="utf-8")
    pathlib.Path("/tmp/audit2411/filter_matrix_v2.json").write_text(
        json.dumps(rows, ensure_ascii=False, indent=1), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
