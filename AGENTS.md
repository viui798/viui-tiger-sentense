# AGENTS.md — 芝士虎整 项目接手说明

> 给任何接手本项目的 agent / 模型：先读完本文（约 5 分钟），再动手。
> 详细历史、决策记录与架构说明见 [`docs/项目日志.md`](docs/项目日志.md)。

## 1. 项目是什么

**芝士虎整**：面向 [Rime](https://rime.im) 的虎码输入方案整合包，公开仓库
<https://github.com/viui798/viui-tiger-sentense>（GPL-3.0）。

它在**上游虎整句**（lvyww/tiger-sentense-rime）的基础上，把虎单、虎词、虎整句和统一的拼音反查
以及一批辅助功能（造词、反查、简繁、快符、拆字、Emoji、Unicode、计算器、时间日期、输入统计）
整合到同一套 Rime 用户目录里。

- 当前版本：**v0.3.23**
- 上游许可与授权记录：[`docs/上游授权与来源.md`](docs/上游授权与来源.md)
- 虎整句上游：`1.6.20261030.1`（源码 `e86ceeb`）
- 语言模型：TCSKNM03 五阶 Q8，405,663,171 字节，SHA-256 `756f6c92…ab8681`
- 方案 ID：`tiger`（虎单）、`tigress`（虎词）、`tiger_sentence`（虎整句）；
  反查由三方案共用五阶模型引擎，旧 `wanxiang_pro` 独立方案自 v0.3.10 起移除

## 2. 铁律（违反会破坏项目）

1. **上游有的功能必须有。** 用户明确要求：虎整句基本功能与上游一致，不能出现「上游有我们没有」。
   升级上游后必须做覆盖审计（见 §6）。
2. **绝不整文件覆盖 `tiger_sentence.schema.yaml`。** 上游 schema 是 4.7KB 精简版；本仓库是
   15KB 整合版（多了反查/快符/统计/简繁/emoji 等）。只能按块合并。
3. **`lua/tiger_sentence.lua` 主 chunk 的局部变量已到 Lua 上限（200 个）。** 现用 199/200
   （v0.4.0 的 `data_file_override` 占 1 个）。新增功能不要加 `local`，用全局表
   （参考 `zaoci_bridge`、`correction_mark_state`）。合并上游新模块时很可能超限。
4. **模型走 Git LFS。** 不要用 `git archive` 打包（会得到指针文件）；用
   `tools/make_release_zip.py`，它从工作区读真实模型。
5. **改动必须过测试再提交：**
   ```bash
   # 契约测试
   LUA_PATH="./lua/?.lua;./lua/?/init.lua;;" lua tools/test_rime_contract.lua .
   # 完整回归（约 1-2 分钟）
   python3 tools/run_regressions.py --lua lua
   ```
6. **文档与 CHANGELOG 同步更新**（中文），并在提交信息里写清楚「为什么」。
7. **大文件不要重新格式化**（词库、`tiger_sentence.lua` 等），避免制造巨大 diff。

## 3. 快速命令

| 目的 | 命令 |
|---|---|
| 契约测试 | `LUA_PATH="./lua/?.lua;./lua/?/init.lua;;" lua tools/test_rime_contract.lua .` |
| 完整回归 | `python3 tools/run_regressions.py --lua lua` |
| 单个测试 | `LUA_PATH="./lua/?.lua;./lua/?/init.lua;;" lua tools/test_xxx.lua .` |
| 打包发行 | `python3 tools/make_release_zip.py vX.Y.Z /tmp/cheese-tiger-vX.Y.Z.zip` |
| 生成增量包 | `python3 tools/make_release_delta.py v0.3.22 v0.3.23 /tmp/cheese-tiger-v0.3.23-update.zip` |
| 桌面一键更新 | 见 [`viui798/rime-updater`](https://github.com/viui798/rime-updater)（独立仓库维护） |
| 部署到鼠须管 | 解压包 → `ditto <包目录> ~/Library/Rime` → 见下方 deployer |
| 重新部署 | `"/Library/Input Methods/Squirrel.app/Contents/MacOS/rime_deployer" --build ~/Library/Rime "/Library/Input Methods/Squirrel.app/Contents/SharedSupport"` |
| 重启前端 | `killall Squirrel; open -a "/Library/Input Methods/Squirrel.app"` |
| 发 Release | `gh release create vX.Y.Z --notes-file /tmp/notes.md --latest`，再 `gh release upload` |

- 鼠须管用户目录：`~/Library/Rime`
- 发行包不包含：`tools/`、`sync/`、`validation/`、`手机精简版/`、`RELEASE.json`、`SHA256SUMS.txt`、
  `SOURCE_BASELINE.md`、`RIME_CORRECTNESS.md`、`IOS_TEST_README.md`，以及旧版万象词库
  （`wanxiang_pro*`、`dicts/*.pro.dict.yaml`、`zuci/moegirl`、`zuci/ext`，见 `tools/make_release_zip.py`）
- 包内顶层目录名：`芝士虎整-vX.Y.Z/`

## 4. 仓库地图

| 路径 | 内容 |
|---|---|
| `tiger_sentence.schema.yaml` | **整合版**虎整句方案（约 19KB，核心） |
| `tiger.schema.yaml` / `tigress.schema.yaml` | 虎单 / 虎词 |
| `lua/` | 全部 Lua：虎整句引擎、学习、字集、回删、辅助功能 |
| `lua/tiger_sentence*.lua` | 上游引擎模块（`tiger_sentence.lua` 有本地集成） |
| `lua/shift_upper.lua` | Shift 大写直出（本地功能） |
| `lua/tiger_symbol_select.lua` | 虎单/虎词 `;` `'` 顶字（本地功能） |
| `lua/tiger_zaoci.lua` | 造词模块（本地功能，与引擎桥接） |
| `lua/tiger_sentence_pinyin.lua` | 拼音反查引擎（v0.3.3：主 chunk 第二实例 + 键位转换 + 分页码表索引，反查候选由五阶模型生成；v0.3.10 起虎单/虎词/虎整句共用） |
| `lua/tiger_mixed.lua` | 虎码 + 拼音混输（词块外挂解码、3 字母合成码、纯反查短路） |
| `lua/reverse_freq.lua` | 短输入反查调频（`reverse_freq.txt`、选非首选一次即置顶） |
| `models/pinyin.codes.*` | 拼音反查分页索引（**生成文件**，`tools/build_pinyin_codes_index.py` 重生成） |
| `lua/pinyin_keymaps.lua` | 五打法键位转换表（**生成文件**，勿手改；`tools/export_pinyin_tables.py` 重生成） |
| `models/` | 五阶模型（LFS）+ 词先验 |
| `pinyin.qp.codes.txt` | 拼音反查码表（**生成文件**，24.8 万条；`tools/export_reverse_codes.py` 重生成） |
| `dicts/`、`zuci/`、`tiger_dicts/` | 词库 |
| `docs/` | 上游技术文档 + 本地更新说明；`docs/项目日志.md` 是交接主文档；自定义与升级说明在 `芝士虎整说明.md` 的「用户数据与升级」一节 |
| `tools/` | 测试、打包、基准脚本（不进发行包） |
| `validation/`、`sync/` | 上游校验记录与同步补丁（不进发行包） |
| `README.md`、`芝士虎整说明.md` | 面向用户的中文文档 |
| `CHANGELOG.md` | 版本日志（发版必更） |

## 5. 关键不变量与坑

| 项 | 说明 |
|---|---|
| **ascii 处理器** | 方案里必须是 `lua_processor@tiger_sentence_ascii`（上游同款），`rime.lua` 要注册 `tiger_sentence_ascii = tiger_sentence.ascii_component`。它保证「提前上屏至编码」的 buffered 状态下按 Shift 切西文时提交显示候选，而不是内部 `~` 标记 |
| **`Ctrl+J`** | 上游 1.6.20261030.1 用它切字集（常用/全字集）。**虎整句的拆字已改到 `Ctrl+Shift+J`**；虎单/虎词仍是 `Ctrl+J` |
| **speller** | 本仓库 `alphabet` 比上游多 `/`（统计指令）、`delimiter` 多 `'`（反查）、`auto_select: true`（快符）——这是有意的扩展，不要改回上游值 |
| **默认行为（上游标准）** | 常用字集、回删整字、首次 Tab 选第二项、纠错默认关闭 |
| **纠错注释** | 默认 ✨，可用 `tiger_sentence/correction_mark` 覆盖（见 `lua/tiger_sentence.lua` 的 `correction_mark_state`） |
| **造词桥接** | `zaoci_bridge` 在 `tiger_sentence.lua` 里，负责自造词参与组句/调频；合并上游时**必须保留** |
| **主题/个人配置** | `squirrel.custom.yaml`、`docs/CORRECTION_*.md`、`docs/EARLY_EVIDENCE_GATE.md` 被 `.gitignore` 排除，不要提交 |
| **开关记忆** | 「要记住」的开关**不能写 `reset`**（librime 每个新会话都会按 reset 强制复位，且热键 toggle 不写 user.yaml）。虎整句存 `tiger_sentence.options.yaml`（`M.options`），虎单/虎词存 `tiger.options.yaml` / `tigress.options.yaml`（`lua/option_persist.lua`）。`ascii_mode` / `ascii_punct` / `full_shape` 保留 reset 属有意行为 |
| **快符** | 符号表在 `default.custom.yaml` 的 `kf_symbols`（26 个字母，三方案共用），`lua/tiger_kf.lua` 启动时用 `Schema(".default")` 逐个字母读取（`ConfigMap:keys()` 在当前 librime-lua 不可用）；`;;`/`;1`/`;2` 是 Lua 规则。`kf.dict.yaml`/`kf.schema.yaml`/`table_translator@kf` 已删除（2026-11-02 收敛），不要加回来 |
| **简拼整段匹配** | 码表第三列 `A`（索引 flags bit2）标记简拼；引擎只在「整段匹配」时允许简拼边。改码表、索引或 `eligible_candidates` 时不要破坏，否则 `fancha` 会拆成 fa+nc+ha 出现「发内存哈」这类拼接词 |
| **反查/造词前缀** | 反查是 `` ` `` 前缀、造词是 `'` 前缀；「拼音+`` ` ``」后缀式反查已移除（v0.3.3）。改 recognizer 时三个 schema 的 `zaoci` / `yin_add_user` 模式与 affix `prefix` 必须同步 |
| **拼音反查双实例** | `lua/tiger_sentence_pinyin.lua` dofile 同一主 chunk 得到第二实例：词库/beam/解码缓存与虎码主实例完全独立（`lexicon_state` 绑定单码表，不能共表）。改主 chunk 的 `read_data_file`/`rebuild_lexicon`/`M.translator` 时必须同时验证两条路径；负向控制锚点严禁改动 |
| **中文文件名** | 打包脚本已处理 UTF-8 标志位；手动 `zip` 会导致 Windows 乱码 |

## 6. 升级上游的正确姿势

1. 拿到上游**完整包**（例如 `虎整句Rime-1.6.20261030.1-完整包.zip`），解压到 `/tmp`。
2. 找到本地代码对应的**基线**上游版本（`RELEASE.json` 的 `source_commit` 对应包），用
   `git merge-file` 做三方合并：
   ```bash
   git merge-file -p --diff3 ours.lua base.lua theirs.lua > merged.lua
   ```
3. 解决冲突时记住：本地集成点 = **zaoci 桥接、用户词排序（`dict_marks`/`dict_first`/`user_version`）、
   ✨ 纠错注释、全局表（200 local 上限）**。
4. schema 只做**增量合并**：新增 switches / `tiger_sentence.*` 配置键，保留本仓库的
   engine（processors/segmentors/translators/filters）、speller、recognizer、key_binder。
5. 新增的上游 Lua 模块直接拷入 `lua/`；新增的数据文件（如 `tiger_sentence.common_characters.txt`）
   与 `docs/` 资料同步拷入。
6. **跑覆盖审计**：逐项比对上游 schema 的 switches / engine 各段 / key_binder / 配置键 /
   `M.*` 导出是否都在本仓库存在（脚本模板见 `docs/项目日志.md` §5）。
7. 更新 `RELEASE.json`、`CHANGELOG.md`、必要时 bump schema 版本；跑全部测试；打包、部署、发版。

## 7. 发布流程

1. 更新 `CHANGELOG.md`（新版本小节：变更 + 行为变化 + 验证）。
2. 提交（中文、说明原因）。
3. `git tag -a vX.Y.Z -m "芝士虎整 vX.Y.Z …"`，`git push origin main`，`git push origin vX.Y.Z`。
4. `python3 tools/make_release_zip.py vX.Y.Z /tmp/cheese-tiger-vX.Y.Z.zip`（检查输出的 SHA-256）。
   再生成增量包：`python3 tools/make_release_delta.py <上一个 tag> vX.Y.Z /tmp/cheese-tiger-vX.Y.Z-update.zip`
   （大模型有变更时 `DELTA.json` 会标 `full_required`，更新器会自动改用完整包）。
5. 部署到鼠须管并验证（见 §3），或至少校验编译产物：
   `grep -n "tiger_sentence_ascii" ~/Library/Rime/build/tiger_sentence.schema.yaml`。
6. `gh release create vX.Y.Z --title "…" --notes-file … --latest`，再
   `gh release upload vX.Y.Z <zip> <zip.sha256> <update.zip> <update.zip.sha256>`；
   核对 assets 状态为 `uploaded`。客户端更新器优先选 `*-update.zip`。
7. 把包复制到 `~/Desktop/输入法/芝士虎整/`（用户的发布目录）。

## 8. 当前状态（2026-11-04）

- `main` = tag `v0.3.23`（性能审计后优化：词先验 bloom、`super_replacer` 每菜单轮询、
  OpenCC `.ocd2`、`db.lua` 旧万象死代码清理；输入行为不变）
- 沿用 v0.3.21/0.3.22：Lua 翻译入口 7→1、原生五码顶屏、四码上屏开关、
  双拼简拼/音节数过滤、数字大写、全字集反查、精确统计、`;z` 整段重复、退格保护
- 拼音反查：虎单/虎词/虎整句共用五阶模型第二实例 + **分页码表索引**
  （`models/pinyin.codes.*`，稳定后每键约 8–14ms；首键约 20–30ms 换入模型页，常驻约 +20MB）；
  词库为 `dicts/pinyin_reverse.dict.yaml` 导出的 24.8 万条（全拼 + 多字词简拼，无辅助码）
- 短输入反查调频：≤8 字母的反查选过一次非首选词即置顶，记录在 `reverse_freq.txt`
  （`lua/reverse_freq.lua` + `lua_processor@*reverse_freq`；开关 `tiger_sentence/reverse_frequency`）
- 混输：`lua/tiger_mixed.lua`，支持 `;`/`'` 选重后接拼音块、句首单字母简码；纯反查段已短路
- 测试：契约 21 cases / 132 checks；`tools/test_pinyin_engine.lua` 48 checks；
  `tools/test_tiger_mixed.lua` 7 checks；`run_regressions.py --lua lua` 全绿
- 万象词库：仓库保留 `dicts/*.pro.dict.yaml` 与 `wanxiang_pro*` 便于回滚，但
  `tools/make_release_zip.py` 已排除，不进发行包
- 上游 `M.*` 导出：100% 覆盖；上游 schema 元素：100% 覆盖
- 多设备更新：增量包由 `tools/make_release_delta.py` 生成（Release 资产 `*-update.zip`）；
  客户端安装器在独立仓库 [`viui798/rime-updater`](https://github.com/viui798/rime-updater)
  （mac 三前端已实机验证，Windows 待实机验证，Android/iOS 尚未接入）

## 9. 已知事项

- 上游**不提供测试**。行为对不对，用「纯净上游模块」跑同一用例作为裁判
  （`TIGER_SENTENCE_MODULE=/path/to/upstream/lua/tiger_sentence.lua`）。
- 拼音反查（v0.4.0）：`auto_select_min_code_length=3`（虎码默认）在拼音表上有病态
  行为（P5 表近零短路、P4 表慢 45×），生产拼音实例固定 min=0，机理未查
  （docs/项目日志.md §10.4）。动 `eligible_candidates` 前先复现。
- 拼音反查首用不再全量建库（分页索引 + 模型按需映射），首键约 20–30ms、常驻约 +20MB；
  简拼只经词首字母码（引擎排除单键边）；反查不再写 zc 用户词典，改为
  `reverse_freq.txt` 的短输入选择记录（≤8 字母，选非首选一次即置顶）。
- 上游已移除 fusion-v1 / exact-correction-v1 硬排序；对应本地测试覆盖已删除，改为断言「旧记录被忽略」。
- `tools/test_lexical_prior.lua` 直接在仓库根跑会生成临时模型夹具
  `sentence-fivegram-mobile.bin`（已在 `.gitignore`）。
- 拼音反查首用不再全量建库（分页索引 + 模型按需映射），首键约 20–30ms、常驻约 +20MB；
  简拼只经词首字母码（引擎排除单键边）；反查不再写 zc 用户词典，改为
  `reverse_freq.txt` 的短输入选择记录（≤8 字母，选非首选一次即置顶）。
- **性能审计 2026-11-04**（[`docs/性能审计-20261104.md`](docs/性能审计-20261104.md)）：
  滤镜链实测在噪声带以下（非瓶颈）；最大瓶颈是本机 Squirrel 1.1.2 缺 librime-lua
  #431 GC 分摊修复（librime 1.17.0 与 Squirrel Nightly 已带，稳定版 1.1.2 尚未；
  升级运行时实测每键 mean -84%~94%，方案包零改动；见 rime/squirrel#1200）；
  词先验 bloom 微优化原型实测整句流 -77μs/键，待收编。
- 详细决策与历史见 [`docs/项目日志.md`](docs/项目日志.md)。
