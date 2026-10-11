-- key_counter.lua — 击键计数器（内存缓冲版 v5）
-- 挂载：方案XXX.schema.yaml processors 第一行加              - lua_processor@*key_counter
-- v5 性能修复：v4 每个按键同步 io.open 两个文件各一次（Windows/Android 上
--   每键卡顿的主因），退格还要把 kc_count.txt 整读整写。当前 input_statistics
--   4.2 版并不读取本模块的输出（它用 translator 自己的触键计数），因此：
--   * pending 计数全部留在内存，take() 时才消费；
--   * 累计值按「上屏批 + 时间/字节双阈值」异步落盘 kc_total.txt；
--   * M.count() / M.status() 返回 文件基线 + 内存增量，读数语义与 v4 一致。
-- 唯一行为差异：进程被强杀时，最后一个未落盘周期的击键不进累计文件。
-- 返回 2 = kNoop（放行不吞键）；返回 1 会吞掉所有按键（删除键失灵）！

local M = {}
local K_NOOP = 2

-- 累计值落盘的节流：距上次落盘至少这么久，或未落盘字节达到这么多个
local RESTORE_SECONDS = 60
local RESTORE_BYTES = 120

-- 计数文件（Rime 用户目录 lua/ 下）：
--   kc_total.txt  → 累计击键字节流：“1”=编码键 “2”=退格键 “3”=被删码
--                   “4”=选字/提交键；只增不清，用于面板验证是否在工作。
--   kc_count.txt  → v4 遗留的 pending 文件，v5 的 pending 全在内存，
--                   不再读写该文件（指针保留以兼容旧诊断脚本的存在性检查）。
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

-- ===== 内存计数（与 v4 的 kc_count.txt / kc_total.txt 字节语义完全一致）=====
-- pending: { {ch="1"|"2"|"3"|"4"}, ... }；退格把最近一个未消费 "1" 改成 "3"
local pending = {}
-- 累计：基线是从 kc_total.txt 读回的既有字节串（惰性读一次），
-- 新增的键先存在 unflushed 里，落盘时一次性追加写入。
local total_baseline = nil            -- 字符串或 ""（读过文件后非 nil）
local unflushed = {}                  -- { {ch=...}, ... } 未落盘的新键
local unflushed_bytes = 0
local last_flush_time = 0

local function pending_clear()
    for i = #pending, 1, -1 do pending[i] = nil end
end

local function pending_track(ch)
    -- v4 的 bump 同时写 pending（kc_count.txt）和累计（kc_total.txt）
    pending[#pending + 1] = ch
    unflushed[#unflushed + 1] = ch
    unflushed_bytes = unflushed_bytes + 1
end

local function ensure_total_baseline()
    if total_baseline then return end
    total_baseline = ""
    if not total_file then return end
    pcall(function()
        local f = io.open(total_file, "rb")
        if f then
            total_baseline = f:read("*a") or ""
            f:close()
        end
    end)
end

-- 累计落盘：把 unflushed 的字节追加到 kc_total.txt。
-- v4 是每键一次写；v5 改为 take()（上屏）时机触发，且受时间/字节阈值控制。
local function total_flush(force)
    ensure_total_baseline()
    if unflushed_bytes == 0 then return end
    local now = os.time()
    if not force and unflushed_bytes < RESTORE_BYTES and
        now - last_flush_time < RESTORE_SECONDS then
        return
    end
    local batch = {}
    for i = 1, #unflushed do batch[i] = unflushed[i] end
    local text = table.concat(batch)
    unflushed = {}
    unflushed_bytes = 0
    last_flush_time = now
    total_baseline = total_baseline .. text
    if not total_file then return end
    pcall(function()
        local f = io.open(total_file, "a")
        if not f then return end
        f:write(text)
        f:close()
    end)
end

-- =========================================================================
-- 以下判定逻辑与 v4 保持一致（只在「记什么」上变化：内存 vs 每键写文件）
-- =========================================================================

-- 退格：把 pending 里最后一个未消费码 "1" 改为 "3"（被删码），并追加 "2"
-- （v4 是读文件改写文件；v5 直接在内存缓冲上做，结果完全一致）
local function backspace_track()
    for i = #pending, 1, -1 do
        if pending[i] == "1" then
            pending[i] = "3"
            -- 累计流同样只保留追加语义：退格额外记一个 "2"（与 v4 追加一致；
            -- v4 对累计文件不改写历史，也不改 pending 段的累计副本）
            pending_track("2")
            return
        end
    end
    -- 空删（无未消费码）：不计数（与 v4 一致，v4 直接不写任何文件）
end

-- 退格键判定（BackSpace 0xff08 / ASCII BS 0x08 / Delete 0xffff）
-- 屏蔽修饰位：Shift+退格（keycode 高位带 0x20000000）也识别为退格
local function is_backspace(ev)
    local kc = ev and ev.keycode or 0
    kc = kc % 0x1000000  -- 去掉 Shift/Ctrl/Alt 修饰位
    return kc == 0xff08 or kc == 0x08 or kc == 0xffff
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
    pending_clear()
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

-- processor 入口：每次按键追加计数（纯内存，零文件 I/O）
-- "1"=未消费码 "2"=退格键 "3"=被删码（原"1"被退格消费）"4"=选字/提交键
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
    -- [0813] 最近按键序列记录（诊断用，默认关闭，身份与 v4 相同）
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
        backspace_track()
        return K_NOOP
    end
    -- 选字/提交键（空格、数字、Enter、Tab、方案绑定的选字键如分号）：记 "4"
    if raw == 0x20 or (raw >= 0x30 and raw <= 0x39)
        or raw == 0xff0d or raw == 0xff09
        or SELECT_KEYS[raw] then
        pending_track("4")
    else
        pending_track("1")
    end
    return K_NOOP
end

-- input_statistics 每次上屏调用：取走待取击键数并清零。
-- v5：读纯内存 pending；同时是累计值的落盘点（受阈值控制，通常数秒一次）。
-- 返回 (总键数, 退格数, 最后键类型)
-- 计数类型："1"=编码键 "2"=退格键 "3"=被删码 "4"=选字/提交键（空格/数字/Enter）
function M.take()
    local n, bs, last_type = 0, 0, nil
    n = #pending
    for i = 1, #pending do
        if pending[i] == "2" then bs = bs + 1 end  -- "2"=退格键
    end
    if n > 0 then last_type = pending[n] end
    pending_clear()
    total_flush(false)   -- 未落盘累计达标则此刻追加一次；不达标留在内存
    return n, bs, last_type
end

-- 次选顶屏：把最后一个编码键写回（它属于下一个字，不算本次上屏）
-- v4 只写 pending（kc_count.txt），不写累计；这里保持一致
function M.restore_last()
    pending[#pending + 1] = "1"
end

-- 读 pending 的字节数（v4 里等于 count_file 的字节数；v5 pending 在内存）

-- 累计击键数（只增不清）：面板显示，打字后变大 = 计数器在工作
-- v5：先落盘（保证外部直接读 kc_total.txt 的脚本也能拿到完整数据），
-- 再返回 文件基线 + 增量。
function M.count()
    ensure_total_baseline()
    if unflushed_bytes > 0 then
        total_flush(true)   -- 立刻把增量写盘，凑整外部读取
    end
    return total_baseline and #total_baseline or 0
end

-- 最近一次按键的 keycode（十六进制字符串），面板"最近键"显示用
-- （v4 的 last_file 诊断开关默认关闭，保持关闭）
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
    pending_clear()
end

-- 挂载检测：曾计数过 = 计数器在工作
function M.status()
    ensure_total_baseline()
    local total = (total_baseline and #total_baseline or 0) + #pending
    return total > 0 and 1 or 0
end

return M
