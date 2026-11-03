-- Share one librime-lua translation coroutine for reverse lookup, mixed input,
-- and the auxiliary translators (numbers / calculator / date-time / statistics).
-- Each producer only yields for its own input, so merging entries does not mix
-- candidates; it only removes redundant LuaTranslation lifecycles (the Squirrel
-- plugin runs a full Lua GC when each one is destroyed).
-- Run mixed first: its cleanup must not wait for a lazy reverse iterator to end.
-- The main sentence translator keeps its own env and lifecycle for now.
local pinyin = require("tiger_sentence_pinyin").translator
local mixed = require("tiger_mixed").translator.func
local number = require("number")
local calculator = require("calculator_translator")
local shijian2 = require("shijian2")

-- 统计模块在加载时会读取 rime_api；测试环境没有 rime_api，延迟到真正用到时再取。
local statistics_module
local function statistics()
    if statistics_module == nil then
        local ok, mod = pcall(require, "input_statistics")
        statistics_module = ok and mod or false
    end
    return statistics_module or nil
end

local M = {}

function M.init(env)
    local st = statistics()
    if st and type(st.init) == "function" then st.init(env) end
end

function M.fini(env)
    local st = statistics()
    if st and type(st.fini) == "function" then st.fini(env) end
end

function M.func(input, seg, env)
    mixed(input, seg, env)
    pinyin(input, seg, env)
    if number then number(input, seg, env) end
    if calculator then calculator(input, seg, env) end
    if shijian2 then shijian2(input, seg, env) end
    local st = statistics()
    if st and type(st.func) == "function" then st.func(input, seg, env) end
end

return M
