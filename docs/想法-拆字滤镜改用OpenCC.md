# 想法：拆字滤镜从 Lua 改为 OpenCC（用 tiger_lookup 生成字典）

状态：**已评估，建议暂缓实施**（2026-11-03 实测）。完整数据见
[评估-拆字滤镜改用OpenCC.md](评估-拆字滤镜改用OpenCC.md)：OpenCC 字典 1:1 可生成；
「只开拆字」时 A/B 等价（all/char 各 56 用例零差异），但**同时开拼音/emoji/字符集提示
或关掉拆字开关时不等价**（71 处注释差异）；本机每键耗时无差异，峰值内存反增 12–18 MiB，
冷启动慢约 100ms，长会话漂移与滤镜无关（「少 Lua/少 GC」无任何形态的收益）。
下方「对比结论」中「OpenCC 性能更好」的推测已被三组实测全部否定。

## 背景

当前虎单/虎词/虎整句的拆字提示由 `lua/chaifen.lua`（Lua 滤镜）实现：

- 数据：用 `ReverseLookup("tiger_lookup")`（`char_word/dictionary` 为 `wubici` 时用 `wubi_lookup`）
  查每个候选的拆字注释，带 `char_cache` 缓存。
- 显示：写进候选注释（`cand.comment`），支持 `enum/chaifen: char | all`（单字/全部）。
- 开关：`chaifen` option（虎单/虎词 `Ctrl+J`，虎整句 `Ctrl+Shift+J`），由 `option_persist` / `M.options` 持久化。

虎码秃版（`~/Downloads/虎码秃版 鼠须管 （Mac）2026.08.15.zip`）用的是 OpenCC 滤镜：

```yaml
chaifen:
  opencc_config: hu_cf.json
  option_name: chaifen
  show_in_comment: true
  comment_format:
    - "xform/&nbsp;/ /"
  tags: [abc, tiger, tigress, reverse_lookup]
  tips: all   # 单字模式可用 char
```

## 对比结论

- **准确性/与虎码一致**：当前 Lua（tiger_lookup 数据）更好。
- **性能/稳定性/少 Lua/少 GC**：秃版 OpenCC 更好（C++ 实现；当前插件每个 Lua 对象析构都会全量 GC）。
- 两者「单字/全部」能力等价（`enum/chaifen` vs `tips`）。

## 目标

把拆字数据从 `tiger_lookup` **导出成 OpenCC JSON**，改用 `simplifier@chaifen`，
达到「数据仍来自虎码 + 运行在 C++」：

1. 删除 `lua/chaifen.lua` 及 `lua_filter@*chaifen` 接线（三方案）。
2. 新增 `opencc/hu_cf.json`（或 `chaifen.json`），由脚本从 `tiger_lookup` 生成。
3. schema 增加 `chaifen:` 配置（`opencc_config`、`option_name: chaifen`、`show_in_comment: true`、
   `comment_format`、`tags`、`tips: all`），并保留 `chaifen` 开关与快捷键。
4. 保持 `enum/chaifen` 的 char/all 等价（OpenCC 用 `tips`，注意 `enum/chaifen` 可保留或迁移）。

## 实施步骤

1. **确认数据格式**
   - 找到 `tiger_lookup` 的词库来源（`tiger_dicts/` 或 build 产物），确认单字条目的拆字字符串格式。
   - 用 `ReverseLookup("tiger_lookup"):lookup(char)` 对若干字抽样，记录输出（字根、分隔符、编号等）。
   - 五笔模式（`char_word/dictionary: wubici` → `wubi_lookup`）是否需要支持？若需要，另生成一份。

2. **写导出脚本** `tools/export_chaifen_opencc.py`
   - 遍历 `tiger_lookup` 的所有**单字**条目，输出 OpenCC 文本/JSON 字典（字 → 拆字）。
   - 跳过多字词/空值；重复/多读音保留第一条或合并。
   - 输出到 `opencc/hu_cf.json`（OpenCC 标准格式，与秃版同结构）。
   - 脚本要可重复运行（固定排序、UTF-8、无随机）。

3. **改 schema**（`tiger.schema.yaml`、`tigress.schema.yaml`、`tiger_sentence.schema.yaml`）
   - 移除 `- lua_filter@*chaifen`。
   - 新增 `chaifen:` 配置块（参考秃版，`tags` 覆盖本方案实际 tag）。
   - 保留 `chaifen` switch、`Ctrl+J` / `Ctrl+Shift+J` 绑定、`enum/chaifen` 或改用 `tips`。
   - 注意 `filters` 顺序：秃版把 `core2022` 放最前、`simplifier@chaifen` 在简繁之后；
     本方案有 `super_replacer`/`db`/`charset_comment`，需要验证顺序对注释的影响。

4. **等价性验证**
   - 抽样：常用字、生僻字、U 区字、多字词、反查候选、造词候选；
     比较候选文本/注释在 char/all 两种模式下的输出。
   - 跑 `tools/snapshot_rime_pipeline.cpp`（如可用）逐键比对候选与注释。
   - 契约 132 checks、拼音 48 checks、完整回归 exit 0。

5. **性能验证**
   - 用 `tools/bench_tiger_sentence_lua.lua` 或 `perkey_probe` 对比：
     移除 Lua 滤镜前后的每键耗时、Lua 堆/GC 次数、启动内存。
   - 记录本机数据（不作为安卓结论）。

6. **清理与回滚**
   - 确认无问题后再删 `lua/chaifen.lua`、`rime.lua` 注册、`lua_filter@*chaifen`。
   - 回滚方式：`git revert` 或恢复 Lua 滤镜；数据文件保留不影响输入。

## 风险

- OpenCC JSON 体积/覆盖：生僻字缺失时回退显示原字，避免注释为空。
- 输出格式差异（空格、字根写法、编号）会改变用户看到的注释，需要人工抽样确认。
- 与简繁/emoji/字符集滤镜的先后顺序可能改变注释叠加结果。
- 虎整句的 `tags` 与虎单/虎词不同（含 `yin_*`/`zaoci` 等），要逐方案配置。
- 五笔模式（`wubi_lookup`）需要单独数据/配置，否则会失去该模式。

## 验收标准

- char/all 两种模式下，拆字注释与当前 Lua 版**逐字等价**（允许明确记录的风格差异）。
- 无新增 Lua 滤镜；`chaifen` 开关、快捷键、持久化行为不变。
- 契约/拼音/回归全绿；性能不劣于当前（最好更快）。

## 相关文件

- `lua/chaifen.lua`（现状）
- `tiger.schema.yaml` / `tigress.schema.yaml` / `tiger_sentence.schema.yaml` 的 `filters` 与 `chaifen` 配置
- `lua/option_persist.lua`、`tiger_sentence.lua` 的 `M.options`（`chaifen` 持久化）
- `tools/`（导出脚本放这里）
- 参考：秃版 `tiger.schema.yaml` 的 `chaifen:` 段与 `opencc/hu_cf.json`
