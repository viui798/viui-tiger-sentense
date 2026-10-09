"""Exercise real Rime radio levels, persistence, and legacy migration in temporary data."""
import argparse
from pathlib import Path
import subprocess
from run_regressions import isolated_sources, temporary_tree

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe',required=True);parser.add_argument('--plugin',required=True)
    parser.add_argument('--model-data');args=parser.parse_args()
    scenarios=[('write','off',None,None),
        ('defaults','weak',None,'weak'),
        ('legacy','medium','options:\n  tiger_sentence_key_correction: true\n',None),
        ('legacy','off','options:\n  tiger_sentence_key_correction: false\n',None),
        ('legacy','strong','options:\n  tiger_sentence_correction_level: strong\n  tiger_sentence_key_correction: false\n',None),
        ('legacy','medium','options:\n  tiger_sentence_correction_level: invalid\n  tiger_sentence_key_correction: true\n',None),
        ('legacy-user','medium','var:\n  option:\n    tiger_sentence_key_correction: true\n',None),
        ('legacy-radio','strong','var:\n  option:\n    tiger_sentence_correction_strong: true\n',None)]
    for saved_level in ('off','weak','medium'):
        scenarios.append(('legacy',saved_level,'options:\n  tiger_sentence_correction_level: "'+saved_level+'"\n  tiger_sentence_key_correction: true\n',None))
    if args.model_data:scenarios.append(('real','off',None,None))
    for scenario,level,contents,default in scenarios:
        with temporary_tree() as root:
            isolated_sources(root)
            shared=root/'_shared';shared.mkdir()
            (shared/'default.yaml').write_text('config_version: "1.0"\nschema_list:\n  - schema: tiger_sentence\nmenu:\n  page_size: 5\nrecognizer:\n  patterns: {}\n')
            (root/'other.schema.yaml').write_text('schema:\n  schema_id: other\n  name: other\n  version: "1"\n')
            saved=root/'tiger_sentence.options.yaml'
            if contents:
                target=root/'user.yaml' if scenario in ('legacy-user','legacy-radio') else saved
                target.write_text(contents)
            if default:
                (root/'tiger_sentence.custom.yaml').write_text('patch:\n  tiger_sentence/option_defaults/tiger_sentence_correction_level: '+default+'\n')
            if scenario=='real':
                model=Path(args.model_data)/'models/sentence-fivegram-mobile.bin'
                (root/'models/sentence-fivegram-mobile.bin').symlink_to(model.resolve())
                with (root/'rime.lua').open('a') as f:
                    f.write('\nlocal ts=require("tiger_sentence")\nlocal base=tiger_sentence_translator\n'
                            'tiger_sentence_translator=function(input,seg,env)\n'
                            ' ts.correction.sync(env.engine.context)\n'
                            ' env.engine.context:set_property("test_level_penalty",tostring(ts.correction.penalty))\n'
                            ' return base(input,seg,env)\nend\n')
            else:
                with (root/'rime.lua').open('a') as f:f.write('\nrequire("tiger_sentence").set_model_enabled(false)\n')
            cmd=[str(Path(args.exe).resolve()),str(root),str(shared),str(Path(args.plugin).resolve())]
            before=(saved.read_bytes(),saved.stat().st_mtime_ns) if saved.exists() else None
            mode='legacy' if scenario.startswith('legacy') else scenario
            subprocess.run(cmd+[mode,level],check=True,timeout=120)
            if scenario=='write':
                assert saved.exists(),'missing preference file'
                data=saved.read_bytes();stamp=saved.stat().st_mtime_ns
                assert b'tiger_sentence_correction_level: strong' in data,'did not persist selected level'
                subprocess.run(cmd+['read','strong'],check=True,timeout=120)
                assert (saved.read_bytes(),saved.stat().st_mtime_ns)==(data,stamp),'restoration/typing wrote preferences'
            elif scenario!='real':
                if before:assert (saved.read_bytes(),saved.stat().st_mtime_ns)==before,'migration rewrote old settings'
                else:assert not saved.exists(),'restoration wrote an unsolicited preference file'
            print('scenario passed:',scenario,level,flush=True)

if __name__=='__main__':main()
