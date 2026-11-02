-- Shift 切换中/英方案
--
-- 电脑上 Shift 原本是 Rime 的「西文直通」（ascii_mode），不出候选；本处理器把
-- 「裸按 Shift」改成在中文方案与 english 方案之间切换：
--   * Shift 按下 → 记住（pending），不消费，Shift+字母仍由 shift_upper 处理成大写；
--   * Shift 松开时若没有字母插入 → 切换方案；
--   * 英文方案里按 Shift → 切回上一个中文方案。
-- 正在输入编码时不切换（保留虎整句 buffered 的原有提交行为）。
--
-- 依赖 librime-lua 的 Engine:apply_schema(id)。若该 API 不存在则安静地什么都不做。

local M = {}

local kAccepted, kNoop = 1, 2
local pending = false
local return_schema = "tiger_sentence"

local CHINESE = {
    tiger = true,
    tigress = true,
    tiger_sentence = true,
}

local function is_shift(repr)
    -- 松开事件的 repr 形如 "Shift+Release+Shift_L"，用子串匹配。
    return repr == "Shift" or repr:find("Shift_L", 1, true) ~= nil or
        repr:find("Shift_R", 1, true) ~= nil
end

local function schema_id(env)
    local schema = env.engine.schema
    return schema and schema.schema_id or nil
end

local function switch_to(env, id)
    -- librime-lua 的 Engine:apply_schema 接收 Schema 对象（不是 schema_id 字符串）。
    if type(env.engine.apply_schema) ~= "function" or type(Schema) ~= "function" then
        return false
    end
    return pcall(function() env.engine:apply_schema(Schema(id)) end)
end

local function clear_shift_upper()
    local module = package.loaded["shift_upper"]
    if module then module.shift_pending = false end
end

function M.init(env)
    pending = false
end

function M.fini(env)
    pending = false
end

function M.processor(key, env)
    local repr = key:repr()

    if is_shift(repr) then
        if key:release() then
            if not pending then return kNoop end
            pending = false
            clear_shift_upper()
            -- 正在输入编码时保留原有行为（虎整句 buffered 提交、ascii 切换等）。
            if env.engine.context:is_composing() then return kNoop end
            local id = schema_id(env)
            if id == "english" then
                if switch_to(env, return_schema) then return kAccepted end
            elseif CHINESE[id] then
                return_schema = id
                if switch_to(env, "english") then return kAccepted end
            end
            return kNoop
        end
        if key:ctrl() or key:alt() or key:super() then return kNoop end
        pending = true
        return kNoop
    end

    -- 其他按键（含字母）都会取消「裸 Shift」状态。
    pending = false
    return kNoop
end

M.func = M.processor

return M
