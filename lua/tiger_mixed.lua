-- 虎码 + 拼音反查混输（原型，v0.3.6）
--
-- 输入形如：je`jiyubeuegmmup
--   前/后是虎码编码，` 开头的一段按所选打法解析为拼音音节；
--   只有当这段拼音的整段 code 在反查词库里**有词条**时，才作为一个“词 token”
--   临时并入虎码整句 lattice（例如 `jiyu → 觊觎），由五阶模型和前后虎码一起选句。
--   后续字母无法继续拼音解析时自动回到虎码（beuegmmup → 她 的 美 貌）。
--
-- 实现：把拼音块替换成一个不会与虎码冲突的临时 3 字母编码（避开真实码前缀，
-- 因而不会被拆成 1+2 或 2+1 抢候选），调用 tiger_sentence.decode_with_overlay
-- 解码，结束后还原码表。纯反查段（` 开头）直接跳过，不重复解码。

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
-- loose=true 时双拍末尾的单键按简拼声母处理（与反查的 convert_keys 一致）；
-- 默认关闭，保持原有「混输拼音块」行为不变。
local function parse_chunk(chunk, scheme, loose)
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
        while i <= #chunk do
            local unit = chunk:sub(i, i + 1)
            local syllable = #unit == 2 and map.units[unit] or nil
            if syllable then
                parts[#parts + 1] = { syllable, 2 }
                i = i + 2
            elseif loose then
                local initial = map.initials and map.initials[chunk:sub(i, i)]
                if not initial then break end
                parts[#parts + 1] = { initial, 1 }
                i = i + 1
            else
                break
            end
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
            -- 单音节码（如 gan）在码表里只有单字，不能要求多字词条；
            -- 多音节码才要求整词，避免「发内存哈」那类拼接。
            local min_len = i >= 2 and 2 or 1
            local ok_word = false
            for j = 1, #entries do
                if (utf8.len(entries[j].t) or 1) >= min_len then ok_word = true; break end
            end
            if ok_word then best = { code = code, consumed = letters, syllables = i } end
        end
    end
    return best and best.code, best and best.consumed or 0, best and best.syllables or 0
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

local function allocate_code(sentence, used)
    -- 合成码用 3 字母且不是任何真实编码的前缀：3 码只能拆成 1+2 或 2+1，
    -- 而 1 字母分段在整句里被禁止，所以不会像 4 码那样被拆成「考虑+考虑」抢候选。
    local candidates = { "qac", "qai", "qaj", "qam", "qap", "qar" }
    sentence.ensure_lexicon(nil)
    for _, code in ipairs(candidates) do
        if not (used and used[code]) and sentence.lexicon_probe(code) == nil then
            return code
        end
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
    -- 混输段必须以虎码字母开头（recognizer: ^[a-z][a-z;']*`）；纯反查段以 `
    -- 开头，交给拼音反查翻译器，这里直接跳过，避免同一段被两条路径重复解码。
    if not input:match("^[a-z]") then return end
    -- 反查段的 affix 已剥掉开头的 `，段内容会变成「字母 + `」，同样要跳过：
    -- 否则 `fj`ia 会被混输把解析不了的 ia 当虎码字母折回去，拼出「一个盘」。
    local function reverse_segment(tag)
        return seg.has_tag and seg:has_tag(tag)
    end
    if reverse_segment("yin_add_user") or reverse_segment("yin_flypy") or
        reverse_segment("yin_qp") or reverse_segment("yin_zrm") or
        reverse_segment("yin_mspy") or reverse_segment("yin_sogou") then
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
    local short_positions = {}
    local used = {}
    local cursor = 0
    local literal_tail = false  -- 上一个输入字符是否按虎码原样进入 raw
    local function push(piece)
        if piece == "" then return end
        out[#out + 1] = piece
        cursor = cursor + #piece
    end
    local i = 1
    while i <= #input do
        local ch = input:sub(i, i)
        if ch == "`" then
            local j = i + 1
            while j <= #input and input:sub(j, j):match("[a-z]") do j = j + 1 end
            local chunk = input:sub(i + 1, j - 1)
            local code, consumed, syllables = parse_chunk(chunk, scheme)
            if code and consumed > 0 then
                local entries = index.lookup(code)
                local words = {}
                -- 单音节块（双拼 gj→gan）在码表里只有单字，不能只收多字词，
                -- 否则 ` 后面的单音节拼音会退回成虎码。
                local min_len = (syllables or 0) >= 2 and 2 or 1
                for k = 1, #entries do
                    if (utf8.len(entries[k].t) or 1) >= min_len then
                        words[#words + 1] = entries[k].t
                    end
                end
                if #words > 0 then
                    local key = cache.synthetic[i]
                    if key and used[key] then key = nil end
                    if not key then key = allocate_code(sentence, used) end
                    if key then
                        used[key] = true
                        cache.synthetic[i] = key
                        overlay[key] = build(words)
                        -- 合成码前若是单字母简码（我 t / 的 u / 是 o …），允许它作为
                        -- 1 字母分段参与组句；否则会因「1 字母不分段」规则整句无候选。
                        -- literal_tail 保证这个字母是虎码原样输入，而不是上一个拼音块。
                        if literal_tail and cursor >= 1 and input:sub(i - 1, i - 1):match("[a-z]") then
                            short_positions[cursor - 1] = true
                        end
                        signature_parts[#signature_parts + 1] = i .. ":" .. key .. "=" .. code
                        push(key)
                        literal_tail = false
                        local rest = chunk:sub(consumed + 1)
                        if rest ~= "" then
                            push(rest)
                            literal_tail = true
                        end
                        i = j
                    else
                        push(chunk)
                        literal_tail = #chunk > 0
                        i = j
                    end
                else
                    push(chunk)
                    literal_tail = #chunk > 0
                    i = j
                end
            else
                push(chunk)
                literal_tail = #chunk > 0
                i = j
            end
        else
            push(ch)
            literal_tail = true
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
    local results = sentence.decode_with_overlay(raw, overlay, reset,
        next(short_positions) and short_positions or nil)
    if not results or #results == 0 then return end
    for k = 1, #results do
        local item = results[k]
        local cand = Candidate("sentence", seg.start, seg._end, item.text, "")
        cand.preedit = input
        yield(cand)
    end
end

M.translator = { func = translate }

-- 供反查引擎复用：把以 ` 开头的段扫成「拼音块 + 虎码」序列。
-- 规则：段首默认是拼音（affix 已剥掉开头的 `），每个 ` 之后也优先按拼音解析；
-- 解析出的词条挂到合成码上，解析不了的部分原样保留当虎码。
-- 只有「至少解析出一个拼音词 + 至少存在一段虎码字面量」才返回方案：
-- 纯拼音段（`jiyu、`jiyu`nihao）交回反查整串解码，双拼打法不匹配时不会冒出虎码乱码。
function M.build_overlay(input, scheme)
    if not input or input == "" then return nil end
    local index = M.index_handle()
    if not index then return nil end
    local sentence = require("tiger_sentence")
    local out, overlay, used = {}, {}, {}
    local has_literal, any_word = false, false
    local i = 1
    local first_block = true
    local expect_pinyin = true   -- 段首：反查段已由 affix 剥掉前缀
    while i <= #input do
        local ch = input:sub(i, i)
        if ch == "`" then
            expect_pinyin = true
            i = i + 1
        elseif expect_pinyin and ch:match("[a-z]") then
            local j = i
            while j <= #input and input:sub(j, j):match("[a-z]") do j = j + 1 end
            local chunk = input:sub(i, j - 1)
            local code, consumed, syllables = parse_chunk(chunk, scheme, true)
            local words = {}
            -- 整块都被解析成拼音（没有残余）时，单音节也照收：` 后面本来就该优先拼音，
            -- 例如双拼 gi/gj 这种一个完整音节。只有「解析出一点、后面还剩一长串」的
            -- 情况才要求至少两个音节，否则全拼 womenunid 打到双拼模式会被拆成
            -- 「玩偶（wo 的简拼词条）+ menunid」。
            local complete = consumed == #chunk
            local min_syllables = complete and 1 or 2
            if code and consumed > 0 and (syllables or 0) >= min_syllables then
                local entries = index.lookup(code)
                local min_len = (syllables or 0) >= 2 and 2 or 1
                for k = 1, #entries do
                    if (utf8.len(entries[k].t) or 1) >= min_len then
                        words[#words + 1] = entries[k].t
                    end
                end
            end
            if #words > 0 then
                local key = allocate_code(sentence, used)
                if key then
                    used[key] = true
                    overlay[key] = build(words)
                    out[#out + 1] = key
                    any_word = true
                end
                local rest = chunk:sub(consumed + 1)
                if rest ~= "" then
                    out[#out + 1] = rest
                    has_literal = true
                end
            else
                -- 整块解析不出词条时：段首块直接放弃（用户是按了 ` 进来反查的，
                -- 不能反过来把这段当虎码解出乱码），过长的块也放弃 —— 虎码单字
                -- 最多五码，六字母以上当字面量只会得到「住衣缺」这类噪声。
                if first_block or #chunk > 5 then return nil end
                out[#out + 1] = chunk
                has_literal = true
            end
            first_block = false
            i = j
            expect_pinyin = false
        else
            local j = i
            while j <= #input and input:sub(j, j) ~= "`" do j = j + 1 end
            out[#out + 1] = input:sub(i, j - 1)
            has_literal = true
            i = j
            expect_pinyin = false
        end
    end
    if not any_word or not has_literal then return nil end
    return { raw = table.concat(out), overlay = overlay }
end

return M
