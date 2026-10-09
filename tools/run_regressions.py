"""Run Lua regressions in an owned temporary copy, never in live Rime user data.

python tools/run_regressions.py --lua lua5.4 --negative-control
The large optional model is not copied. Binary-model quality remains a separate run.
"""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT


@contextmanager
def temporary_tree():
    temporary = tempfile.TemporaryDirectory(prefix="tiger-rime-regression-")
    try:
        yield Path(temporary.name)
    finally:
        for attempt in range(6):
            try:
                temporary.cleanup()
                break
            except OSError as error:
                if attempt == 5:
                    print(json.dumps({"cleanup_warning": str(error),
                                      "residual": temporary.name, "attempts": 6}), file=sys.stderr)
                else:
                    time.sleep(0.1 * 2 ** attempt)


def isolated_sources(destination):
    shutil.copytree(PACK / "lua", destination / "lua")
    (destination / "tools").mkdir()
    for name in ("test_tiger_sentence_incremental.lua", "test_rime_contract.lua", "test_sentence_safety.lua", "test_sentence_learning.lua", "test_adaptive_learning.lua", "test_review_regressions.lua", "test_ngram_reader.lua", "test_memory.lua", "test_lexical_prior.lua", "test_whole_single_reward.lua", "test_allocation.lua", "test_key_correction_reuse.lua", "test_early_evidence_gate.lua", "test_empty_commit_correction_off.lua", "test_correction_levels.lua", "test_key_correction_gap.lua"):
        source = (ROOT / "tools" / name).read_text(encoding="utf-8")
        # Run the shared suite in the public mirror layout, without copying
        # unrelated TigerClaw tools or any live configuration/model files.
        source = source.replace("", "")
        (destination / "tools" / name).write_text(source, encoding="utf-8")
    shutil.copy2(ROOT / "tools/model_fixture.lua", destination / "tools/model_fixture.lua")
    shutil.copy2(ROOT / "tools/test_key_correction.lua", destination / "tools/test_key_correction.lua")
    for pattern in ("*.txt", "*.yaml", "rime.lua"):
        for path in PACK.glob(pattern):
            shutil.copy2(path, destination / path.name)
    (destination / "models").mkdir()
    shutil.copy2(PACK / "models/tiger_sentence.lexical.bin",
                 destination / "models/tiger_sentence.lexical.bin")
    (destination / "tools/test_high_freq_limit.lua").write_text((ROOT / "tools/test_high_freq_limit.lua").read_text().replace("", ""))
    (destination / "tools/test_backspace.lua").write_text((ROOT / "tools/test_backspace.lua").read_text().replace("", ""))


def execute(lua, root, script, override=None):
    env = os.environ.copy()
    env["LUA_PATH"] = str(root / "lua" / "?.lua") + ";;"
    env.pop("TIGER_SENTENCE_MODULE", None)
    if override:
        env["TIGER_SENTENCE_MODULE"] = str(override)
    return subprocess.run([lua, str(root / "tools" / script), str(root)], cwd=root,
                          env=env, text=True, encoding="utf-8", errors="replace",
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)


def negative_controls(lua, root):
    source = (root / "lua/tiger_sentence.lua").read_text(encoding="utf-8")
    variants = [
        ("primary-reward-disabled", "test_whole_single_reward.lua",
         '    canonical_code_reward = 0.0,', '    canonical_code_reward = 2.0,',
         "primary-code reward must be disabled in production"),
        ("unrestricted-whole-reward", "test_whole_single_reward.lua",
         'candidate.whole_single_reward_eligible and', 'candidate.optimal_single and',
         "whole score delta ujkf N=0"),
        ("whole-reward-confidence", "test_whole_single_reward.lua",
         'whole_input_single_character_reward_added,\n', '0.0,\n',
         "whole reward leaked into confidence"),
        ("partial-ranking-work", "test_allocation.lua",
         'local function evaluate_evidence_state(item)\n',
         'local function evaluate_evidence_state(item)\n    path_isolation_penalty(item)\n',
         "Partial evidence evaluated ranking-only isolation"),
        ("fusion-pair-cache", "test_allocation.lua",
         'local score = pair_scores[key]', 'local score = nil',
         "Fusion recalculated an identical pair in one merge"),
        ("memory-schema-less", "test_memory.lua",
         'if not env or not schema then return end',
         'if not env or not schema then set_memory_profile("balanced"); return end',
         "schema-less decode reset compact profile"),
        ("internal-limit", "test_high_freq_limit.lua",
         'if not schema then', 'if false then',
         "First decode reset explicit high_freq_limit zero"),
        ("schema-default", "test_high_freq_limit.lua",
         'if limit == nil then limit = default_high_freq_limit end',
         'if limit == nil then limit = lexicon_state.high_freq_limit or default_high_freq_limit end',
         "Schema with missing/invalid key inherited previous limit"),
        ("caret-insert", "test_rime_contract.lua",
         'if caret ~= #live_before then', 'if false then',
         "Insertion invalidated wrong lock range"),
        ("lazy-menu", "test_rime_contract.lua",
         'local count = type(menu.prepare) == "function"\n        and menu:prepare(candidate_limit) or menu:candidate_count()',
         'local count = menu:candidate_count()', "Tab wrapped at materialized prefix"),
        ("caret-delete", "test_rime_contract.lua",
         'local raw = live_input(context)\n            local caret = input_caret(context)\n            local first = repr == "BackSpace" and caret - 1 or caret',
         'local raw = live_input(context)\n            local caret = input_caret(context)\n            local first = #raw - 1', "Boundary delete removed data"),
        ("display-confidence", "test_sentence_safety.lua",
         '            all_candidates,\n            completed._truncated or false,',
         '            result,\n            completed._truncated or false,', "Display Top-K inflated confidence"),
        ("ranking-prior-confidence", "test_lexical_prior.lua",
         'local confidence_score = (item.mass_score or item.score) + confidence_ending_adjustment',
         'local confidence_score = item.score + ending_adjustment',
         "ranking priors changed the Beam candidates or confidence mass"),
        ("ancestor-truncation", "test_sentence_safety.lua",
         'states[consumed_end]._truncated = true',
         'states[consumed_end]._truncated = false', "Descendant lost ancestor truncation"),
        ("model-retry", "test_sentence_safety.lua",
         'decode = guarded_decode(decode)',
         '-- negative control: decode guard removed', "Model failure escaped decode guard"),
        ("long-code-boundary", "test_review_regressions.lua",
         'local max_code = lexicon_state.max_code_len', 'local max_code = 4',
         "long-code incremental/full mismatch"),
        ("learning-inhibition-parity", "test_review_regressions.lua",
         '(left.learning_affected or false) ~= (right.learning_affected or false)', 'false',
         "behavior-bearing snapshot mutation was ignored"),
    ]
    variants.extend([
        ("correction-empty-code-disabled", "test_empty_commit_correction_off.lua",
         'if correction.enabled or not context:get_option("tiger_sentence_early_commit") or state.suspended then',
         'if not context:get_option("tiger_sentence_early_commit") or state.suspended then',
         "correction enabled allowed empty-code commit"),
        ("correction-empty-code-stale", "test_empty_commit_correction_off.lua",
         'if correction.enabled or not context:get_option("tiger_sentence_early_commit") or state.suspended then\n        state.empty_code_pending = nil',
         'if correction.enabled or not context:get_option("tiger_sentence_early_commit") or state.suspended then\n        -- negative control: retained stale proposal',
         "disabled empty-code retained stale proposal"),
        ("evidence-before-correction-gate", "test_early_evidence_gate.lua",
         'local current = decode(full_raw, false, state.committed_text, active_lock(state))',
         'local current = decode(full_raw, true, state.committed_text, active_lock(state))',
         "blocked correction built early evidence"),
        ("evidence-incomplete-gate", "test_early_evidence_gate.lua",
         '        if current.correction_incomplete or current.exact_correction_affected or\n            (current[1]',
         '        if false or current.exact_correction_affected or\n            (current[1]',
         "incomplete correction built early evidence"),
        ("correction-prefix-view", "test_key_correction_reuse.lua",
         '        "\\tv3:" .. correction.profile',
         '        "\\t" .. (required or "") .. "\\tv3:" .. correction.profile',
         "required prefix launched a second search"),
        ("correction-incomplete-prefix", "test_key_correction_reuse.lua",
         'safe = math.min(safe, cache.complete_through or floor)',
         'safe = common', "reused an incomplete bucket"),
        ("tail-backspace-reset", "test_backspace.lua",
         'if not reuse_tail then reset_decode_cache() end', 'reset_decode_cache()',
         "Tail Backspace rebuilt the locked lattice"),
        ("selector-tail-reuse", "test_backspace.lua",
         'deleted_tail and deleted_tail:match("^[a-z]$")', 'deleted_tail',
         "unsafe edit bypassed conservative rebuild"),
        ("learned-tail-reuse", "test_backspace.lua",
         'cache.states and not cache.learning_affected and', 'cache.states and',
         "learning-affected deletion reused cumulative inhibition"),
        ("text-only-replay", "test_backspace.lua",
         'if buffered ~= "" and input == "" and lock and', 'if false and input == "" and lock and',
         "Text-only Backspace replayed locked history"),
    ])
    for name, script, before, after, expected in variants:
        if source.count(before) != 1:
            raise RuntimeError(f"Negative-control anchor changed: {name}")
        mutant = root / (name + ".lua")
        mutant.write_text(source.replace(before, after), encoding="utf-8")
        result = execute(lua, root, script, mutant)
        if (name == "ranking-prior-confidence" and result.returncode == 0 and
                '"model_features":false' in result.stdout):
            print(json.dumps({"negative_control": name, "status": "skipped",
                              "reason": "binary fixture API unavailable"}), flush=True)
            continue
        if result.returncode == 0 or expected not in result.stdout:
            raise RuntimeError(f"Negative control did not fail at its functional assertion: {name}\n{result.stdout}")
        print(json.dumps({"negative_control": name, "status": "detected"}), flush=True)
    # Helper-module mutants run in this owned copy only and are always restored.
    helpers = [
        ("correction-d89-default", "tiger_sentence_correction.lua", "test_key_correction_gap.lua",
         'A={seeds=8,one=16,two=8,steps=4096,delta_one=8,delta_two=9}',
         'A={seeds=8,one=16,two=8,steps=4096}',
         "default D89 thresholds missing"),
        ("correction-gap-cutoff", "tiger_sentence_correction.lua", "test_key_correction_gap.lua",
         'if items[i].score < cutoff then break end',
         'if false then break end', "wrong independent budget cutoffs"),
        ("correction-gap-optional", "tiger_sentence_correction.lua", "test_key_correction_gap.lua",
         'local delta = profile.delta_one\n        if budget == 2 then delta = profile.delta_two end',
         'local delta = budget == 1 and profile.delta_one or profile.delta_two',
         "nil single gap inherited double cutoff"),
        ("correction-strength-cost", "tiger_sentence_correction.lua", "test_correction_levels.lua",
         'M.level_penalties = {weak=8, medium=6, strong=4}',
         'M.level_penalties = {weak=4, medium=6, strong=8}',
         "wrong level penalty"),
        ("memory-learning-cap", "tiger_sentence_learning.lua", "test_memory.lua",
         'local MATERIALIZED_CODE_LIMIT = 256', 'local MATERIALIZED_CODE_LIMIT = 10000',
         "materialized learning cache is unbounded"),
        ("learning-window", "tiger_sentence_learning.lua", "test_review_regressions.lua",
         'for i = lo, math.min(#codes, lo + 63) do', 'for i = lo, math.min(#codes, lo + 64) do',
         "equal code no longer consumes the 64-slot window"),
        ("observed-zero", "tiger_sentence_fivegram.lua", "test_ngram_reader.lua",
         'local _,_,observed=lookup(2,history,1,right)\n            return observed',
         'local p,_,observed=lookup(2,history,1,right)\n            return observed and p ~= header.quant[2].pmin',
         "zero-valued observed record was confused with missing"),
    ]
    for name, module, script, before, after, expected in helpers:
        path = root / "lua" / module
        original = path.read_text(encoding="utf-8")
        if original.count(before) != 1:
            raise RuntimeError(f"Negative-control anchor changed: {name}")
        try:
            path.write_text(original.replace(before, after), encoding="utf-8")
            result = execute(lua, root, script)
        finally:
            path.write_text(original, encoding="utf-8")
        if name == "observed-zero" and '"status":"skipped"' in result.stdout and result.returncode == 0:
            print(json.dumps({"negative_control": name, "status": "skipped", "reason": "binary API unavailable"}), flush=True)
            continue
        if result.returncode == 0 or expected not in result.stdout:
            raise RuntimeError(f"Negative control did not fail at its functional assertion: {name}\n{result.stdout}")
        print(json.dumps({"negative_control": name, "status": "detected"}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", default="lua")
    parser.add_argument("--negative-control", action="store_true")
    args = parser.parse_args()
    lua = shutil.which(args.lua)
    if not lua:
        parser.error(f"Lua interpreter not found: {args.lua}")
    lua = str(Path(lua).resolve())
    with temporary_tree() as root:
        isolated_sources(root)
        for script in ("test_tiger_sentence_incremental.lua", "test_rime_contract.lua", "test_sentence_safety.lua", "test_sentence_learning.lua", "test_adaptive_learning.lua", "test_review_regressions.lua", "test_ngram_reader.lua", "test_memory.lua", "test_lexical_prior.lua", "test_whole_single_reward.lua", "test_allocation.lua", "test_key_correction_reuse.lua", "test_early_evidence_gate.lua", "test_empty_commit_correction_off.lua", "test_correction_levels.lua", "test_key_correction_gap.lua"):
            result = execute(lua, root, script)
            print(result.stdout, end="", flush=True)
            result.check_returncode()
        result = execute(lua, root, "test_high_freq_limit.lua")
        print(result.stdout, end="", flush=True)
        result.check_returncode()
        result = execute(lua, root, "test_backspace.lua")
        print(result.stdout, end="", flush=True)
        result.check_returncode()
        result = subprocess.run([lua, str(root / "tools/test_key_correction.lua"), str(root), str(root)],
                                text=True, capture_output=True, timeout=120)
        print(result.stdout, end="", flush=True)
        if result.returncode: print(result.stderr, end="")
        result.check_returncode()
        if args.negative_control:
            negative_controls(lua, root)


if __name__ == "__main__":
    main()
