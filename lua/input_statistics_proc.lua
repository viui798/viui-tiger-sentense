-- 链首计键：提前上屏会清空 input，不能用 input 反推。
-- 源文件变更后，本文件只作为 lua_processor 的入口。
local stats = require("input_statistics")
return { func = function(key, env) return stats.processor(key, env) end }
