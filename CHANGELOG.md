# 更新日志

本文件记录「芝士虎整」方案包的主要更新。虎整句方案版本见 `tiger_sentence.schema.yaml` 中 `schema.version`（当前 `1.6.20261030.1`，基于上游 `1.6.20261030.1` / `e86ceeb` 发布）。

## v0.3.2（2026-10-31，未打标签）

修复辅助开关「只在当前输入会话有效、换应用或重启就回默认」的问题。

### 根因

- librime 每个输入会话都新建一个 Engine；引擎构造时 `InitializeOptions()` 会把 `switches` 中带 `reset`
  的开关强制写回默认值。`reset` 的语义是「每会话复位」，不是「首次默认」。
- `key_binder` 的 `toggle:` 只改内存选项，从不写 `user.yaml`；只有方案菜单里的开关会按
  `switcher/save_options` 落盘。因此热键切换的开关无法靠 librime 自己记住。
- 「提前上屏」之所以正常，是因为方案 Lua 把它存进 `tiger_sentence.options.yaml` 并在每个新会话重放。

### 变更

- **虎整句**：`pinyin`、`chaifen`、`emoji_cn`、`charset_comment_filter`、`udpf_switch`、`yin`、
  `yin_flypy…sogou` 打法组、`s2s/s2t/s2hk/s2tw` 去掉 `reset`，改由 `lua/tiger_sentence.lua` 的
  `M.options` 持久化（radio 档位按选中 option 名存 `tiger_sentence.options.yaml`，跨会话合并）。
- **虎单 / 虎词**：新增 `lua/option_persist.lua`，同样的开关存到 `tiger.options.yaml` /
  `tigress.options.yaml`；字集开关 `extended_char` 一并记忆。注册为 `lua_processor@*option_persist`。
- **音码开关真正接线**：`Ctrl+Q` 的 `yin` 原本没有任何消费者；现在 `lua/yin_pick.lua` 读取它，
  关闭后保留 `yin_add_user` 标签不做转换，单引号反查不再出候选。默认仍为开。
- `ascii_mode`、`ascii_punct`、`full_shape` 保留 `reset`（有意每会话复位）。
- 测试：`tools/test_tiger_sentence_incremental.lua` 新增「上述开关不得带 reset / 三个方案必须接线
  持久化模块 / yin_pick 必须读取 yin」的结构断言。

### 验证

- 契约测试 112 checks 通过；`tools/run_regressions.py --lua lua` 全绿。
- 用本机 librime 探针（隔离用户目录）验证三种路径：同会话内切换、新建会话、进程重启后，
  虎整句的拼音/拆字/音码/简繁与虎单、虎词的拆字/字集均保持所选状态。

## v0.3.1（2026-10-31）

对齐上游 1.6.20261030.1 的实现细节，并清理死代码与过期测试。

- **ascii 处理器与上游一致**（`tiger_sentence.schema.yaml` / `rime.lua`）：processors 改回 `lua_processor@tiger_sentence_ascii`。在「提前上屏至编码」的 buffered 状态下按 Shift 切西文时，提交的是显示的候选，而不是内部 `~` 传输标记。
- **恢复上游全部导出**：`apply_auto_select_min_code_length`、`apply_source_ordering_for_test`、`dedup_limit_for_test`、`lexicon_lengths`、`prefix_extends`（v0.3.0 的清理曾误把它们当作死代码删除）。
- **清理**：移除设备端性能打点 `perf_diag`（`tiger_sentence/perf_log` 开关一并移除）、`rime.lua` 中未使用的 `tiger_kf_processor`、过期的 `安装与更新说明.txt`。
- **测试对齐上游**：learning（码长门槛、结果级 `learning_affected`、移除已废弃的 fusion/exact-correction 覆盖）、lexical prior（单候选跳过重排）、backspace（显式选择「回删编码」）、allocation（移除 fusion 用例）；`tools/run_regressions.py` 恢复全绿。
- **覆盖审计**：switches / processors / segmentors / translators / filters / key_binder / 配置键 / `M.*` 导出全部与上游对齐，零缺失。

## v0.3.0（2026-10-31）

虎整句引擎升级到上游 `1.6.20261030.1`（源码 `e86ceeb`），模型与上一版逐字节相同（SHA-256 `756f6c92…ab8681`）。

### 新增（按上游标准）

- **字集切换**：常用字集 / 全字集，默认**常用**，`Ctrl+J` 或方案菜单切换并长期保存。清单为 `tiger_sentence.common_characters.txt`（空清单 = 空字集），来源见 `docs/COMMON_CHARACTERS_SOURCE.json`。
- **三档回删**：回删编码 / 回删整字（默认）/ 先编码后整字，`Backspace` 按选中单位删除，跨会话保存；新增 `lua/tiger_sentence_backspace.lua`。
- **Windows 自学习修复**：中文名学习文件在 C locale 下报 Illegal byte sequence、导致「上屏但没有学习」；现在只在打开文件期间临时启用 UTF-8 locale（`lua/tiger_sentence_learning_text.lua`）。
- 白名单新增 7 字：倍 课 洪 供 察 峰 症。
- 方案版本 `1.6.20261030.1`。

### 行为变化

- **Tab 首批**：上游 `first_choice_selection=false`，首次 Tab 直接选第二项；循环回首选不锁定、不强化。
- **默认字集为「常用」**：生僻字需 `Ctrl+J` 切到全字集才会出现。
- **默认回删单位为「整字」**：退格删掉当前候选末字的完整编码，不再是删一码。
- **虎整句的拆字快捷键改为 `Ctrl+Shift+J`**：`Ctrl+J` 已被上游字集切换占用，且字集处理器排在 `key_binder` 之前。虎单/虎词仍是 `Ctrl+J`。

### 保留（芝士虎整自有集成）

- 造词桥接（自造词参与组句与调频）、✨ 纠错注释（`tiger_sentence/correction_mark`）、`perf_log` 诊断、标准 `ascii_composer` 管线、快符、拼音反查、输入统计、简繁四档、emoji/Unicode/拆字、Shift 大写直出、虎单/虎词 `;` `'` 顶字。
- 合并后主 chunk 局部变量触及 Lua 200 上限，`zaoci_bridge` 与纠错注释状态改为全局表（行为不变）。

### 验证

- 全部 Lua 语法通过；契约测试 112 项通过（新增字集/回删接线断言）。

## v0.2.9（2026-10-23）

清理中英混输下线后遗留的死代码与随包资源，输入行为不变（不含模型与词库拆分，发布包体积的大头不受影响）。

- **删除混输实现**（`lua/tiger_sentence.lua`，净减 610 行）：括号候选菜单、`decode_inline_english`、英文联想与释义加载、`ascii_component` ASCII 包装器、Tab 续接、预热函数以及各处 `[` 守卫分支全部移除；标准 `ascii_composer` 与标点直接上屏的行为保持 v0.2.8.2 现状。
- **删除 en_dict 模块**（`lua/db.lua`，净减 127 行）：该模块在首次部署时会读取 `dicts/en.dict.yaml` 并构建 `lua/en_dict.userdb`，但 `english_word` 选项在所有随附方案中均未定义，属无效开销。
- **移除两张仅混输/英文候选使用的词表**：`lua/data/english_chinese.txt` 与 `dicts/en.dict.yaml`（压缩后约 0.85MB）。
- **测试更新**：契约测试改为断言“管线不接线、混输接口不再导出、en_dict 不再存在”，防止未来无声回退。
- **新增 Shift 大写直出**（`lua/shift_upper.lua`，三个虎码方案均已接入）：中文态且没有编码时，Shift + 字母直接上屏大写字母，不再进入虎码编码、不出中文候选。兼容前端发 `Shift+a`、直接发大写 `A`、以及只发一次裸 `Shift_L` 再由小写字母跟随这三种情况。原因：librime 的 speller 只看 keycode、忽略 Shift 修饰，`Shift+a` 原本会被当成虎码编码 `a`。西文态与正在输入编码时不做接管。
- **虎单/虎词新增 `;` / `'` 顶字**（`lua/tiger_symbol_select.lua`，`tiger` 与 `tigress` 方案均已接入，排在 `key_binder` 之前）：候选不足时，`;`（无次选）和 `'`（不足三选）不再空按，而是先上屏首选、再输出标点。例：`rjk` 只有唯一候选时，`rjk;` → `符；`；`'` 顶字后输出 `’`。候选够数时仍交给 `key_binder` 正常选重。只接管 `^[a-z]+$` 的纯虎码编码，反查、造词、统计指令、计算器不受影响。注：参考实现（`symbol_proc.lua`，作者 晴）顶字后把符号放行给 punctuator；本方案 `;` 在 `speller.alphabet`、`'` 是 delimiter，放行会被 speller 吞成新编码，因此改为直接补出标点。
- **纠错注释符号改为 ✨**（`lua/tiger_sentence.lua`）：虎整句纠错候选的注释从硬编码的 `🐞` 换成 `✨`，并支持方案配置覆盖——在 `tiger_sentence.custom.yaml` 写 `"tiger_sentence/correction_mark": "✓"` 即可，读取一次后缓存，重新部署或重启前端生效。注：`docs/虎整句D89-r3-安装与版本核对.txt` 是上游原包记录，里面仍写 🐞，属于上游行为描述，未改动。
- **清理死引用与补文档**：`rime.lua` 移除已删除的 `tiger_sentence_ascii` 组件导出；README 选项表补充 `tiger_sentence/correction_mark`；`芝士虎整说明.md` 补 ✨ 与配置说明；上游安装记录与历史对比文档各加一行注记，说明 🐞/混输属于上游或历史状态。

## v0.2.8.3（2026-10-11）

修复 v0.2.8.2 遗留的无谓开销与文档问题，候选行为不变。

- **停用英文表 init 预热**（`lua/tiger_sentence.lua`）：中英混输已下线，但方案初始化仍无条件解析两张英文表（71,536 + 71,269 行；本机实测 ~158ms、约 6MB 内存，手机按前次测量为 1~2 秒级）。现移除该调用，方案加载不再为已移除的功能付费；预热函数仍留在模块内，将来重新启用混输时可在 init 接回。
- **更正 v0.2.8.2 文案**：旧条目误写「四个方括号类候选来自 punctuator，保持不变」。实际为半角档 `[` / `]` 直接原样上屏，四候选菜单已在 v0.2.8.2 移除。
- **补充接线断言**（`tools/test_rime_contract.lua`）：断言 schema 不再注册 `lua_processor@tiger_sentence_ascii` 与 `inline_english`，处理器列表包含标准 `ascii_composer`，且半角方括号为直接上屏，防止未来改动无声回退。
- 方案版本 `1.6.20261010.3`（仅版本标识变化，配置行为与 v0.2.8.2 相同）。

## v0.2.8.2（2026-10-11）

**移除中英混输**。设备端排查确认：只要用过一次中英混输，之后普通中文输入就持续变卡（切方案也不恢复）。为恢复打字手感，本版本把该功能整体摘除，其余功能不变。

- `tiger_sentence.schema.yaml`：
  - processors 的 `lua_processor@tiger_sentence_ascii` 换回标准 `ascii_composer`（Shift 切英文的按键规则仍在：Caps 启动切换、Shift_L/R 上屏编码并进西文）；
  - recognizer 不再注册 `inline_english` 模式，`[`/`]` 恢复原样上屏（半角档直接输出 `[` / `]`，此前的方括号四候选菜单移除）；
  - schema 版本 `1.6.20261010.2`。
- 保留诊断开关 `tiger_sentence/perf_log`（默认关），以及 `memory_profile` / `max_lookahead` 低配档位选项。

## v0.2.8.1（2026-10-11）

统计与滤镜性能修复（Android/Windows 打字卡顿治理）。详细说明见 [`docs/更新说明-20261011-统计与滤镜性能修复.md`](docs/更新说明-20261011-统计与滤镜性能修复.md)。

- **击键计数器 v5**（`lua/key_counter.lua`）：pending 计数改纯内存累计，取消每键 2 次同步写盘（Windows/Android 每键卡顿主因）；累计文件改按上屏批 + 时间/字节阈值落盘；按键分类与对外 API 语义不变。
- **统计保存节流**（`lua/input_statistics.lua`）：每次上屏的全量序列化重写改为 ≥30s 节流，用户指令仍即时写，正常退出补写不丢数据。
- **简繁滤镜**（`lua/wanxiang/super_replacer.lua`）：`max_lookahead` 可配置（默认 16，低配可设 8）；`fmm_cache` 加触顶上限，消除会话内无上限累积导致的「越打越卡」。
- **重码组句**（`lua/db.lua`）：组合搜索加 `MAX_DFS_NODES=2000` 硬上限，长句最坏耗时可控。
- **中英混输首键冻结**（第 5 项，`lua/tiger_sentence.lua`）：英文词典索引与释义表改为方案 init 时预热，消除手机每次会话第一次进英文段的 1~2s 整帧冻结。
- 虎整句引擎解码性能经逐键基准确认**无回归**（本次上游升级后反而更快）；以上改动均不改变候选结果与统计读数语义。

## v0.2.8（2026-10-10）

虎整句核心更新到上游 `1.6.20261010.1`（`9ed168f`），并以三方合并方式保留芝士虎整的全部辅助功能。

- 新增 `auto_select_min_code_length`，默认 3；旧的单字重码开关改为该数值设置。
- 人工选择的正码片段可以跨前缀复用；旧 `fusion-v1|` 和 `exact-correction-v1|` 记录不再参与有效学习。
- Direct 与组句候选改用普通学习分和来源顺序竞争，模型、码表、词先验未变化。
- 中英混输、英文释义、双空格退出、Tab 续接、自造词、拼音反查、快符、简繁、拆字、Emoji、Unicode、计算器、时间日期、输入统计和击键计数均保留。
- 源码 A/B 对照：关闭和开启五阶模型各 15,128 条快照完全一致。
- 鼠须管重新部署成功：11 个方案成功、0 个失败，运行日志 0 ERROR / 0 WARNING。
- 详细说明见 [`docs/更新说明-20261010-虎整句上游更新.md`](docs/更新说明-20261010-虎整句上游更新.md)。

## v0.2.7（2026-10-09）

中英混输的英文段支持连续按两下空格退出，并重写根目录 README。详细说明见 [`docs/更新说明-20261009-双空格退出英文段.md`](docs/更新说明-20261009-双空格退出英文段.md)。

- **英文段双空格退出**：在虎整句的英文段（`[` … `]`）里，第一次空格仍写入英文原文；当输入串末尾已经是空格时，再按一次空格会等价于按 `]`，闭合英文段并回到中文输入。适合手机端不用切到符号页寻找 `]`。
- **边界保持不变**：英文段闭合后，空格仍用于上屏候选；中文编码下的空格行为不变；空格加字母后再按空格不会误退出；按过 Tab 时仍优先完成词典候选替换。
- **代价**：英文段内不能再直接用空格键输入两个连续空格，第二下空格会被解释为退出英文段。
- **README 重写**：补充安装、升级、日常输入、虎整句选项、中英混输、自造词、拼音反查、简繁四档、辅助功能、统计、用户数据、手机精简版、故障排查和授权说明。
- 验证：双空格专项 4 个用例、原空格回归和 Tab 补全 5 个用例全部通过；`luac -p` 通过；`tools/test_sentence_learning.lua` 当前回归 23,084 项通过；鼠须管日志 0 ERROR / 0 WARNING。

## v0.2.6（2026-10-09）

两处改进：中英混输的英文段支持「Tab 选重后接着打字」；简繁整句转换的向前看窗口由 6 字提到 16 字。详细说明见 [`docs/更新说明-20261009-混输Tab与简繁窗口.md`](docs/更新说明-20261009-混输Tab与简繁窗口.md)。

- **中英混输**：在英文段（`[` … `]`）里用 Tab 选中词典联想后，按字母或空格会先把正在输入的那个英文词替换成高亮候选里的词，再接上本次按键。例：`[hell` → Tab 选中 `hello` → 按 `w` 得 `[hellow`，按空格得 `[hello `。没有按过 Tab 时行为不变；Shift+Tab 退回「原样输入」也不替换。
- **简繁转换**：`lua/wanxiang/super_replacer.lua` 的 `MAX_LOOKAHEAD` 由 6 改为 16。词表里有 **883 条长度 >6 字**的条目（最长 16 字，多为俗语/长句），窗口太小会让这些消歧条目永远匹配不到、只能逐字转换，从而把「不干不净」「人如风后入江云」「后天下之乐而乐」「全彩干式印表机」等转错。实测：883 条长词条中 **46 条结果修正**；日常常用词 5000 条与诗词语料 3000 条**均 0 变化**（无回归）。
- 实现说明：`lua/tiger_sentence.lua` 的局部变量已达 Lua 的 200 上限，本次新增的辅助函数挂在 `correction` 表上，避免超限。

## v0.2.5（2026-10-09）

简繁词表更新：与 OpenCC 官方表取并集，并补齐港/臺词组变体表。详细说明见 [`docs/更新说明-20261009-简繁词表更新.md`](docs/更新说明-20261009-简繁词表更新.md)。

- `lua/data/STCharacters.txt` / `STPhrases.txt` 取「万象随包 ∪ OpenCC 官方」并集（冲突以 OpenCC 为准）：单字表 3,979 → **4,012**，词组表 49,098 → **49,938**；修正 `实时→即時` 等错值，补上 `征西`、`复次`、`云溪`、`出戏`、`冲压`、`三复` 等消歧/新条目。
- 新增 `lua/data/HKVariantsPhrases.txt`（272 条）与 `TWVariantsPhrases.txt`（12 条），接进 `tiger` / `tigress` / `tiger_sentence` 的 s2hk / s2tw 规则链。
- 新增 `lua/data/STPhrases_GeneratedFromRegionalPhrases.txt`（7 条）：港/臺专有名词（`东涌线`、`无线新闻台`、`林杰梁` 等）的输入侧预置，避免被简→繁步骤抢先改写导致地区写法失效。
- 实测：与 OpenCC 官方表在同一贪心算法下，3000 条诗词语料的转换差异由 9 条降为 **0 条**；通繁档位不受地区专名影响。
- 未采用：CJK 兼容区字形规范化——我们三张虎码码表里共有 1,014 种兼容区字符，其中 1,002 种的标准形也在同一张表里，启用后会变成重复并被 `uniquifier` 去重，候选减少；收益小、副作用独特。

## v0.2.4（2026-10-09）

虎整句引擎升级到上游 `20261009-4eaf42e`（schema 版本 `1.6.20261009`）。详细说明见 [`docs/更新说明-20261009-虎整句引擎升级.md`](docs/更新说明-20261009-虎整句引擎升级.md)。

- **打分调整**：取消单字主码按码长累计的奖励（`canonical_code_reward` 2.0 → 0）；新增 `whole_single_reward_eligible`——整个输入一次匹配一个单字时保留 +5 奖励，但只有前 N 高频且不在白名单的字才要求用最优码，范围外及白名单单字允许使用码表已有的非最优码。
- **学习记录改存文本文件**：由 LevelDB（`tiger_sentence_learning_<hash>.userdb`）改为 UTF-8 文本 `自学习-tiger_sentence.txt`，新增模块 `lua/tiger_sentence_learning_text.lua`；LevelDB 仅用于跨进程锁，学习模式串改为中文键。**旧 LevelDB 学习记录不迁移**（上游既有规则）。
- `lua/tiger_sentence_learning.lua` 新增 `plan_levels`、`confidence_score`、`projected_score`、`runtime_index`；`reinforce_existing` 增加 `supplemental` 参数。
- 中英混输、自造词桥接、拼音反查、快符、简繁、输入统计等整合功能全部保留（三方合并为完美并集：整合的 690 行一行不差，无冲突）。
- 并入上游新增的 `docs/`、`tools/`、`validation/` 资料。

## v0.2.3（2026-10-08）

虎整句中英混输的两处改进。详细说明见 [`docs/更新说明-20261008-中英混输改进.md`](docs/更新说明-20261008-中英混输改进.md)。

- 虎整句中英混输的英文词典联想候选，注释由固定的「英文词典」改为**该单词的中文释义**：新增随包词表 `lua/data/english_chinese.txt`（71,269 条，取自万象），`lua/tiger_sentence.lua` 惰性加载并按单词小写查表；词库里查不到的词仍显示「英文词典」。例：`[hell` → `hello 你好`、`hell 地狱`、`help 帮助`。
- 虎整句中英混输的空格行为调整：按 `[` 进入英文后，空格改为**把空格写进英文原文**（可输入 `[hello world]`），不再上屏候选；只有按 `]` 结束英文段之后，空格才上屏。纯中文编码下的空格行为不变。

## v0.2.2（2026-10-08）

- 修复 Android 前端（元书/同文等）上字符集过滤报错的问题：`lua/wanxiang/charset_filter.lua` 加载字集反查库 `lua/data/charset.reverse.bin` 时统一改用相对路径。旧版 librime 用字符串拼接用户目录，传入绝对路径会被二次拼接，导致 `ReverseDb` 打开失败；相对路径在新旧 librime 上都正确解析。Windows 小狼毫行为不变，macOS/Linux 上的字符集过滤行为也不变，拼音反查（`'` 触发的那套）不受影响。

## v0.2.1（2026-10-08）

虎整句引擎升级到上游 `20261007-r3-d46fab4`，并保留全部整合功能。详细说明见 [`docs/更新说明-20261008-虎整句r3引擎升级.md`](docs/更新说明-20261008-虎整句r3引擎升级.md)。

- **引擎**：`lua/tiger_sentence.lua` 以上游新版为底回填整合（33 处、+649/−19 行）；`tiger_sentence_correction.lua`、`tiger_sentence_learning.lua` 与上游逐字节一致。新增「正码可学习超过纠错候选」的最终菜单偏好（`exact-correction-v1`），发生此类重排时不再沿用旧首选的自动上屏证据；同时恢复提交去重并收窄学习早退条件。
- **整合功能保留**：中英混输、自造词桥接、拼音反查、快符、拆字、emoji、Unicode 提示与编码显示、简繁四档、计算器、时间日期、输入统计、击键计数、符号菜单与相关快捷键全部照旧。
- **对齐上游**：方案名/版本改为 `虎整句` / `1.5`；Tab 处理改为上游方式（`key_binder` 增加 Tab/Shift+Tab 绑定，并把快符与整句处理器调整到 `key_binder` 之前）。
- **资料**：并入上游随包技术文档、测试与校验资料（`RELEASE.json`、`SOURCE_BASELINE.md`、`sync/`、`tools/`、`validation/`、`docs/`）；新增 [`docs/整合版与上游原版深度对比.md`](docs/整合版与上游原版深度对比.md)。
- 新增根目录 [`LICENSE`](LICENSE)（GPL-3.0），并在 README 增加「授权」一节，说明芝士虎整自身部分与随包第三方组件的授权归属。

## v0.2.0（2026-10-07）

中英混输与输入统计。对应提交 `eff5a74`、`09f731e`。

### 虎整句中英混输

- 在虎整句（`tiger_sentence`）中，用 `[` 开始英文片段、用 `]` 结束；英文按原样保留，可与前后的中文留在同一段组合输入里一起选词上屏。
- 空闲时按 `[` 或 `]` 显示方括号键上的四个符号候选（左键 `【`、`{`、`[`、`「`；右键 `】`、`}`、`]`、`」`），可用空格或 Tab 选取；该候选表由方案 `punctuator.half_shape` 提供。
- 正在输入中文编码时按 `[` 进入英文，再按 `]` 返回虎码整句；空闲时按 `[` 后直接输入字母同样进入英文模式。
- 英文片段未闭合且已输入两个及以上英文字母时，根据随包 `dicts/en.dict.yaml` 提供词典联想，同时保留原样输入候选。
- 按 `[` 后、输入英文第一个字母前显示 `[西文]`；按 `]` 后、开始输入中文前显示 `[中文]`。开始输入后提示自动隐藏。
- 修复中文前缀已经自动上屏后，继续输入中英混合内容时候选消失的问题；修复中英混输的自动上屏行为。
- 识别器新增 `inline_english` 规则，用于方括号待选与英文片段。

### 输入统计

- 重整日、周、月、年统计报告，提供短报告和详细报告，展示速度、准确性、词长与码长分布等信息。
- 新增按累计输入字数计算的 20 级称号与七境界进度，可用 `//6` 或 `/scj` 查看生涯段位。
- 统计报告统一显示前端英文代号，并在前端提供版本信息时一并显示；补充 Android 前端识别。
- 调整报告排版、进度条样式与名言折行显示；`//60` 为进度条皮肤统计。

### 文档

- `README.md` 增补中英混输说明与输入输出示例。
- `芝士虎整说明.md` 更新输入统计命令与虎整句说明。
- 新增 `docs/更新说明-中英混输与统计.md`，作为本次更新的详细说明。

## 2026-10-04 项目更名与初始发布

- `3ec1183` 项目更名为「芝士虎整」。
- `5af183b` 初始提交：虎单、虎词、虎整句方案及辅助工具、词典与模型资料。
- 标签 `v0.1.0`。
