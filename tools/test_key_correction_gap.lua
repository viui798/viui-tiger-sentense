-- Production D89 defaults, independent error budgets, and no-gap fallback.
local pack=arg[1] or '.'
package.path=pack..'/lua/?.lua;'..package.path
local c=require('tiger_sentence_correction')
local checks=0
local function check(ok,msg)checks=checks+1;assert(ok,msg)end
local defaults=c.profiles.A
check(defaults.delta_one==8 and defaults.delta_two==9,'default D89 thresholds missing')
check(defaults.seeds==8 and defaults.one==16 and defaults.two==8 and defaults.steps==4096,
    'D89 changed count caps or scoring quota')
check(c.profile=='A' and not c.enabled,'D89 changed first-use correction switch')
check(c.search_penalty==8 and c.margin==2,'D89 changed search cost or promotion margin')
check(c.level_penalties.weak==8 and c.level_penalties.medium==6 and c.level_penalties.strong==4,
    'D89 changed user strength penalties')
c.profiles.gaptest={seeds=8,one=16,two=8,steps=4096,delta_one=2,delta_two=3}
c.configure('gaptest')
local exact={{text='正码',score=1000},{text='另一正码',score=-1000}}
local bucket={{text='单一',score=0,correction_count=1},{text='单二',score=-2,correction_count=1},
    {text='单三',score=-2.001,correction_count=1},{text='双一',score=-100,correction_count=2},
    {text='双二',score=-103,correction_count=2},{text='双三',score=-103.001,correction_count=2}}
local result=c.current(bucket,exact,10)
check(#result==6,'wrong independent budget cutoffs')
check(result[1].text=='单一' and result[2].text=='单二','single gap boundary')
check(result[3].text=='双一' and result[4].text=='双二','double group compared to wrong pool')
check(result[5]==exact[1] and result[6]==exact[2],'exact states changed')
check(#bucket==6 and #exact==2,'input buckets changed')
c.profiles.gaptest.delta_one=nil;c.profiles.gaptest.delta_two=nil
check(#c.current(bucket,exact,10)==8,'disabled gap changed count-only behavior')
check(#c.current({},exact,10)==2,'empty correction group lost exact states')
local optional={{text='a',score=0,correction_count=1},{text='b',score=-30,correction_count=1},
    {text='c',score=-100,correction_count=2},{text='d',score=-130,correction_count=2}}
c.profiles.gaptest.delta_two=3
result=c.current(optional,nil,10)
check(#result==3 and result[2].text=='b','nil single gap inherited double cutoff')
c.profiles.gaptest.delta_one=2;c.profiles.gaptest.delta_two=nil
result=c.current(optional,nil,10)
check(#result==3 and result[3].text=='d','nil double gap inherited single cutoff')
c.profiles.gaptest.delta_one=0;c.profiles.gaptest.delta_two=0
result=c.current(optional,nil,10)
check(#result==2 and result[1].text=='a' and result[2].text=='c','zero gap ignored')
c.configure('A')
local wide={}
for n=1,24 do
    wide[#wide+1]={text=string.format('single%02d',n),score=-n/100,correction_count=1}
    wide[#wide+1]={text=string.format('double%02d',n),score=-100-n/100,correction_count=2}
end
check(#c.current(wide,exact,24)==16+8+2,'short-input count cap changed')
check(#c.current(wide,exact,25)==8+4+2,'long-input count cap changed')
local same={{text='same',score=0,correction_count=1},{text='same',score=-1,correction_count=1},
    {text='same',score=-100,correction_count=2}}
result=c.current(same,nil,10)
check(#result==2 and result[1].score==0 and result[2].correction_count==2,'dedup crossed error budgets')
local boundary={{text='s1',score=0,correction_count=1},{text='s2',score=-8,correction_count=1},
    {text='s3',score=-8.001,correction_count=1},{text='d1',score=-100,correction_count=2},
    {text='d2',score=-109,correction_count=2},{text='d3',score=-109.001,correction_count=2}}
c.gap_stats={[1]=0,[2]=0,calls=0,seen=0,pruned=0}
result=c.current(boundary,exact,10)
check(#result==6 and result[2].text=='s2' and result[4].text=='d2','production D89 boundary changed')
check(c.gap_stats[1]==2 and c.gap_stats[2]==2 and c.gap_stats.pruned==2,'gap diagnostics counted wrong paths')
c.gap_stats=nil
check(defaults.delta_one==8 and defaults.delta_two==9,'fixture mutated production defaults')
print(string.format('{"gap_unit_checks":%d,"default_d89":true}',checks))
