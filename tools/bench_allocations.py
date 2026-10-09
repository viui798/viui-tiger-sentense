"""Paired, isolated real-model CPU/allocation benchmark (not device latency).

Use the same counting-allocator Lua runner and the same probe for both trees.
Raw per-round reports and all Lua SHA-256 identities are retained in --output.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def stage(tree, dst, model):
    shutil.copytree(tree / 'lua', dst / 'lua')
    for pattern in ('*.txt', '*.yaml', 'tiger_sentence.lexical.bin'):
        for p in tree.glob(pattern): shutil.copy2(p, dst / p.name)
    (dst / 'models').mkdir()
    target = dst / 'models/sentence-ngram-mobile.bin'
    try: target.symlink_to(model)
    except OSError: shutil.copy2(model, target)

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline', type=Path, required=True)
    ap.add_argument('--candidate', type=Path, default=ROOT)
    ap.add_argument('--model', type=Path, required=True)
    ap.add_argument('--runner', type=Path, required=True)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--rounds', type=int, default=5)
    ap.add_argument('--bursts', type=int, default=100)
    args = ap.parse_args()
    if not 1 <= args.rounds <= 20 or not 1 <= args.bursts <= 1000:
        ap.error('rounds must be 1..20, bursts 1..1000')
    for tree in (args.baseline, args.candidate):
        if not (tree / 'lua/tiger_sentence.lua').is_file(): ap.error(f'not a source tree: {tree}')
    if not args.model.is_file() or not args.runner.is_file(): ap.error('model and runner must exist')
    with args.model.open('rb') as f:
        if f.read(8) != b'TCSKNM02': ap.error('explicit TCSKNM02 model required')
    args.output.mkdir(parents=True, exist_ok=True)
    probe = ROOT / 'tools/bench_memory.lua'
    report = {'physical_device_tested': False, 'model_sha256': sha(args.model),
              'probe_sha256': sha(probe), 'runner_sha256': sha(args.runner),
              'rounds': args.rounds, 'bursts': args.bursts, 'runs': [], 'sources': {}}
    with tempfile.TemporaryDirectory(prefix='tiger-allocation-ab-') as tmp:
        roots = {}
        for label, tree in (('baseline', args.baseline), ('candidate', args.candidate)):
            root = Path(tmp) / label; root.mkdir(); stage(tree, root, args.model.resolve()); roots[label] = root
            report['sources'][label] = {p.name: sha(p) for p in sorted((root/'lua').glob('*.lua'))}
        for round_index in range(args.rounds):
            labels = ('baseline', 'candidate') if round_index % 2 == 0 else ('candidate', 'baseline')
            profiles = ('compact', 'balanced') if round_index % 2 == 0 else ('balanced', 'compact')
            for profile in profiles:
                for label in labels:
                    name = f'{label}-{profile}-{round_index+1}.jsonl'
                    path = args.output / name
                    with path.open('x', encoding='utf-8') as out:
                        result = subprocess.run([str(args.runner.resolve()), str(probe), str(roots[label]),
                                                 profile, str(args.bursts)], stdout=out, stderr=subprocess.PIPE,
                                                text=True, timeout=600)
                    if result.returncode: raise RuntimeError(f'{name}: {result.stderr}')
                    rows = [json.loads(line) for line in path.read_text().splitlines() if line.startswith('{')]
                    if not rows[0]['allocator_instrumented']: raise RuntimeError('counting allocator required')
                    timing = next(r for r in rows if 'timing' in r)
                    alloc = next(r for r in rows if 'allocation_phase' in r)
                    long = next(r for r in rows if r.get('phase') == 'long_128')
                    lookup = next(r for r in rows if 'lookup_phase' in r)
                    report['runs'].append(dict(label=label, profile=profile, round=round_index+1,
                        mean_cpu_ms=timing['mean_cpu_ms'], p95_cpu_ms=timing['p95_cpu_ms'],
                        p99_cpu_ms=timing['p99_cpu_ms'], allocation_calls=alloc['calls'],
                        allocation_growth_bytes=alloc['growth_bytes'],
                        peak_lua_bytes=max(r.get('lua_phase_peak_bytes') or 0 for r in rows),
                        long_retained_bytes=long['lua_retained_bytes'],
                        page_misses=lookup['page_misses'], page_bytes=lookup['page_bytes']))
                    print(name, timing['mean_cpu_ms'], flush=True)
    report['medians'] = {}
    for profile in ('compact', 'balanced'):
        for label in ('baseline', 'candidate'):
            runs = [r for r in report['runs'] if r['label'] == label and r['profile'] == profile]
            report['medians'][f'{label}-{profile}'] = {
                key: statistics.median(r[key] for r in runs) for key in runs[0] if key not in ('label','profile','round')}
    (args.output/'summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(report['medians'], indent=2))

if __name__ == '__main__': main()
