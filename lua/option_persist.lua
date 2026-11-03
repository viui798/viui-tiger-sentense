-- 开关记忆：虎单 / 虎词
--
-- 背景：librime 的 switches reset 是「每个新输入会话都强制回默认」，而且
-- key_binder 的 toggle 从不写 user.yaml（只有方案菜单里的开关会按
-- switcher/save_options 落盘）。唯一可靠的跨会话记忆是方案自己存一份 Config：
-- 本模块把辅助开关写进 <user_dir>/<schema_id>.options.yaml，并在每个新会话
-- 的 init（引擎构造期间）与每次按键前重放。
--
-- 注意：对应开关必须不带 reset，否则 InitializeOptions 会在本组件 init 之后
-- 把它们写回默认值（引擎构造顺序是 InitializeComponents -> InitializeOptions）。
--
-- 首次默认值写在本文件的 NAMES / GROUPS 里；保存后以文件为准。

local kNoop = 2

local NAMES = {
  pinyin = false,
  emoji_cn = false,
  chaifen = false,
  charset_comment_filter = false,
  udpf_switch = false,
  yin = true,
  pinyin_no_model = false,
  extended_char = true,
  repeat_z = false
}

local GROUPS = {
  { path = "options/hans", options = { "s2s", "s2t", "s2hk", "s2tw" }, default = "s2s" },
  { path = "options/yin_scheme",
    options = { "yin_flypy", "yin_qp", "yin_zrm", "yin_mspy", "yin_sogou" }, default = "yin_flypy" }
}

local group_of = {}
for _, group in ipairs(GROUPS) do
  group.members = {}
  for _, name in ipairs(group.options) do
    group.members[name] = true
    group_of[name] = group
  end
end

local stores = {}
local M = {}

-- librime-lua 没有全局 file_exists（tiger_sentence.lua 自带同名局部函数）。
local function file_exists(path)
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end

local function open_store(directory, schema_id)
  local path = directory .. "/" .. schema_id .. ".options.yaml"
  if stores[path] then return stores[path] end
  local config = Config()
  if file_exists(path) then config:load_from_file(path) end
  local legacy = Config()
  if file_exists(directory .. "/user.yaml") then
    legacy:load_from_file(directory .. "/user.yaml")
  end
  local store = { config = config, path = path, values = {}, groups = {}, revision = 0 }
  for name in pairs(NAMES) do
    local value = config:get_bool("options/" .. name)
    if value == nil then value = legacy:get_bool("var/option/" .. name) end
    store.values[name] = value
  end
  for _, group in ipairs(GROUPS) do
    local value = config:get_string(group.path)
    if not group.members[value] then
      value = nil
      for _, name in ipairs(group.options) do
        if legacy:get_bool("var/option/" .. name) then value = name end
      end
    end
    store.groups[group.path] = value or group.default
  end
  stores[path] = store
  return store
end

local function save_store(store)
  local ok, saved = pcall(function()
    for name, value in pairs(store.values) do
      if value ~= nil then store.config:set_bool("options/" .. name, value) end
    end
    for _, group in ipairs(GROUPS) do
      store.config:set_string(group.path, store.groups[group.path])
    end
    return store.config:save_to_file(store.path)
  end)
  return ok and saved
end

local function apply(context, store)
  for name, fallback in pairs(NAMES) do
    local value = store.values[name]
    if value == nil then value = fallback end
    if context:get_option(name) ~= value then context:set_option(name, value) end
  end
  for _, group in ipairs(GROUPS) do
    local selected = store.groups[group.path] or group.default
    --- 先选中的再清其余：同步重译时不能出现空组。
    if group.members[selected] and not context:get_option(selected) then
      context:set_option(selected, true)
    end
    for _, name in ipairs(group.options) do
      if name ~= selected and context:get_option(name) then
        context:set_option(name, false)
      end
    end
  end
end

function M.sync(env)
  local live = env._option_persist_live
  if not live or live.syncing or live.revision == live.store.revision then return end
  live.syncing = true
  apply(env.engine.context, live.store)
  live.revision = live.store.revision
  live.syncing = false
end

function M.init(env)
  if type(Config) ~= "function" or not rime_api or
      type(rime_api.get_user_data_dir) ~= "function" then return end
  local directory = rime_api.get_user_data_dir()
  local schema = env.engine.schema
  if not directory or directory == "" or not schema or not schema.schema_id then return end
  local ok, store = pcall(open_store, directory, schema.schema_id)
  if not ok or not store then return end
  local live = { store = store, syncing = false, revision = -1 }
  env._option_persist_live = live
  M.sync(env)
  live.connection = env.engine.context.option_update_notifier:connect(function(ctx, name)
    if live.syncing then return end
    local group = group_of[name]
    if group then
      -- radio 组可能先取消再选中，只记正选择。
      if not ctx:get_option(name) then return end
      if store.groups[group.path] == name then return end
      store.groups[group.path] = name
      store.revision = store.revision + 1
      save_store(store)
      return
    end
    if NAMES[name] == nil then return end
    local value = ctx:get_option(name)
    if store.values[name] == value then return end
    store.values[name] = value
    store.revision = store.revision + 1
    -- 保持本会话过期，让其它会话在下次按键时合并，而不是互相覆盖。
    save_store(store)
  end)
end

function M.func(key, env)
  M.sync(env)
  return kNoop
end

function M.fini(env)
  local live = env._option_persist_live
  if live and live.connection then live.connection:disconnect() end
  env._option_persist_live = nil
end

return M
