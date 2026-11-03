#!/usr/bin/env python3
"""A/B 对比：拆字滤镜 lua_filter@*chaifen  vs  simplifier@chaifen (OpenCC)。

在隔离用户目录里准备两套仅拆字实现不同的 schema，用
tools/snapshot_rime_pipeline.cpp 编译出的探针回放同一批按键，逐键、逐候选
比对候选文本与注释。用于 docs/想法-拆字滤镜改用OpenCC.md 的等价性验收。

准备隔离目录（示例）：
  tools/prepare_chaifen_ab.sh /tmp/cf_test/user
  python3 tools/make_release_zip.py ...  # 不需要

用法：
  python3 tools/compare_chaifen.py --user /tmp/cf_test/user \
      --snapshot /tmp/snapshot [--mode all|char] [--json /tmp/cf_report.json]

默认 shared/plugin 取本机鼠须管。探针需先编译（见脚本末尾注释）。
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_SHARED = "/Library/Input Methods/Squirrel.app/Contents/SharedSupport"
DEFAULT_PLUGIN = (
    "/Library/Input Methods/Squirrel.app/Contents/Frameworks/"
    "rime-plugins/librime-lua.dylib"
)
PAIRS = [("tiger", "tiger_cc"), ("tigress", "tigress_cc"),
         ("tiger_sentence", "tiger_sentence_cc")]
DEPLOYER = "/Library/Input Methods/Squirrel.app/Contents/MacOS/rime_deployer"


@dataclass
class Case:
    group: str
    a: str
    b: str
    keys: str
    label: str


def read_table(path: pathlib.Path, min_cols: int = 2) -> list[list[str]]:
    rows = []
    started = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip() == "...":
            started = True
            continue
        if not started or not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= min_cols:
            rows.append(parts)
    return rows


def build_cases() -> list[Case]:
    """从真实词库取码，保证用例可复跑且覆盖常用字/生僻字/多字词/整句。"""
    cases: list[Case] = []

    # 单字码：tiger.dict.yaml 是 字 / 权重 / 码 三列。
    char_codes: dict[str, str] = {}
    for parts in read_table(ROOT / "tiger.dict.yaml", 3):
        char_codes.setdefault(parts[0], parts[2])
    lookup = {parts[0]: parts[1]
              for parts in read_table(ROOT / "tiger_lookup.dict.yaml", 2)}
    common = [c for c in "的一是在不了有人我他这中大为上个国" if c in char_codes]
    rare = [c for c in lookup if ord(c) > 0x20000 and c in char_codes][:6]
    for ch in common[:8] + rare[:4]:
        code = char_codes[ch]
        cases.append(Case("单字", "tiger", "tiger_cc", code, f"{ch}/{code}"))
        cases.append(Case("单字", "tigress", "tigress_cc", code, f"{ch}/{code}"))

    # 多字词：tigress_ci.dict.yaml 是 词 / 权重 / 码。
    words = [p for p in read_table(ROOT / "tigress_ci.dict.yaml", 3)
             if 2 <= len(p[0]) <= 5]
    for p in words[:8] + words[500:504] + words[9000:9004]:
        cases.append(Case("多字词", "tigress", "tigress_cc", p[2], f"{p[0]}/{p[2]}"))

    # 虎整句：连续单字码，让引擎排出整句候选。
    sentence = "".join(char_codes[c] for c in "我们是中国人"[:6] if c in char_codes)
    if sentence:
        cases.append(Case("整句", "tiger_sentence", "tiger_sentence_cc",
                          sentence, "我们是中国人"))
    sentence2 = "".join(char_codes[c] for c in "今天天气很好"[:5] if c in char_codes)
    if sentence2:
        cases.append(Case("整句", "tiger_sentence", "tiger_sentence_cc",
                          sentence2, "今天天气很好"))

    # 反查 / 造词 / 快符 / 全字集反查：覆盖不同 segment tag。
    for prefix, keys, label in [
        ("`", "nihao", "反查全拼 nihao"),
        ("`", "jsj", "反查简拼 jsj"),
        ("`", "bm", "反查双拼 bm"),
        ("`", "bian", "反查双拼 bian"),
        ("'", "unid", "造词前缀"),
        (";", "a", "快符"),
        ('"', "unid", "全字集反查"),
    ]:
        cases.append(Case("特殊段", "tiger", "tiger_cc", prefix + keys, label))
        cases.append(Case("特殊段", "tigress", "tigress_cc", prefix + keys, label))
    return cases


def decode(hexstr: str) -> str:
    if not hexstr:
        return ""
    try:
        return bytes.fromhex(hexstr).decode("utf-8", "replace")
    except ValueError:
        return f"<badhex:{hexstr}>"


def parse_line(line: str) -> dict:
    """一行探针输出 → {preedit, menu, candidates:[(text,comment)], commit}。"""
    parts = line.split("|")
    out = {"head": parts[0] if parts else "", "preedit": decode(parts[1]) if len(parts) > 1 else "",
           "menu": parts[2] if len(parts) > 2 else "", "candidates": [], "commit": ""}
    rest = parts[3:]
    if rest and rest[-1] == "":
        rest.pop()  # 行尾分隔符
    # 末尾可能有一个 commit field（不与候选成对）
    if len(rest) % 2 == 1:
        out["commit"] = decode(rest.pop())
    for i in range(0, len(rest), 2):
        out["candidates"].append((decode(rest[i]), decode(rest[i + 1])))
    return out


def run_snapshot(snapshot: str, user: str, shared: str, plugin: str,
                 schema: str, keys: str) -> list[dict]:
    proc = subprocess.run([snapshot, user, shared, plugin, schema, keys],
                          capture_output=True, text=True, timeout=300)
    if proc.returncode != 0:
        raise RuntimeError(f"probe failed ({schema} {keys!r}): {proc.stderr[-400:]}")
    return [parse_line(l) for l in proc.stdout.splitlines()
            if l.startswith("key=")]


def compare(a: list[dict], b: list[dict]) -> list[dict]:
    diffs = []
    for i in range(max(len(a), len(b))):
        if i >= len(a) or i >= len(b):
            diffs.append({"step": i, "field": "行数", "a": len(a), "b": len(b)})
            continue
        x, y = a[i], b[i]
        for field in ("head", "preedit", "menu", "commit"):
            if x[field] != y[field]:
                diffs.append({"step": i, "field": field, "a": x[field], "b": y[field]})
        if x["candidates"] != y["candidates"]:
            for j in range(max(len(x["candidates"]), len(y["candidates"]))):
                cx = x["candidates"][j] if j < len(x["candidates"]) else None
                cy = y["candidates"][j] if j < len(y["candidates"]) else None
                if cx != cy:
                    diffs.append({"step": i, "field": f"cand[{j}]",
                                  "a": cx, "b": cy})
    return diffs


def deploy(user: str, shared: str) -> None:
    subprocess.run([DEPLOYER, "--build", user, shared],
                   capture_output=True, text=True, check=True, timeout=900)


def patch_char_mode(user: pathlib.Path) -> list[tuple[pathlib.Path, str]]:
    """char 模式：Lua 版 enum/chaifen: char，OpenCC 版 tips: char。"""
    backups = []
    for p in sorted(user.glob("*.schema.yaml")):
        if p.is_symlink():
            continue
        s = p.read_text(encoding="utf-8")
        orig = s
        if "_cc" in p.name:
            # 只改 chaifen 段里的 tips，不动 emoji_cn 段。
            s = re.sub(r"(^chaifen:\n(?:  .*\n)*?  tips: )all", r"\1char",
                       s, count=1, flags=re.M)
        else:
            s = re.sub(r"(^enum:\n  chaifen: )all", r"\1char", s,
                       count=1, flags=re.M)
        if s != orig:
            backups.append((p, orig))
            p.write_text(s, encoding="utf-8")
    return backups


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", default="/tmp/cf_test/user")
    ap.add_argument("--shared", default=DEFAULT_SHARED)
    ap.add_argument("--plugin", default=DEFAULT_PLUGIN)
    ap.add_argument("--snapshot", default="/tmp/snapshot")
    ap.add_argument("--mode", choices=["all", "char"], default="all")
    ap.add_argument("--json", default="")
    args = ap.parse_args()

    user = pathlib.Path(args.user)
    if not pathlib.Path(args.snapshot).exists() or not (user / "build").is_dir():
        sys.exit("缺少探针或隔离目录 build/；先编译 tools/snapshot_rime_pipeline.cpp 并部署")

    backups = []
    if args.mode == "char":
        backups = patch_char_mode(user)
        if not backups:
            sys.exit("char 模式：未找到可 patch 的 schema（隔离目录里应为实体文件）")
        deploy(args.user, args.shared)

    cases = build_cases()
    report = {"mode": args.mode, "pairs": PAIRS, "cases": [], "diffs": []}
    try:
        for case in cases:
            try:
                a = run_snapshot(args.snapshot, args.user, args.shared,
                                 args.plugin, case.a, case.keys)
                b = run_snapshot(args.snapshot, args.user, args.shared,
                                 args.plugin, case.b, case.keys)
            except (RuntimeError, subprocess.TimeoutExpired) as e:
                report["diffs"].append({"case": case.label, "error": str(e)})
                continue
            diffs = compare(a, b)
            report["cases"].append({"group": case.group, "schema": case.a,
                                    "keys": case.keys, "label": case.label,
                                    "steps": len(a), "diffs": len(diffs)})
            report["diffs"].extend({**d, "case": case.label, "schema": case.a,
                                    "keys": case.keys} for d in diffs)
    finally:
        for p, content in backups:
            p.write_text(content, encoding="utf-8")
        if backups:
            deploy(args.user, args.shared)

    total = len(report["cases"])
    bad = [c for c in report["cases"] if c["diffs"]]
    print(f"模式={args.mode}  用例={total}  逐键步数={sum(c['steps'] for c in report['cases'])}")
    print(f"差异用例={len(bad)}  差异条目={len(report['diffs'])}")
    for c in bad[:20]:
        print(f"  [差异] {c['group']} {c['schema']} {c['label']}: {c['diffs']} 处")
    for d in report["diffs"][:20]:
        if "error" not in d:
            print(f"    step {d['step']} {d['field']}: A={d['a']!r} B={d['b']!r}")
    if args.json:
        pathlib.Path(args.json).write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"报告 → {args.json}")
    return 1 if report["diffs"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
