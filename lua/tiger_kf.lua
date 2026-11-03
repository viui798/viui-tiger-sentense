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

-- 上一次上屏的完整文本（;z 重复用；含标点/英文）。
-- 提前上屏不触发 commit_notifier，所以从 commit_history 差量拼接整段：
-- raw 片段先攒进 pending_text，遇到真正的提交再合并成一次完整上屏。
-- 上一次上屏状态按 env（引擎）隔离：Squirrel 为每个应用/会话建新引擎，
-- 模块级变量会被上一个引擎的历史串进来，导致 ;z 重复出拼接错误的文本。
local function ensure_state(env)
  local s = env._kf_state
  if not s then
    s = { last_commit = "", hist_snapshot = nil, pending_text = "" }
    env._kf_state = s
  end
  return s
end
-- 反查/造词/快符的前缀会被记成 raw 记录，不属于要重复的正文
local PREFIX_ONLY = { ["`"] = true, ["\\"] = true, ["'"] = true, [";"] = true }

-- 启动时读取一次，优先级：内置默认 < 共享 kf_symbols.schema.yaml < 方案内 kf_symbols。
local LETTERS = {}
for code = string.byte("a"), string.byte("z") do
  LETTERS[#LETTERS + 1] = string.char(code)
end

-- 逐个字母读 kf_symbols/<letter>（不依赖 ConfigMap:keys，兼容当前 librime-lua）。
local function merge_map(mapping, config)
  if not config then return end
  for _, key in ipairs(LETTERS) do
    local ok, value = pcall(function() return config:get_string("kf_symbols/" .. key) end)
    if ok and type(value) == "string" and value ~= "" then
      mapping[key] = value
    end
  end
end

local function load_symbols(env)
  local mapping = {}
  for key, value in pairs(DEFAULT_SYMBOLS) do mapping[key] = value end
  -- 共享符号表：三方案共用，改符号只改 default.custom.yaml 的 kf_symbols。
  local ok_shared, shared = pcall(function() return Schema(".default") end)
  if ok_shared and shared then merge_map(mapping, shared.config) end
  -- 方案内 kf_symbols 仍然可以覆盖（可选）。
  local ok, config = pcall(function() return env.engine.schema.config end)
  if ok and config then merge_map(mapping, config) end
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
-- 只由标点组成（ASCII 标点 / 中文标点），用于「句末标点并入上一次上屏」
local function is_punct_only(s)
  if s == "" then return false end
  for _, cp in utf8.codes(s) do
    local ascii_punct = cp > 32 and cp < 127 and not (cp >= 48 and cp <= 57)
      and not (cp >= 65 and cp <= 90) and not (cp >= 97 and cp <= 122)
    local cjk_punct = (cp >= 0x3000 and cp <= 0x303F) or (cp >= 0xFF00 and cp <= 0xFF65)
      or cp == 0x2026 or cp == 0x2014 or cp == 0x2018 or cp == 0x2019
      or cp == 0x201C or cp == 0x201D
    if not (ascii_punct or cjk_punct) then return false end
  end
  return true
end

local function merge_text(pending, text)
  if pending ~= "" and text:sub(1, #pending) == pending then return text end
  return pending .. text
end

local function capture_commits(env, commit_text)
  local ok, tbl = pcall(function() return env.engine.context.commit_history:to_table() end)
  if not ok or type(tbl) ~= "table" then return end
  local state = ensure_state(env)
  local sig = {}
  for i = 1, #tbl do
    sig[i] = tostring(tbl[i].type) .. "\0" .. tostring(tbl[i].text)
  end
  local prev = state.hist_snapshot
  state.hist_snapshot = sig
  if not prev then return end
  local n, m = #sig, #prev
  local overlap = 0
  for j = math.min(n, m), 0, -1 do
    local match = true
    for i = 1, j do
      if prev[m - j + i] ~= sig[i] then match = false break end
    end
    if match then overlap = j break end
  end
  local added = n - overlap
  if added <= 0 then return end
  -- 历史被重置/换引擎：只重建基准，清掉挂起文本，绝不把旧文本拼进来
  if overlap == 0 and #prev > 0 then
    state.pending_text = ""
    return
  end
  if added > 20 then return end
  for i = overlap + 1, n do
    local r = tbl[i]
    local text = r.text or ""
    if text ~= "" and text:sub(1, 1) ~= "/" and r.type ~= "thru" and r.type ~= "stat" then
      if r.type == "raw" then
        if commit_text then
          -- 用户提交帧：与提交文本相同的 raw 记录就是本次提交本身，跳过
          if not PREFIX_ONLY[text] and text ~= commit_text then
            state.pending_text = state.pending_text .. text
          end
        elseif env.engine.context:is_composing() then
          -- 组合中：提前上屏的片段，先攒着
          if not PREFIX_ONLY[text] then
            state.pending_text = state.pending_text .. text
          end
        elseif text ~= "" and (state.last_commit == "" or
            state.last_commit:sub(-#text) ~= text) then
          -- 非组合态：这是一次已经完成的提交（如 aaa 回车），或上次提交的残留；
          -- 残留（是 last_commit 的后缀）直接忽略。
          state.last_commit = merge_text(state.pending_text, text)
          state.pending_text = ""
        end
      elseif commit_text then
        -- 用户提交路径只收集 raw 片段；提交正文由 commit_notifier 的 get_commit_text 处理
      elseif r.type == "punct" then
        if state.last_commit ~= "" then state.last_commit = state.last_commit .. text end
      else
        state.last_commit = state.pending_text .. text
        state.pending_text = ""
      end
    end
  end
end

local function execute_quick_symbol(env, ctx, text)
  -- ;z 重复上次上屏（开关 repeat_z，默认关；关着时 ;z 仍是普通符号）
  local state = ensure_state(env)
  if text == ";z" and ctx:get_option("repeat_z") and state.last_commit ~= "" then
    env.engine:commit_text(state.last_commit)
    ctx:clear()
    return true
  end
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
  env.conn_commit = env.engine.context.commit_notifier:connect(function(ctx)
    local text = ctx:get_commit_text() or ""
    capture_commits(env, text)
    if text ~= "" and text:sub(1, 1) ~= "/" then
      local state = ensure_state(env)
      if is_punct_only(text) and state.last_commit ~= "" then
        -- 句末标点：并入上一次上屏，不要覆盖整句
        if state.last_commit:sub(-#text) ~= text then
          state.last_commit = state.last_commit .. text
        end
      else
        state.last_commit = merge_text(state.pending_text, text)
      end
      state.pending_text = ""
    end
  end)
  env._kf_cap_len = 0
  env.conn_update2 = env.engine.context.update_notifier:connect(function(ctx)
    local len = #(ctx.input or "")
    if ctx:is_composing() and len >= (env._kf_cap_len or 0) then
      env._kf_cap_len = len
      return
    end
    env._kf_cap_len = len
    capture_commits(env)
  end)
  capture_commits(env)
end

function M.fini(env)
  if env.conn_update then
    env.conn_update:disconnect()
    env.conn_update = nil
  end
  if env.conn_commit then
    env.conn_commit:disconnect()
    env.conn_commit = nil
  end
  if env.conn_update2 then
    env.conn_update2:disconnect()
    env.conn_update2 = nil
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
