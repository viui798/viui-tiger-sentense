-- Prefix-view and interrupted-search contracts. All fixture writes are temporary.
-- lua tools/test_key_correction_reuse.lua <pack> [isolated-real-model-data]
local pack, data = assert(arg[1]), arg[2] or arg[1]
package.path = pack .. '/lua/?.lua;' .. package.path
rime_api = {get_user_data_dir=function() return data end}
local fixture, checks, completed, resumed, recovered = nil, 0, 0, 0, 0
local function check(ok, message) checks=checks+1; assert(ok, message) end
local function load_decoder(use_override)
    for name in pairs(package.loaded) do
        if name:match('^tiger_sentence') then package.loaded[name]=nil end
    end
    if fixture then
        local reader = require('tiger_sentence_ngram')
        local new = reader.new
        reader.new = function(...)
            local instance = new(...)
            instance.try_load = function(limits) return instance.load(fixture, limits) end
            return instance
        end
    end
    local override=use_override and os.getenv('TIGER_SENTENCE_MODULE')
    local s=override and dofile(override) or require('tiger_sentence')
    s.ensure_lexicon(); s.set_memory_profile('compact')
    return s
end
local function run()
    if not arg[2] then
        fixture=os.tmpname()
        dofile(pack .. '/tools/model_fixture.lua')(fixture, 12)
    end
    local s, oracle = load_decoder(true), load_decoder(false)
    check(s.model_status().loaded and oracle.model_status().loaded, 'test model not loaded')
    local c=s.correction; c.set_enabled(true); c.diagnostics_enabled=true
    oracle.correction.set_enabled(true)
    local function with_budget(steps)
        local profile = {}
        for key, value in pairs(c.profiles.A) do profile[key] = value end
        profile.steps = steps
        return profile
    end
    -- Same Beam and merge policy as A; only the independent oracle has no quota.
    oracle.correction.profiles.A.steps=math.huge
    oracle.correction.configure('A')
    for _, raw in ipairs({'kispfidy','jaefmfmvqcbzl','kospfifyiejryfen'}) do
        s.reset_decode_cache(); local first=s.decode(raw, true, '')
        local cache, searches = c.cache, c.stats.searches
        local one, two = cache.work.used[1], cache.work.used[2]
        for _, required in ipairs({'测','测试','今','不可能的前缀',''}) do
            local result=s.decode(raw, true, required)
            check(c.stats.searches==searches, 'required prefix launched a second search')
            check(c.cache==cache, 'prefix refresh replaced the search generation')
            check(cache.work.used[1]==one and cache.work.used[2]==two, 'prefix refresh renewed EOS quota')
            for _,v in ipairs(result) do
                if v.correction_count then
                    check(v.text:sub(1,#required)==required, 'unfiltered correction leaked')
                end
            end
            if not result.correction_incomplete then
                local expected=oracle.decode_full(raw,true,required)
                check(s.results_equal(result,expected), 'prefix view/full mismatch: '..raw..'/'..required)
            end
        end
        local again=s.decode(raw,true,'')
        check(s.results_equal(first,again), 'restoring prefix changed the candidate view')
    end
    c.profiles.tiny_reuse=with_budget(2)
    c.configure('tiny_reuse'); s.reset_decode_cache()
    check(s.decode('kispfidy',true,'').correction_incomplete, 'forced exhaustion missing')
    local searches=c.stats.searches
    for _,required in ipairs({'测','不匹配',''}) do
        local result=s.decode('kispfidy',true,required)
        check(result.correction_incomplete, 'prefix refresh concealed exhaustion')
        check(c.stats.searches==searches, 'exhausted generation renewed its search quota')
        check(s.capture_empty_code_candidate('kispfidy',required)==nil, 'incomplete search authorized early commit')
    end
    for _,budget in ipairs({256,512,1024}) do
        c.profiles.budget_reuse=with_budget(budget)
        c.configure('budget_reuse')
        for _,raw in ipairs({'kispfidyiejryfenahbmsp','jaefmfmvqcbzlkospfify',
                            ('kospfifyiejryfenahbmsp'):rep(2)}) do
            s.reset_decode_cache()
            for n=1,#raw do
                local old=c.cache
                local result=s.decode(raw:sub(1,n),true,'')
                local fresh=c.cache
                if fresh~=old and fresh.reused_through then
                    resumed=resumed+1
                    check(fresh.reused_through<=old.complete_through, 'reused an incomplete bucket')
                    check(fresh.from<=fresh.reused_through, 'missed crossing edges')
                    if not result.correction_incomplete then recovered=recovered+1 end
                end
                if fresh.work then
                    check(fresh.work.used[1]<=fresh.work.limit and fresh.work.used[2]<=fresh.work.limit,
                        'per-generation budget exceeded')
                end
                for _,v in ipairs(result) do
                    if v.correction_count then
                        check(v.path.raw_length==n and #v.corrected_raw==n, 'stale/partial corrected path')
                    end
                end
                if not result.correction_incomplete then
                    local expected=oracle.decode_full(raw:sub(1,n),true,'')
                    check(s.results_equal(result,expected), 'completed resumed/full mismatch: '..budget..'/'..raw:sub(1,n))
                    completed=completed+1
                end
            end
            for n=#raw-1,5,-1 do
                local old=c.cache
                local result=s.decode(raw:sub(1,n),true,'')
                if c.cache~=old and c.cache.reused_through then
                    resumed=resumed+1
                    check(c.cache.reused_through<=old.complete_through, 'backspace reused incomplete bucket')
                    if not result.correction_incomplete then recovered=recovered+1 end
                end
                if not result.correction_incomplete then
                    check(s.results_equal(result,oracle.decode_full(raw:sub(1,n),true,'')), 'resumed backspace/full mismatch')
                    completed=completed+1
                end
            end
        end
    end
    check(resumed>0, 'did not exercise interrupted-prefix reuse')
    check(recovered>0, 'did not exercise completion after interruption')
end
local ok, failure=xpcall(run,debug.traceback)
if fixture then os.remove(fixture) end
if not ok then error(failure,0) end
print(string.format('{"reuse_checks":%d,"completed_oracle_comparisons":%d,"prefix_resumes":%d,"recovered_generations":%d,"real_model":%s}',checks,completed,resumed,recovered,tostring(arg[2]~=nil)))
