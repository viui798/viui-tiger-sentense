-- Shift 大写直出
--
-- 目标：中文态、没有编码时，「按住/点下 Shift 再打字母」直接上屏大写字母，
--       不进入候选、不留编码。也就是把 Shift 当普通键盘的大写键用。
--
-- 背景（2026-10 手机端排查）：
--   * librime 的 speller 只看 keycode、不理会 Shift 修饰键，所以中文态下
--     Shift+a 会被当成虎码编码 'a'，出中文候选；
--   * 部分手机前端（元书/同文）的 Shift 是键盘自己的大小写状态，是否把
--     Shift 送进 librime、送的是 Shift_L 还是大写字符，各前端不一致。
--   本处理器同时兼容三种情况：
--     1) 字母带 Shift 修饰：repr 形如 "Shift+a"；
--     2) 前端直接发大写键码：repr 形如 "A"；
--     3) 前端只发一次裸 Shift_L/Shift_R，字母仍是小写：记住这次 Shift，
--        紧跟着的第一个字母按大写处理。
--
-- 只在「非西文态 + 没有正在输入」时接管，所以不影响：
--   * 西文态（ascii_mode）下的正常英文输入；
--   * 已经输入了虎码编码之后的继续输入；
--   * 其他所有按键（一律 kNoop 放行）。

local M = {}

local kAccepted, kNoop = 1, 2

-- 单个字母的按键描述；不是字母返回 nil
local function letter_of(repr)
  return repr:match("^Shift%+(%a)$") or repr:match("^(%a)$")
end

local function is_shift_key(repr)
  return repr == "Shift_L" or repr == "Shift_R" or repr == "Shift"
end

function M.init(env)
  M.shift_pending = false
end

function M.fini(env)
  M.shift_pending = false
end

function M.processor(key, env)
  if key:release() then
    return kNoop
  end
  if key:ctrl() or key:alt() or key:super() then
    return kNoop
  end

  local repr = key:repr()

  -- 记录裸 Shift 按下：有些前端只在 Shift 键本身发一次 Shift_L
  if is_shift_key(repr) then
    M.shift_pending = true
    return kNoop
  end

  local ch = letter_of(repr)
  if not ch then
    -- 任何其他按键都清掉「刚按过 Shift」的状态，避免误伤后续中文输入
    M.shift_pending = false
    return kNoop
  end

  local pending = M.shift_pending
  M.shift_pending = false

  local ctx = env.engine.context
  if ctx:is_composing() or ctx:get_option("ascii_mode") then
    return kNoop
  end

  local shifted = pending
    or repr:find("^Shift%+") ~= nil
    or ch:match("%u") ~= nil
  if not shifted then
    return kNoop
  end

  env.engine:commit_text(ch:upper())
  return kAccepted
end

M.func = M.processor

return M
