charset_comment_filter = require("charset_comment_filter") --Unicode閸掑棗灏幓鎰仛
core2022 = require("core2022_filter") --閼奉亜鐣炬稊澶婄摟缁楋箓娉︽潻鍥ㄦ姢閿涘牆鐖堕悽銊ョ摟闂嗗棴绱?
-- dz_ci = require("dz_ci_filter") --閸楁洖鐡уΟ鈥崇础 鏉╂瑤閲滈崚顐ゆ暏閿涘本婀侀梻顕€顣介惃?
number_translator = require("number")
lua_unicode_display_filter = require("unicode_display")  --Unicode缂傛牜鐖滈幓鎰仛
calculator_translator = require("calculator_translator")  --缁犫偓閺勬捁顓哥粻妤€娅?
exe_processor = require("exe")  -- 缂冩垿銆夐崥顖氬З閸?
shijian2_translator = require("shijian2") -- 妤傛楠囬弮鍫曟？

-- 快符

-- 韫囶偆顑?

-- 閾忓孩鏆ｉ崣?
local tiger_sentence = require("tiger_sentence")
tiger_sentence_processor = tiger_sentence.processor_component
tiger_sentence_translator = tiger_sentence.translator
tiger_sentence_buffer_filter = tiger_sentence.buffer_filter
input_statistics = require("input_statistics")

-- Shift 大写直出：中文态下 Shift+字母 → 直接上屏大写（见 lua/shift_upper.lua）
shift_upper = require("shift_upper")

-- 虎单：候选不足时 ; / ' 顶字（见 lua/tiger_symbol_select.lua）
tiger_symbol_select = require("tiger_symbol_select")

-- 加词模块（` 前缀造词 + 内存词库即时生效）
local tiger_zaoci = require("tiger_zaoci")
tiger_zaoci_processor = tiger_zaoci.processor
tiger_zaoci_translator = tiger_zaoci.translator -- 跨统计窗口主动刷新统计数据
