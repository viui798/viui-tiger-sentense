-- 双引号全字集反查：speller 不接收 "，由本处理器在识别器之前把它放进输入串。
-- 之后交给 matcher / affix_segmentor@yin_full 出 tiger_full 候选。
local M = {}
local K_ACCEPT, K_NOOP = 1, 2

function M.processor(key, env)
  if key:release() then return K_NOOP end
  local ctx = env.engine.context
  -- 西文模式：不拦截，反斜杠直接交给前端（否则会抢占后续字母开中文组词）。
  if ctx:get_option("ascii_mode") then return K_NOOP end
  -- 反斜杠键：repr 可能是 "\" 或 "backslash"。
  local repr = key:repr()
  if repr ~= "backslash" and repr ~= "\\" then return K_NOOP end
  if ctx:is_composing() then return K_NOOP end
  ctx:push_input("\\")
  return K_ACCEPT
end

M.func = M.processor
return M
