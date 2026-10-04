-- tiger_zaoci.lua —— 芝士虎整 · 加词模块（` + 编码造词）
--
-- 两个角色：
--   processor  ：监听 `` ` `` 前缀造词的上屏，把「词 + 编码」写进用户词库并**同步进内存**；
--   translator ：在普通编码路径按内存词库补候选 —— 所以造完词当前会话立刻可用，
--                不必等重新部署。
--
-- 用户词库 custom_phrase.txt：纯文本、TAB 分隔、只读语义，输入法不会自动学词，
-- 也不参与主码表自动调频，词库不会自己膨胀。
--
-- 用法：`` ` `` + 虎码编码 → 选词上屏 → 写入 <用户目录>/custom_phrase.txt
--       虎码编码 + ``/`` → 该编码下的自造词候选注释变〔删词〕，选中即从词库删掉
--       （例：aaaa/ → 魑魅魍魉〔删词〕→ 选中，词库里那一行就没了，词不会打到屏幕上）
--   手工维护同一文件：每行 词<TAB>编码[<TAB>权重]，# 开头是注释；改完重新部署生效。
--
-- 造词模式下的候选有两个来源：
--   ① 词典/词库里「这个编码」的条目（含补全，见下）；
--   ② 「最近上屏的那一条词」（本模块新增，见下）。
-- 为什么需要 ②：虎码编码最长 4 码，词典条目也就到 4 码为止，所以 `` ` `` + 4 码
-- （及以上）时补全已经用尽，只剩该编码的精确条目 —— 想造的词不在其中时就会
-- 一个候选都没有（实测 `` `uawl `` = 0 个候选），自然「选不了新词」。
-- 现在把最近上屏的那一条也列出来（注释〔最近〕）：先把词打出来（什么编码、
-- 多长都行），再造词时就能把它绑到你要的编码上；只列一条，不拼接。
local M = {}

local DEFAULT_TABLE = "custom_phrase.txt"
local COMMENT = "〔自造词〕"
local CANDIDATE_QUALITY = 1e9      -- 词库候选置顶
local RECENT_QUALITY = 1e8         -- 「最近上屏」候选：排在自造词之后、词典候选之前
local RECENT_MAX = 16              -- 内存池保留条数
local RECENT_SHOWN = 1             -- 造词模式下只列「最近上屏」的那一条
local RECENT_COMMENT = "〔最近〕"
local DELETE_COMMENT = "〔删词〕"   -- 编码 + ``/`` 时自造词候选的注释
local DELETE_QUALITY = 2e9         -- 删词候选排最前
local DELETE_HINT_SECONDS = 5      -- 「已删除」回执保留时间（秒）

-- 模块级共享：三个方案共用同一份内存词库（require 只加载一次）
local store = nil                  -- { [code] = { {word=, weight=}, ... } }
local store_path = nil
local store_version = 0            -- 词库版本：整句引擎靠它判断要不要重建词库
local recent = {}                  -- 最近上屏的字词，新的在前：{ {word=, code=}, ... }
local last_delete = nil            -- 最近一次删词 { word=, code=, at= }，用于给用户回执

local function user_dir()
  if rime_api and type(rime_api.get_user_data_dir) == "function" then
    local ok, d = pcall(rime_api.get_user_data_dir)
    if ok and type(d) == "string" and d ~= "" then return d end
  end
  return nil
end

-- 词库路径：可在方案里配 tiger_zaoci/table_path（绝对路径或相对用户目录）
local function resolve_path(env)
  local name
  if env and env.engine and env.engine.schema then
    local ok, v = pcall(function()
      return env.engine.schema.config:get_string("tiger_zaoci/table_path")
    end)
    if ok then name = v end
  end
  if not name or name == "" then name = DEFAULT_TABLE end
  if name:sub(1, 1) == "/" then return name end
  local d = user_dir()
  if not d then return name end
  if d:sub(-1) == "/" or d:sub(-1) == "\\" then return d .. name end
  return d .. "/" .. name
end

local function read_content(path)
  local f = io.open(path, "rb")
  -- 文件不存在 = 空词库（全新安装只有 custom_phrase.example.txt，
  -- 没有 custom_phrase.txt）。这里必须返回空表：调用方会直接 ipairs，
  -- 返回 nil 会让 processor/translator 初始化时报 attempt to index a nil value。
  if not f then return {} end
  local content = f:read("*a") or ""
  f:close()
  content = content:gsub("^\239\187\191", "")       -- 去 BOM
  -- 去掉结尾换行（连同历史遗留的空行）：gmatch 在「…\n」上会多匹配出一个空串，
  -- 写回文件就变成一行空行，造词 / 删词来回几次就攒出一串空白。
  content = content:gsub("\r?\n+$", "")
  if content == "" then return {} end
  local lines = {}
  for line in (content .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
  return lines
end

local function sort_by_weight(list)
  table.sort(list, function(a, b)
    if (a.weight or 0) ~= (b.weight or 0) then return (a.weight or 0) > (b.weight or 0) end
    return a.word < b.word
  end)
end

local function load_file(path)
  local map = {}
  local lines = read_content(path)
  for _, line in ipairs(lines) do
    if line:sub(1, 1) ~= "#" then
      local w, c, wt = line:match("^([^\t]+)\t([^\t]+)\t?([^\t]*)")
      if w and c and w ~= "" then
        c = c:lower()
        map[c] = map[c] or {}
        map[c][#map[c] + 1] = { word = w, weight = tonumber(wt) or 0 }
      end
    end
  end
  for _, list in pairs(map) do sort_by_weight(list) end
  return map
end

local function reload_store(path)
  store_path = path
  store = load_file(path)
  store_version = store_version + 1
  return store
end

local function ensure_store(env)
  local path = resolve_path(env)
  if not store or store_path ~= path then
    reload_store(path)
  end
  return store
end

-- 纯中文才算「可造的词」；返回字数，非纯中文或超长返回 nil
local function chinese_len(word)
  if not word or word == "" then return nil end
  if word:find("[%w%p%s]") then return nil end       -- 含 ASCII/标点/空白的不收
  local n = (utf8 and utf8.len) and utf8.len(word) or #word
  if not n then return nil end
  return n
end

-- 最近上屏池：造词模式下的「新词来源」（先打一遍词，再造词就能把它绑到编码上）
local function push_recent(word, code)
  local n = chinese_len(word)
  if not n or n > 12 then return end                 -- 太长的整句不入池
  for i = 1, #recent do
    if recent[i].word == word then table.remove(recent, i) break end
  end
  table.insert(recent, 1, { word = word, code = code or "" })
  while #recent > RECENT_MAX do table.remove(recent) end
end

-- 写盘：同一 (词, 编码) 已存在则权重 +1，同时更新内存
local function save_entry(path, word, code)
  if not word or word == "" or not code or code == "" then return false end
  if word:find("[%s]") then return false end        -- 含空白的不入库
  code = code:lower()
  local lines = read_content(path)
  local hit = false
  for i, line in ipairs(lines) do
    local w, c, wt = line:match("^([^\t]+)\t([^\t]+)\t?([^\t]*)")
    if w == word and c and c:lower() == code then
      lines[i] = word .. "\t" .. code .. "\t" .. ((tonumber(wt) or 0) + 1)
      hit = true
      break
    end
  end
  if not hit then lines[#lines + 1] = word .. "\t" .. code .. "\t1" end
  local out = io.open(path, "w")
  if not out then return false end
  out:write(table.concat(lines, "\n"), "\n")
  out:close()
  reload_store(path)                                 -- 与文件权重/自定义路径保持一致
  return true
end

-- ==================== 删词：编码 + ``/`` ====================
-- 写盘：把「词 + 编码」这一行从词库里去掉，同时更新内存
local function delete_entry(path, word, code)
  if not word or word == "" or not code or code == "" then return false end
  code = code:lower()
  local lines = read_content(path)
  local kept, removed = {}, false
  for i = 1, #lines do
    local w, c = lines[i]:match("^([^\t]+)\t([^\t]+)")
    if not removed and w == word and c and c:lower() == code then
      removed = true                                   -- 这一行不要了
    else
      kept[#kept + 1] = lines[i]
    end
  end
  if not removed then return false end
  local out = io.open(path, "w")
  if not out then return false end
  out:write(table.concat(kept, "\n"), "\n")
  out:close()
  reload_store(path)                                 -- 刷新内存词库与整句引擎版本
  last_delete = { word = word, code = code, at = os.time() }
  return true
end

-- 这个编码下有没有自造词：有才把 ``/`` 当删词入口，不影响 / 的其他用法
local function has_code(code)
  local map = store or ensure_store(nil)
  local list = code and map[code]
  return (list and #list > 0) and true or false
end

-- 这条候选对应哪个编码的自造词（删词模式下就是输入的编码，精确匹配）
local function find_entry(env, code, word)
  if not word or word == "" then return nil end
  local map = store or ensure_store(env)
  local list = map[code]
  if not list then return nil end
  for i = 1, #list do
    if list[i].word == word then return code end
  end
  return nil
end

-- ==================== processor：写入 ====================
local function processor_init(env)
  env._zaoci_path = resolve_path(env)
  ensure_store(env)
  env._zaoci_conn = env.engine.context.commit_notifier:connect(function(ctx)
    local raw = ctx.input or ""
    local text = ctx:get_commit_text() or ""
    if text == "" then return end
    local zaoci = raw:sub(1, 1) == "`"                -- 只有 `` ` `` 前缀造词才写库
    local code = zaoci and raw:sub(2):lower() or ""
    push_recent(text, code)                           -- 所有上屏都进「最近」池
    if zaoci and code ~= "" then
      save_entry(env._zaoci_path, text, code)
    end
  end)
end

local function processor_fini(env)
  if env._zaoci_conn then
    env._zaoci_conn:disconnect()
    env._zaoci_conn = nil
  end
end

-- 造词模式下把数字键变成「选词键」：
-- 虎整句方案的数字键平时会写进编码（选重），直接用它选候选会失败，
-- 所以这里只在 zaoci tag 下拦截数字，其余情况原样放行。
local function page_size_of(env)
  if env._zaoci_page_size then return env._zaoci_page_size end
  local n
  local ok = pcall(function()
    n = env.engine.schema.config:get_int("menu/page_size")
  end)
  local size = (ok and type(n) == "number" and n > 0) and n or 9
  env._zaoci_page_size = size
  return size
end

-- 删词模式：数字键 / 空格 / 回车 = 「删掉这个自造词」，返回要处理的候选下标
local function delete_key_index(seg, env, repr)
  local size = page_size_of(env)
  local d = tonumber(repr)
  if d then
    if d < 0 or d > 9 then return nil end
    if d == 0 then d = 10 end
    if d > size then return nil end
  elseif repr ~= "space" and repr ~= "Return" and repr ~= "KP_Enter" then
    return nil
  end
  local menu = seg.menu
  if not menu then return nil end
  local count = menu:prepare(size)
  if not count or count == 0 then return nil end
  local index
  if d then
    local sel = seg.selected_index or 0
    index = math.floor(sel / size) * size + (d - 1)
  else
    index = seg.selected_index or 0
  end
  if index < 0 or index >= count then return nil end
  return index
end

-- 当前这一段的输入（段内文本，不含前面已确认的部分）
local function segment_input(ctx, seg)
  local raw = ctx.input or ""
  local s = (seg.start or 0) + 1
  local e = seg._end or 0
  if e > #raw then e = #raw end
  if e < s then return "" end
  return raw:sub(s, e)
end

-- 删词输入：编码 + ``/``（如 aaaa/）→ 返回编码，否则 nil
local function delete_code_of(text)
  if type(text) ~= "string" then return nil end
  return text:match("^([a-z]+)/$")
end

local function processor_func(key, env)
  if key and key.release and key:release() then return 2 end
  local ctx = env.engine.context
  local comp = ctx.composition
  if not comp or comp:empty() then return 2 end
  local seg = comp:back()
  if not seg then return 2 end

  local repr = key and key:repr() or ""
  local typed = segment_input(ctx, seg)

  -- 删词入口：编码 + ``/``。只有「这个编码确实有自造词」时才拦，
  -- 其余 ``/`` 用法（//1 统计、/0 符号菜单、标点）完全不受影响。
  if (repr == "slash" or repr == "/") and typed:match("^[a-z]+$") and has_code(typed:lower()) then
    ctx:push_input("/")                               -- 让 ``/`` 进输入串，候选改出〔删词〕
    return 1
  end

  -- 删词模式（编码 + ``/``）：选中即从词库删掉，不把词打到屏幕上
  local del_code = delete_code_of(typed)
  if del_code then
    local index = delete_key_index(seg, env, repr)
    if not index then return 2 end
    local cand = seg.menu:get_candidate_at(index)
    local word = cand and cand.text or nil
    local target = word and find_entry(env, del_code, word) or nil
    if target then
      delete_entry(env._zaoci_path or resolve_path(env), word, target)
      ctx:refresh_non_confirmed_composition()         -- 刷新候选：删掉的词消失，留〔已删除〕回执
    else
      ctx:clear()                                     -- 选的是回执：退出删词模式
    end
    return 1
  end

  if not seg:has_tag("zaoci") then return 2 end                     -- 以下只在 `` ` `` 造词模式生效

  local d = tonumber(repr)
  if not d or d < 0 or d > 9 then return 2 end
  if d == 0 then d = 10 end

  local size = page_size_of(env)
  if d > size then return 2 end
  local menu = seg.menu
  if not menu then return 2 end
  local count = menu:prepare(size)
  if not count or count == 0 then return 2 end

  local sel = seg.selected_index or 0
  local page_start = math.floor(sel / size) * size
  local index = page_start + (d - 1)
  if index >= count then return 2 end
  ctx:select(index)
  return 1                                            -- kAccepted：不让数字进编码
end

-- ==================== translator：只读内存词库，即时出候选 ====================
local function translator_init(env)
  ensure_store(env)
end

-- 整句方案（tiger_sentence）里，用户词库已经并进整句引擎自己的词库
-- （见 tiger_sentence.lua 的 rebuild_lexicon），排序交给整句（含 Tab 纠错学习）。
-- 这里若再以 CANDIDATE_QUALITY 抢首位，自造词就永远钉在第一、调频调不动。
local function sentence_owns_ranking(env)
  local ok, id = pcall(function() return env.engine.schema.schema_id end)
  return ok and id == "tiger_sentence"
end

-- 供整句引擎给候选打「〔自造词〕」标记（缓存，词库版本变了才重建）
local word_set, word_set_version = nil, -1
function M.is_user_word(word)
  if type(word) ~= "string" or word == "" then return false end
  if not word_set or word_set_version ~= store_version then
    word_set = {}
    local map = store or ensure_store(nil)
    for _, list in pairs(map) do
      for i = 1, #list do word_set[list[i].word] = true end
    end
    word_set_version = store_version
  end
  return word_set[word] == true
end

local function translator_func(input, seg, env)
  if not input or input == "" then return end
  local map = store or ensure_store(env)

  -- 删词模式（编码 + ``/``）：只列这个编码下的自造词，注释〔删词〕，选中即删（处理见 processor）
  local del_code = delete_code_of(input)
  if del_code then
    if last_delete and last_delete.code == del_code and
        os.time() - last_delete.at <= DELETE_HINT_SECONDS then
      local done = Candidate("tiger_zaoci_del_done", seg.start, seg._end,
                             "〔已删除 " .. last_delete.word .. "〕", "")
      done.quality = DELETE_QUALITY + 1
      yield(done)
    end
    local del_list = map[del_code]
    if del_list then
      local seen_word = {}
      for i = 1, #del_list do
        local w = del_list[i].word
        if w and w ~= "" and not seen_word[w] then
          seen_word[w] = true
          local cand = Candidate("tiger_zaoci_del", seg.start, seg._end, w, DELETE_COMMENT)
          cand.quality = DELETE_QUALITY
          yield(cand)
        end
      end
    end
    return
  end

  local code = input:lower()
  local seen = {}
  local list = map[code]
  if list and not sentence_owns_ranking(env) then
    for i = 1, #list do
      local item = list[i]
      seen[item.word] = true
      local cand = Candidate("tiger_zaoci", seg.start, seg._end, item.word, COMMENT)
      cand.quality = CANDIDATE_QUALITY
      yield(cand)
    end
  end

  -- 「最近上屏」候选：只在 `` ` `` 造词模式下出现，只列最近的那一条
  -- （它是「先打一遍词 → 再造词」这条路的入口），普通输入完全不受影响
  if not (seg.has_tag and seg:has_tag("zaoci")) then return end
  if RECENT_SHOWN <= 0 then return end
  local latest = recent[1]
  local text = latest and latest.word or nil
  if text and text ~= "" and not seen[text] and chinese_len(text) then
    local cand = Candidate("tiger_zaoci_recent", seg.start, seg._end, text, RECENT_COMMENT)
    cand.quality = RECENT_QUALITY
    yield(cand)
  end
end

local function translator_fini(env)
end

-- ============ 给整句引擎（tiger_sentence）取用：整句里也能用上自造词 ============
-- 整句方案走的是「整段输入 + 自己的词库」搜句，普通候选路径上的自造词它看不到，
-- 所以这里把词库交出去并入整句词库；store_version 用来告诉它「词库变了，重建」。
function M.store_version()
  return store_version
end

function M.lexicon_entries()
  local map = store or ensure_store(nil)
  local out = {}
  for code, list in pairs(map) do
    if type(code) == "string" and code:match("^[a-z]+$") then
      for i = 1, #list do
        local word = list[i].word
        if type(word) == "string" and word ~= "" then
          out[#out + 1] = { word = word, code = code }
        end
      end
    end
  end
  return out, store_version
end

M.processor  = { init = processor_init,  func = processor_func,  fini = processor_fini }
M.translator = { init = translator_init, func = translator_func, fini = translator_fini }
return M
