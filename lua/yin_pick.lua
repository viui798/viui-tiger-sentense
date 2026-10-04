-- 拼音反查：运行时只启用一种打法
--
-- 背景：五份拼写索引（小鹤 / 全拼 / 自然码 / 微软 / 搜狗）在部署时都已生成，
--       但用户要求「同一时间只有一种反查」，用 /flypy /pinyin /zrm /mspy /sogou 切换。
--
-- 原理：recognizer 把反查输入（' 开头 或 ` 结尾）打成 tag "yin_add_user"，
--       matcher 据此建好分段。本分段器排在 matcher 之后、各 affix_segmentor 之前，
--       把该分段的 tag 换成当前选中打法的 tag，于是只有对应的那一个
--       affix_segmentor（切前缀）+ script_translator（查索引）会响应。
--       换 tag 是纯运行时操作，**不需要重新部署**。
--
-- 为什么小鹤的 tag 叫 yin_flypy 而不是 yin_add_user：
--       五份索引的配置块都写了 extra_tags: [ yin_add_user ]，
--       好让 lua/chaifen.lua、lua/db.lua 认出「这是反查」。
--       如果小鹤翻译器也用 tag yin_add_user，那它就会连全拼/自然码的编码段
--       一起响应（编码段带着 extra_tags 的 yin_add_user），
--       变成「五种同时在线」，比如切到全拼后 'nihc 仍会出「你好」。
--       所以小鹤单独用 yin_flypy，与 extra_tags 的 yin_add_user 错开。
--
-- 选中状态由 yin_scheme 这组 radio 开关（switches）保存，默认 0 = 小鹤双拼。
-- 若一个都没选中（例如开关被外部清掉），兜底走小鹤。

local MAP = {
  { option = "yin_flypy", tag = "yin_flypy" }, -- 小鹤双拼
  { option = "yin_qp",    tag = "yin_qp" },
  { option = "yin_zrm",   tag = "yin_zrm" },
  { option = "yin_mspy",  tag = "yin_mspy" },
  { option = "yin_sogou", tag = "yin_sogou" },
}

local M = {}

function M.init(env)
  env.ctx = env.engine.context
end

function M.func(segmentation, env)
  local seg = segmentation:back()
  -- 不是反查输入就交给后面的分段器
  if not seg or not seg:has_tag("yin_add_user") then
    return true
  end
  local tag = "yin_flypy"
  for _, item in ipairs(MAP) do
    if env.ctx:get_option(item.option) then
      tag = item.tag
      break
    end
  end
  if tag ~= "yin_add_user" then
    local tags = {}
    for name in pairs(seg.tags) do
      tags[name] = true
    end
    tags["yin_add_user"] = nil
    tags[tag] = true
    seg.tags = tags
  end
  return true
end

return M
