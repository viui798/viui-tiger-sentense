-- 拼音反查：切换打法（同一时间只启用一种）
--
--   /flypy  → 小鹤双拼（默认）
--   /pinyin → 全拼
--   /zrm    → 自然码
--   /mspy   → 微软双拼
--   /sogou  → 搜狗双拼
--
-- 9.25 之前：/flypy、/pinyin 会改写 wanxiang_pro.schema.yaml 的 speller/algebra，
--            必须「重新部署」才会重建 prism 生效。
-- 9.25 起：  五份 prism 在部署时一次生成，切换只改 yin_scheme 这组 radio 开关，
--            由 lua/yin_pick.lua 在运行时把反查分段的 tag 换成选中打法的 tag，
--            所以**立即生效、不需要重新部署**，而且同一时间只有一种反查在线。
--
-- 两个坑（都已实测踩过）：
--   1) 本文件必须注册成 lua_processor，不能是 lua_translator：
--      在翻译器里调用 ctx:set_option 会触发 OnOptionUpdate
--      → RefreshNonConfirmedComposition → 重入 Compose，破坏正在遍历的分段，
--      librime 直接崩溃（实测 SIGSEGV）。处理器在 ProcessKey 阶段运行，
--      先 clear 再改开关，不会重入。
--   2) 处理器必须排在 speller 之前（这里放 engine/processors 第一位）：
--      排在 speller 后面时，最后一个字母已经被 speller kAccepted 吃掉，
--      处理器根本收不到，命令永远不触发。因为排在前面，输入里还没有当前这个键，
--      所以要用「已有输入 + 当前按键」预判，而不是直接看 ctx.input。
--
-- 切换状态存在开关里，重新部署/重启后回到默认值（小鹤双拼）。
-- 也可以按 Ctrl+`（或 F4）在菜单里选「小鹤/全拼/自然码/微软/搜狗」。

local OPTIONS = { "yin_flypy", "yin_qp", "yin_zrm", "yin_mspy", "yin_sogou" }

local CMD = {
  ["/flypy"]  = { option = "yin_flypy", label = "小鹤双拼" },
  ["/pinyin"] = { option = "yin_qp",    label = "全拼" },
  ["/zrm"]    = { option = "yin_zrm",   label = "自然码" },
  ["/mspy"]   = { option = "yin_mspy",  label = "微软双拼" },
  ["/sogou"]  = { option = "yin_sogou", label = "搜狗双拼" },
}

local kAccepted, kNoop = 1, 2

local function processor(key, env)
  if key:release() or key:ctrl() or key:alt() or key:super() then
    return kNoop
  end
  local ctx = env.engine.context
  local input = ctx.input
  if input:sub(1, 1) ~= "/" then
    return kNoop
  end
  local ch = key.keycode
  if ch >= 0x20 and ch < 0x7f then
    input = input .. string.char(ch)
  end
  local cmd = CMD[input]
  if not cmd then
    return kNoop
  end
  ctx:clear()
  for _, name in ipairs(OPTIONS) do
    ctx:set_option(name, name == cmd.option)
  end
  return kAccepted
end

return processor
