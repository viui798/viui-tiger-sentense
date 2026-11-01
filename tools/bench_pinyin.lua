-- 拼音整句性能实验：与 tools/bench_tiger_sentence_lua.lua 同一套测量方法，
-- 用例换成全拼输入（去声调、无辅助码，worst case）。
-- 用法:
--   lua bench_pinyin.lua <repo> <case_dir> [--repeat N] [--burst-cases N] [--set NAME=NUM]

local repo = arg[1]
local case_dir = arg[2] or (repo .. "/tools")
local mode = "auto"
local repeats = 5
local burst_cases = 10
local parameters = {}
for i = 3, #arg do
    if arg[i] == "--mode" then
        mode = arg[i + 1] or mode
    elseif arg[i] == "--repeat" then
        repeats = math.max(1, tonumber(arg[i + 1]) or repeats)
    elseif arg[i] == "--burst-cases" then
        burst_cases = math.max(0, tonumber(arg[i + 1]) or burst_cases)
    elseif arg[i] == "--set" then
        local name, value = (arg[i + 1] or ""):match("^([%w_]+)=([%+%-%.%deE]+)$")
        if not name or not tonumber(value) then
            io.stderr:write("--set expects NAME=NUMBER\n")
            os.exit(2)
        end
        parameters[name] = tonumber(value)
    end
end

package.path = repo .. "/lua/?.lua;" .. package.path
rime_api = {
    get_user_data_dir = function()
        return repo .. ""
    end
}

local function read_lines(path)
    local out = {}
    local file = io.open(path, "r")
    if not file then return out end
    for line in file:lines() do
        if line ~= "" then out[#out + 1] = line end
    end
    file:close()
    return out
end

local cases = {}
for _, line in ipairs(read_lines(case_dir .. "/pinyin_bench_cases.txt")) do
    local name, raw = line:match("^(.-)\t(.+)$")
    if name then cases[#cases + 1] = { name = name, raw = raw } end
end
local bursts = read_lines(case_dir .. "/pinyin_bench_bursts.txt")

local sentence = require("tiger_sentence")
local build_started = os.clock()
-- 生产拼音路径用 auto_select_min_code_length=0（单/双键音节边可参与组句），
-- high_freq_limit 走默认；与 tiger_sentence_pinyin.lua 的假 env 一致。
local fake_config
fake_config = {
    get_int = function(_, key)
        if key == "tiger_sentence/auto_select_min_code_length" then return 0 end
        return ""  -- 非数字 → 引擎保持默认
    end,
}
local fake_env = { engine = { schema = { config = fake_config } } }
sentence.ensure_lexicon(fake_env)
collectgarbage("collect")
io.write(string.format("lexicon build: %.2fs, resident %.1f MiB\n",
    os.clock() - build_started, collectgarbage("count") / 1024))
sentence.set_decoder_parameters_for_test(parameters)
sentence.set_model_enabled(mode ~= "none")
local model = sentence.model_status()
if mode ~= "none" and not model.loaded then
    io.stderr:write("model failed: " .. tostring(model.error) .. "\n")
    os.exit(2)
end

local function percentile(sorted, share)
    return sorted[math.max(1, math.ceil(#sorted * share))]
end

local function summarize(times, gc_total)
    local sorted = {}
    local total, maximum = 0.0, 0.0
    for i = 1, #times do
        sorted[i] = times[i]
        total = total + times[i]
        maximum = math.max(maximum, times[i])
    end
    table.sort(sorted)
    return {
        mean = total / #times,
        p50 = percentile(sorted, 0.50),
        p95 = percentile(sorted, 0.95),
        p99 = percentile(sorted, 0.99),
        maximum = maximum,
        gc_kib = gc_total / #times
    }
end

local function measure(run)
    local times = {}
    local gc_total = 0.0
    local result
    for _ = 1, repeats do
        collectgarbage("collect")
        local before_gc = collectgarbage("count")
        local started = os.clock()
        result = run()
        times[#times + 1] = (os.clock() - started) * 1000
        gc_total = gc_total + math.max(0.0, collectgarbage("count") - before_gc)
    end
    return result, summarize(times, gc_total)
end

local function run_full(raw, evidence)
    return function()
        sentence.reset_decode_cache()
        return sentence.decode_full(raw, evidence, "")
    end
end

local function run_incremental(raw, evidence)
    return function()
        sentence.reset_decode_cache()
        local result = {}
        for length = 1, #raw do
            result = sentence.decode(raw:sub(1, length), evidence, "")
        end
        return result
    end
end

local function run_frontend(raw)
    return function()
        sentence.reset_decode_cache()
        local result = {}
        for length = 1, #raw do
            if length > 1 then
                sentence.decode(raw:sub(1, length - 1), true, "")
            end
            result = sentence.decode(raw:sub(1, length), false, "")
        end
        return result
    end
end

local function run_display(raw)
    return function()
        sentence.reset_decode_cache()
        local result = {}
        for length = 1, #raw do
            result = sentence.decode(raw:sub(1, length), true, "")
            for i = 1, #result do
                assert(type(result[i].segmented) == "string")
            end
        end
        return result
    end
end

local function performance_snapshot()
    local current = sentence.performance_status().current
    return {
        decode_calls = current.decode_calls,
        page_misses = current.page_misses,
        page_bytes = current.page_bytes,
        evidence_builds = current.early_evidence_builds
    }
end

local function print_result(case, kind, result, stats, metrics)
    local top = result[1] and result[1].text or ""
    io.write(string.format(
        "%-22s %-11s keys=%2d cands=%2d mean=%8.2fms p50=%8.2fms " ..
        "p95=%8.2fms max=%8.2fms gc=%8.1fKiB calls=%5.1f ev=%4.1f " ..
        "miss=%6.1f read=%8.1fKiB top=%s\n",
        case.name, kind, #case.raw, #result, stats.mean, stats.p50,
        stats.p95, stats.maximum, stats.gc_kib, metrics.decode_calls,
        metrics.evidence_builds, metrics.page_misses, metrics.page_kib, top))
end

local function benchmark(case, kind, run)
    local before = performance_snapshot()
    local result, stats = measure(run)
    local after = performance_snapshot()
    local metrics = {
        decode_calls = (after.decode_calls - before.decode_calls) / repeats,
        evidence_builds = (after.evidence_builds - before.evidence_builds) / repeats,
        page_misses = (after.page_misses - before.page_misses) / repeats,
        page_kib = (after.page_bytes - before.page_bytes) / repeats / 1024
    }
    print_result(case, kind, result, stats, metrics)
    return result
end

io.write(string.format(
    "engine=%s mode=%s repeats=%d burst_cases=%d model=%s params=%s\n",
    (_VERSION or "?") .. (jit and ("/" .. jit.version) or ""),
    mode, repeats, burst_cases, model.loaded and tostring(model.format) or "none",
    next(parameters) and "custom" or "default"))

if burst_cases > 0 then
    local totals = {}
    local per_key = {}
    for case_index = 1, math.min(burst_cases, #bursts) do
        local raw = bursts[case_index]
        sentence.reset_decode_cache()
        local total_started = os.clock()
        for length = 1, #raw do
            local key_started = os.clock()
            sentence.decode(raw:sub(1, length), false, "")
            per_key[#per_key + 1] = (os.clock() - key_started) * 1000
        end
        totals[#totals + 1] = (os.clock() - total_started) * 1000
    end
    local total_stats = summarize(totals, 0.0)
    local key_stats = summarize(per_key, 0.0)
    io.write(string.format(
        "%-22s %-11s cases=%2d mean=%8.2fms p50=%8.2fms p95=%8.2fms " ..
        "max=%8.2fms key_p95=%6.2fms key_p99=%6.2fms key_max=%6.2fms\n",
        "40键随机音节串", "burst", burst_cases, total_stats.mean,
        total_stats.p50, total_stats.p95, total_stats.maximum,
        key_stats.p95, key_stats.p99, key_stats.maximum))
end

for _, case in ipairs(cases) do
    sentence.reset_decode_cache()
    sentence.decode_full(case.raw, true, "")

    local full = benchmark(case, "full", run_full(case.raw, false))
    local incremental = benchmark(case, "incremental", run_incremental(case.raw, false))
    local evidence = benchmark(case, "evidence", run_incremental(case.raw, true))
    local frontend = benchmark(case, "frontend", run_frontend(case.raw))
    benchmark(case, "display", run_display(case.raw))

    if not sentence.results_equal(incremental, sentence.decode_full(case.raw, false, "")) or
        not sentence.results_equal(evidence, sentence.decode_full(case.raw, true, "")) or
        not sentence.results_equal(frontend, incremental) then
        io.stderr:write("incremental/full mismatch for " .. case.raw .. "\n")
        os.exit(1)
    end
end
