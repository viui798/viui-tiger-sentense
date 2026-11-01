-- Isolated allocation/representation invariants. No live Rime database.
local repo = arg[1] or "."
package.path = repo .. "/lua/?.lua;" .. package.path
rime_api = {get_user_data_dir=function() return repo end}
-- 夹具里的 𠀀（U+20000，4 字节）不在常用字集（tiger_sentence_common_data）里，
-- 会被字集滤镜过滤，导致 "abcdef" 解不出含它的路径、_confidence_candidates 恒空，
-- 下面的 seam 检查全部空转。注入只含夹具字符的最小字集，保证 4 字节字符可见。
package.preload["tiger_sentence_common_data"] = function()
    return "甲乙丙丁𠀀"
end
local sentence = dofile(os.getenv("TIGER_SENTENCE_MODULE") or repo.."/lua/tiger_sentence.lua")

-- 兼容旧测试 API：上游 20261010 起用 auto_select_min_code_length 取代
-- 「允许单字重码组句」布尔开关；测试沿用旧调用时映射到新 API。
local function set_duplicate_single(ctx)
    local enabled = true
    if type(ctx) == "table" and type(ctx.get_option) == "function" then
        enabled = ctx:get_option("tiger_sentence_allow_duplicate_single") and true or false
    end
    sentence.apply_auto_select_min_code_length(enabled and 1 or 0)
end

local checks = 0
local function check(ok, msg) checks=checks+1; assert(ok, msg) end
sentence.set_model_enabled(false)
local original_open=io.open
local entries="甲\tab\n乙\tab\n丙\tcd\n丁\tcd\n𠀀\tef\n甲丙\tabcd\n乙丁\tabcd\n"
io.open=function(path,mode)
    if path==repo.."/tiger_sentence.codes.txt" then
        return {read=function()return entries end,close=function()end}
    end
    return original_open(path,mode)
end
sentence.apply_high_freq_limit(0)
set_duplicate_single({get_option=function()return true end})
-- An old published snapshot survives later decode/trim/reset generations.
local function signature(result)
    local out={}
    for _,v in ipairs(result) do
        out[#out+1]=v.text.."|"..v.score
        local n=v.path
        while n do out[#out+1]=(n.text or "")..":"..(n.raw_length or 0);n=n.previous end
    end
    for _,p in ipairs(result.early_commit_evidence.prefixes) do
        out[#out+1]=p.text..":"..p.share..":"..p.base_share
    end
    return table.concat(out,";")
end
local old=sentence.decode("abcdef",true,"");local saved=signature(old)
-- The light evaluator must not call path-isolation (a menu-ranking prior),
-- while computing both confidence scores identically to the full evaluator.
local function seam(root,name)
    local seen={}
    local function find(fn)
        if seen[fn] then return end;seen[fn]=true
        local nested={}
        for i=1,200 do
            local n,v=debug.getupvalue(fn,i);if not n then break end
            if n==name then return fn,i,v end
            if type(v)=="function" then nested[#nested+1]=v end
        end
        for _,child in ipairs(nested) do local f,i,v=find(child);if f then return f,i,v end end
    end
    local f,i,v=find(root);assert(f,"missing performance seam: "..name);return f,i,v
end
local _,_,full=seam(sentence.decode,"evaluate_state")
local _,_,light=seam(sentence.decode,"evaluate_evidence_state")
local f,i,prior=seam(sentence.decode,"path_isolation_penalty")
for _,candidate in ipairs(old._confidence_candidates) do
    local expected=full(candidate.path)
    local function forbidden() error("Partial evidence evaluated ranking-only isolation") end
    debug.setupvalue(f,i,forbidden)
    local ok,actual=pcall(light,candidate.path)
    debug.setupvalue(f,i,prior)
    check(ok,"Partial evidence evaluated ranking-only isolation")
    check(actual.text==expected.text and actual.path==expected.path and
        actual.confidence_score==expected.confidence_score and
        actual.early_commit_confidence_score==expected.early_commit_confidence_score,
        "Light evidence changed confidence")
end
for i=1,25 do sentence.decode("abcd"..string.rep("ab",i%5),true,"");sentence.trim_memory() end
check(signature(old)==saved,"later generation mutated a published path/evidence snapshot")
-- Cached character count remains independent of UTF-8 byte length.
for _,p in ipairs(old.early_commit_evidence.prefixes) do
    local _,count=p.text:gsub("[^\128-\191]","")
    check(p.text_char_count==count,"prefix character count confused bytes with codepoints")
end
io.open=original_open
print(string.format('{"status":"passed","allocation_checks":%d,"real_frontend":false}',checks))
