# 拆字滤镜改用 OpenCC：可行性与 A/B 实测评估

记录于 2026-11-03（v0.3.22 之后）。对应想法文档：[想法-拆字滤镜改用OpenCC.md](想法-拆字滤镜改用OpenCC.md)。

**结论：数据层面完全可行，但「逐字等价」只在「只开拆字、其余辅助滤镜全关」时成立。
实际使用（同时开拼音提示 / emoji / 字符集提示，或用快捷键关掉拆字）下两版显示的注释
并不一样；本机也没有性能收益，反而多占 12–18 MiB 常驻内存、冷启动慢约 100ms。
长会话（约 1500 键）漂移两版相同，「少 Lua/少 GC」无累积收益；**安卓（同文芝版
模拟器）实测拆字滤镜开-关差 ±8μs/键，成本为零**——最后一条开放路径已关闭。
建议暂缓实施（实为「不做」）。**

补充实测见 §3.1；纠正了初版评估「等价性全绿」过于乐观的结论。

## 1. 数据可行性：可行，且比预想干净

`tiger_lookup.dict.yaml` 正文 **99,142 行，全部是单字，无重复、无多字词、无空值**，
格式统一为 `字\t〔部件·虎码〕`，值里不含空格 / `&` / Tab。

与虎码秃版的 `opencc/hu_cf.txt` 比对：字数与 key 集合 **完全一致（99,142）**，
秃版唯一差别是把 `·` 两侧的空格写成 `&nbsp;`（OpenCC 文本字典用空格分隔多个值，
值里不能含裸空格）。本仓库原始数据 `·` 两侧本来就没有空格，因此**不需要**这一步。

由此生成 1:1 的 OpenCC 字典没有歧义，不需要处理多音字合并、重复 key、多字词切分。

### 多字候选的空格分隔

Lua 版（`lua/chaifen.lua`）对多字候选是「逐字查表，用单个空格连接」。
OpenCC 的 simplifier 会把整个候选文本交给 OpenCC 转换再拼回注释，值不能以空格结尾。
解法：每个单字值**尾随一个 `&nbsp;`** 作为字间分隔，schema 里用两条 `comment_format` 还原：

```yaml
chaifen:
  option_name: chaifen            # 必须写！否则默认 simplification，滤镜永远不启动
  opencc_config: hu_cf.json
  show_in_comment: true
  comment_format:
    - "xform/&nbsp;$//"           # 去掉最后一个分隔（单字候选不留尾空格）
    - "xform/&nbsp;/ /"           # 其余还原为空格
  tags: [ ... ]                   # 见 §5，必须覆盖反查段
  tips: all                       # char 模式改成 char，与 enum/chaifen 等价
```

单字「我」→ `〔丿扌戈·tupg〕`；多字「我们」→ `〔丿扌戈·tupg〕 〔亻门·jam〕`。
与 Lua 版逐字一致，`·` 两侧也保持本仓库风格（无空格）。

## 2. 本次落地的评估产物

| 文件 | 用途 |
|---|---|
| `tools/export_chaifen_opencc.py` | 从 `tiger_lookup.dict.yaml` 生成 `opencc/hu_cf.txt` + `hu_cf.json` |
| `opencc/hu_cf.txt` / `hu_cf.json` | **评估产物，3.2 MiB，尚未接入任何生产 schema**；发版前需删除或加入打包排除 |
| `tools/compare_chaifen.py` | A/B 等价性对比（56 用例，逐键逐候选比对） |
| `tools/check_chaifen_realuse.py` | 多滤镜叠加、关开关、冷启动首键的贴近真实使用检查 |
| `tools/bench_chaifen.cpp` / `bench_chaifen.py` | 每键耗时探针与交错 A/B 驱动 |

测试用隔离目录 `/tmp/cf_test/user`，A 版（Lua 滤镜）与 B 版（`simplifier@chaifen`）
各三套方案（tiger / tigress / tiger_sentence），仅拆字实现不同。探针链接本机
鼠须管自带 `librime.1.dylib`（1.16.0）与 `librime-lua.dylib`，不触碰 `~/Library/Rime`。

## 3. 等价性：全绿

`python3 tools/compare_chaifen.py --mode all|char --json <报告>`

| 模式 | 用例 | 逐键步数 | 差异 |
|---|---|---|---|
| `all`（默认） | 56 | 334 | **0** |
| `char` | 56 | 334 | **0** |

用例从真实词库取码，覆盖：常用单字、U 区生僻字（>U+20000）、2–5 字多字词、
整句连续码流、拼音反查（全拼 / 简拼 / 双拼）、造词 `'` 前缀、快符 `;a`、
全字集反查 `"` 前缀；三套方案各跑一遍。逐键比对 preedit、menu 状态、每个候选的
text 与 comment、commit。

> **限定条件**：以上测试把 `pinyin` / `emoji_cn` / `charset_comment_filter` 保持默认关闭，
> 只开 `chaifen`。这是「只开拆字」的场景，也是方案默认状态。
> 多滤镜叠加时不等价，见 §3.1。

## 3.1 贴近真实使用的补充检查：叠加场景下不等价

`tools/check_chaifen_realuse.py`：把 `chaifen` + `pinyin` + `emoji_cn` +
`charset_comment_filter` 同时打开（用户可能的真实配置），并额外测
「用快捷键把拆字关掉」与「部署后第一键」。

| 场景 | 虎单 | 虎词 | 反查 | 虎整句 | 合计 |
|---|---|---|---|---|---|
| 多滤镜叠加、拆字开 | 4 | 5 | 11 | 43 | **63** |
| 拆字关（其余仍开） | 0 | 0 | 8 | 0 | **8** |

（数值为该场景下逐键逐候选的差异条目数，合计 **71**。）

典型差异，就是用户眼睛能看到的东西：

| 候选 | A / Lua 注释 | B / OpenCC 注释 |
|---|---|---|
| `我们` | `〔丿扌戈·tupg〕 〔亻门·jam〕 [基本]` | `〔丿扌戈·tupg〕 〔亻门·jam〕` |
| `的`（虎整句首键） | `（dí dì de）` | `〔白勹丶·unid〕` |
| 反查 `你好` | `〔你好〕 [杂符]` | `〔亻⺈小·jxyx〕 〔女子·bhi〕` |
| 反查 `你`（拆字**已关**） | `〔亻⺈小·jxyx〕 [基本]` | ` [基本]` |

三类成因：

1. **注释继承语义不同**。Lua 版 `cand:get_genuine().comment = ...` 改最内层，
   外层 `charset_comment_filter` 的 `[基本]` 等标记仍叠在上面；
   `simplifier` 用 `ShadowCandidate` 重新包一层并写 comment，把上游标记丢掉了。
   试过 `inherit_comment: true`，**71 处差异一处没少**，配置修不了。
2. **拼音提示与拆字的优先级反了**。A 版部分单字候选显示拼音注释（`（dí dì de）`），
   B 版同位置显示拆字串 —— 因为拼音 `simplifier` 的包装层与 Lua 版 genuine 改写的
   层级关系不同。
3. **反查段「关掉拆字仍显示」是 Lua 版独有行为**。`ZH.init` 优先级 2 对
   `yin_add_user` / `rvlk1` / `rvlk2` 段强制启用拆字，不看 `chaifen` 开关；
   OpenCC 版 `Apply()` 只看 option，关掉就整体静默。这个行为**无法用 simplifier 配置复现**，
   要么保留 Lua 滤镜，要么接受开关行为变化。

冷启动首键（部署/重启输入法后按下的第一键）也测了，但**跨批次波动比 A/B 差异大**：
虎整句在两批测量里分别是 +1183 μs 与 −1346 μs，虎单 +22 / +357 μs，
虎词 +209 / +41 μs，反查 −77 / +45 μs。受模型 mmap 预热、系统缓存影响，
**不能据此断言谁更快**；可以确定的是没有量级上的差别（都在 1–5 ms 内）。

另外两版在 `tips: all` 下都会给整句每个字都加拆分，一句 8 字就是 8 个 `〔…〕`
串成上百字符的注释，候选栏很挤 —— 这是共有行为，不是改造引入的。

## 4. 性能与内存：没有收益

交错 A/B、每组合 5 次独立进程、每轮 50×11~15 键，单位 μs/键（中位数，括号内为波动区间）：

| 场景 | Lua（开） | OpenCC（开） | Lua（关） | OpenCC（关） |
|---|---|---|---|---|
| 虎单 单字码流 | 1493 (1476~1502) | 1519 (1503~1524) | 1540 | 1530 |
| 虎词 多字词码流 | 1570 (1563~1574) | 1566 (1540~1631) | 1585 | 1566 |
| 虎整句 连续码流 | 6547 (5798~6751) | 6418 (5803~6570) | 6360 | 6397 |

- 差异为 **+1.7% / −0.3% / −2.0%**，全部落在各自波动区间内。首次非交错测量曾出现
  「虎整句慢 10.7%」，交错重测后消失，属机器负载漂移，**不可作为结论**。
- 「开/关」差值同样被噪声淹没（−47 ~ +187 μs），说明拆字滤镜本身对每键耗时影响极小；
  当前主开销仍在上游（librime-lua 的 LuaTranslation 析构 GC、整句解码），少一个 Lua
  **filter** 并不能省掉它。

峰值常驻内存（`/usr/bin/time -l`，同一按键串）：

| 方案 | Lua | OpenCC | 增量 |
|---|---|---|---|
| 虎单 | 39.7 MiB | 52.0 MiB | **+12.3 MiB** |
| 虎整句 | 41.6 MiB | 59.9 MiB | **+18.3 MiB** |

增量来自 99,142 条 OpenCC 字典常驻，是确定的成本。

> 本机数据仅代表 macOS 鼠须管 librime 1.16.0 + 自带 lua 插件。安卓实测见 §4.4：
> 同文（Trime）的 librime_jni.so 同样内嵌 Lua 5.4 插件与 OpenCC，结论一致。

### 4.1 长会话漂移：「少 Lua / 少 GC」无累积收益（2026-11-03 补测）

原始假设里唯一没测过的是 GC 累积效应：Lua 滤镜每键产生的对象若让堆持续增长，
长会话后段会越打越慢，OpenCC（C++）应更平。测法：每样本独立进程连打约 1500 键
（100 轮码流），按每 200 键分段取中位数，交错 A/B × 5，线性拟合斜率（μs/百键）：

| 场景 | Lua 漂移 | OpenCC 漂移 | A/B 差 |
|---|---|---|---|
| 虎单 单字码流 | +40.95 | +38.82 | −2.13 |
| 虎词 多字词码流 | +43.13 | +42.52 | −0.61 |
| 虎整句 连续码流 | +259.65 | +273.49 | +13.84 |

- **两版都以几乎相同的斜率上漂**——漂移来自会话本身（解码缓存增长、模型分页、
  候选池变化），与拆字滤镜无关；虎整句的 260μs/百键在两版间同样存在。
- A/B 差幅度在噪声内且方向不一致（两负一正，虎整句那点正差折算到 1500 键
  ≈ 0.2ms）。**「换 OpenCC 能让长会话更平」不成立**。

### 4.2 冷启动：OpenCC 一致慢约 100ms（2026-11-03 补测）

独立进程墙钟（librime 初始化 + 维护检查 + schema 加载 + 打字；rounds 固定，
墙钟差即加载差），交错 × 7 取中位：

| 场景 | Lua 墙钟 | OpenCC 墙钟 | 差 | 首键中位 |
|---|---|---|---|---|
| 虎单 | 1034 ms | 1127 ms | **+93.9 ms** | Lua 2587 / OpenCC 2729 μs |
| 虎词 | 970 ms | 1080 ms | **+110.1 ms** | — |
| 虎整句 | 1176 ms | 1281 ms | **+104.6 ms** | — |

三方案方向一致、区间无重叠（如虎整句 1170–1220 vs 1267–1296），是 3.19 MiB
OpenCC 字典的确定加载成本，不是噪声。

### 4.3 打包体积（静态事实）

`opencc/hu_cf.txt` 3.19 MiB，zip 内约 1.04 MiB（发行包 388 MiB 的 0.27%）。
体积不是主要矛盾，但运行时常驻的 3.19 MiB 与 §4 的 12–18 MiB 峰值增量同源。

### 4.4 安卓实测：拆字滤镜成本为零（2026-11-04，同文芝版模拟器）

评估的触发条件是「在目标平台（尤其安卓）实测到拆字滤镜每键耗时或 GC 显著」。
已在安卓端完成同等测试，触发条件不成立。

环境：`~/Desktop/芝版同文` 项目自带的 AVD（`zhi_test`，arm64-v8a，Android 15）
运行芝版同文（Trime fork，`com.viui.trime.cheese`）。探针 `tools/bench_chaifen.cpp`
用项目内 NDK 交叉编译（`-static-libstdc++`），**直接链接并 dlopen 同文 APK 的
`librime_jni.so`**（librime + Lua 5.4 插件 + OpenCC 全部内嵌，符号 `rime_get_api`
导出），在 `/data/local/tmp/cf` 隔离目录里跑与 macOS 完全相同的 A/B 矩阵
（A = Lua 滤镜方案、B = `_cc` simplifier 方案，user 树共用）。

| 场景 | Lua 开 | OpenCC 开 | 开−关差 Lua | 开−关差 OpenCC |
|---|---|---|---|---|
| 虎单 单字码流 | 1766 μs | 1740 μs（−1.5%） | +3 μs | −8 μs |
| 虎词 多字词码流 | 1779 μs | 1789 μs（+0.6%） | −8 μs | +5 μs |

（交错 A/B × 5，中位数；波动区间 ±2~6%。）

- **拆字滤镜自身的开−关差在 ±8μs/键，就是零**——「在安卓上滤镜会显著变贵」
  的假设不成立；A/B 差 −1.5%/+0.6% 同在噪声内，方向还不一致。
- 模拟器（Apple Silicon 宿主）每键 ~1.75ms，与 macOS 实机 ~1.5ms 同一量级。
- 虎整句组未跑：405MB 模型不进本次实验——安卓上引擎开销只会更彻底淹没滤镜
  成本，单字/词组两组已足以回答问题。
- 设备侧复现：`adb push` 后 `LD_LIBRARY_PATH=/data/local/tmp/cf ./bench_chaifen …`，
  驱动为 `tools/bench_chaifen_android.py`（含完整设备侧准备说明）。测试树
  留在模拟器 `/data/local/tmp/cf`（约 140MB，可随时删除）。

## 5. 实施必须注意的坑（本次实测踩到）

1. **`option_name: chaifen` 不能漏**。漏写时 simplifier 用默认 `simplification`，
   `Apply()` 直接透传，所有候选注释为空，且不会报错。
2. **`tags` 必须覆盖反查段全部 tag**。只写 `[abc]` 时，普通候选正常，
   但 `` `nihao `` 这类反查候选完全无注释。实测可用集合：
   `abc, tiger, tigress, reverse_lookup, yin_add_user, yin_flypy, yin_qp,
   yin_zrm, yin_mspy, yin_sogou, zaoci, yin_full`。
   **不要加 `mixed`**：Lua 版明确排除混输段（`ZH.init` 优先级 0），加上会多出注释。
3. **B 版必须有同名 `.custom.yaml`**。`<schema_id>.custom.yaml` 的 patch 按文件名匹配；
   测试初期 B 版缺补丁，导致 `translator/dictionary`、`menu/page_size` 等丢失，
   反查前缀 `` ` `` 被当成编码字符收进 preedit，候选列表都与 A 版不同。
4. **五笔模式未覆盖**。`char_word/dictionary: wubici` 时 Lua 版改用 `wubi_lookup`，
   本次只导出了 `tiger_lookup`。要实施需另生成一份并加开关，否则会丢该模式。
5. **滤镜顺序**。`simplifier@chaifen` 放在原 `lua_filter@*chaifen` 位置即可；
   `charset_comment` / `super_replacer` 等后续滤镜对注释的叠加需在实机上再抽样确认。

## 6. 建议

**暂不实施。** 数据可行，但原本设想的收益（更少 Lua、更少 GC、更快）在本机不成立：
耗时无差异（§4），长会话漂移与滤镜无关（§4.1），冷启动反而慢约 100ms（§4.2），
内存涨 12–18 MiB。三条收益路径全部实测为负。更重要的是 §3.1 证明**实际使用不等价** ——
只要用户同时开拼音/emoji/字符集提示，或用 `Ctrl+J` 关掉拆字，看到的注释就和现在不一样；
其中「反查段关掉拆字仍显示」是 Lua 版独有逻辑，simplifier 配置层无法复现。
再加上 tags 维护、五笔模式、滤镜顺序这些长期风险，改造是净负债。

当前版本（v0.3.22）性能瓶颈已通过「Lua 翻译入口 7→1」收敛，再动拆字滤镜性价比低。

原定的触发条件「在目标平台（尤其安卓）实测到拆字滤镜每键耗时或 GC 显著」
已于 2026-11-04 在同文芝版模拟器上实测，结果为不显著（§4.4）——该触发条件
**已被消耗**。除非未来出现新的证据（如某平台 librime-lua 换用其他 Lua 实现、
或方案规模变化使注释工作量大增），本评估不再需要重开。

## 7. 复跑方法

```bash
# 0) 生成 OpenCC 数据（幂等）
python3 tools/export_chaifen_opencc.py

# 1) 编译探针（本机鼠须管 librime 1.16.0；rime_api.h 取自 librime 1.16.0 tag）
g++ -std=c++17 -O2 tools/snapshot_rime_pipeline.cpp -I/path/to/rimehdr \
  "/Library/Input Methods/Squirrel.app/Contents/Frameworks/librime.1.dylib" \
  -ldl -o /tmp/snapshot
g++ -std=c++17 -O2 tools/bench_chaifen.cpp -I/path/to/rimehdr \
  "/Library/Input Methods/Squirrel.app/Contents/Frameworks/librime.1.dylib" \
  -ldl -o /tmp/bench_chaifen

# 2) 隔离目录：A 版实体副本 + B 版（改 filters、加 chaifen 段、补 *.custom.yaml）
#    opencc/ 指向本仓库；schema_list 同时列出六套；*.options.yaml 预置 chaifen: true
"/Library/Input Methods/Squirrel.app/Contents/MacOS/rime_deployer" \
  --build /tmp/cf_test/user "/Library/Input Methods/Squirrel.app/Contents/SharedSupport"

# 3) 等价性与性能
python3 tools/compare_chaifen.py --mode all  --json /tmp/cf_all.json
python3 tools/compare_chaifen.py --mode char --json /tmp/cf_char.json
python3 tools/check_chaifen_realuse.py > /tmp/cf_realuse.log   # 叠加/关开关/冷启动
python3 tools/bench_chaifen.py --repeat 5 --json /tmp/cf_perf.json
python3 tools/bench_chaifen_drift.py --repeat 5 --json /tmp/cf_drift.json    # 长会话漂移
python3 tools/bench_chaifen_startup.py --repeat 7 --json /tmp/cf_startup.json  # 冷启动

# 安卓（同文芝版模拟器，设备侧准备见 bench_chaifen_android.py 模块注释）
python3 tools/bench_chaifen_android.py --repeat 5 --json /tmp/cf_android_perf.json
```

`check_chaifen_realuse.py` 会临时改写隔离目录的 `*.options.yaml` 并在结束时恢复。
