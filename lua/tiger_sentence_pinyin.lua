-- 拼音反查整句引擎：把「拼音反查」段的候选生成从 librime script_translator
-- （万象词库词频）换成虎整句的五阶模型 lattice。
--
-- 架构：
--   · 反查段（yin_flypy/yin_qp/yin_zrm/yin_mspy/yin_sogou 五 tag，由 lua/yin_pick.lua
--     按 radio 打法换 tag）由本模块的 translator 接管；段上的 affix 剥离、
--     tips、extra_tags（供 chaifen 挂〔拆分·虎码〕注释、db.lua 剥 ` 后缀）全部不变。
--   · 引擎本体 = 同一份 lua/tiger_sentence.lua 的第二实例（dofile，词库/beam/缓存
--     与虎码主实例互相独立）。码表用 pinyin.qp.codes.txt（全拼无调音节 + 辅助码 +
--     简拼首字母 + 词），虎码的 char_ranks/whitelist/supplement 跳过（语义绑定虎码）。
--   · 键位转换：双拍（小鹤/自然码/微软/搜狗）按 2 键单元转全拼音节（映射表
--     lua/pinyin_keymaps.lua，从 wanxiang_algebra 同源派生）；全拼恒等。
--     转换失败的输入（非法键序）不出候选，与现状一致。
--   · 候选由本模块自建（不走第二实例的 M.translator）：preedit 显示键位，
--     注释仅带按键纠错 ✨ 标记；〔拆分·虎码〕由下游 chaifen 滤镜照旧附加。
--   · 学习与提前上屏不参与：反查是选重上屏的查询路径，decode 的 learning_index
--     保持 nil（learning.reward 对 nil 安全，bench 同样如此调用）。
--
-- 已知边界（docs/更新说明同步）：反查的 zc 用户词典调频不再生效（模型排序补偿）；
-- 生僻字用「拼音+辅助码」可达（码表含全部字的辅助码）。

local M = {}

-- 反查段 tag -> 键位方案。注意不含 yin_add_user：音码总开关（Ctrl+Q）关闭时
-- yin_pick 不换 tag，段留在 yin_add_user 上，本翻译器不响应（与现状一致地静默）。
local TAG_SCHEMES = {
    yin_flypy = "flypy",
    yin_qp = "qp",
    yin_zrm = "zrm",
    yin_mspy = "mspy",
    yin_sogou = "sogou",
}

local keymaps = require("pinyin_keymaps")
local SEPARATORS = { [" "] = true, ["'"] = true, ["`"] = true } -- `：后缀式反查的尾部反引号（affix 未剥时兜底）
local MAX_CONVERTED = 120 -- 低于主实例 max_raw_length(128)，留安全余量

-- 反查段尾部的选重键（与整句引擎 parse_selector 一致）：数字一律是选重；
-- 分号在 小鹤/全拼/自然码 也是选重，但在 微软/搜狗 里 `;` 是 ing 键，不能剥离。
-- 返回 (去掉选重键的主体, 选重键串)，主体交给 convert_keys，选重键原样进解码。
local function split_selectors(raw, scheme)
    local index = #raw
    while index >= 1 do
        local ch = raw:sub(index, index)
        if ch:match("%d") or (ch == ";" and scheme ~= "mspy" and scheme ~= "sogou") then
            index = index - 1
        else
            break
        end
    end
    return raw:sub(1, index), raw:sub(index + 1)
end

-- ---- 第二引擎实例 ----------------------------------------------------------
-- dofile（非 require）绕过模块缓存，得到独立的 lexicon_state/beam/decode 缓存。
-- 路径从本文件自身推导，兼容 librime 的 LUA_PATH 与测试的 package.path。
local instance
local function ensure_instance()
    if instance then return instance end
    local self_path = package.searchpath("tiger_sentence_pinyin", package.path)
    local main_path = self_path and
        self_path:gsub("tiger_sentence_pinyin%.lua$", "tiger_sentence.lua") or
        "tiger_sentence.lua"
    local engine = dofile(main_path)
    engine.set_data_file_override({
        ["tiger_sentence.codes.txt"] = "pinyin.qp.codes.txt",
        ["tiger_sentence.char_ranks.txt"] = false,
        ["tiger_sentence.full_code_whitelist.txt"] = false,
        ["tiger_sentence.supplement.txt"] = false,
    })
    -- 原型：优先用分页索引（models/pinyin.codes.*）；缺失则回退旧的全量解析路径。
    local directory = rime_api and type(rime_api.get_user_data_dir) == "function" and
        rime_api.get_user_data_dir() or "."
    local ok, pinyin_index = pcall(require, "tiger_sentence_pinyin_index")
    if ok and pinyin_index then
        local handle = pinyin_index.open(
            directory .. "/models/pinyin.codes.idx",
            directory .. "/models/pinyin.codes.dat",
            directory .. "/models/pinyin.codes.pool")
        if handle then engine.set_codes_index_override(handle) end
    end
    instance = engine
    return engine
end

-- 生产参数：ensure_lexicon 时把 auto_select_min_code_length 压到 0（单/双键
-- 音节边才可参与组句，简拼必需），high_freq_limit 走默认。beam 参数从
-- schema 读取一次（tiger_sentence/pinyin/*，缺省沿用 P5 Gate 实测值）。
local function fake_config()
    return {
        get_int = function(_, key)
            if key == "tiger_sentence/auto_select_min_code_length" then
                return 0
            end
            return "" -- 非数字 → 引擎保持默认（high_freq_limit=1500）
        end,
    }
end

local params_applied = false
local function apply_parameters(env)
    if params_applied then return end
    params_applied = true
    local engine = ensure_instance()
    local ok_int = function(name, default)
        local ok, value = pcall(function()
            return env.engine.schema.config:get_int(name)
        end)
        if ok and type(value) == "number" and value >= 1 then
            return math.floor(value)
        end
        return default
    end
    engine.configure_decoder_parameters({
        beam_width = ok_int("tiger_sentence/pinyin/beam_width", 48),
        long_input_full_beam_length =
            ok_int("tiger_sentence/pinyin/long_input_full_beam_length", 16),
        long_input_beam_width =
            ok_int("tiger_sentence/pinyin/long_input_beam_width", 16),
    })
end

-- ---- 键位转换 --------------------------------------------------------------
-- 双拍：每 2 键一个音节单元。**单元查不到就整段放弃**，不再退化成「首字母简拼」——
-- 否则打错的键（如 qz、im 不是小鹤音节）会被折成简拼串，五阶模型照样能拼出一句
-- 读起来通顺但语义无关的话（例：构件安装包包二奶），比不出候选更难发现。
-- 分隔符（空格/引号/反引号）跳过。全拼：恒等（简拼首字母码在码表里，如 jsj）。
local function convert_keys(raw, scheme)
    local s = raw:lower()
    if scheme == "qp" then
        return (s:gsub("[%s'`]+", ""))
    end
    local map = keymaps[scheme]
    if not map then return nil end
    local units = map.units
    local parts = {}
    local i = 1
    while i <= #s do
        local ch = s:sub(i, i)
        if SEPARATORS[ch] then
            i = i + 1
        else
            local syllable = i < #s and units[s:sub(i, i + 1)] or nil
            if syllable then
                parts[#parts + 1] = syllable
                i = i + 2
            else
                -- 不是合法音节组：整段放弃，交给别的路径（如混输/普通输入）
                return nil
            end
        end
    end
    return table.concat(parts)
end

-- 双拍 preedit：按消费的键分组重建（"fjia" -> "fj ia"），贴近 librime 反查的显示。
local function double_preedit(raw, scheme)
    local s = raw
    local map = keymaps[scheme]
    if not map then return s end
    local units = map.units
    local groups = {}
    local i = 1
    while i <= #s do
        local ch = s:sub(i, i)
        if SEPARATORS[ch] then
            i = i + 1
        else
            local unit = i < #s and s:sub(i, i + 1) or nil
            if unit and units[unit] then
                groups[#groups + 1] = unit
                i = i + 2
            else
                groups[#groups + 1] = s:sub(i, i)
                i = i + 1
            end
        end
    end
    return table.concat(groups, " ")
end

-- ---- 解码与候选 ------------------------------------------------------------
local last_converted = nil

local reverse_freq = require("reverse_freq")

local function decode_converted(converted)
    local engine = ensure_instance()
    -- 增量缓存只对「前缀延伸」安全；编辑/回删/换段（非前缀）必须重建。
    if converted ~= last_converted then
        if not (last_converted and #converted > #last_converted and
                converted:sub(1, #last_converted) == last_converted) then
            engine.reset_decode_cache()
        end
        last_converted = converted
    end
    return engine.decode(converted, false, "", nil)
end

local function candidate_comment(env, item)
    local comment = ""
    if (item.correction_count or 0) > 0 then
        local mark = "✨"
        pcall(function()
            mark = correction_mark_state.get(env) or mark
        end)
        comment = mark
    end
    pcall(function()
        if zaoci_bridge.is_user_word(item.text) then
            comment = comment .. "〔自造词〕"
        end
    end)
    return comment
end

function M.translator(input, seg, env)
    local scheme = nil
    for tag, mapped in pairs(TAG_SCHEMES) do
        if seg:has_tag(tag) then
            scheme = mapped
            break
        end
    end
    if not scheme then return end
    -- 每次反查段重新判定：混合候选由下面的 build_overlay 路径置真，
    -- 供 chaifen 滤镜关掉拆分注释（长句逐字拆分会把候选栏挤满）。
    _G.tiger_mixed_active = false
    if input == "" or input:match("^[a-z]+/$") then return end

    local letters = #(input:gsub("[^A-Za-z]", ""))
    local code, selector = split_selectors(input, scheme)
    -- 双拼：查专用表（精确匹配，不兜底）；全拼：沿用原来的恒等转换。
    local converted
    if scheme == "qp" then
        converted = convert_keys(code, scheme)
    else
        local ok_map, map = pcall(require, "tiger_pinyin_map")
        if ok_map and map and map.available(scheme) then
            converted = map.lookup(scheme, code)
        else
            -- 没有专用表（测试环境 / 旧部署缺文件）时退回键位转换；
            -- 转换出的结果仍受「无简拼、禁残余兜底」的过滤约束。
            converted = convert_keys(code, scheme)
        end
    end
    local converted_code = converted
    local results = {}

    -- 尾部选重键（数字 / 小鹤等的分号）原样附加回编码，交给引擎 parse_selector 处理；
    -- 转换失败（混输段：拼音后接虎码，或虎码里夹着 ; 数字）不直接放弃，
    -- 下面统一走 build_overlay，否则整段反查会退化成虎码。
    if converted and converted ~= "" and #(converted .. selector) <= MAX_CONVERTED then
        converted = converted .. selector
        apply_parameters(env)
        local engine = ensure_instance()
        -- 只改变拼音第二实例的模型评分；不开模型仍保留码表组句与调频。
        -- setter 在值改变时清模型/解码缓存，同值为 noop；跨方案/会话切换也重放。
        -- 无 context 的纯解码测试保留调用方显式设定的模型状态。
        local context = env.engine.context
        if context and type(context.get_option) == "function" then
            engine.set_model_enabled(not context:get_option("pinyin_no_model"))
        end
        -- 全拼保留简拼边（fa+nc+ha 合法）；双拼只允许音节组合。
        if engine.set_allow_abbreviation_edges then
            engine.set_allow_abbreviation_edges(scheme == "qp")
        end
        -- 双拼不出现简拼（含整段简拼 jsj=计算机、nh=你好）；全拼保留。
        if engine.set_strict_abbreviation then
            engine.set_strict_abbreviation(scheme ~= "qp")
        end
        -- 音节级标记（内部 `）：短输入时允许全部同音单字参与，给出多条候选；
        -- 长输入仍走单条最优句，避免解码爆炸。阈值：字母数 ≤16 且内部标记 ≤4。
        -- 字母数用「删除非字母后的长度」统计（gsub 的第二个返回值是被替换的次数，
        -- 不是剩余长度；v0.3.4 的长度闸门曾因此失效）。
        -- 末尾的 ` 是旧后缀式习惯，不算音节分隔标记；只要有 1 个内部 ` 就展开
        -- （两字词「fj`ia」只有一个音节边界，旧阈值 >=2 让两字词永远不展开）。
        local marked_body = input:gsub("`$", "")
        local marks = select(2, marked_body:gsub("`", ""))
        local marked = marks >= 1
        local expand = marked and marks <= 5 and letters <= 16
        if engine.set_allow_duplicate_single then
            engine.set_allow_duplicate_single(expand)
        end
        local ok_lexicon, _ = pcall(engine.ensure_lexicon, {
            engine = { schema = { config = fake_config() } },
        })
        if ok_lexicon then
            local ok, decoded = pcall(decode_converted, converted)
            if ok and type(decoded) == "table" then
                results = decoded
            else
                last_converted = nil
            end
        end
    end

    -- 拼音在前、虎码在后，且支持一句里多个 ` 块：整段拼音解码不出候选时，
    -- 把每个 ` 块里可解析的拼音词挂成合成码，其余字母当虎码，交给主引擎组句。
    -- 纯反查时 build_overlay 返回 nil（没有虎码字面量），原路径完全不变。
    local mixed_plan
    if #results == 0 then
        local ok_mixed, mixed = pcall(require, "tiger_mixed")
        if ok_mixed and mixed and type(mixed.build_overlay) == "function" then
            local ok_plan, plan = pcall(mixed.build_overlay, input, scheme)
            if ok_plan and plan then
                local ok_main, main = pcall(require, "tiger_sentence")
                if ok_main and main and type(main.decode_with_overlay) == "function" then
                    local ok_decode, mixed_results = pcall(main.decode_with_overlay,
                        plan.raw, plan.overlay, true, nil)
                    if ok_decode and type(mixed_results) == "table" and #mixed_results > 0 then
                        results, mixed_plan = mixed_results, plan
                        _G.tiger_mixed_active = true
                    end
                end
            end
        end
    end

    -- 短输入才参与调频；长句完全交给模型，避免局部偏好破坏整句通顺度。
    -- 混输候选同样参与「选过即置顶」：key 用去掉反引号的输入串，与纯反查共用
    -- reverse_freq 的存储和提交挂钩（此前混输直接跳过调频，选过的词下次不会前移）。
    local freq_code = mixed_plan and (input:gsub("`", "")) or converted_code or
        (input:gsub("`", ""))
    if reverse_freq.short_enough(letters) and reverse_freq.enabled(env) then
        results = reverse_freq.rank_for(env, freq_code, results)
    else
        reverse_freq.clear_pending(env)
    end

    -- 双拼：候选字数不能超过用户输入的「音节数」。
    -- 例：`bm 在双拼里是 bian 一个音节，不能因为把 bian 切成 bi+an 而冒出「比按」这类全拼词。
    local max_chars
    if scheme ~= "qp" and not mixed_plan then
        local ok_pre, pre = pcall(double_preedit, input, scheme)
        if ok_pre and type(pre) == "string" then
            local groups = 0
            for _ in pre:gmatch("%S+") do groups = groups + 1 end
            if groups > 0 then max_chars = groups end
        end
    end

    for i = 1, #results do
        local item = results[i]
        local ok_len = true
        if max_chars then
            local n = utf8.len(item.text) or #item.text
            if n > max_chars then ok_len = false end
        end
        if ok_len then
            local cand = Candidate("sentence", seg.start, seg._end, item.text,
                candidate_comment(env, item))
            -- 预编辑文本：始终显示用户实际输入的键（含音节 `），不做模型分词展示。
            cand.preedit = "`" .. input
            yield(cand)
        end
    end
end

-- 测试钩子：转换与 preedit 是纯函数，直接暴露给单测。
M.convert_keys = convert_keys
M.double_preedit = double_preedit
M.split_selectors = split_selectors
M._engine_for_test = ensure_instance
M._reset_for_test = function()
    instance = nil
    params_applied = false
    last_converted = nil
end

return M
