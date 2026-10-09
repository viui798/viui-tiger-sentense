#!/usr/bin/env python3
from __future__ import annotations
import argparse
import subprocess
import tempfile
from pathlib import Path

ARPA = r"""\data\
ngram 1=6
ngram 2=7
ngram 3=5
ngram 4=3
ngram 5=1

\1-grams:
-1.0	<unk>	0
-0.5	<s>	-0.1
-0.6	</s>	0
-0.7	你	-0.2
-0.8	好	-0.3
-0.9	吗	-0.4

\2-grams:
-0.2	<s> 你	-0.1
-0.3	你 好	-0.2
-0.4	好 吗	-0.3
-0.5	吗 </s>	0
-0.6	<s> 好	-0.1
-0.7	你 吗	-0.2
-0.8	好 </s>	0

\3-grams:
-0.11	<s> 你 好	-0.05
-0.12	你 好 吗	-0.06
-0.13	好 吗 </s>	0
-0.14	<s> 好 吗	-0.07
-0.15	你 吗 </s>	0

\4-grams:
-0.08	<s> 你 好 吗	-0.04
-0.09	你 好 吗 </s>	0
-0.10	<s> 好 吗 </s>	0

\5-grams:
-0.03	<s> 你 好 吗 </s>

\end\
"""

LUA = r'''
package.path=arg[1].."/lua/?.lua;"..package.path
rime_api={get_user_data_dir=function() return arg[2] end,
          get_shared_data_dir=function() return "" end}
local reader=require("tiger_sentence_ngram").new({page_misses=0,page_bytes=0})
local model,err=reader.try_load({})
assert(model and model.format=="TCSKNM03",err)
assert(model.has_observed_bigram("你","好"))
assert(not model.has_observed_bigram("吗","你"))
local a,b,c,d,n=model.bos_id,0,0,0,1
local score
score,a,b,c,d,n=model.step(a,b,c,d,n,"你")
assert(math.abs(score-(-0.2*math.log(10)))<2e-5)
score,a,b,c,d,n=model.step(a,b,c,d,n,"好")
assert(math.abs(score-(-0.11*math.log(10)))<2e-5)
score,a,b,c,d,n=model.step(a,b,c,d,n,"吗")
assert(math.abs(score-(-0.08*math.log(10)))<2e-5)
score,a,b,c,d,n=model.step(a,b,c,d,n,"\3")
assert(math.abs(score-(-0.03*math.log(10)))<2e-5)
print("TCSKNM03 fixture OK",model.bytes,n)
'''

def main() -> int:
    parser=argparse.ArgumentParser()
    parser.add_argument("--lua",default="lua")
    parser.add_argument("--cxx",default="g++")
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="tcs3-") as raw:
        temp=Path(raw)
        arpa=temp/"fixture.arpa"
        arpa.write_text(ARPA,encoding="utf-8")
        builder=temp/"build_tcs_knm03"
        subprocess.run([args.cxx,"-std=c++20","-O2",
            str(root/"tools/build_tcs_knm03.cpp"),"-o",str(builder)],check=True)
        model=temp/"user"/"models"/"sentence-fivegram-mobile.bin"
        model.parent.mkdir(parents=True)
        subprocess.run([str(builder),str(arpa),str(model),str(temp/"work")],check=True)
        script=temp/"probe.lua"
        script.write_text(LUA,encoding="utf-8")
        subprocess.run([args.lua,str(script),str(root),str(temp/"user")],check=True)
    return 0

if __name__=="__main__":
    raise SystemExit(main())
