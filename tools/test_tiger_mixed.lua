-- 混输翻译器不得接管反查段。
-- 反查段的 affix 会把开头的 ` 剥掉，段内容变成「字母 + `」（如 fj`ia）；
-- 混输如果只看字符形状就会把它当混输，把解析不了的拼音块折成虎码字母，
-- 拼出「一个盘」等无关候选（2026-11-02 用户反馈）。
local repo = arg[1] or "."
package.path = repo .. "/lua/?.lua;" .. package.path
rime_api = { get_user_data_dir = function() return repo end }

local yielded = {}
Candidate = function(_, _, _, text) return { text = text } end
yield = function(candidate) yielded[#yielded + 1] = candidate end

local sentence = require("tiger_sentence")
local decode_calls = 0
local original_decode = sentence.decode_with_overlay
sentence.decode_with_overlay = function(...)
    decode_calls = decode_calls + 1
    return original_decode(...)
end

local mixed = require("tiger_mixed")
local checks = 0
local function check(ok, message)
    checks = checks + 1
    assert(ok, message)
end

local function env()
    return { engine = { context = { get_option = function() return false end } } }
end

local function segment(tag)
    return { has_tag = function(_, name) return name == tag end, start = 0, _end = 8 }
end

-- 反查段：任何 yin_* 段都直接跳过，不触发解码。
for _, tag in ipairs({ "yin_add_user", "yin_flypy", "yin_qp", "yin_zrm",
    "yin_mspy", "yin_sogou" }) do
    yielded = {}
    decode_calls = 0
    mixed.translator.func("fj`ia", segment(tag), env())
    check(decode_calls == 0 and #yielded == 0,
        "反查段被混输重复解码: " .. tag)
end

-- 正向对照：真正的混输段仍然走解码（索引与解码用桩，避免加载模型）。
mixed.index_handle = function()
    return {
        lookup = function(code)
            if code == "cha" then return { { t = "查杀" } } end
            if code == "jiyu" then return { { t = "觊觎" } } end
            return nil
        end,
    }
end
-- 选重键（; / 数字）必须原样留在字面量里，交给整句引擎的 parse_selector；
-- 不能被 build_overlay 当成拼音的一部分吃掉。
sentence.ensure_lexicon = function() end
sentence.lexicon_probe = function() return nil end
local plan_semicolon = mixed.build_overlay("jiyu;unid", "flypy")
check(plan_semicolon and plan_semicolon.raw:find(";unid", 1, true),
    "反查混输的分号应留在字面量")
local plan_digit = mixed.build_overlay("jiyu1unid", "flypy")
check(plan_digit and plan_digit.raw:find("1unid", 1, true),
    "反查混输的数字应留在字面量")

sentence.decode_with_overlay = function()
    decode_calls = decode_calls + 1
    return { { text = "结果" } }
end
yielded = {}
decode_calls = 0
mixed.translator.func("fj`ia", segment("mixed"), env())
check(decode_calls == 1 and #yielded == 1 and yielded[1].text == "结果",
    "真正的混输段没有解码")
sentence.decode_with_overlay = original_decode

print(string.format('{"status":"passed","mixed_checks":%d}', checks))
