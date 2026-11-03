do
  local count=0
  local original=tiger_sentence_processor.func
  tiger_sentence_processor.func=function(key,env)
    local result=original(key,env)
    if not key:release() then count=count+1 end
    if count==81 then
      local before=collectgarbage('count')
      local started=os.clock()
      for i=1,10 do collectgarbage('collect') end
      local elapsed=(os.clock()-started)*1000/10
      local after=collectgarbage('count')
      io.stderr:write(string.format('DEEP_HEAP before_kib=%.3f live_kib=%.3f full_gc_ms=%.3f\n',before,after,elapsed))
    end
    return result
  end
end
