# 正码超过纠错候选的显式偏好

正码可以通过明确改选并成功提交，建立超过纠错候选的独立最终菜单偏好；退出并重开后保留。现有 fusion-v1 的正码内部跨来源偏好继续生效。

2026-10-09 的新评分已让默认模型下 ujkf 的“捡”直接首选。学习回归在隔离目录内通过测试参数恢复原先“轮滑／热滑／拾滑在捡前面”的分差，验证点击、Tab、重复通知和重开时的学习行为；正式包默认使用新评分。

## 记录与应用边界

- 只由成功提交的无纠错来源、无纠错历史的正码选择触发，Direct、Composed 均适用。
- 仅记录当时实际显示在该选择前面的纠错候选；取消、提交文字不匹配、重复提交通知、正常接受已学首选均不新增。
- 新模式为 exact-correction-v1|<现有学习模式>；code 为 ~c 加现有 Lua 哈希，输入字节为 raw\0E\0exact_text\0C\0corrected_text，text 为 E、context 为空。沿用当前主线的 UTF-8 可读学习文件；新偏好仍与普通片段、fusion-v1 记录分开。旧版 LevelDb 学习数据库按主线既有规则不读取、不迁移。
- 原始输入、模式、正码文本和纠错文本共同隔离偏好。纠错强度和同一输出的纠错路径不进入键，因此切换档位仍有效；换成另一原始输入不受影响。
- 此记录只用于最终候选归并，不参与正码码表、片段奖励、Beam 搜索或模型分数。现有普通学习与 fusion-v1 记录格式及作用保持。
- 两条候选链分别保持内部相对顺序。当前纠错项若被后面的正码偏好阻挡，先输出必要的正码前缀；没有偏好时顺序原样。重排在最终菜单条数截断前执行。
- 真正发生此类重排时标记学习影响并清除本轮自动上屏证据，避免沿用旧首选的成熟判断。
- 关闭自学习同时停止应用和新增；记录保留，重新启用后恢复。选择纠错项不会创建相反偏好，也不会把纠错文本写成正码词条。

C++ 与 Lua 沿用各自历史哈希算法，本功能语义一致，不承诺跨后端直接互换学习文件。

## 回归入口

完整包中包含可运行的生产测试，均在测试自己的临时目录或内存存储适配器执行，不初始化真实用户目录：

    lua tools/test_sentence_learning.lua . .
    luajit tools/test_sentence_learning.lua . .
    g++ -std=c++17 -O2 tools/rime_learning_probe.cpp -lrime -ldl -o /tmp/rime-learning-probe
    python3 tools/test_rime_learning_integration.py --exe /tmp/rime-learning-probe --plugin /usr/lib64/rime-plugins/librime-lua.so --model models/sentence-fivegram-mobile.bin
    python3 tools/test_rime_learning_integration.py --exe /tmp/rime-learning-probe --plugin /usr/lib64/rime-plugins/librime-lua.so --model models/sentence-fivegram-mobile.bin --case fusion --correction strong --selection tap
    python3 tools/test_rime_learning_integration.py --exe /tmp/rime-learning-probe --plugin /usr/lib64/rime-plugins/librime-lua.so --model models/sentence-fivegram-mobile.bin --case fusion --correction strong --selection tab

按本机 librime Lua 插件位置调整 --plugin。Lua 测试覆盖四档点击/Tab、重复通知、取消、错提交、纠错来源/历史拒绝、关学习再开、不同原码隔离、已有 fusion 偏好补充纠错偏好及重载；CAPI 探针覆盖真实菜单索引、提交、持久化和引擎重启。
