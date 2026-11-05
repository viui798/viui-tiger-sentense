-- 双拼专用反查表：把「双拼键串」精确映射到「全拼码」，再交给现有引擎解码。
--
-- 为什么不用运行时键位转换：转换失败时无论怎么兜底，都可能把简拼/全拼词混进
-- 双拼候选（例如残余字母折成首字母简拼）。查表是精确匹配：表里没有这个键串，
-- 就是没有候选，结构上不会“猜”。
--
-- 产物由 tools/export_double_pinyin_codes.py 生成码表，
-- tools/build_pinyin_codes_index.py --prefix pinyin.<scheme> 建索引。
local M = {}

local CACHE = {}      -- scheme -> index 或 false
local PREFIX = "models/pinyin."

local function user_dir()
  if rime_api and type(rime_api.get_user_data_dir) == "function" then
    local ok, dir = pcall(rime_api.get_user_data_dir)
    if ok and type(dir) == "string" and dir ~= "" then return dir end
  end
  return nil
end

local function open_index(scheme)
  if CACHE[scheme] ~= nil then return CACHE[scheme] or nil end
  local ok_mod, module = pcall(require, "tiger_sentence_pinyin_index")
  local dir = user_dir()
  if not ok_mod or not module or not dir then
    CACHE[scheme] = false
    return nil
  end
  local ok_open, index = pcall(module.open,
    dir .. "/" .. PREFIX .. scheme .. ".idx",
    dir .. "/" .. PREFIX .. scheme .. ".dat",
    dir .. "/" .. PREFIX .. scheme .. ".pool")
  local result = (ok_open and index) or false
  CACHE[scheme] = result
  return result or nil
end

-- 返回该键串唯一对应的全拼码；没有就返回 nil（调用方不要再兜底）。
function M.lookup(scheme, keys)
  if not scheme or not keys or keys == "" then return nil end
  local index = open_index(scheme)
  if not index then return nil end
  local ok, entries = pcall(index.lookup, keys)
  if not ok or type(entries) ~= "table" or #entries == 0 then return nil end
  return entries[1].t
end

function M.available(scheme)
  return open_index(scheme) ~= nil
end

M._reset_for_test = function() CACHE = {} end
return M
