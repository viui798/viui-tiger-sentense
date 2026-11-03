-- Verify call order, lazy yields and cleanup with controlled translator doubles.
-- Real candidate equivalence is checked separately by snapshot_rime_pipeline.cpp.
local repo = arg[1] or "."
package.path = repo .. "/lua/?.lua;" .. package.path
local calls, output = {}, {}
local sentinel = {}
package.loaded.tiger_sentence_pinyin = { translator = function(input, seg, env)
    assert(env == sentinel)
    calls[#calls + 1] = "pinyin"
    if seg.reverse then yield({text = input, quality = 7, preedit = "`" .. input}) end
end }
local active = false
package.loaded.tiger_mixed = { translator = { func = function(input, seg, env)
    assert(env == sentinel)
    calls[#calls + 1] = "mixed"
    if not input:find("`", 1, true) or seg.reverse then active = false; return end
    active = true
    yield({text = "mixed", quality = 9, preedit = input})
end } }
yield = coroutine.yield
local dispatch_module = require("tiger_sentence_dispatch")
local dispatch = type(dispatch_module) == "function" and dispatch_module or dispatch_module.func
local checks = 0
for _, case in ipairs({{"abc", false, 0}, {"nihao", true, 1},
    {"fj`ia", true, 1}, {"je`nihao", false, 1}, {"nihao", true, 1},
    {"je`nihao", false, 1}, {"abc", false, 0},
    {"", false, 0}}) do
    calls, output = {}, {}
    local co = coroutine.create(dispatch)
    local ok, value = coroutine.resume(co, case[1], {reverse = case[2]}, sentinel)
    while coroutine.status(co) ~= "dead" do
        assert(ok, value)
        if case[2] then assert(not active, "reverse yield delayed mixed cleanup") end
        output[#output + 1] = value
        ok, value = coroutine.resume(co)
    end
    assert(ok, value)
    assert(table.concat(calls, ",") == "mixed,pinyin", "call order/cleanup lost")
    assert(#output == case[3], "wrong candidate count")
    if case[2] then assert(output[1].quality == 7 and output[1].preedit == "`" .. case[1]) end
    if not case[1]:find("`", 1, true) then assert(not active, "mixed state retained") end
    checks = checks + 1
end
print(string.format('{"status":"passed","dispatch_cases":%d}', checks))
