-- Standalone Lua heap/RSS probe, NOT an iOS extension footprint measurement.
-- lua tools/bench_memory.lua SOURCE_ROOT baseline|balanced|compact [burst_cases]
-- A counting-allocator runner can supply __memory(reset) -> current, peak bytes.
-- Without it, allocation peaks are explicitly null (not sampled/guessed).
local repo,profile=arg[1] or '.',arg[2] or 'balanced'
local bursts=tonumber(arg[3]) or 100
assert(bursts>=1 and bursts%1==0)
package.path=repo..'/lua/?.lua;'..package.path
rime_api={get_user_data_dir=function()return repo end}
local function memory()if __memory then return __memory()end return collectgarbage('count')*1024,nil end
local function number(x)return x and string.format('%.3f',x) or 'null'end
local function phase(name)
 local before,peak=memory()
 collectgarbage('collect')
 local retained=collectgarbage('count')*1024
 local rss,hwm
 local f=io.open('/proc/self/status','r')
 if f then local text=f:read('*a');f:close();rss=tonumber(text:match('VmRSS:%s*(%d+)'));hwm=tonumber(text:match('VmHWM:%s*(%d+)'))end
 print(string.format('{"phase":%q,"lua_before_gc_bytes":%s,"lua_retained_bytes":%s,"lua_phase_peak_bytes":%s,"rss_kib":%s,"process_hwm_kib":%s}',name,number(before),number(retained),number(peak),number(rss),number(hwm)))
 if __memory then __memory(true)end
end
print(string.format('{"lua":%q,"profile":%q,"bursts":%d,"allocator_instrumented":%s,"physical_ios":false}',_VERSION,profile,bursts,tostring(__memory~=nil)))
phase('empty')
local s=require('tiger_sentence')
if profile~='baseline' then assert(s.set_memory_profile and s.set_memory_profile(profile),'profile unavailable')end
phase('module')
s.ensure_lexicon(nil);phase('lexicon')
assert(s.model_status().loaded,'production model required for this probe');phase('model')
local function run(raw,times)
 s.reset_decode_cache()
 for n=1,#raw do
  local start=os.clock()
  local result=s.decode(raw:sub(1,n),true,'')
  for _,item in ipairs(result)do assert(type(item.segmented)=='string')end
  if times then times[#times+1]=(os.clock()-start)*1000 end
 end
end
for _,raw in ipairs({'jaefmonyftuderlmljgbmnvs','jeumbauefaalhngyoehiyfbmvmxfzbflrl','nnczggqrrjrrltwwbwkedmkswgjgiuapnphbszbp'})do run(raw);phase('input_'..#raw)end
local seed,times=20260914,{}
local allocation_calls, allocation_growth
if __allocations then allocation_calls, allocation_growth=__allocations() end
local function rnd(n)seed=seed*48271%2147483647;return seed%n+1 end
for j=1,bursts do
 local chars={};for i=1,40 do chars[i]=string.char(96+rnd(26))end
 run(table.concat(chars),times)
 if j==1 or j==20 or j==bursts then phase('random_'..j)end
end
if __allocations then
 local calls,growth=__allocations()
 print(string.format('{"allocation_phase":"random_bursts","calls":%.0f,"growth_bytes":%.0f}',
   calls-allocation_calls,growth-allocation_growth))
end
if s.performance_status then
 local stats=s.performance_status().current
 print(string.format('{"lookup_phase":"random_bursts","page_misses":%.0f,"page_bytes":%.0f}',stats.page_misses,stats.page_bytes))
end
local total=0;for _,v in ipairs(times)do total=total+v end;table.sort(times)
print(string.format('{"timing":"40-key bursts including evidence and segmentation","keys":%d,"mean_cpu_ms":%.6f,"p95_cpu_ms":%.6f,"p99_cpu_ms":%.6f,"max_cpu_ms":%.6f}',#times,total/#times,times[math.ceil(#times*.95)],times[math.ceil(#times*.99)],times[#times]))
run(('jeumbauefaalhngyoehiyfbmvmxfzbflrl'):rep(4):sub(1,128));phase('long_128')
s.reset_decode_cache();phase('reset')
if s.trim_memory then
 local start=os.clock();s.trim_memory()
 print(string.format('{"trim_cpu_ms":%.6f}',(os.clock()-start)*1000));phase('trim')
end
s.set_model_enabled(false);phase('model_disabled')
