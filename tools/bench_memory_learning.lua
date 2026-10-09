-- Synthetic maximum-length learning history: no model, LevelDb or UI.
-- Same probe for old/new sources. Events/aggregates remain resident in both.
local repo,n=arg[1] or '.',tonumber(arg[2]) or 10000
package.path=repo..'/lua/?.lua;'..package.path
local m=require('tiger_sentence_learning')
local function sample(name)
 local current,peak
 if __memory then current,peak=__memory()end
 collectgarbage('collect')
 print(string.format('{"phase":%q,"retained_bytes":%.0f,"peak_bytes":%s}',name,collectgarbage('count')*1024,peak and tostring(peak) or 'null'))
 if __memory then __memory(true)end
end
sample('module')
local events={}
for i=1,n do events[i]={code=string.format('ab%05d',i),text=string.rep('甲',16),mode='memory',context='左文',time=1800000000}end
local index=m.runtime_index(events,1800000000);sample('events_and_aggregates')
local start=os.clock()
for _,e in ipairs(events)do assert(m.score(index,e.mode,e.code,e.text,e.context)==9)end
print(string.format('{"records":%d,"query_cpu_ms":%.3f}',n,(os.clock()-start)*1000))
sample('all_codes_queried')
for _,i in ipairs({1,math.floor(n/2),n})do local e=events[i];assert(m.score(index,e.mode,e.code,e.text,e.context)==9)end
sample('revisited')
