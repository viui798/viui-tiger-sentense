#!/usr/bin/env python3
# 导出拼音反查引擎数据（五阶模型整句引擎用）。
#
# 产出（仓库根 / lua/）：
#   pinyin.qp.codes.txt     旧版全拼码表（v0.3.3 起正式反查表改由
#                           tools/export_reverse_codes.py 生成；本脚本的 codes 输出仅作对照）
#                           字：每音节 top --char-cap（权重降序）
#                           辅助码：全部字的 音节+辅1 / 音节+辅1辅2（top 外的生僻字可达）
#                           简拼：首字母组（字 + 词首字母码）
#                           词：与 wanxiang_pro.dict.yaml 同源，权重 >= --min-word-weight
#   lua/pinyin_keymaps.lua  四种双拍的键位转换表（2 键 -> 全拼音节 + 首键 -> 声母首字母），
#                           规则从 wanxiang_algebra.yaml 的 pro/* 节程序化派生，
#                           与万象反查 prism 同源，保证键位习惯一致。
#
# 用法: python3 -I tools/export_pinyin_tables.py [repo_root]
import collections
import os
import re
import sys
import unicodedata

REPO = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
NO_AUX = "--no-aux" in sys.argv  # 反查不需要辅助码时跳过「音节+辅助码」条目
CHAR_CAP = 32          # 每音节单字上限（性能实验 P4 实测可用值）
INITIAL_CAP = 32       # 每个首字母/词首字母码的候选上限
MIN_WORD_WEIGHT = 145  # 词权重下限：覆盖常用词与常见成语（买椟还珠=145 为锚点）
MAX_WORD_ENTRIES = 250000  # 词表硬上限：P5 实测 382k 条建库 3.7s/常驻 201MiB，250k 约 2.4s/135MiB
MAX_WORD_CHARS = 12    # 词长上限（字数）
DOUBLE_SCHEMES = [("小鹤双拼", "flypy"), ("自然码", "zrm"),
                  ("微软双拼", "mspy"), ("搜狗双拼", "sogou")]
UMLAUTS = set("üǖǘǚǜǕǗǙǛ")
ENTRY = re.compile(r"^(.{1,30})\t([^\t]+)\t(\d+)\s*$")


def read_lines(path):
    with open(path, encoding="utf-8") as f:
        return f.readlines()


def strip_tone(syl):
    """hǎo -> hao；nǚ -> nv（仅含 ü 的音节 u->v）；非 [a-z] 返回 None"""
    has_um = any(ch in UMLAUTS for ch in syl)
    d = unicodedata.normalize("NFD", syl)
    d = "".join(ch for ch in d if not unicodedata.combining(ch))
    if has_um:
        d = d.replace("u", "v", 1)
    return d if re.fullmatch(r"[a-z]+", d) else None


def parse_syllable_column(col):
    """'ā;tz bà;hm' -> (['a','ba'], ['tz','hm'])；无法解析返回 (None, None)"""
    sylls, auxs = [], []
    for part in col.split():
        pieces = part.split(";")
        toned = pieces[0]
        aux = pieces[1].split(",")[0].strip() if len(pieces) > 1 else None
        t = strip_tone(toned)
        if not t:
            return None, None
        sylls.append(t)
        auxs.append(aux if aux and re.fullmatch(r"[a-z]{1,2}", aux) else None)
    return sylls, auxs


def load_wanxiang_imports():
    paths = []
    for line in read_lines(os.path.join(REPO, "wanxiang_pro.dict.yaml")):
        m = re.match(r"^\s*-\s+([^#\s]+)", line)
        if m:
            paths.append(m.group(1))
    return paths


# ---------- wanxiang_algebra 规则 ----------
def parse_algebra_rules(section):
    """pro: 树下的指定节（同名的节在 base/reverse/mixed 树也有，必须限定 pro）"""
    lines = read_lines(os.path.join(REPO, "wanxiang_algebra.yaml"))
    rules = []
    start = None
    in_pro = False
    for line in lines:
        if re.match(r"^pro:\s*$", line):
            in_pro = True
            continue
        if in_pro and re.match(r"^\S", line):
            break  # pro: 树结束
        if not in_pro:
            continue
        if start is None:
            if re.match(r"^  {0}:\s*$".format(re.escape(section)), line):
                start = True
            continue
        if re.match(r"^  \S", line):
            break  # 下一节
        m = re.match(r"^\s+- (xform|derive|xlit|erase)/(.*)\s*$", line)
        if not m:
            continue
        op, rest = m.group(1), m.group(2)
        parts = rest.split("/", 2)  # 规则尾部可能带 #注释，只取 pat 与 repl
        if len(parts) < 2:
            continue
        if op == "xlit":
            rules.append(("xlit", parts[0], parts[1]))
        else:
            rules.append((op, parts[0], parts[1]))
    if start is None:
        raise SystemExit("pro 树下未找到 algebra 节: " + section)
    return rules


def py_re(libre_pattern):
    """librime 正则 -> Python（$1 反向引用 -> \\1）"""
    return re.sub(r"\$(\d)", r"\\\1", libre_pattern)


def apply_rules(rules, spelling):
    current = [spelling]
    for op, pat, repl in rules:
        if op == "xform":
            current = [re.sub(py_re(pat), py_re(repl), s) for s in current]
        elif op == "derive":
            nxt = []
            for s in current:
                nxt.append(s)
                v = re.sub(py_re(pat), py_re(repl), s)
                if v != s:
                    nxt.append(v)
            current = nxt
        elif op == "erase":
            current = [s for s in current if not re.search(py_re(pat), s)]
        elif op == "xlit":
            table = str.maketrans(pat, repl)
            current = [s.translate(table) for s in current]
    return current


def derive_scheme_map(section, syllables):
    """一种双拍的转换表：{2键unit: 全拼音节} + {首键: 声母首字母}
    音节跑一次无调形态（链首规则自动补 ④ 轻声；2 键形态与声调无关）"""
    rules = parse_algebra_rules(section)
    units, initial = {}, collections.defaultdict(collections.Counter)
    failures = []
    for syl in syllables:
        spelled = apply_rules(rules, syl + "④;")
        codes = set()
        for s in spelled:
            s = s.replace("◯", ";")  # 微软/搜狗 ing 键占位符（释放规则在反查纯拼节）
            s = re.sub(r"\d;$", "", s)  # 去调号数字与结尾分号
            if re.fullmatch(r"[a-z;]{2}", s):
                codes.add(s)
        if not codes:
            failures.append(syl)
            continue
        for unit in codes:
            units.setdefault(unit, syl)
            initial[unit[0]][syl[0]] += 1
    key_initial = {}
    conflicts = []
    for key, counter in initial.items():
        best = counter.most_common(2)
        key_initial[key] = best[0][0]
        if len(best) > 1 and best[1][1] == best[0][1]:
            conflicts.append((key, dict(counter)))
    return units, key_initial, failures, conflicts


def main():
    imports = load_wanxiang_imports()
    print("词表来源（同 wanxiang_pro.dict.yaml）:", ", ".join(imports))

    char_w = {}        # (char, toneless) -> max weight
    char_aux = {}      # (char, toneless) -> (weight, aux)
    word_w = {}        # (word, code) -> max weight
    word_sylls = {}    # (word, code) -> 无调音节列表（词首字母码用）
    skipped_syll = skipped_len = 0

    for imp in imports:
        path = os.path.join(REPO, imp + ".dict.yaml")
        if not os.path.exists(path):
            print("  跳过缺失词表:", imp)
            continue
        for line in read_lines(path):
            m = ENTRY.match(line)
            if not m:
                continue
            text, col, weight = m.group(1), m.group(2), int(m.group(3))
            sylls, auxs = parse_syllable_column(col)
            if sylls is None:
                skipped_syll += 1
                continue
            if len(text) == 1:
                k = (text, sylls[0])
                if weight > char_w.get(k, 0):
                    char_w[k] = weight
                old = char_aux.get(k)
                if auxs[0] and (old is None or weight > old[0]):
                    char_aux[k] = (weight, auxs[0])
            elif 2 <= len(text) <= MAX_WORD_CHARS and len(sylls) == len(text):
                code = "".join(sylls)
                k = (text, code)
                if weight > word_w.get(k, 0):
                    word_w[k] = weight
                    word_sylls[k] = sylls
            else:
                skipped_len += 1

    toneless_set = sorted({syl for (_, syl) in char_w})
    print(f"无调音节: {len(toneless_set)} | 字-音节对: {len(char_w)} | "
          f"词对(原始): {len(word_w)} | 跳过行: 音节 {skipped_syll} / 词长 {skipped_len}")

    # ---------- 双拍键位转换表 ----------
    lua_maps = []
    for section, key in DOUBLE_SCHEMES:
        units, key_initial, failures, conflicts = derive_scheme_map(section, toneless_set)
        print(f"[{section}] unit 数: {len(units)} | 音节失败: {len(failures)}"
              + (f" {failures[:8]}" if failures else "")
              + (f" | 首键歧义: {conflicts[:4]}" if conflicts else ""))
        unit_rows = ",".join(f'["{u}"]="{s}"' for u, s in sorted(units.items()))
        init_rows = ",".join(f'["{k}"]="{v}"' for k, v in sorted(key_initial.items()))
        lua_maps.append(f'  {key} = {{\n    units = {{ {unit_rows} }},\n'
                        f'    initials = {{ {init_rows} }}\n  }}')
    lua_path = os.path.join(REPO, "lua", "pinyin_keymaps.lua")
    with open(lua_path, "w", encoding="utf-8") as f:
        f.write("-- 五打法键位转换表（tools/export_pinyin_tables.py 生成，勿手改）。\n"
                "-- units: 双拍 2 键 -> 全拼无调音节；initials: 单键简拼 -> 声母首字母。\n"
                "-- 规则派生自 wanxiang_algebra.yaml 的 pro/* 节，与万象反查 prism 同源。\n"
                "return {\n" + ",\n".join(lua_maps) + "\n}\n")
    print("写出:", lua_path)

    # ---------- 字集过滤（引擎字集之外的字不可见，直接不导出） ----------
    common = set()
    with open(os.path.join(REPO, "tiger_sentence.common_characters.txt"),
              encoding="utf-8") as f:
        for ch in f.read():
            if not ch.isspace():
                common.add(ch)

    def visible(text):
        return all(ch in common for ch in text)

    # ---------- 全拼码表 ----------
    entries = []          # (code, text)
    emitted = set()       # (text, code)

    def add(code, text):
        if re.fullmatch(r"[a-z]+", code) and (text, code) not in emitted:
            emitted.add((text, code))
            entries.append((code, text))

    by_syll = collections.defaultdict(list)
    for (ch, syl), w in char_w.items():
        if visible(ch):
            by_syll[syl].append((w, ch))
    for syl in by_syll:
        by_syll[syl].sort(reverse=True)
    for syl in sorted(by_syll):
        for w, ch in by_syll[syl][:CHAR_CAP]:
            add(syl, ch)
    syll_entries = len(entries)

    # 辅助码：全部可见字（含 top 外生僻字）
    aux_count = 0
    if not NO_AUX:
        for (ch, syl), (w, aux) in sorted(char_aux.items()):
            if aux and visible(ch):
                before = len(entries)
                add(syl + aux[0], ch)
                add(syl + aux, ch)
                aux_count += len(entries) - before

    # 简拼首字母（字）
    by_initial = collections.defaultdict(list)
    for (ch, syl), w in char_w.items():
        if visible(ch):
            by_initial[syl[0]].append((w, ch))
    for letter in by_initial:
        by_initial[letter].sort(reverse=True)
    initial_count = 0
    for letter in sorted(by_initial):
        seen = 0
        for w, ch in by_initial[letter]:
            if seen >= INITIAL_CAP:
                break
            before = len(entries)
            add(letter, ch)
            initial_count += len(entries) - before
            seen += len(entries) - before

    # ---------- 词表 ----------
    kept = [(w, t, c) for (t, c), w in word_w.items()
            if w >= MIN_WORD_WEIGHT and visible(t)]
    kept.sort(reverse=True)
    if len(kept) > MAX_WORD_ENTRIES:
        cutoff = kept[MAX_WORD_ENTRIES - 1][0]
        kept = [x for x in kept if x[0] >= max(MIN_WORD_WEIGHT, cutoff)]
        print(f"词表截断: 权重 >= {kept[-1][0]}（上限 {MAX_WORD_ENTRIES} 条）")
    word_by_code = collections.defaultdict(list)
    word_initial = collections.defaultdict(list)
    for w, t, c in kept:
        word_by_code[c].append((w, t))
        # 词首字母码 = 逐音节首字母（计算机 jisuanji -> jsj）。整词码没有音节
        # 边界，必须在加载期保留音节列表（word_sylls）。
        sylls = word_sylls.get((t, c))
        if sylls:
            word_initial["".join(s[0] for s in sylls)].append((w, t))
    for code in word_by_code:
        word_by_code[code].sort(reverse=True)
    for code in word_initial:
        word_initial[code].sort(reverse=True)
    word_entries = []
    for code in sorted(word_by_code):
        for w, t in word_by_code[code]:
            add(code, t)
    word_main = len(entries) - syll_entries - aux_count - initial_count
    wi_count = 0
    for code in sorted(word_initial):
        if re.fullmatch(r"[a-z]+", code):
            # 2 键简拼组（两字词）裁到 top-8：它们能在普通全拼串内部成边，
            # 组越大内存越重；高频两字词 top-8 足够覆盖。3 键以上维持 32。
            cap = 8 if len(code) == 2 else INITIAL_CAP
            seen = 0
            for w, t in word_initial[code]:
                if seen >= cap:
                    break
                before = len(entries)
                add(code, t)
                seen += len(entries) - before
                wi_count += len(entries) - before

    out_path = os.path.join(REPO, "pinyin.qp.codes.txt")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("# 拼音反查引擎码表（tools/export_pinyin_tables.py 生成，勿手改）\n"
                f"# 全拼无调音节(每音节top{CHAR_CAP}) + 辅助码 + 简拼首字母 "
                f"+ 词(权重>={MIN_WORD_WEIGHT})；行序 = 组内 rank\n")
        for code, text in entries:
            f.write(f"{text}\t{code}\n")

    print(f"字表: 音节 {syll_entries} / 辅助码 {aux_count} / 简拼字 {initial_count}")
    print(f"词表: 主体 {word_main} / 简拼词 {wi_count}")
    print(f"总条目: {len(entries)} | 写出: {out_path} "
          f"({os.path.getsize(out_path) / 1048576:.1f} MiB)")
    dropped_words = sum(1 for (t, c), w in word_w.items()
                        if w >= MIN_WORD_WEIGHT and not visible(t))
    print(f"因字集不可见而丢弃的词: {dropped_words}")


if __name__ == "__main__":
    main()
