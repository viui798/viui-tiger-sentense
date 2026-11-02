-- 双引号全字集反查：speller 不接收 "，由本处理器在识别器之前把它放进输入串。
-- 之后交给 matcher / affix_segmentor@yin_full 出 tiger_full 候选。
local M = {}
local K_ACCEPT, K_NOOP = 1, 2

function M.processor(key, env)
  if key:release() then return K_NOOP end
  -- librime 里双引号键的 repr 是 "quotedbl"，不是字符 "。
  local repr = key:repr()
  if repr ~= "quotedbl" and repr ~= '"' then return K_NOOP end
  local ctx = env.engine.context
  if ctx:is_composing() then return K_NOOP end
  ctx:push_input('"')
  return K_ACCEPT
end

M.func = M.processor
return M
