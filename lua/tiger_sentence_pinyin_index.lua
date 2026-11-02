-- 拼音码表分页索引读取器（原型）
--
-- 目标：不把 43 万条码表建成 Lua 小表（那会让 librime-lua 的每键全量 GC
-- 变成秒级），而是把码表预编译成三个文件：
--   models/pinyin.codes.idx   排序 code 表 + 段起点/条数
--   models/pinyin.codes.dat   每条 8 字节（text_off u32 / text_len u16 / flags u8）
--   models/pinyin.codes.pool  候选文本拼接
-- 运行期只保留三个大字符串（GC 标记成本极低），按 code 二分查找、按段取数。
--
-- 由 tools/build_pinyin_codes_index.py 生成；格式见该脚本头部注释。

local M = {}

local KEY_LEN = 24
local RECORD_LEN = 32

local function read_all(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return content
end

local function u16(s, i)
  local a, b = s:byte(i), s:byte(i + 1)
  if not a or not b then return nil end
  return a + b * 256
end

local function u32(s, i)
  local a, b, c, d = s:byte(i), s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
  if not a or not b or not c or not d then return nil end
  return a + b * 256 + c * 65536 + d * 16777216
end

-- 把 target 与 idx 里的定长 key 比较：-1 target 小，0 相等，1 target 大。
-- key 用 NUL 填充：只有 target 恰好等于整个 key 才算相等；target 是 key 的真前缀
-- 时按字典序算「更小」，否则二分查找会把 `ni` 误配到 `nixingfu`。
local function compare_key(index, position, target)
  for i = 1, #target do
    local b = index:byte(position + i - 1)
    if not b or b == 0 then return 1 end
    local c = target:byte(i)
    if c < b then return -1 elseif c > b then return 1 end
  end
  local next_byte = index:byte(position + #target)
  if next_byte == nil then return 1 end
  return next_byte == 0 and 0 or -1
end

function M.open(index_path, data_path, pool_path)
  local index = read_all(index_path)
  local data = read_all(data_path)
  local pool = read_all(pool_path)
  if not index or not data or not pool then return nil end
  if index:sub(1, 8) ~= "PCOD0001" then return nil end
  local code_count = u32(index, 9)
  local entry_count = u32(index, 13)
  local max_code_len = u16(index, 17)
  local lengths_count = u16(index, 19)
  if not code_count or not entry_count or not max_code_len or not lengths_count then
    return nil
  end
  local lengths = {}
  for i = 0, lengths_count - 1 do lengths[#lengths + 1] = index:byte(21 + i) end
  -- 头部固定 20 字节（magic 8 + I4 + I4 + H + H），随后是 lengths_count 个长度字节。
  local base = 20 + lengths_count

  local function entries_at(offset, count)
    local entries = {}
    for j = 1, count do
      local p = 1 + (offset + j - 1) * 8
      local text_off = u32(data, p)
      local text_len = u16(data, p + 4)
      local flags = data:byte(p + 6)
      if not text_off or not text_len or not flags then return nil end
      entries[j] = {
        t = pool:sub(text_off + 1, text_off + text_len),
        optimal = flags % 2 == 1,
        primary = flags >= 2,
      }
    end
    return entries
  end

  local function lookup(code)
    local low, high = 0, code_count - 1
    while low <= high do
      local mid = (low + high) // 2
      local pos = base + mid * RECORD_LEN + 1
      local order = compare_key(index, pos, code)
      if order == 0 then
        local offset = u32(index, pos + KEY_LEN)
        local count = u16(index, pos + KEY_LEN + 4)
        if not offset or not count then return nil end
        return entries_at(offset, count)
      elseif order > 0 then
        low = mid + 1
      else
        high = mid - 1
      end
    end
    return nil
  end

  -- 是否是某个 code 的真前缀（替代原先的 proper_code_prefixes 大表）。
  local function has_prefix(tail)
    if tail == "" then return false end
    local low, high = 0, code_count - 1
    while low < high do
      local mid = (low + high) // 2
      if compare_key(index, base + mid * RECORD_LEN + 1, tail) <= 0 then
        high = mid
      else
        low = mid + 1
      end
    end
    local position = base + low * RECORD_LEN + 1
    for i = 1, #tail do
      if index:byte(position + i - 1) ~= tail:byte(i) then return false end
    end
    return true
  end

  return {
    path = index_path,
    code_count = code_count,
    entry_count = entry_count,
    max_code_len = max_code_len,
    lengths = lengths,
    lookup = lookup,
    has_prefix = has_prefix,
  }
end

return M
