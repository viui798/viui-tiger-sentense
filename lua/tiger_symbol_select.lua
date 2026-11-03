-- 虎单 / 虎词：候选不足时用 `;` / `'` 顶字
--
-- 背景：虎单、虎词的 key_binder 把 `;` 绑成次选（send 2）、`'` 绑成三选（send 3）。
-- 当候选不够时，这两个键按下去没有反应，只是「卡住」。本处理器让它们在
-- 候选不足时改为「顶字」：上屏首选，并接着输出对应的标点。
--
--   例：rjk 只有唯一候选时
--     rjk;  →  符；
--
-- 判定规则（与 key_binder 的选重键一一对应）：
--   * `;`（次选键）：没有第 2 个候选 → 顶字；
--   * `'`（三选键）：没有第 3 个候选 → 顶字；
--   * 候选够数时一律放行，交给 key_binder 正常选重。
--
-- 只处理「纯虎码编码」的输入（^[a-z]+$），因此不会影响：
--   * 拼音反查（` 开头，输入里含 ' / ;）；
--   * 造词（' 开头）、统计指令（/ 开头）、计算器（= 开头）；
--   * 快符（; 开头且无编码）与标点菜单。
--
-- 与上游参考实现（symbol_proc.lua，作者 晴）的差别：那份实现顶字后把符号
-- 放行给 punctuator 输出；本方案 `;` 在 speller.alphabet、`'` 是 delimiter，
-- 放行会被 speller 当作新编码吞掉，所以这里在上屏首选后直接补上标点。
-- 标点取值与 symbols.yaml 保持一致：`;` → `；`；`'` 取右引号 `’`。

local M = {}

local kAccepted, kNoop = 1, 2
local KEY_APOSTROPHE = 0x27

-- 顶字后一并输出的标点（与 symbols.yaml 的 half_shape/full_shape 一致）
local PUNCT = {
  [0x3b] = "；", -- ;
  [KEY_APOSTROPHE] = "’", -- '
}

-- 取第 index 个候选（0 起）
local function candidate_at(seg, index)
  if not seg or not seg.menu then
    return nil
  end
  seg.menu:prepare(index + 1)
  return seg.menu:get_candidate_at(index)
end

-- 四码上屏（菜单开关，默认关）：4 个字母码完成后立即上屏首选。
-- 用 update_notifier 在 4 码翻译完成后触发；只处理纯字母编码。
local function commit_four_codes(env)
  local ctx = env.engine.context
  if not ctx:get_option("four_code_commit") then return end
  if not ctx:is_composing() then return end
  local input = ctx.input or ""
  if #input ~= 4 or not input:match("^[a-z]+$") then return end
  if not ctx:has_menu() then return end
  local seg = ctx.composition:back()
  local first = candidate_at(seg, 0)
  if not first or first.text == input then return end
  env.engine:commit_text(first.text)
  ctx:clear()
end

function M.init(env)
  env.conn_four_code = env.engine.context.update_notifier:connect(function()
    commit_four_codes(env)
  end)
end
function M.fini(env)
  if env.conn_four_code then
    env.conn_four_code:disconnect()
    env.conn_four_code = nil
  end
end

function M.processor(key, env)
  local keycode = key.keycode
  local punct = PUNCT[keycode]
  if not punct then
    return kNoop
  end
  if key:release() or key:ctrl() or key:alt() or key:super() then
    return kNoop
  end

  local ctx = env.engine.context
  if not ctx:has_menu() then
    return kNoop
  end

  -- 只接管纯虎码编码：排除反查 / 造词 / 统计 / 计算器等前缀输入
  local input = ctx.input or ""
  if not input:match("^[a-z]+$") then
    return kNoop
  end

  local seg = ctx.composition:back()
  local first = candidate_at(seg, 0)
  if not first or first.text == input then
    -- 没有候选，或候选与编码同文（编码直出），顶字没有意义
    return kNoop
  end

  -- ';' 判二选，''' 判三选；候选够数就交给 key_binder 正常选重
  local needed = (keycode == KEY_APOSTROPHE) and 2 or 1
  if candidate_at(seg, needed) then
    return kNoop
  end

  ctx:confirm_current_selection()
  env.engine:commit_text(punct)
  return kAccepted
end

M.func = M.processor

return M
