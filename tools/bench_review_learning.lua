-- Learning/query CPU benchmark, independent of LevelDb and any UI or model.
-- Run alternating old/new source directories with the SAME probe/interpreter:
-- lua tools/bench_review_learning.lua SOURCE_DIR [REPEATS]
local root,repeats=arg[1] or ".",tonumber(arg[2]) or 7
package.path=root.."/lua/?.lua;"..package.path
rime_api={get_user_data_dir=function()return root end}
os.time=function()return 1800000000 end
local sentence=require("tiger_sentence")
sentence.ensure_lexicon(nil);sentence.set_model_enabled(false)
local learning=sentence.learning
local events={}
for i=1,1000 do events[i]={code="tu"..string.format("%04d",i),text="我不是",context="",mode="bench",time=os.time()} end
local index=learning.runtime_index(events,os.time())
local function measure(name,count,run)
    run() -- materialize/cache once; this is explicitly a warm-workload benchmark
    local times,heaps={},{}
    for i=1,repeats do
        collectgarbage("collect")
        local before=collectgarbage("count")
        local start=os.clock()
        for j=1,count do run() end
        times[i]=(os.clock()-start)*1000
        heaps[i]=collectgarbage("count")-before
    end
    table.sort(times);table.sort(heaps)
    local at=math.ceil(#times/2)
    print(string.format('{"name":"%s","operations":%d,"repeats":%d,"median_cpu_ms":%.6f,"live_heap_delta_kib":%.3f}',
        name,count,repeats,times[at],heaps[at]))
end
measure("prefix_query",2000,function()learning.prefix_score(index,"bench","tu","我","")end)
sentence.set_learning_for_test(index,"bench")
local raw="jeumbauefaalhngyoehiyfbmvmxfzbflrl"
measure("decoder_with_learning",10,function()
    sentence.reset_decode_cache()
    for i=1,#raw do
        local prefix=raw:sub(1,i)
        sentence.decode(prefix,false,"")
        sentence.decode(prefix,true,"")
    end
end)
sentence.set_learning_for_test(nil,"")
measure("decoder_without_learning",10,function()
    sentence.reset_decode_cache()
    for i=1,#raw do
        local prefix=raw:sub(1,i)
        sentence.decode(prefix,false,"")
        sentence.decode(prefix,true,"")
    end
end)
