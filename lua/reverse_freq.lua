-- 短输入反查调频（原型）
--
-- 只对「短输入」（字母数 ≤ SHORT_LETTERS）记录选择次数，并按次数小幅前移；
-- 长句完全由五阶模型排序，避免局部偏好破坏整句通顺度。
--
-- 存储：用户目录 reverse_freq.txt，行格式 code<TAB>词<TAB>次数。
-- code 用规范化后的全拼音节（双拼/全拼都归一到同一个 code），切打法仍共享。
--
-- 为什么单独做成 processor：
--   lua_translator 的函数版本没有 init/fini，在翻译过程中直接 connect
--   commit_notifier 会让 librime 在引擎销毁时 SIGSEGV（已实测 139）。
--   这里用 lua_processor 的 init 连接通知器，translator 只负责登记
--   「当前反查段的 code + 候选集合」，提交时由本模块记一次选择。

local M = {}

local SHORT_LETTERS = 8
local MAX_COUNT = 8
local freq, freq_path, freq_loaded = nil, nil, false
local pending_by_engine = {}

local function engine_key(env)
    local schema = env.engine and env.engine.schema
    return schema and schema.schema_id or "default"
end

local function user_dir()
    if rime_api and type(rime_api.get_user_data_dir) == "function" then
        local directory = rime_api.get_user_data_dir()
        if directory and directory ~= "" then return directory end
    end
    return nil
end

local function load_frequency()
    if freq_loaded then return freq end
    freq_loaded, freq = true, {}
    local directory = user_dir()
    if not directory then return freq end
    freq_path = directory .. "/reverse_freq.txt"
    local handle = io.open(freq_path, "rb")
    if not handle then return freq end
    for line in handle:lines() do
        local code, text, count = line:match("^([a-z]+)\t([^\t]+)\t(%d+)$")
        if code and text then
            local n = tonumber(count)
            if n and n > 0 then
                local counts = freq[code]
                if not counts then counts = {}; freq[code] = counts end
                counts[text] = math.min(n, MAX_COUNT)
            end
        end
    end
    handle:close()
    return freq
end

local function save_frequency()
    if not freq_path then return end
    local temporary = freq_path .. ".tmp"
    local handle = io.open(temporary, "wb")
    if not handle then return end
    for code, counts in pairs(freq) do
        for text, count in pairs(counts) do
            handle:write(code, "\t", text, "\t", count, "\n")
        end
    end
    handle:close()
    os.rename(temporary, freq_path)
end

local function record(code, text)
    local counts = freq[code]
    if not counts then counts = {}; freq[code] = counts end
    counts[text] = math.min((counts[text] or 0) + 1, MAX_COUNT)
    save_frequency()
end

-- 选过一次即置顶（与虎整句「选过就记住」的体感一致）：有过选择记录的词
-- 排在最前，按次数降序；没选过的仍按模型顺序。次数封顶，避免无限累积。
local function rank(items, counts)
    if not counts or not next(counts) then return items end
    local ranked = {}
    for i = 1, #items do
        local count = counts[items[i].text] or 0
        ranked[i] = {
            item = items[i],
            promoted = count > 0,
            count = count,
            order = i,
        }
    end
    table.sort(ranked, function(a, b)
        if a.promoted ~= b.promoted then return a.promoted end
        if a.count ~= b.count then return a.count > b.count end
        return a.order < b.order
    end)
    local out = {}
    for i = 1, #ranked do out[i] = ranked[i].item end
    return out
end

function M.enabled(env)
    local ok, value = pcall(function()
        return env.engine.schema.config:get_bool("tiger_sentence/reverse_frequency")
    end)
    return not ok or value ~= false
end

function M.short_enough(letters)
    return letters <= SHORT_LETTERS
end

-- translator 侧：登记本次反查段，返回排好序的候选。
function M.rank_for(env, code, items)
    local counts = load_frequency()[code]
    local first = items[1] and items[1].text
    local ranked = counts and rank(items, counts) or items
    local texts = {}
    for i = 1, #ranked do texts[ranked[i].text] = true end
    pending_by_engine[engine_key(env)] = { code = code, texts = texts, first = first }
    return ranked
end

function M.clear_pending(env)
    pending_by_engine[engine_key(env)] = nil
end

function M.init(env)
    if env.conn then return end
    local context = env.engine.context
    if not context or not context.commit_notifier then return end
    env.conn = context.commit_notifier:connect(function(ctx)
        local key = engine_key(env)
        local pending = pending_by_engine[key]
        if not pending then return end
        pending_by_engine[key] = nil
        local input = ctx.input or ""
        if not input:find("`", 1, true) then return end
        local committed = ""
        pcall(function() committed = ctx:get_commit_text() or "" end)
        -- 只有「主动选了非首选」才记一次：直接空格选首选不需要调频，
        -- 也避免把「打拼音看虎码」的随手首选误记成偏好。
        if pending.texts[committed] and committed ~= pending.first then
            record(pending.code, committed)
        end
    end)
end

function M.fini(env)
    if env.conn then env.conn:disconnect(); env.conn = nil end
end

function M.func()
    return 2 -- kNoop：只借 init 连接通知器，不处理按键
end

M.rank = rank
M._reset_for_test = function()
    freq, freq_path, freq_loaded = nil, nil, false
    pending_by_engine = {}
end

return M
