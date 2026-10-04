-- key_counter.lua — 击键计数器（文件共享版 v4）
-- 挂载：方案XXX.schema.yaml processors 第一行加              - lua_processor@*key_counter
-- 为什么用文件：元书实测 processor 与 translator 的 Lua 状态不共享内存，
--   文件系统是唯一可靠的跨实例通道。
-- 返回 2 = kNoop（放行不吞键）；返回 1 会吞掉所有按键（删除键失灵）！

local M = {}
local K_NOOP = 2

-- 两个计数文件（Rime 用户目录 lua/ 下）：
--   kc_count.txt  → pending 待取走的击键数（每次上屏 take 清零）
--   kc_total.txt  → 累计击键数（只增不清，用于面板验证是否在工作）
local count_file, total_file, last_file
if rime_api and rime_api.get_user_data_dir then
    local ok, dir = pcall(rime_api.get_user_data_dir)
    if ok and dir then
        if dir:sub(-1) ~= "/" then dir = dir .. "/" end
        count_file = dir .. "lua/kc_count.txt"
        total_file = dir .. "lua/kc_total.txt"
        last_file = dir .. "lua/kc_last.txt"
    end
end

-- 追加 1 字节（一次按键）：普通键 "1"，退格键 "2"；失败静默
local function bump(byte)
    byte = byte or "1"
    if not count_file then return end
    pcall(function()
        local f = io.open(count_file, "a")
        if f then f:write(byte); f:close() end
        local t = io.open(total_file, "a")
        if t then t:write(byte); t:close() end
    end)
end

-- 退格键判定（BackSpace 0xff08 / ASCII BS 0x08 / Delete 0xffff）
-- 屏蔽修饰位：Shift+退格（keycode 高位带 0x20000000）也识别为退格
local function is_backspace(ev)
    local kc = ev and ev.keycode or 0
    kc = kc % 0x1000000  -- 去掉 Shift/Ctrl/Alt 修饰位
    return kc == 0xff08 or kc == 0x08 or kc == 0xffff
end

-- 读文件字节数
local function read_bytes(path)
    if not path then return 0 end
    local n = 0
    pcall(function()
        local f = io.open(path, "rb")
        if f then
            local s = f:read("*a")
            n = s and #s or 0
            f:close()
        end
    end)
    return n
end

-- 有效退格：把最后一个未消费码 "1" 改为 "3"（被删码），并追加 "2"（退格键）
-- 空删（无未消费码）：不写任何文件，不计入统计
local function backspace_bump()
    if not count_file then return end
    pcall(function()
        local f = io.open(count_file, "rb")
        if not f then return end
        local s = f:read("*a") or ""
        f:close()
        local last = nil
        for i = #s, 1, -1 do
            if s:sub(i, i) == "1" then last = i break end
        end
        if last then
            s = s:sub(1, last - 1) .. "3" .. s:sub(last + 1)
            local g = io.open(count_file, "w")
            if g then g:write(s); g:close() end
            local h = io.open(count_file, "a")
            if h then h:write("2"); h:close() end
            local t = io.open(total_file, "a")
            if t then t:write("2"); t:close() end
        end
    end)
end

-- 修饰键（Shift/Ctrl/Alt/Caps 等）：单独按下只是切换模式，不产生输入，不计数
local MODIFIER_KEYS = {
    [0xffe1] = true, [0xffe2] = true,  -- Shift L/R
    [0xffe3] = true, [0xffe4] = true,  -- Control L/R
    [0xffe5] = true,                   -- Caps Lock
    [0xffe7] = true,                   -- Meta
    [0xffe9] = true, [0xffea] = true,  -- Alt L/R
}
-- Esc：清空当前输入 → 连同之前未上屏的码一起丢弃，不计数
local function escape_clear()
    if not count_file then return end
    pcall(function()
        local f = io.open(count_file, "w")
        if f then f:close() end
    end)
end

-- [0813] 选字键动态收集：从 schema 的 key_binder/bindings 读取绑定了候选
-- 选择的键（如小鹤 semicolon → send: 2 次选键），这类键是"选字/提交键"，
-- 必须记 "4"——否则被当编码键"1"，顶屏判定误判为次选顶屏 → restore 残留
-- → 下一次多 1 键（用户实测 4码+分号次选显示 6 键）。
-- 静态兜底：分号 0x3b（小鹤次选键，绝大多数方案分号不作编码字符）
local SELECT_KEYS = { [0x3b] = true }
local select_loaded = false
local recent_keys = {}  -- 最近按键序列（诊断显示）
local last_raw_kc = nil -- 上一个按键键值（元书次选键附带事件去重用）
local KEY_NAME_CODE = {
    space = 0x20, semicolon = 0x3b, apostrophe = 0x27, comma = 0x2c,
    period = 0x2e, slash = 0x2f, minus = 0x2d, equal = 0x3d, grave = 0x60,
    bracketleft = 0x5b, bracketright = 0x5d, backslash = 0x5c,
    tab = 0xff09, ["return"] = 0xff0d, escape = 0xff1b, backspace = 0xff08,
    back = 0xff08, delete = 0xffff, up = 0xff52, down = 0xff54,
    left = 0xff51, right = 0xff53, page_up = 0xff55, page_down = 0xff56,
    home = 0xff50, ["end"] = 0xff57,
}
local function keycode_of(acc)
    if not acc or acc == "" then return nil end
    local n = tonumber(acc)
    if n then return n end
    if #acc == 1 then
        local b = acc:byte()
        if b and b >= 0x20 and b <= 0x7e then return b end
    end
    return KEY_NAME_CODE[acc:lower()]
end
local function load_select_keys(env)
    if select_loaded then return end
    select_loaded = true
    pcall(function()
        local config = env and env.engine and env.engine.schema
            and env.engine.schema.config
        if not config then return end
        local list = config.get_list and config:get_list("key_binder/bindings")
        if not list then return end
        local size = list.size or 0
        for i = 0, size - 1 do
            local b = list:get_value_at(i)
            if b then
                local send = b.get_int and b:get_int("send")
                if send and send >= 1 and send <= 9 then
                    local acc = b.get_string and b:get_string("accept")
                    local kc = keycode_of(acc)
                    if kc then SELECT_KEYS[kc] = true end
                end
            end
        end
    end)
end

-- processor 入口：每次按键追加计数
-- "1"=未消费码 "2"=退格键 "3"=被删码（原"1"被退格消费）
function M.func(key_event, env)
    load_select_keys(env)
    local rep = key_event and key_event["repeat"]
    -- [0813] 长按 repeat（桌面物理键盘按住连发）不计入击键；
    -- librime-lua 有 repeat 字段则过滤，无该字段则跳过（安全）
    if rep then return K_NOOP end
    local kc = key_event and key_event.keycode or 0
    if kc == 0 then
        return K_NOOP  -- 无有效键值的事件（特殊通知），不计数
    end
    -- [0813] 最近按键序列记录（诊断用，默认关闭）
    -- 需要诊断选字键识别/重复事件问题时：删除下方 --[[ 和 ]]-- 启用。
    -- 启用后每键覆盖写 kc_last.txt（最近 6 键，约 70 字节恒定）。
    -- 恢复面板显示需在 input_statistics format_summary 的 kc_line 后
    -- 加：读取 key_counter.last_key() 展示。
    --[[
    if last_file then
        pcall(function()
            table.insert(recent_keys, string.format("0x%x", kc))
            if #recent_keys > 6 then table.remove(recent_keys, 1) end
            local f = io.open(last_file, "w")
            if f then
                f:write(table.concat(recent_keys, " "))
                f:close()
            end
        end)
    end
    ]]--
    -- [0813] keyup（release 位 0x40000000）不计数：小狼毫等桌面 Rime 会
    -- keydown+keyup 都调 process_key（每个物理键 2 次事件），导致每键 ×2、
    -- 且顶屏/指令清理后残留 1 键（keyup 在 TAKE/RESET 之后到达）。
    -- release 标志在 modifier（keycode 仍是正常键值）。
    -- 手机元书不发送 release 事件，此判断不影响手机。
    local modf = key_event and key_event.modifier or 0
    if modf % 0x80000000 >= 0x40000000 then
        return K_NOOP
    end
    -- [0813] 元书次选键附带事件去重：键盘"分号位"次选键点击一次发送
    -- 两个事件（0x3b 触发方案次选 + 0x32 兜底选第 2 候选），后者不重复
    -- 计数——否则 4码+分号 = 6 键（用户实测 kc 序列 0x3b 0x32）。
    local raw_kc = kc % 0x1000000
    if raw_kc == 0x32 and last_raw_kc and last_raw_kc % 0x1000000 == 0x3b then
        last_raw_kc = kc
        return K_NOOP
    end
    last_raw_kc = kc
    -- [0813] Ctrl/Alt/Meta 组合键（Ctrl+Space 切中英、Ctrl+字母快捷键等）
    -- 不产生输入提交但会被计数 → 残留污染下一次上屏（用户实测 4码+空格
    -- 变 7 键）。修饰位可能在 modifier 字段或 keycode 高位，分开检查。
    -- Shift 组合（大写/Shift+数字选字）不受影响；Caps 状态位（0x02000000）
    -- 也不拦截（Caps 开启时打字照常计数）。
    local function has_ctrl_alt_meta(n)
        -- 右移 26 位（÷2^26），低 3 位非 0 = 含 Ctrl(2^28)/Alt(2^27)/Meta(2^26)
        return math.floor(n / 0x4000000) % 8 ~= 0
    end
    if has_ctrl_alt_meta(modf) then return K_NOOP end
    local kc_high = kc - kc % 0x1000000  -- keycode 高位修饰（合并式 keycode 如 0x10000020）
    if has_ctrl_alt_meta(kc_high) then return K_NOOP end
    local raw = kc % 0x1000000  -- 屏蔽修饰位后的键值
    if MODIFIER_KEYS[raw] then
        return K_NOOP                    -- 修饰键不计数
    end
    if raw == 0xff1b then
        escape_clear()                   -- Esc：丢弃当前输入（含之前的码）
        return K_NOOP
    end
    if is_backspace(key_event) then
        backspace_bump()
        return K_NOOP
    end
    -- 选字/提交键（空格、数字、Enter、Tab、方案绑定的选字键如分号）：写 "4"
    if raw == 0x20 or (raw >= 0x30 and raw <= 0x39)
        or raw == 0xff0d or raw == 0xff09
        or SELECT_KEYS[raw] then
        bump("4")
    else
        bump("1")
    end
    return K_NOOP
end

-- input_statistics 每次上屏调用：取走待取击键数并清零（保留文件）
-- 返回 (总键数, 退格数, 最后键类型)
-- 文件内容："1"=编码键 "2"=退格键 "3"=被删码 "4"=选字/提交键（空格/数字/Enter）
function M.take()
    local n, bs, last_type = 0, 0, nil
    if count_file then
        pcall(function()
            local f = io.open(count_file, "rb")
            if f then
                local s = f:read("*a") or ""
                n = #s  -- 总键 = 全部字节
                for i = 1, #s do
                    if s:sub(i, i) == "2" then bs = bs + 1 end  -- "2"=退格键
                end
                if #s > 0 then
                    last_type = s:sub(#s, #s)  -- 最后一个键的类型
                end
                f:close()
            end
            local g = io.open(count_file, "w")
            if g then g:close() end
        end)
    end
    return n, bs, last_type
end

-- 次选顶屏：把最后一个编码键写回（它属于下一个字，不算本次上屏）
function M.restore_last()
    if count_file then
        pcall(function()
            local f = io.open(count_file, "a")
            if f then f:write("1"); f:close() end
        end)
    end
end

-- 累计击键数（只增不清）：面板显示，打字后变大 = 计数器在工作
function M.count()
    return read_bytes(total_file)
end

-- 最近一次按键的 keycode（十六进制字符串），面板"最近键"显示用
function M.last_key()
    local s = ""
    if last_file then
        pcall(function()
            local f = io.open(last_file, "r")
            if f then
                s = f:read("*a") or ""
                f:close()
            end
        end)
    end
    return s
end

-- 清空待取计数（指令模式下调用：指令键不 commit，不计入统计）
function M.reset()
    if count_file then
        pcall(function()
            local f = io.open(count_file, "w")
            if f then f:close() end
        end)
    end
end

-- 挂载检测：累计文件存在 = func 至少跑过一次
function M.status()
    return total_file and read_bytes(total_file) > 0 and 1 or 0
end

return M
