-- 拼音反查整句引擎单元测试（lua/tiger_sentence_pinyin.lua）。
-- 三段：键位转换/纯函数、wrapper 行为（微型码表）、真实码表冒烟。
-- 无需五阶模型（set_model_enabled(false)），在回归临时树内自包含运行。

local repo = arg[1] or "."
package.path = repo .. "/lua/?.lua;" .. package.path
rime_api = { get_user_data_dir = function() return repo end }
-- 本测试用微型码表夹具，禁用分页索引（否则会读到仓库 models/ 下的真实索引）。
package.loaded["tiger_sentence_pinyin_index"] = { open = function() return nil end }

local checks = 0
local function check(ok, msg)
    checks = checks + 1
    assert(ok, msg)
end

-- ---- 夹具：微型全拼码表（覆盖 音节字/词/简拼组） ---------------------------
local MOCK_TABLE = table.concat({
    "你\tni", "好\thao", "你好\tnihao",
    "的\tde",
    "反\tfan", "查\tcha", "差\tcha", "反查\tfancha", "反差\tfancha",
    "计\tji", "算\tsuan", "机\tji", "计算机\tjisuanji",
    "计\tj", "机\tj", "算\ts", "计算机\tjsj", "你好\tnh",
}, "\n") .. "\n"

local original_open = io.open
io.open = function(path, mode)
    if path == repo .. "/pinyin.qp.codes.txt" then
        return { read = function() return MOCK_TABLE end, close = function() end }
    end
    return original_open(path, mode)
end

-- translator 运行环境需要全局 Candidate / yield（librime-lua 由宿主提供）
local yielded = {}
Candidate = function(typ, start, _end, text, comment)
    return { type = typ, start = start, _end = _end, text = text, comment = comment }
end
yield = function(cand) yielded[#yielded + 1] = cand end

local pinyin = require("tiger_sentence_pinyin")
local engine = pinyin._engine_for_test and pinyin._engine_for_test()
if engine then engine.set_model_enabled(false) end

local function fake_env()
    return {
        engine = {
            schema = { config = { get_int = function() return "" end } },
        },
    }
end

local function seg_with_tag(tag)
    return { has_tag = function(_, t) return t == tag end, start = 0, _end = 5 }
end

local function translate(tag, input)
    yielded = {}
    pinyin.translator(input, seg_with_tag(tag), fake_env())
    return yielded
end

local function texts(cands)
    local out = {}
    for i, c in ipairs(cands) do out[i] = c.text end
    return table.concat(out, "|")
end

-- ---- 1. 键位转换（真 keymap：派生自 wanxiang_algebra） ----------------------
check(pinyin.convert_keys("fjia", "flypy") == "fancha", "小鹤 fjia -> fancha")
check(pinyin.convert_keys("fj ia", "flypy") == "fancha", "小鹤分隔符跳过")
check(pinyin.convert_keys("NIHAO", "qp") == "nihao", "全拼大小写归一")
check(pinyin.convert_keys("fjv", "flypy") == "fanz", "小鹤简拼尾键 v->z")
check(pinyin.convert_keys("jsj", "qp") == "jsj", "全拼简拼恒等")
check(pinyin.convert_keys("zz1", "flypy") == nil, "非法键序放弃转换")

check(pinyin.double_preedit("fjia", "flypy") == "fj ia", "双拍 preedit 分组")
check(pinyin.double_preedit("fj ia", "flypy") == "fj ia", "双拍 preedit 原分隔")

-- ---- 1.5 短输入调频：稳定排序，只前移不改变候选集合 --------------------------
local reverse_freq = require("reverse_freq")
check(reverse_freq.short_enough(8) and not reverse_freq.short_enough(9),
    "短输入阈值：8 字母参与调频，9 字母不参与")
local base = { { text = "A" }, { text = "B" }, { text = "C" }, { text = "D" } }
local ranked = reverse_freq.rank(base, { D = 1 })
check(#ranked == 4, "调频不改变候选数量")
check(ranked[1].text == "D", "选过一次即置顶")
local ranked2 = reverse_freq.rank(base, { B = 1 })
check(ranked2[1].text == "B" and ranked2[2].text == "A" and ranked2[3].text == "C",
    "只前移选过的词，其余保持稳定")
local ranked4 = reverse_freq.rank(base, { C = 2, B = 1 })
check(ranked4[1].text == "C" and ranked4[2].text == "B" and ranked4[3].text == "A",
    "多个已选词按次数降序，未选词保持模型顺序")
local ranked3 = reverse_freq.rank(base, { Z = 9 })
check(ranked3[1].text == "A" and ranked3[4].text == "D", "未知词条不影响原有顺序")

-- ---- 2. wrapper 行为（微型码表，无模型） -----------------------------------
local cands = translate("abc", "nihao")
check(#cands == 0, "虎码 abc 段不出拼音候选")

cands = translate("yin_add_user", "nihao")
check(#cands == 0, "yin 总开关关闭（段留 yin_add_user）时静默")

cands = translate("yin_qp", "nihao")
check(cands[1] and cands[1].text == "你好", "全拼 nihao -> 你好（词边）")
check(type(cands[1].preedit) == "string" and cands[1].preedit:find("ni", 1, true),
    "全拼 preedit 含键位")

cands = translate("yin_flypy", "fjia")
check(texts(cands):find("反差", 1, true), "小鹤 fjia 出反差（词边）")
check(cands[1].preedit == "`fjia", "小鹤 preedit 保持原始按键（含反引号前缀）")

cands = translate("yin_qp", "jsj")
check(texts(cands):find("计算机", 1, true), "简拼 jsj 出计算机（词首字母码）")

cands = translate("yin_qp", "nh")
check(texts(cands):find("你好", 1, true), "简拼 nh 出你好（词首字母码）")

-- 引擎结构性边界：#raw>1 时单键边不参与组句（与现状 librime 屏蔽简拼一致），
-- 字级首字母序列不出候选；简拼靠词首字母码整段匹配。
cands = translate("yin_qp", "js")
check(#cands == 0, "字级首字母序列 js 不组句（结构性边界）")

-- 非前缀编辑必须重置缓存：ni -> nihao（延伸）-> hao（换段）
cands = translate("yin_qp", "ni")
check(cands[1] and cands[1].text == "你", "增量：ni")
cands = translate("yin_qp", "nihao")
check(cands[1] and cands[1].text == "你好", "增量：nihao（前缀延伸）")
cands = translate("yin_qp", "hao")
check(cands[1] and cands[1].text == "好", "非前缀切换：hao（缓存重建）")

cands = translate("yin_qp", "zz1")
check(#cands == 0, "转换失败不出候选（与现状一致）")

io.open = original_open

-- ---- 3. 真实码表冒烟（仓库根 pinyin.qp.codes.txt，无模型断言存在性） --------
local real_file = io.open(repo .. "/pinyin.qp.codes.txt", "rb")
if real_file then
    real_file:close()
    pinyin._reset_for_test()
    local real_engine = pinyin._engine_for_test()
    real_engine.set_model_enabled(false)
    local ok, results = pcall(real_engine.decode_full, "fancha", false, "")
    check(ok, "真实码表可解码")
    local found = false
    for _, item in ipairs(results or {}) do
        if item.text == "反差" then found = true break end
    end
    check(found, "真实码表 fancha 含反差")
end

print(string.format('{"status":"passed","pinyin_checks":%d,"real_model":false}', checks))
