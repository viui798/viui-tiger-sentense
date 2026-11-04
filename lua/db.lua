-- ==================== 0. 引入外部依赖 ====================
local wanxiang = require("wanxiang/wanxiang")
local userdb = require("wanxiang/userdb")

-- ==================== 1. 全局常量与路径预解析 ====================
local ENTRY_SEP = string.char(1)
local USER_DATA_DIR = rime_api.get_user_data_dir()

local function find_dict_path(filename)
    local check_list = {
        USER_DATA_DIR .. "/lua/" .. filename,  -- 优先 lua 目录
        USER_DATA_DIR .. "/" .. filename       -- 次选根目录
    }
    for _, path in ipairs(check_list) do
        if wanxiang.file_exists(path) then 
            return path 
        end
    end
    return nil
end

local PATHS = {
    collision_tiger = find_dict_path("chongma_tiger.txt"),
    collision_wubi  = find_dict_path("chongma_wubi.txt"),
    tigress_ci      = find_dict_path("tiger_dicts/tigress/tigress_ci.dict.yaml") or find_dict_path("tigress_ci.dict.yaml"),
    wubici          = find_dict_path("wubici.dict.yaml")
}

-- 全局句柄缓存
local GLOBAL_CACHE = {
    dbs = {}
}

-- ==================== 2. 数据库与通用工具 ====================
local db_pool = setmetatable({}, { __mode = "v" }) -- 弱引用缓存池

local function get_level_db(db_name)
    local key = db_name .. ".userdb"
    local db = db_pool[key]
    if not db then
        db = userdb.LevelDb(db_name)
        db:open()
        db_pool[key] = db
    end
    return db
end

local function log_rebuild(module_name, reason, duration)
    local log_dir = USER_DATA_DIR .. "/lua/data"
    local log_file_path = log_dir .. "/db_rebuild.log"
    local log_file = io.open(log_file_path, "a")
    if log_file then
        local timestamp = os.date("%Y-%m-%d %H:%M:%S")
        local log_entry = duration
            and string.format("[%s] 模块: %-15s 原因: %s 耗时: %.3f秒\n", timestamp, module_name, reason, duration)
            or string.format("[%s] 模块: %-15s 原因: %s\n", timestamp, module_name, reason)
        log_file:write(log_entry)
        log_file:close()
    end
end

local function fast_init_db(db_name, internal_version, meta_key)
    if GLOBAL_CACHE.dbs[db_name] then
        return GLOBAL_CACHE.dbs[db_name], false
    end

    local db = get_level_db(db_name)
    GLOBAL_CACHE.dbs[db_name] = db

    local key = meta_key or "version"
    local current_ver = db:meta_fetch(key)
    if current_ver ~= internal_version then
        return db, true
    end
    return db, false
end

-- ==================== 3. 重码词替换模块 (collision_dict) ====================
local collision_dict = {
    CONFIG = { 
        MAX_COMBINATIONS = 10, 
        -- MAX_DFS_NODES：组合搜索的展开次数硬上限（2026-10 性能修复）。
        -- MAX_COMBINATIONS 只限「结果条数」，候选重码很多时 DFS 分支仍可能
        -- 转 plenty 次；这里对展开计数早退，语义与触顶一致（只是少搜几条）。
        MAX_DFS_NODES = 2000,
        PRIORITY_DECREMENT = 100, 
        SHOW_REPLACEMENT_COMMENT = true, 
        COMMENT_PREFIX = "💫" 
    },
    INTERNAL_VERSION = "collision_v2.1", 
    META_KEY = "db_version", 
    SOURCE_SIG_META_KEY = "source_sig", 
    db = nil, 
    initialized = false
}

function collision_dict.calc_file_signature(p)
    local f = io.open(p or "", "rb")
    if not f then return end
    local h, s, pr, m = 2166136261, 0, 16777619, 4294967296
    while true do
        local c = f:read(65536); if not c then break end
        s = s + #c; for i = 1, #c do h = ((h ~ c:byte(i)) * pr) % m end
    end
    f:close(); return string.format("%08x:%d", h, s)
end

function collision_dict.find_valid_matches(text, preedit, db)
    local codes, chars, pos, raw, matches = {}, {}, {}, {}, {}
    for s in preedit:gmatch("%S+") do codes[#codes+1] = #s end
    for p, c in utf8.codes(text) do chars[#chars+1] = utf8.char(c); pos[#pos+1] = p end
    if #chars ~= #codes then return {} end
    for i = 1, #chars do
        local word = ""
        for len = 1, 4 do
            if i+len-1 > #chars or codes[i+len-1] ~= 2 then break end
            word = word .. chars[i+len-1]
            local data = db:fetch(word)
            if data then 
                table.insert(raw, {
                    k = word, s = pos[i], si = i, ei = i+len-1, d = data, l = len, 
                    bl = (pos[i+len] or (#text+1)) - pos[i]
                }) 
            end
        end
    end
    for i, a in ipairs(raw) do
        local is_sub = false
        for j, b in ipairs(raw) do 
            if i ~= j and a.si >= b.si and a.ei <= b.ei and b.l > a.l then is_sub = true; break end 
        end
        if not is_sub and a.d ~= "" then
            local cols = {}
            for w in a.d:gmatch("[^" .. ENTRY_SEP .. "]+") do table.insert(cols, w) end
            table.insert(matches, {key = a.k, start = a.s, byte_len = a.bl, collisions = cols})
        end
    end
    return matches
end

function collision_dict.apply_replacements(text, comb, selected)
    for i = #comb, 1, -1 do 
        text = text:sub(1, comb[i].start - 1) .. selected[i] .. text:sub(comb[i].start + comb[i].byte_len) 
    end
    return text
end

function collision_dict.init(env)
    local sid = env.engine.schema.schema_id
    local path = (sid == "tiger") and PATHS.collision_tiger or (sid == "wubi" and PATHS.collision_wubi)
    if not path then return end
    
    local db, rebuild = fast_init_db("lua/collision_"..sid, collision_dict.INTERNAL_VERSION, collision_dict.META_KEY)
    collision_dict.db = db
    local sig = collision_dict.calc_file_signature(path)
    if sig and db:meta_fetch(collision_dict.SOURCE_SIG_META_KEY) ~= sig then rebuild = true end
    
    if rebuild and path then
        local t0 = os.clock()
        local map = {}
        for raw_line in io.lines(path) do
            local line = raw_line:match("^%s*(.-)%s*$")
            if line ~= "" and line:sub(1,1) ~= "#" then
                local l, r = line:match("^(.-)→(.-)$")
                local lw, rw = {}, {}
                for w in (l or line):gmatch("%S+") do lw[#lw+1] = w end
                for w in (r or line):gmatch("%S+") do rw[#rw+1] = w end
                for _, s in ipairs(lw) do
                    map[s] = map[s] or {}
                    for _, t in ipairs(rw) do table.insert(map[s], t) end
                end
            end
        end
        db:empty()
        for k, v in pairs(map) do db:update(k, table.concat(v, ENTRY_SEP)) end
        db:meta_update(collision_dict.META_KEY, collision_dict.INTERNAL_VERSION)
        if sig then db:meta_update(collision_dict.SOURCE_SIG_META_KEY, sig) end
        log_rebuild("collision_dict", "重建 "..sid, os.clock()-t0)
    end
    collision_dict.initialized = (db ~= nil)
end

-- ==================== 4. 中文词库模块 (tigress_ci_dict)  ====================
local tigress_ci_dict = {
    INTERNAL_VERSION = "tigress_ci_v13_ultimate",
    META_KEY = "db_version",
    db = nil
}

local function get_az_buckets()
    local buckets = {}
    for c = string.byte('a'), string.byte('z') do
        table.insert(buckets, string.char(c))
    end
    return buckets
end

function tigress_ci_dict.init(env)
    local dict_name = env.engine.schema.config:get_string("char_word/dictionary") or "tigress"
    local db_name = (dict_name == "wubici") and "lua/wubici" or "lua/tigress"
    local dict_path = (dict_name == "wubici") and PATHS.wubici or PATHS.tigress_ci

    local db, needs_rebuild = fast_init_db(db_name, tigress_ci_dict.INTERNAL_VERSION, tigress_ci_dict.META_KEY)
    tigress_ci_dict.db = db

    if needs_rebuild and dict_path then
        local start_time = os.clock()
        db:empty()
        
        local file = io.open(dict_path, "r")
        if file then
            local az_buckets = {}
            for _, ch in ipairs(get_az_buckets()) do
                az_buckets[ch] = {}
            end

            for line in file:lines() do
                if string.byte(line) ~= 35 and line ~= "" then
                    local t1 = string.find(line, "\t", 1, true)
                    if t1 then
                        local first_ch = string.sub(line, t1 + 1, t1 + 1):lower()
                        if az_buckets[first_ch] then
                            table.insert(az_buckets[first_ch], line)
                        end
                    end
                end
            end
            file:close()

            for _, ch in ipairs(get_az_buckets()) do
                local bucket_list = az_buckets[ch]
                if #bucket_list > 0 then
                    local pref_group = {}
                    
                    for _, line in ipairs(bucket_list) do
                        local text, code, weight = line:match("^([^\t]+)\t([^\t]+)\t(%d+)")
                        if text and code and weight then
                            local cl = code:lower()
                            if #cl >= 4 then
                                local pref = cl:sub(1, 3)
                                pref_group[pref] = pref_group[pref] or {}
                                table.insert(pref_group[pref], {
                                    text = text,
                                    suffix = cl:sub(4),
                                    weight = tonumber(weight),
                                    len = #cl
                                })
                            end
                        end
                    end

                    for pref, entries in pairs(pref_group) do
                        table.sort(entries, function(a, b)
                            if a.weight ~= b.weight then return a.weight > b.weight end
                            return a.len < b.len
                        end)
                        local parts = {}
                        for _, itm in ipairs(entries) do
                            table.insert(parts, itm.text .. itm.suffix)
                        end
                        db:update(pref, table.concat(parts, " "))
                    end

                    az_buckets[ch] = nil
                    pref_group = nil
                    collectgarbage("step", 300)
                end
            end

            db:meta_update(tigress_ci_dict.META_KEY, tigress_ci_dict.INTERNAL_VERSION)
            log_rebuild("tigress_ci_dict", "极速分桶流式重建", os.clock() - start_time)
            collectgarbage("collect")
        end
    end
end

function tigress_ci_dict.get_candidates(prefix)
    if not tigress_ci_dict.db or not prefix or #prefix ~= 3 then return {} end
    local data = tigress_ci_dict.db:fetch(prefix) or ""
    if data == "" then return {} end
    local res = {}
    for block in data:gmatch("%S+") do
        local t, r = block:match("^(.-)([a-z]*)$")
        if t then table.insert(res, {text = t, remaining = r}) end
    end
    return res
end

-- ==================== 7. 主模块 ====================
local merged_dict = {}

function merged_dict.init(e)
    collision_dict.init(e); e.collision = collision_dict
    tigress_ci_dict.init(e); e.tigress_ci = tigress_ci_dict
    e.engine_ctx = e.engine.context

    -- v0.3.3：反查改为 ` 前缀；后缀式（拼音+`）暂时移除，这里不再拦截尾随反引号。
end

function merged_dict.func(input, env)
    local ctx = env.engine_ctx; if not ctx then for c in input:iter() do yield(c) end return end

    local s = ctx.input:gsub("%s+", ""); if #s == 0 then for c in input:iter() do yield(c) end return end
    
    local opt_c = ctx:get_option("completion")
    
    -- === 新增：读取重码替换开关状态 ===
    local chongma_off = ctx:get_option("chongma_off")
    local tishi_off   = ctx:get_option("tishi_off")

    local m_s_p, seg = false, ctx.composition:back()
    local is_rad = seg and (seg:has_tag("radical_lookup") or seg:has_tag("reverse_stroke") or seg:has_tag("yin_add_user") or seg:has_tag("rvlk1"))
    local SUBS = {"₂", "₃", "₄", "₅", "₆"}

    for cand in input:iter() do
        local pc = cand
        local col, g = env.collision, pc:get_genuine()
        
        -- === 修改：当 chongma_off 为 true 时，直接跳过重码逻辑 ===
        if not chongma_off and col and col.initialized and not is_rad and (g.type=="sentence" or g.type=="phrase") and #s>=5 and not m_s_p then
            m_s_p = true
            local ms = col.find_valid_matches(g.text, g.preedit, col.db)
            if #ms > 0 then
                local cf, res, seen, ol, sm, sa = col.CONFIG, {}, {}, {}, {}, {}
                for i, m in ipairs(ms) do
                    local o, u = { m.key }, { [m.key] = true }
                    for _, a in ipairs(m.collisions) do if a and not u[a] then table.insert(o, a); u[a]=true end end
                    ol[i] = o
                end
                local dfs_nodes = 0  -- 组合搜索展开计数（硬上限防最坏耗时）
                local function dfs(p, le)
                    if dfs_nodes >= cf.MAX_DFS_NODES then return end
                    dfs_nodes = dfs_nodes + 1
                    if #res >= cf.MAX_COMBINATIONS or p > #ms then
                        if #sm > 0 then
                            local nt = col.apply_replacements(g.text, sm, sa)
                            if not seen[nt] then
                                seen[nt] = true
                                local chg, target = {}, {}
                                for i=1, #sm do table.insert(chg, sm[i].key .. "→" .. sa[i]); table.insert(target, sa[i]) end
                                table.insert(res, {text = nt, change = table.concat(chg, " "), short = table.concat(target, "")})
                            end
                        end
                        return
                    end
                    dfs(p + 1, le)
                    if ms[p].start >= le then
                        for i = 2, #ol[p] do
                            if #res >= cf.MAX_COMBINATIONS then break end
                            table.insert(sm, ms[p]); table.insert(sa, ol[p][i]); dfs(p + 1, ms[p].start + ms[p].byte_len); table.remove(sm); table.remove(sa)
                        end
                    end
                end
                dfs(1, -1)
                
                -- === 修改：当 tishi_off 为 false 时才显示提示 ===
                if #res > 0 and not tishi_off then
                    local summary = ""
                    for i = 1, math.min(#res, 5) do summary = summary .. SUBS[i] .. res[i].short end
                    pc.comment = (pc.comment or "") .. summary
                end
                yield(pc)
                
                for i, itm in ipairs(res) do
                    -- === 修改：当 tishi_off 为 true 时，不给替换词加注释 ===
                    local comment = ""
                    if not tishi_off then
                        comment = (#res >= 4 and itm.change or cf.COMMENT_PREFIX)
                    end
                    local nc = Candidate(g.type, cand.start, cand._end, itm.text, comment)
                    nc.quality = g.quality - i * cf.PRIORITY_DECREMENT; yield(nc)
                end
            else yield(pc) end
        else yield(pc) end
    end
    if opt_c and #s == 3 and env.tigress_ci then
        local ok, l = pcall(env.tigress_ci.get_candidates, s:lower())
        if ok and l then for i, v in ipairs(l) do yield(Candidate("tigress_ci", 0, #ctx.input, v.text, "~"..v.remaining)); if i>=50 then break end end end
    end
    collectgarbage("step", 20)
end

function merged_dict.fini(env)
    if env.select_notifier then
        env.select_notifier:disconnect()
    end
end

return merged_dict
