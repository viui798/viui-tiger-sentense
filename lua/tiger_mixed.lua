-- 虎码 + 拼音反查混输（原型，v0.3.6）
--
-- 输入形如：je`jiyubeuegmmup
--   前/后是虎码编码，` 开头的一段按所选打法解析为拼音音节；
--   只有当这段拼音的整段 code 在反查词库里**有词条**时，才作为一个“词 token”
--   临时并入虎码整句 lattice（例如 `jiyu → 觊觎），由五阶模型和前后虎码一起选句。
--   后续字母无法继续拼音解析时自动回到虎码（beuegmmup → 她 的 美 貌）。
--
-- 实现：把拼音块替换成一个不会与虎码冲突的临时 4 字母编码，调用
-- tiger_sentence.decode_with_overlay 解码，结束后还原码表。

local M = {}
local keymaps = require("pinyin_keymaps")

local SINGLE = { ["a"] = true, ["e"] = true, ["o"] = true }
local QP_SYLLABLES = nil

local function qp_syllables()
    if QP_SYLLABLES then return QP_SYLLABLES end
    local set = {}
    for _, map in pairs(keymaps) do
        for _, syllable in pairs(map.units or {}) do set[syllable] = true end
    end
    for syllable in pairs(SINGLE) do set[syllable] = true end
    QP_SYLLABLES = set
    return set
end

local function scheme_of(ctx)
    local order = {
        { "yin_qp", "qp" }, { "yin_flypy", "flypy" },
        { "yin_zrm", "zrm" }, { "yin_mspy", "mspy" }, { "yin_sogou", "sogou" },
    }
    for _, item in ipairs(order) do
        if ctx:get_option(item[1]) then return item[2] end
    end
    return "flypy"
end

-- 解析一个拼音块：返回 (完整拼音 code, 消费的字母数)；只接受词库里存在**词条**的整段。
local function parse_chunk(chunk, scheme)
    local parts = {}  -- { syllable, letters }
    if scheme == "qp" then
        local set = qp_syllables()
        local i = 1
        while i <= #chunk do
            local chosen
            for len = math.min(8, #chunk - i + 1), 1, -1 do
                local piece = chunk:sub(i, i + len - 1)
                if set[piece] then chosen = piece; break end
            end
            if not chosen then break end
            parts[#parts + 1] = { chosen, #chosen }
            i = i + #chosen
        end
    else
        local map = keymaps[scheme]
        if not map then return nil end
        local i = 1
        while i + 1 <= #chunk do
            local unit = chunk:sub(i, i + 1)
            local syllable = map.units[unit]
            if not syllable then break end
            parts[#parts + 1] = { syllable, 2 }
            i = i + 2
        end
    end
    if #parts == 0 then return nil end

    local index = M.index_handle()
    if not index then return nil end
    local code, consumed, letters, best = "", 0, 0, nil
    for i = 1, #parts do
        code = code .. parts[i][1]
        letters = letters + parts[i][2]
        local entries = index.lookup(code)
        if entries then
            local has_word = false
            for j = 1, #entries do
                if utf8.len(entries[j].t) > 1 then has_word = true; break end
            end
            if has_word then best = { code = code, consumed = letters } end
        end
    end
    return best and best.code, best and best.consumed or 0
end

local function user_dir()
    if rime_api and type(rime_api.get_user_data_dir) == "function" then
        local directory = rime_api.get_user_data_dir()
        if directory and directory ~= "" then return directory end
    end
    return "."
end

function M.index_handle()
    if M.index then return M.index end
    local ok, module = pcall(require, "tiger_sentence_pinyin_index")
    if not ok or not module then return nil end
    local directory = user_dir()
    M.index = module.open(directory .. "/models/pinyin.codes.idx",
        directory .. "/models/pinyin.codes.dat",
        directory .. "/models/pinyin.codes.pool")
    return M.index
end

local function allocate_code(sentence)
    local candidates = { "qzqz", "vqvq", "qzvq", "vqzq", "qzqzq", "vqvqv" }
    sentence.ensure_lexicon(nil)
    for _, code in ipairs(candidates) do
        if sentence.lexicon_probe(code) == nil then return code end
    end
    return nil
end

local function build(words)
    local entries = {}
    for i = 1, #words do
        entries[i] = {
            t = words[i], r = 1, user = false,
            optimal_single = false, whole_single_reward_eligible = false,
            primary_single = false,
        }
    end
    return entries
end

local cache = { signature = "", synthetic = {}, active = false }

local function translate(input, seg, env)
    if not input or input:find("`", 1, true) == nil then
        if cache.active then
            require("tiger_sentence").decode_with_overlay("", nil, true)
            cache.active, cache.signature = false, ""
        end
        return
    end
    local ctx = env.engine.context
    local scheme = scheme_of(ctx)
    local sentence = require("tiger_sentence")
    local index = M.index_handle()
    if not index then return end

    local out, overlay = {}, {}
    local signature_parts = {}
    local i = 1
    while i <= #input do
        local ch = input:sub(i, i)
        if ch == "`" then
            local j = i + 1
            while j <= #input and input:sub(j, j):match("[a-z]") do j = j + 1 end
            local chunk = input:sub(i + 1, j - 1)
            local code, consumed = parse_chunk(chunk, scheme)
            if code and consumed > 0 then
                local entries = index.lookup(code)
                local words = {}
                for k = 1, #entries do
                    if utf8.len(entries[k].t) > 1 then words[#words + 1] = entries[k].t end
                end
                if #words > 0 then
                    local key = cache.synthetic[i] or allocate_code(sentence)
                    if key then
                        cache.synthetic[i] = key
                        overlay[key] = build(words)
                        signature_parts[#signature_parts + 1] = key .. "=" .. code
                        out[#out + 1] = key
                        local rest = chunk:sub(consumed + 1)
                        if rest ~= "" then out[#out + 1] = rest end
                        i = j
                    else
                        out[#out + 1] = chunk
                        i = j
                    end
                else
                    out[#out + 1] = chunk
                    i = j
                end
            else
                out[#out + 1] = chunk
                i = j
            end
        else
            out[#out + 1] = ch
            i = i + 1
        end
    end

    local raw = table.concat(out)
    if raw == input and next(overlay) == nil then return end
    local signature = table.concat(signature_parts, "|")
    local reset = signature ~= cache.signature or
        (cache.active ~= (next(overlay) ~= nil))
    cache.signature = signature
    cache.active = next(overlay) ~= nil
    local results = sentence.decode_with_overlay(raw, overlay, reset)
    if not results or #results == 0 then return end
    for k = 1, #results do
        local item = results[k]
        local cand = Candidate("sentence", seg.start, seg._end, item.text, "")
        cand.preedit = input
        yield(cand)
    end
end

M.translator = { func = translate }

return M
