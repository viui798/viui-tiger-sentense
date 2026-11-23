-- 输入统计口径回归（v0.3.28）
--
-- 覆盖 2026-11 修复的四个问题：
--   ① 生词判定的毫秒/秒混用：以前每个上屏都被记成生词；
--   ② 平均分速把「挂着候选窗发呆」的时长算进本轮：日统计读数掉到 1 字/分；
--   ③ 上屏的空格、选重数字被算进击键/码长：误触率虚高（实测 37%）；
--   ④ 非汉字上屏后计键不归零：码长与轮次计时串到下一个词。
-- 另验证存档体积有界（旧版 avgGaps 无限增长，单方案 1.3MB）。
--
-- 运行：lua tools/test_input_statistics.lua .
local repo = arg[1] or "."
package.path = repo .. "/lua/?.lua;" .. package.path

local checks = 0
local function check(ok, message)
    checks = checks + 1
    assert(ok, message)
end

-- ── 仿真环境 ────────────────────────────────────────────────
local tmpbase = os.getenv("TMPDIR") or "/tmp"
local userdir = tmpbase .. "/tiger-stats-test-" .. tostring(os.time()) .. "-" .. tostring(math.random(1e6))
os.execute("mkdir -p '" .. userdir .. "/lua'")

local clock = 1000000
rime_api = {
    get_user_data_dir = function() return userdir end,
    get_distribution_code_name = function() return "Squirrel" end,
    get_distribution_version = function() return "1.0.0" end,
    get_time_ms = function() return clock end,
}

local yielded = {}
Candidate = function(_, _, _, text) return { text = text } end
yield = function(c) yielded[#yielded + 1] = c end

local function signal()
    local handlers = {}
    return {
        connect = function(_, fn) handlers[#handlers + 1] = fn; return { disconnect = function() end } end,
        emit = function(_, ...) for _, fn in ipairs(handlers) do fn(...) end end,
    }
end

local S, ctx, env, history

local function key(kc)
    return {
        keycode = kc,
        repr = function() return kc < 128 and string.char(kc) or "" end,
        release = function() return false end,
        ctrl = function() return false end,
        alt = function() return false end,
        super = function() return false end,
    }
end

local function new_session(id, keep_file)
    if S then S.fini(env) end
    package.loaded["input_statistics"] = nil
    history = {}
    ctx = {
        input = "",
        composing = false,
        commit_notifier = signal(),
        update_notifier = signal(),
        property_update_notifier = signal(),
        get_commit_text = function(self) return self._commit or "" end,
        is_composing = function(self) return self.composing end,
        get_property = function() return nil end,
        commit_history = {
            to_table = function()
                local t = {}
                for i, r in ipairs(history) do t[i] = { type = r.type, text = r.text } end
                return t
            end,
        },
    }
    env = { engine = { context = ctx, schema = { schema_id = id, schema_name = "仿真" } } }
    if not keep_file then
        os.remove(userdir .. "/lua/input_stats_" .. id .. ".lua")
    end
    S = require("input_statistics")
    S.init(env)
end

local function tick(ms) clock = clock + (ms or 100) end

local function press(ch, ms)
    tick(ms or 100)
    S.processor(key(string.byte(ch)), env)
    ctx.input = ctx.input .. ch
    ctx.composing = true
    ctx.update_notifier:emit(ctx)
    S.func(ctx.input, { start = 0, _end = #ctx.input }, env)
end

local function press_key(kc, ms)
    tick(ms or 100)
    S.processor(key(kc), env)
    S.func(ctx.input, { start = 0, _end = #ctx.input }, env)
end

local function commit(text, ctype)
    tick(100)
    S.processor(key(0x20), env) -- 空格上屏
    history[#history + 1] = { type = ctype or "sentence", text = text }
    ctx.input = ""
    ctx.composing = false
    ctx._commit = text
    ctx.commit_notifier:emit(ctx)
    ctx.update_notifier:emit(ctx)
end

local function report(cmd)
    yielded = {}
    S.func(cmd, { start = 0, _end = #cmd }, env)
    return (yielded[1] and yielded[1].text or ""):gsub("\r\n", "\n")
end

local function saved(id)
    local e = {}
    local f = loadfile(userdir .. "/lua/input_stats_" .. id .. ".lua", "t", e)
    if not f then return nil end
    f()
    return e.input_stats
end

-- ── ① 生词判定：只有 >3s 卡壳的词才进生词本 ──────────────────
new_session("t_words")
press("w", 100); press("o", 100); commit("我们")
tick(500)
press("t", 100); press("a", 100); commit("他")
tick(5000)
press("s", 100); press("h", 100); press("u", 100); commit("书")
S.fini(env)
local st = saved("t_words")
local words = {}
for k in pairs(st.newWords.words) do words[#words + 1] = k end
check(#words == 1 and words[1] == "书", "只有卡壳后的「书」应记入生词本，实际：" .. table.concat(words, ","))
check(st.newWords.startTime > 1500000000 and st.newWords.startTime < 4102444800,
    "生词起始时间必须是秒级时间戳，实际：" .. tostring(st.newWords.startTime))

-- ── ② 平均分速：长停顿不进样本；1.3s 的 2 字词 ≈ 92 字/分 ─────
new_session("t_speed")
for _ = 1, 6 do
    press("w", 1200); press("o", 1200); commit("我们")
end
S.fini(env)
local sp = saved("t_speed")
local sumGap = 0
for i = 1, #sp.daily.avgGaps do sumGap = sumGap + sp.daily.avgGaps[i] end
check(#sp.daily.avgGaps == 6, "6 个 1.3s 的轮次都应入样，实际 " .. #sp.daily.avgGaps)
check(sp.daily.avgCntSum == 12, "6 个 2 字词共 12 字，实际 " .. tostring(sp.daily.avgCntSum))
check(math.abs(12 / sumGap * 60 - 92.3) < 3, "平均分速应接近 92 字/分，实际 " .. (12 / sumGap * 60))

new_session("t_idle")
press("t", 400); press("a", 400); press("m", 400)
tick(600 * 1000) -- 候选窗挂 10 分钟再上屏
commit("他们")
S.fini(env)
local si = saved("t_idle")
check(#si.daily.avgGaps == 0, "挂着候选窗发呆的轮次不应进入平均速度")
check(si.daily.count == 1 and si.daily.length == 2, "发呆轮次仍应计上屏次数与字数")

-- ── ③ 击键/码长：选重数字与空格不计 ─────────────────────────
new_session("t_keys")
press("a"); press("b"); press("c"); press("d")
press_key(string.byte("2")) -- 数字选重
commit("测")
local rep = report("//11")
S.fini(env)
local sk = saved("t_keys")
check(sk.daily.totalCodeLenWithoutSpace == 4, "码长应为 4（不含选重键），实际 " .. sk.daily.totalCodeLenWithoutSpace)
check(sk.daily.keyTouchCnt == 4, "击键应为 4（不含空格/数字），实际 " .. sk.daily.keyTouchCnt)
check(rep:find("误触0次", 1, true) ~= nil, "选重与空格不应算误触：" .. rep:gsub("\n", " | "))
check(rep:find("码长4.0", 1, true) ~= nil, "面板码长应为 4.0：" .. rep:gsub("\n", " | "))

-- ── ④ 非汉字上屏：计键归零，不串到下一个词 ──────────────────
new_session("t_leak")
press("t"); press("e"); press("s"); press("t")
commit("test") -- 英文提交（不统计）
tick(2000)
press("a"); press("b"); press("c"); press("d")
commit("测")
S.fini(env)
local sl = saved("t_leak")
check(sl.daily.totalCodeLenWithoutSpace == 4, "英文按键不应串进中文码长，实际 " .. sl.daily.totalCodeLenWithoutSpace)
check(sl.daily.keyTouchCnt == 4, "英文按键不应串进击键，实际 " .. sl.daily.keyTouchCnt)
check(sl.daily.avgCntSum == 1 and sl.daily.avgGapSum < 1.0,
    "轮次计时不应包含英文段的 2s，实际 gap=" .. sl.daily.avgGapSum)

-- ── ⑤ 存档体积：2000 次上屏后数组有界 ──────────────────────
new_session("t_size")
for _ = 1, 2000 do
    press("a", 400); press("b", 400); commit("测")
end
S.fini(env)
local f = io.open(userdir .. "/lua/input_stats_t_size.lua")
local data = f:read("*a")
f:close()
local zs = saved("t_size")
check(#zs.daily.avgGaps <= 150, "avgGaps 应截尾到 150 以内，实际 " .. #zs.daily.avgGaps)
check(#data < 80 * 1024, "统计文件应小于 80KB，实际 " .. string.format("%.1fKB", #data / 1024))
check(zs.daily.count == 2000 and zs.daily.length == 2000, "计数不应受截尾影响")

-- ── ⑥ 旧存档迁移：清脏生词、截尾数组、扣掉空格误触 ──────────
os.remove(userdir .. "/lua/input_stats_legacy.lua")
local legacy = [[
input_stats = {
  ["daily"] = {
    ["count"] = 100, ["length"] = 200,
    ["fastest"] = { ["spd"] = 900, ["keyTouchSpd"] = 0, ["avgCodeLen"] = 0 },
    ["ts"] = 0,
    ["lengths"] = { [1] = 100 },
    ["codeLengths"] = { [4] = 100 },
    ["avgGaps"] = { [1] = 30697, [2] = 1.3, [3] = 1.3, [4] = 600 },
    ["avgCnts"] = { [1] = 1, [2] = 2, [3] = 2, [4] = 2 },
    ["avgCodeLen"] = { [1] = 4, [2] = 8, [3] = 8, [4] = 8 },
    ["keyTouchCnt"] = 900, ["totalCodeLenWithoutSpace"] = 400
  },
  ["weekly"]  = { ["count"] = 0, ["length"] = 0, ["fastest"] = { ["spd"] = 0, ["keyTouchSpd"] = 0, ["avgCodeLen"] = 0 }, ["ts"] = 0, ["lengths"] = {}, ["codeLengths"] = {}, ["avgGaps"] = {}, ["avgCnts"] = {}, ["avgCodeLen"] = {}, ["keyTouchCnt"] = 0, ["totalCodeLenWithoutSpace"] = 0 },
  ["monthly"] = { ["count"] = 0, ["length"] = 0, ["fastest"] = { ["spd"] = 0, ["keyTouchSpd"] = 0, ["avgCodeLen"] = 0 }, ["ts"] = 0, ["lengths"] = {}, ["codeLengths"] = {}, ["avgGaps"] = {}, ["avgCnts"] = {}, ["avgCodeLen"] = {}, ["keyTouchCnt"] = 0, ["totalCodeLenWithoutSpace"] = 0 },
  ["yearly"]  = { ["count"] = 0, ["length"] = 0, ["fastest"] = { ["spd"] = 0, ["keyTouchSpd"] = 0, ["avgCodeLen"] = 0 }, ["ts"] = 0, ["lengths"] = {}, ["codeLengths"] = {}, ["avgGaps"] = {}, ["avgCnts"] = {}, ["avgCodeLen"] = {}, ["keyTouchCnt"] = 0, ["totalCodeLenWithoutSpace"] = 0 },
  ["logVer"] = 4,
  ["daily_max"] = 2,
  ["newWords"] = { ["startTime"] = 1000000, ["words"] = { ["的"] = 1, ["我们"] = 1, ["是"] = 1 } },
  ["deviceType"] = "💻",
  ["progressBarSkinIdx_word"] = 1,
  ["progressBarSkinIdx_code"] = 1
}
]]
local lf = assert(io.open(userdir .. "/lua/input_stats_legacy.lua", "w"))
lf:write(legacy)
lf:close()
new_session("legacy", true)
rep = report("//11")
S.fini(env)
local lg = saved("legacy")
check(#lg.daily.avgGaps == 2, "只保留 2 个可信样本（1.3s×2），实际 " .. #lg.daily.avgGaps)
check(math.abs(lg.daily.avgGapSum - 2.6) < 1e-6, "累计时长应按保留样本重算")
check(lg.daily.fastest.spd == 0, "900 字/分的脏极速应清掉")
check(lg.daily.keyTouchCnt == 800, "旧口径的 100 次上屏空格应从击键里扣掉")
check(next(lg.newWords.words) == nil, "旧的脏生词本应清空")
check(rep:find("已掌握生词  0", 1, true) ~= nil or rep:find("已掌握生词 0", 1, true) ~= nil,
    "面板应显示 0 个生词：" .. rep:gsub("\n", " | "))

-- 再次启动不能把「全周期累计和」按尾部 120 个样本重算（否则平均速度会漂移）
new_session("legacy", true)
S.fini(env)
local lg2 = saved("legacy")
check(lg2.daily.avgGapSum == lg.daily.avgGapSum and lg2.daily.avgCntSum == lg.daily.avgCntSum,
    "重复启动后累计和应保持不变")

os.execute("rm -rf '" .. userdir .. "'")
print(string.format("input_statistics: %d checks passed", checks))
