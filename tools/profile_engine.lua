-- 引擎解码 Lua 采样剖析：统计 decode 期间 VM 指令采样落在哪些函数/行。
-- 用法: lua profile_engine.lua <repo> [rounds]
-- 低失真：sethook 每 N 条指令采样一次，只记 debug.getinfo(2) 的 func+line。
local repo = arg[1] or "."
local rounds = tonumber(arg[2]) or 200
package.path = repo .. "/lua/?.lua;" .. package.path
rime_api = { get_user_data_dir = function() return repo end }

local sentence = require("tiger_sentence")
sentence.ensure_lexicon(nil)
sentence.set_model_enabled(true)
if not sentence.model_status().loaded then error("model not loaded") end

local RAW = "jaefmonyftuderlmljgbmnvs" -- 今天早上我吃了两个面包（整句流）

-- 预热（含模型分页）
sentence.reset_decode_cache()
sentence.decode_full(RAW, true, "")

local samples, by_line = {}, {}
local total_samples = 0
local sampling = false

local function hook()
    if not sampling then return end
    local info = debug.getinfo(2, "Sn")
    if not info then return end
    local name = info.name or "?"
    local src = info.source:match("([^/]+)$") or info.source
    local key = src .. ":" .. (info.linedefined or 0) .. " " .. name
    samples[key] = (samples[key] or 0) + 1
    local lkey = key .. "@" .. tostring(info.currentline or 0)
    by_line[lkey] = (by_line[lkey] or 0) + 1
    total_samples = total_samples + 1
end

debug.sethook(hook, "", 5000)
for i = 1, rounds do
    sentence.reset_decode_cache()
    -- 模拟真实逐键（含缓存命中路径）：每键一次 decode
    for len = 1, #RAW do
        sampling = true
        sentence.decode(RAW:sub(1, len), false, "")
        sampling = false
    end
end
debug.sethook()

print(string.format("rounds=%d samples=%d (每样本≈%.0f 条VM指令采样点/round)",
    rounds, total_samples, total_samples / rounds))

local sorted = {}
for k, v in pairs(samples) do sorted[#sorted + 1] = { k = k, v = v } end
table.sort(sorted, function(a, b) return a.v > b.v end)
print("\n== 函数级 Top 20（占采样 %）==")
for i = 1, math.min(20, #sorted) do
    local e = sorted[i]
    print(string.format("%5.1f%%  %6d  %s", e.v / total_samples * 100, e.v, e.k))
end

local lsorted = {}
for k, v in pairs(by_line) do lsorted[#lsorted + 1] = { k = k, v = v } end
table.sort(lsorted, function(a, b) return a.v > b.v end)
print("\n== 行级 Top 15 ==")
for i = 1, math.min(15, #lsorted) do
    local e = lsorted[i]
    print(string.format("%5.1f%%  %6d  %s", e.v / total_samples * 100, e.v, e.k))
end
