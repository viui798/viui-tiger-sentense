-- Test private production closures; no test seams are added to the runtime.
local repo,data=arg[1] or '.',arg[2]
package.path=repo..'/lua/?.lua;'..package.path
rime_api={get_user_data_dir=function()return data or repo end}
local s=dofile(os.getenv('TIGER_SENTENCE_MODULE') or repo..'/lua/tiger_sentence.lua')
s.ensure_lexicon();s.set_model_enabled(false)
local checks,cases=0,0
local function check(ok,msg)checks=checks+1;assert(ok,msg)end
local function slot(root,name)
    local seen={}
    local function visit(fn)
        if seen[fn]then return end;seen[fn]=true
        local children={}
        for i=1,200 do
            local n,v=debug.getupvalue(fn,i);if not n then break end
            if n==name then return fn,i,v end
            if type(v)=='function'then children[#children+1]=v end
        end
        for _,child in ipairs(children)do local f,i,v=visit(child);if f then return f,i,v end end
    end
    local f,i,v=visit(root);assert(f,'missing private function '..name);return f,i,v
end
local function value(root,name)local _,_,v=slot(root,name);return v end
local attempt=value(s.processor,'try_early_commit')
local state_for=value(attempt,'sentence_state')
local df,di,decode=slot(attempt,'decode')
local gf,gi,initial_generation=slot(attempt,'model_generation')
local c=s.correction
local function environment(raw,enabled)
    local properties={}
    local context={input=raw,caret_pos=#raw}
    function context:get_property(k)return properties[k] or ''end
    function context:set_property(k,v)properties[k]=v end
    function context:get_option(k)return k=='tiger_sentence_early_commit' and enabled end
    local env={engine={context=context,commit_text=function()error('unexpected commit')end}}
    local state=state_for(context,env)
    state.trackers={sentinel={}};state.last_seen_raw='stale'
    state.empty_code_pending={stale=true}
    return env,state,properties
end
local function synthetic(spec)
    c.enabled=spec.correction~=false
    local env,state=environment(spec.raw or 'qduujhi',spec.early~=false)
    if spec.caret then env.engine.context.caret_pos=spec.caret end
    state.suspended=spec.suspended or false
    local calls={}
    debug.setupvalue(df,di,function(raw,early,required,lock)
        calls[#calls+1]=early and 'evidence' or 'ordinary'
        if spec.fail_at==#calls then error('test-only decode failure')end
        if spec.generation_at==#calls then
            debug.setupvalue(gf,gi,initial_generation+1)
        end
        local r=early and (spec.upgrade or spec.result) or spec.result
        return r or {{text='普通候选',correction_count=0}}
    end)
    local ok,err=pcall(attempt,env)
    debug.setupvalue(df,di,decode)
    check(table.concat(calls,',')==spec.calls,spec.message or 'wrong evidence dispatch')
    if spec.fail_at then check(not ok and tostring(err):find('test%-only decode failure'),'decode error swallowed')
    else check(ok,tostring(err))end
    if spec.cleared then
        check(next(state.trackers)==nil and state.last_seen_raw=='' and state.empty_code_pending==nil,'blocked generation retained stale early commit')
    end
    if spec.generation_at then check(state.model_generation==initial_generation+1,'model generation not synchronized')end
    debug.setupvalue(gf,gi,initial_generation);cases=cases+1
end
synthetic{result={{text='造轮子',correction_count=1}},calls='ordinary',cleared=true,message='blocked correction built early evidence'}
synthetic{result={{text='测试一下',correction_count=2}},calls='ordinary',cleared=true}
synthetic{result={correction_incomplete=true,{text='正码'}},calls='ordinary',cleared=true,message='incomplete correction built early evidence'}
synthetic{calls='ordinary,evidence'}
synthetic{result={{text='已锁定纠错历史',correction_history=true}},calls='ordinary,evidence'}
synthetic{result={},calls='ordinary,evidence'}
synthetic{correction=false,calls='evidence',message='correction-off gained preflight work'}
synthetic{early=false,calls=''}
synthetic{suspended=true,calls=''}
synthetic{caret=2,calls=''}
synthetic{raw='qduu',calls=''}
synthetic{generation_at=1,calls='ordinary',cleared=true,message='preflight model change built early evidence'}
synthetic{generation_at=2,calls='ordinary,evidence',cleared=true}
synthetic{upgrade={correction_incomplete=true,{text='正码'}},calls='ordinary,evidence',cleared=true}
synthetic{upgrade={{text='造轮子',correction_count=1}},calls='ordinary,evidence',cleared=true}
synthetic{fail_at=1,calls='ordinary'}
synthetic{fail_at=2,calls='ordinary,evidence'}
c.enabled=false
if data then
    s.set_model_enabled(true);check(s.model_status().loaded,'real model required')
    c.set_enabled(true);c.diagnostics_enabled=true
    for _,raw in ipairs({'qduujhi','kispfidy'})do
        s.reset_decode_cache();local ordinary
        for n=1,#raw do ordinary=s.decode(raw:sub(1,n),false,'')end
        check(ordinary[1] and (ordinary[1].correction_count or 0)>0,'known corrected input not corrected')
        local env,state=environment(raw,true)
        local builds=s.performance_status().current.early_evidence_builds
        local searches,one,two=c.stats.searches,c.stats.one_steps,c.stats.two_steps
        attempt(env)
        check(s.performance_status().current.early_evidence_builds==builds,'real corrected input built early evidence')
        check(c.stats.searches==searches and c.stats.one_steps==one and c.stats.two_steps==two,'preflight renewed correction work')
        check(next(state.trackers)==nil and state.empty_code_pending==nil,'real blocked state not reset')
        local after=s.decode(raw,false,'')
        check(s.results_equal(ordinary,after),'preflight changed corrected results')
    end
    s.reset_decode_cache()
    local raw='jaefmfmvqcbzl';local ordinary=s.decode(raw,false,'')
    check(ordinary[1].text=='今天天气不错' and not ordinary[1].correction_count,'expected exact top')
    local builds=s.performance_status().current.early_evidence_builds
    local searches,one,two=c.stats.searches,c.stats.one_steps,c.stats.two_steps
    local env=environment(raw,true);attempt(env)
    check(s.performance_status().current.early_evidence_builds==builds+1,'eligible input failed to build one evidence generation')
    check(c.stats.searches==searches and c.stats.one_steps==one and c.stats.two_steps==two,'evidence upgrade repeated correction search')
    local after=s.decode(raw,false,'')
    for i,item in ipairs(ordinary)do
        check(item.text==after[i].text and item.score==after[i].score and item.correction_count==after[i].correction_count,'eligible output changed')
    end
    c.profiles.gate_tiny={seeds=8,one=16,two=8,steps=2};c.configure('gate_tiny');s.reset_decode_cache()
    local limited=s.decode('kispfidy',false,'')
    check(limited.correction_incomplete,'incomplete fixture did not exhaust')
    builds=s.performance_status().current.early_evidence_builds
    searches=c.stats.searches
    env=environment('kispfidy',true);attempt(env)
    check(s.performance_status().current.early_evidence_builds==builds,'real incomplete input built early evidence')
    check(c.stats.searches==searches,'incomplete preflight renewed search')
end
print(string.format('{"evidence_gate_checks":%d,"synthetic_cases":%d,"real_model":%s}',checks,cases,tostring(data~=nil)))
