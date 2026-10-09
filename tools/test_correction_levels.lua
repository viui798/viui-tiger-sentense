-- Four user levels alter ranking cost, never the correction search profile.
local repo,data=arg[1] or '.',arg[2]
package.path=repo..'/lua/?.lua;'..package.path
rime_api={get_user_data_dir=function()return data or repo end}
local s=dofile(os.getenv('TIGER_SENTENCE_MODULE') or repo..'/lua/tiger_sentence.lua')
local c=s.correction;local checks=0
local function check(ok,msg)checks=checks+1;assert(ok,msg)end
local function context(values)return {get_option=function(_,name)return values[name]==true end}end
local oldprofile=c.profile;local profile=c.profiles[oldprofile]
for _,level in ipairs({'off','weak','medium','strong'})do
    c.set_level(level)
    check(c.enabled==(level~='off'),'wrong enabled flag')
    check(c.level==level,'wrong reported level')
    check(c.penalty==({off=6,weak=8,medium=6,strong=4})[level],'wrong level penalty')
    check(c.search_penalty==8 and c.margin==2,'strength altered fixed search cost or promotion margin')
    check(c.profile==oldprofile and c.profiles[oldprofile]==profile,'strength changed Beam profile')
    local values={[c.option_for_level(level)]=true}
    c.sync(context(values));check(c.level==level,'radio selection ignored')
    local epoch=c.epoch;c.sync(context(values));check(c.epoch==epoch,'same level discarded caches')
end
c.sync(context({[c.option]=true}));check(c.level=='medium','legacy enabled did not map to medium')
c.sync(context({}));check(c.level=='off','legacy disabled did not map to off')
local level,penalty,enabled=c.level,c.penalty,c.enabled
check(not pcall(c.set_level,'invalid'),'invalid level accepted')
check(c.level==level and c.penalty==penalty and c.enabled==enabled,'invalid level mutated runtime')
check(not pcall(c.option_for_level,'invalid'),'invalid radio option accepted')
s.ensure_lexicon();s.set_model_enabled(data~=nil)
if data then
    check(s.model_status().loaded,'real model required')
    c.diagnostics_enabled=true
    for _,raw in ipairs({'ptue','qduujhi','kispfidy','jaefmfmvqcbzl'})do
        local work
        for _,name in ipairs({'weak','medium','strong'})do
            c.set_level(name);s.reset_decode_cache()
            local one,two=c.stats.one_steps,c.stats.two_steps
            local result=s.decode(raw,false,'')
            local actual={one=c.stats.one_steps-one,two=c.stats.two_steps-two}
            if work then check(work.one==actual.one and work.two==actual.two,'strength changed scoring workload')end
            work=actual
            local count=0
            for _,v in ipairs(result)do if (v.correction_count or 0)>0 then count=count+1 end end
            check(count<=2,'strength bypassed two-correction menu cap')
            local p=c.level_penalties[name]
            c.set_enabled(true);c.penalty=p;s.reset_decode_cache()
            local expected=s.decode(raw,false,'')
            check(s.results_equal(result,expected),'strength differed from fixed-cost oracle')
            for i,v in ipairs(result)do
                check(v.correction_count==expected[i].correction_count and v.corrected_raw==expected[i].corrected_raw,'correction metadata changed')
            end
        end
        c.set_level('off');local result=s.decode(raw,false,'')
        for _,v in ipairs(result)do check(not v.correction_count,'off generated corrections')end
    end
end
print(string.format('{"correction_level_checks":%d,"real_model":%s}',checks,tostring(data~=nil)))
