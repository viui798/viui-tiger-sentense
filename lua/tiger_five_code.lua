-- 虎单 / 虎词：第五码顶屏
--
-- 虎码单字与词最多 4 码。当前输入已经有 4 码、并且能出候选时，再按第 5 个字母键
-- 先上屏首选，再把这个字母交给 speller 作为下一字的开始。
-- 只处理纯字母编码（^[a-z]+$），不影响反查（`）、造词（'）、统计（/）、快符（;）。
local M = {}

local kNoop = 2

local function candidate_at(seg, index)
  if not seg or not seg.menu then
    return nil
  end
  seg.menu:prepare(index + 1)
  return seg.menu:get_candidate_at(index)
end

function M.processor(key, env)
  if key:release() or key:ctrl() or key:alt() or key:super() then
    return kNoop
  end
  local keycode = key.keycode
  if keycode < 0x61 or keycode > 0x7a then -- a-z
    return kNoop
  end
  local ctx = env.engine.context
  if not ctx:is_composing() then
    return kNoop
  end
  local input = ctx.input or ""
  -- 这个按键是第 5 码：已有 4 码，且全是字母
  if #input ~= 4 or not input:match("^[a-z]+$") then
    return kNoop
  end
  if not ctx:has_menu() then
    return kNoop
  end
  local seg = ctx.composition:back()
  local first = candidate_at(seg, 0)
  if not first or first.text == input then
    return kNoop
  end
  env.engine:commit_text(first.text)
  ctx:clear()
  -- 放行第 5 个字母，作为下一字的第 1 码
  return kNoop
end

M.func = M.processor

return M
