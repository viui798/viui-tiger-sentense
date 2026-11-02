-- 快符：分号引导的符号快捷输入，三模式通用（单字/词/整句）。
-- 符号表优先读 schema 的 kf_symbols（tiger / tigress / tiger_sentence 各一份），
-- 读不到时用内置默认值兜底；`;;` → ；、`;1` → ：、`;2` → ； 是代码规则，不在 YAML 里。
-- 借鉴万象虎 super_processor 的做法：处理器拦截按键直接上屏，不依赖 auto_select。

local M = {}

local K_REJECT, K_ACCEPT, K_NOOP = 0, 1, 2

-- 与各 schema 的 kf_symbols 保持一致（仅在配置缺失时兜底）。
local DEFAULT_SYMBOLS = {
  a = "！", b = "_", c = "”", d = "、", e = "(", f = "%", g = "·",
  h = "=", i = "-", j = "+", k = "（", l = "）", m = "」", n = "「",
  o = "[", p = "]", q = "：“", r = ")", s = "……", t = "@", u = "》",
  v = "——", w = "？", x = "→", y = "《", z = "“",
}

local punctuation = { [1] = "：", [2] = "；" }

-- 启动时读取一次：schema 的 kf_symbols 覆盖内置默认值（改符号只改 YAML）。
local function load_symbols(env)
  local mapping = {}
  for key, value in pairs(DEFAULT_SYMBOLS) do mapping[key] = value end
  local ok, config = pcall(function() return env.engine.schema.config end)
  if ok and config then
    local ok_map, map = pcall(function() return config:get_map("kf_symbols") end)
    if ok_map and map then
      local ok_keys, keys = pcall(function() return map:keys() end)
      if ok_keys and keys then
        for _, key in ipairs(keys) do
          key = tostring(key)
          local value = config:get_string("kf_symbols/" .. key)
          if type(value) == "string" and value ~= "" then
            mapping[key] = value
          end
        end
      end
    end
  end
  env.kf_mapping = mapping
end

-- 触发规则：";"+字母 → 快符；";;" → 中文分号；";数字" → 选 ：/；
local function quick_symbol(mapping, text)
  if text == ";;" then
    return "；"
  end
  local qkey = text:match("^;([a-z])$")
  if qkey then
    return mapping[qkey]
  end
  local digit = text:match("^;([1-9])$")
  if digit then
    return punctuation[tonumber(digit)]
  end
  return nil
end

-- 核心：命中则直接上屏并清空
local function execute_quick_symbol(env, ctx, text)
  local symbol = quick_symbol(env.kf_mapping or DEFAULT_SYMBOLS, text)
  if symbol and symbol ~= "" then
    env.engine:commit_text(symbol)
    ctx:clear()
    return true
  end
  return false
end

-- 处理器：拦截可打印按键，把 input+当前键 拼起来判断
local function handle_intercept(key, env, ctx)
  local keycode = key.keycode
  if keycode < 0x20 or keycode > 0x7E then return false end
  local input = ctx.input or ""
  local next_input = input .. string.char(keycode)
  return execute_quick_symbol(env, ctx, next_input)
end

-- 方案载入时就连上 update_notifier：recognizer 处理器会把命中模式的键
-- （如 ``;a``）直接 PushInput 并 kAccepted 吞掉，快符处理器收不到。
function M.init(env)
  load_symbols(env)
  env.conn_update = env.engine.context.update_notifier:connect(function(ctx)
    execute_quick_symbol(env, ctx, ctx.input or "")
  end)
end

function M.fini(env)
  if env.conn_update then
    env.conn_update:disconnect()
    env.conn_update = nil
  end
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
