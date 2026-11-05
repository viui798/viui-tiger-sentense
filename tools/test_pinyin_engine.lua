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
    "计\tj", "机\tj", "算\ts", "计算机\tjsj\tA", "你好\tnh\tA",
    -- 简拼整段匹配回归：fancha 不能拆成 fa + nc(内存) + ha
    "发\tfa", "哈\tha", "内存\tnc\tA",
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

-- 尾部选重键：数字/分号剥离后再转换，交给引擎 parse_selector。
local function split(raw, scheme)
    local body, sel = pinyin.split_selectors(raw, scheme)
    return body .. "|" .. sel
end
check(split("jiyu1", "flypy") == "jiyu|1", "尾部数字剥离为选重")
check(split("jiyu12", "flypy") == "jiyu|12", "连续数字整体剥离")
check(split("jiyu;", "flypy") == "jiyu|;", "小鹤尾部分号是选重")
check(split("j;", "mspy") == "j;|", "微软分号是 ing 键，不剥离")
check(split("jiyu", "flypy") == "jiyu|", "无选重键时原样")

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

cands = translate("yin_qp", "fancha")
check(texts(cands):find("反查", 1, true), "全拼 fancha 出反查")
check(texts(cands):find("发内存哈", 1, true),
    "全拼反查保留简拼边（fa+nc+ha 可以组成发内存哈）")

cands = translate("yin_flypy", "fjia")
check(texts(cands):find("反查", 1, true), "小鹤 fjia 出反查")
check(not texts(cands):find("发内存哈", 1, true),
    "双拼反查不出现简拼拼接词（fancha 只有音节组合）")

cands = translate("yin_qp", "jsj")
check(texts(cands):find("计算机", 1, true), "整段简拼 jsj 仍出计算机")

cands = translate("yin_flypy", "jsj")
check(not texts(cands):find("计算机", 1, true), "双拼不出现整段简拼 jsj")
cands = translate("yin_flypy", "nh")
check(not texts(cands):find("你好", 1, true), "双拼不出现整段简拼 nh")

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

-- 选重键不再中断反查：尾部数字/分号仍按反查解码，只选出对应名次。
cands = translate("yin_qp", "nihao1")
check(cands[1] and cands[1].text == "你好", "全拼尾部数字仍出候选（选重键不中断反查）")
cands = translate("yin_flypy", "fjia;")
check(#cands > 0 and texts(cands):find("反差", 1, true),
    "小鹤尾部分号仍出候选（选重键不中断反查）")

-- 模型开关作用域与中途切换：观察第二实例 setter，不需要真实模型。
local main_engine = require("tiger_sentence")
main_engine.set_model_enabled(false)
local setter = engine.set_model_enabled
local requested = {}
engine.set_model_enabled = function(enabled)
    requested[#requested + 1] = enabled
    -- 夹具测试始终不加载真实模型；这里只拦截并断言路由请求。
    setter(false)
end
local function translate_mode(disabled, tag, raw)
    yielded = {}
    local env = fake_env()
    env.engine.context = { get_option = function(_, name)
        return name == "pinyin_no_model" and disabled
    end }
    pinyin.translator(raw, seg_with_tag(tag), env)
    return yielded
end
check(#translate_mode(true, "yin_qp", "nihao") > 0,
    "无模型模式仍可拼音组句")
check(requested[#requested] == false, "关闭模型只路由到拼音第二实例")
check(#translate_mode(false, "yin_flypy", "nihc") > 0,
    "重新开启模型后双拼仍可输入")
check(requested[#requested] == true, "恢复模型评分请求")
local previous_calls = #requested
translate_mode(true, "abc", "nihao")
check(#requested == previous_calls, "普通虎码不触碰拼音模型状态")
check(not main_engine.model_status().loaded, "反查切换不启用虎码主实例模型")
engine.set_model_enabled = setter

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
    local real_texts = {}
    pinyin._reset_for_test()
    real_engine = pinyin._engine_for_test()
    real_engine.set_model_enabled(false)
    local function real_translate(tag, input)
        yielded = {}
        pinyin.translator(input, seg_with_tag(tag), fake_env())
        local out = {}
        for i, c in ipairs(yielded) do out[i] = c.text end
        return out
    end
    local fjia = real_translate("yin_flypy", "fjia")
    check(fjia[1] == "反查", "真实码表 fjia 首选反查")
    check(not table.concat(fjia, "|"):find("发内存哈", 1, true),
        "真实码表 fjia 不含简拼拼接词")
    local marked = real_translate("yin_flypy", "fj`ia")
    check(#marked >= 10, "真实码表 fj`ia 一个音节标记即展开多候选")
    local qp_fancha = real_translate("yin_qp", "fancha")
    check(table.concat(qp_fancha, "|"):find("发内存哈", 1, true),
        "全拼真实码表保留简拼拼接词（fa+nc+ha）")
    local flypy_fancha = real_translate("yin_flypy", "fjia")
    check(not table.concat(flypy_fancha, "|"):find("发内存哈", 1, true),
        "双拼真实码表不出现简拼拼接词")
    local qp_ygpan = real_translate("yin_qp", "ygpan")
    check(table.concat(qp_ygpan, "|"):find("一个盘", 1, true),
        "全拼真实码表保留简拼拼接（yg+pan 可以是一个盘）")
end

print(string.format('{"status":"passed","pinyin_checks":%d,"real_model":false}', checks))
