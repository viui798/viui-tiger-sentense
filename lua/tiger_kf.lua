-- 快符：分号引导的符号快捷输入，三模式通用（单字/词/整句）
-- 借鉴万象虎 super_processor 的做法：
--   1) 处理器拦截按键，把 input+当前键 拼起来命中触发规则后直接 commit_text 上屏；
--   2) update_notifier 兜底，输入变化时也检查一次；
-- 全程不依赖 auto_select，因此整句(auto_select=false)也能用。

local M = {}

local K_REJECT, K_ACCEPT, K_NOOP = 0, 1, 2

-- 与 kf.dict.yaml 中 ; 引导的条目保持一致
local quick = {
  a = "！", b = "_", c = "”", d = "、", e = "(", f = "%", g = "·",
  h = "=", i = "-", j = "+", k = "（", l = "）", m = "」", n = "「",
  o = "[", p = "]", q = "：“", r = ")", s = "……", t = "@", u = "》",
  v = "——", w = "？", x = "→", y = "《", z = "“"
}

local punctuation = { [1] = "：", [2] = "；" }

-- 触发规则：";"+字母 → 快符；";;" → 中文分号；";数字" → 选 ：/；
local function quick_symbol(text)
  if text == ";;" then
    return "；"
  end
  local qkey = text:match("^;([a-z])$")
  if qkey then
    return quick[qkey]
  end
  local d = text:match("^;([1-9])$")
  if d then
    return punctuation[tonumber(d)]
  end
  return nil
end

-- 核心：命中则直接上屏并清空
local function execute_quick_symbol(env, ctx, text)
  local sym = quick_symbol(text)
  if sym and sym ~= "" then
    env.engine:commit_text(sym)
    ctx:clear()
    return true
  end
  return false
end

-- 处理器：拦截可打印按键，把 input+当前键 拼起来判断
local function handle_intercept(key, env, ctx)
  local kc = key.keycode
  if kc < 0x20 or kc > 0x7E then return false end
  local input = ctx.input or ""
  local next_input = input .. string.char(kc)
  if execute_quick_symbol(env, ctx, next_input) then
    return true
  end
  return false
end

-- 方案载入时就连上 update_notifier：recognizer 处理器会把命中模式的键
-- （如 ``;a``）直接 PushInput 并 kAccepted 吞掉，快符处理器收不到；
-- 旧版「首次调用时再连通知器」的惰性写法，会话里第一次打快符时连不上，
-- 候选就只有 ``！`` 而不会自动上屏。
function M.init(env)
  env.conn_update = env.engine.context.update_notifier:connect(function(ctx)
    execute_quick_symbol(env, ctx, ctx.input or "")
  end)
end

function M.fini(env)
  if env.conn_update then env.conn_update:disconnect(); env.conn_update = nil end
end

function M.processor(key_event, env)
  if not env.conn_update then
    env.conn_update = env.engine.context.update_notifier:connect(function(ctx)
      execute_quick_symbol(env, ctx, ctx.input or "")
    end)
  end
  if key_event:release() then return K_NOOP end
  local ctx = env.engine.context
  if handle_intercept(key_event, env, ctx) then
    return K_ACCEPT
  end
  return K_NOOP
end

M.func = M.processor

return M
