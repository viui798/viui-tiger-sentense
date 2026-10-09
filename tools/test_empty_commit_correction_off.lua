-- Enabling correction disables empty-code commit, not probabilistic commit.
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
        if seen[fn]then return end;seen[fn]=true;local children={}
        for i=1,200 do
            local n,v=debug.getupvalue(fn,i);if not n then break end
            if n==name then return fn,i,v end
            if type(v)=='function'then children[#children+1]=v end
        end
        for _,child in ipairs(children)do local f,i,v=visit(child);if f then return f,i,v end end
    end
    local f,i,v=visit(root);assert(f,'missing closure '..name);return f,i,v
end
local function value(root,name)local _,_,v=slot(root,name);return v end
local attempt=value(s.processor,'try_empty_code_commit')
local state_for=value(s.processor,'sentence_state')
local lex=value(s.decode,'lexicon_state')
local c=s.correction
check(c.before_append==nil,'obsolete correction empty-code precheck retained')
local function test(spec)
    c.enabled=spec.correction~=false
    local committed_raw=spec.context and 'abcdefgh' or ''
    local committed_text=spec.context and '已提交' or ''
    local raw=committed_raw..'pt'..string.rep('z',spec.tail or 1)
    local properties={};local context={input=raw:sub(#committed_raw+1),caret_pos=#raw-#committed_raw}
    function context:get_option(k)return k=='tiger_sentence_early_commit' and spec.early~=false end
    function context:get_property(k)return properties[k] or ''end
    function context:set_property(k,v)properties[k]=v end
    local env={engine={context=context,schema={config={get_int=function()return spec.retain or 0 end}}}}
    local state=state_for(context,env);state.committed_raw=committed_raw;state.committed_text=committed_text
    state.suspended=spec.suspended or false;local trackers={sentinel={}};state.trackers=trackers
    local pending={candidate_text=committed_text..'跃',committed_text=committed_text,
        base_raw_length=#committed_raw+2,last_segment_start=#committed_raw,requires_uniqueness_check=true}
    state.empty_code_pending=not spec.no_pending and pending or nil
    local edits={};local count,probes,output=0,0,''
    local function replace(name,fn)
        local f,i,old=slot(attempt,name);edits[#edits+1]={f,i,old};debug.setupvalue(f,i,fn)
    end
    local prefixes=lex.proper_code_prefixes;lex.proper_code_prefixes={}
    replace('capture_empty_code_candidate',function()probes=probes+1;return pending end)
    replace('has_complete_candidate',function()probes=probes+1;return spec.complete==true end)
    replace('competing_boundary_end',function(_,floor,boundary)return boundary+(spec.crossing or 0)end)
    replace('submit_early',function(_,_,_,text)count=count+1;output=output..text end)
    replace('restore_composition_input',function(_,text)context.input=text end)
    local ok,result=pcall(attempt,env,state,raw:sub(1,-2),'z')
    for i=#edits,1,-1 do local e=edits[i];debug.setupvalue(e[1],e[2],e[3])end
    lex.proper_code_prefixes=prefixes
    check(ok,tostring(result))
    if c.enabled then check(result==false and count==0,'correction enabled allowed empty-code commit')end
    check(result==spec.commit,'incorrect empty-code policy')
    check(count==(spec.commit and 1 or 0),'incorrect submission count')
    if spec.commit then
        check(output=='跃' and state.committed_raw==committed_raw..'pt','wrong committed boundary')
        check(context.input==string.rep('z',spec.tail or 1),'retained input lost')
    elseif c.enabled or spec.early==false or spec.suspended then
        check(probes==0,'disabled empty-code path performed candidate work')
        check(state.empty_code_pending==nil,'disabled empty-code retained stale proposal')
        check(state.committed_raw==committed_raw and state.committed_text==committed_text,'guard changed committed history')
        check(state.trackers==trackers,'empty-code guard reset probabilistic trackers')
    end
    cases=cases+1
end
for _,tail in ipairs({1,2,3,4,8,32})do
    test{tail=tail,commit=false}
    test{tail=tail,no_pending=true,commit=false}
end
test{tail=8,context=true,retain=3,commit=false}
test{tail=8,complete=true,commit=false}
test{tail=8,early=false,commit=false}
test{tail=8,suspended=true,commit=false}
test{correction=false,tail=1,commit=true}
test{correction=false,tail=4,retain=3,commit=true}
test{correction=false,tail=1,retain=3,commit=false}
test{correction=false,tail=1,no_pending=true,commit=true}
test{correction=false,tail=8,early=false,commit=false}
test{correction=false,tail=8,suspended=true,commit=false}
c.enabled=false
if data then
    s.set_model_enabled(true);check(s.model_status().loaded,'real model required')
    c.set_enabled(true)
    check(s.decode('pt')[1].text=='跃','prefix fixture changed')
    check(#s.decode('ptu')==0,'partial code is no longer empty')
    local result=s.decode('ptue')
    check(result[1].text=='是的' and result[1].correction_count==1,'short correction failed')
    check(result[1].corrected_raw=='otue','wrong corrected code')
    for _,tail in ipairs({1,3,12})do test{tail=tail,no_pending=true,commit=false}end
end
print(string.format('{"empty_commit_correction_checks":%d,"cases":%d,"real_model":%s}',checks,cases,tostring(data~=nil)))
