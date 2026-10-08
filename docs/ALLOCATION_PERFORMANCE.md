# Lua allocation/evidence optimization — 2026-09-20

Baseline: `b30187c270d91e88cb5956524afdeaf40204152d`.
This is an equivalent-computation optimization, not a Beam/threshold change.
No production Rime user directory, model, schema options or learning database is modified.

## Retained changes

- Partial-tail evidence uses a confidence-only evaluator; unused menu-ranking isolation and fields are not computed.
- UTF-8 character counts are accumulated alongside byte lengths when the native UTF-8 implementation is available. LuaJIT's existing fallback counting is preserved.
- Prefix mass accumulation does not allocate two intermediate weight arrays. Each sum keeps the original candidate iteration and floating-point operation order.
- Frozen buckets reuse their private result array instead of copying it into another array. The learning-reserve and membership tables are created only when an actual reserve exists.
- Composed-only menus bypass Fusion setup. Mixed-source menus cache exact pair scores only for the duration of that merge, including zero scores.
- No mutable work buffer is reused across published snapshots.

## Evaluated but not shipped

A persistent, lazy-string path prototype passed functional tests but was slower and had no reliable peak-memory benefit on this Lua workload. It is not enabled or shipped behind a flag.

Tuple-key cache subtables and compact metatable-backed state rows were also tested. Their CPU/memory trade-offs varied by profile; they did not provide a reliable improvement in both profiles. The final runtime retains the original string-key caches, limits, and directly-addressable state fields. No large cache increase or forced per-key GC is introduced.

## Validation and repeatability

`tools/test_allocation.lua` covers confidence-only evaluation, stable old published snapshots across later decode/trim generations, character-vs-byte lengths, and one score calculation per Fusion pair. Functional negative controls deliberately reintroduce the unused ranking work and duplicate pair calculations.

The independent snapshot probe now includes source/rank provenance, code/lexical scores, personalized confidence, model-only BaseShare, and learning bonuses. CI no longer omits early evidence or learning behavior from old/new comparison. Nonfinite scores remain rejected; the documented no-Direct-rank sentinel is serialized as `none`.

The benchmark uses one probe/runner/model for both source trees in fresh processes, alternating execution order. The counting allocator reports requested Lua bytes and allocation growth, not native Rime memory or iOS physical footprint. Production-model measurements are kept separate from synthetic tests and host integration.

```sh
python3 tools/run_regressions.py --lua lua --negative-control
python3 tools/run_regressions.py --lua luajit --negative-control
python3 tools/compare_revisions.py --baseline /path/to/b30187c --lua lua \
  --model /path/to/sentence-ngram-mobile.bin --require-model \
  --memory-profile compact --trim-every 37 --report compact.json
python3 tools/bench_allocations.py --baseline /path/to/b30187c \
  --model /path/to/sentence-ngram-mobile.bin --runner /path/to/lua-memory \
  --rounds 3 --bursts 100 --output /new/report/directory
```

No physical desktop/mobile frontend acceptance is claimed by these headless tests.
