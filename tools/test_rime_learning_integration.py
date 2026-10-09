"""Real librime/librime-lua learning with production data in owned user dirs."""
import argparse
from contextlib import contextmanager
from pathlib import Path
import shutil
import subprocess
import tempfile

try:
    from run_regressions import isolated_sources, temporary_tree
except ModuleNotFoundError as error:
    if error.name != 'run_regressions':
        raise
    # Release archives contain the production layout, without the full source
    # repository's regression runner. Keep this integration probe usable there.
    @contextmanager
    def temporary_tree():
        with tempfile.TemporaryDirectory(prefix='tiger-rime-learning-') as directory:
            yield Path(directory)

    def isolated_sources(root):
        source = Path(__file__).resolve().parents[1]
        for pattern in ('*.yaml', '*.txt', 'rime.lua'):
            for path in source.glob(pattern):
                shutil.copy2(path, root / path.name)
        shutil.copytree(source / 'lua', root / 'lua')
        (root / 'models').mkdir()
        shutil.copy2(source / 'models/tiger_sentence.lexical.bin',
                     root / 'models/tiger_sentence.lexical.bin')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', required=True)
    parser.add_argument('--plugin', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--case', choices=('all', 'composed', 'fusion'), default='all',
                        help='Also cover ujkf: Composed 拾滑 -> Direct 捡.')
    parser.add_argument('--correction', choices=('off', 'weak', 'medium', 'strong'), default='off')
    parser.add_argument('--selection', default='all', choices=('all', 'tap', 'tab'))
    args = parser.parse_args()
    if args.correction != 'off' and args.case != 'fusion':
        parser.error('correction integration requires --case fusion')
    cases = ('composed', 'fusion') if args.case == 'all' else (args.case,)
    selections = ('tap', 'tab', 'tab-comma', 'tab-period',
                  'tab-continue', 'tab-continue-comma', 'tab-continue-period',
                  'tab-buffer-continue-comma', 'tab-buffer-continue-period')
    if args.selection != 'all':
        selections = (args.selection,)
    for case in cases:
        for selection in selections:
            with temporary_tree() as root:
                isolated_sources(root)
                if case == 'fusion':
                    # New production scores already place 捡 first. This owned
                    # fixture retains a lower exact candidate to test learning.
                    with (root / 'rime.lua').open('a', encoding='utf-8') as handle:
                        handle.write('\nrequire("tiger_sentence").set_decoder_parameters_for_test('
                                     '{canonical_code_reward=2,whole_input_single_character_reward=0})\n')
                shared = root / '_shared'
                shared.mkdir()
                (shared / 'default.yaml').write_text(
                    'config_version: "1.0"\nschema_list:\n  - schema: tiger_sentence\n'
                    'menu:\n  page_size: 20\nrecognizer:\n  patterns: {}\n')
                (root / 'models').mkdir(exist_ok=True)
                (root / 'models/sentence-fivegram-mobile.bin').symlink_to(Path(args.model).resolve())
                subprocess.run([str(Path(args.exe).resolve()), str(root), str(shared),
                                str(Path(args.plugin).resolve()), selection, case, args.correction],
                               check=True, timeout=120)


if __name__ == '__main__':
    main()
