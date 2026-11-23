-- Copyright (C) github.com/happyDom
--[[
👉首先，把本脚本放在你的方案下的lua文件夹内

🚩：如果你的脚本名称为 仙女0501.lua，你需要把文件名改为 input_statistics.lua后再用

🚩：如果你第一次使用不早于 ₂₀₂₅1208・B 版本的本脚本，请把你原来lua文件夹下的 input_stats.lua删除

👉其次，如果你的方案可以输入 /fj 以输入特殊符号，可以忽略这条。否则你需要调整你的方案的 alphabet 设定（在补丁中调整），加入符号 /
  # 不需要与下面这条安全一样，但需要确认其中有符号 /
  speller/alphabet: "abcdefghijklmnopqrstuvwxyz;'/"
  # 如果你的方案中设置了 initials，请确认其中也包含符号 /，例如：
  speller/initials: ';abcdefghijklmnopqrstuvwxyz/'

👉再其次，在你的方案补丁文件中，在translators节点加入对 input_statistics 的引用，如下👇：
  engine/translators/+:				#定制translator如下
	- lua_translator@*input_statistics				# 统计输入速度等信息

👉再其次，为了让统计数据在输入 //01 时有响应，你需要在方案补丁文件中加入以下👇补丁（让方案捕捉/xx [xx为数字] 这类输入):
  recognizer/patterns/punct: '^/(/[0-9]+|[A-Za-z]+)$'

👉最后，做为选项，如果你希望在你的统计消息后追加一个随机的名言，你可以在本脚本所在的目录下创建一个 quote.txt 文档，
在文档内按行写入你想要展示的名句，本脚本会随机从其中的名句中挑选一个追加在统计消息后。

👉最后，重新部署你的rime/同文

🚩使用提示（例如/01 /rtj 两种方式均可）：
//1 //11 /rtj /rtjj	查看日统计
//2 //22 /ztj /ztjj	查看周统计
//3 //33 /ytj /ytjj	查看月统计
//4 //44 /ntj /ntjj	查看年统计
//5 /sztj	查看生字/词
//07 /qcjs	清除极速数据
//08 /qcsz	清除生字/词
//09 /qctj	清除所有统计数据
//6 /scj	查看生涯段位
//60 /pf	查看统计进度条皮肤（消息会显示切换皮肤的命令用法）
]]

-- 卡壳时间门限(单位：s)，当上屏的字/词距离前一次上屏时间大于该门限时，该字/词被记录为生字/词组数据
local boggleThd_s = 3
-- 自动顶屏码数：四码顶字上屏，设置4；3码顶字上屏，设置为3；如果你不用顶字上屏功能，此处设置为0
-- 如果统计文件己经存在，则此处的设置不再生效，如果你要重新设置该值，请先删除对应方案的统计文件，重新部署rime，操作步骤如下：
-- 第一步，把统计文件删掉
-- 第二步，设置 codeLenOfAutoCommit={5,6}  -- 顶屏码数(5和6都视为自动顶屏)，如果不顶屏，这里设置为{0},可以增加或者减少
-- 第三步，重新部署rime
-- 第四步，切换输入方案到对应的方案，随便输入几个字，确保统计文件创建成功
-- 对于其它方案，重复以上步骤（只用设置需要顶屏的方案即可，设置完成后，重新设置codeLenOfAutoCommit=0，以便适用于其它不需要顶屏的方案）
local codeLenOfAutoCommit = { 0 }
-- 如果你想在平均码长后加以说明，请在这里自定义你的说明内容，可以使用 \n 换行
local avgCodeLenDesc = ''
-- 短款报告结尾是否显示随机名言：true = 显示，false = 不显示（改完需重新部署 rime）
local showQuoteShort = true
-- 名言折行宽度（显示列数）：越小折得越早，可自己调
local quoteLineWidth = 24
-- 脚本版本常量
local SCRIPT_VERSION = '✨ 仙女0501-优化版2 ✨'
-- 如果脚本不能正确识别到你的设备类型，请在这里手动指定您的设备类型，仅符号📱(手机)和💻(电脑)有效
local deviceType = '' -- 📱 or 💻；留空时自动识别平台
-- 定义一个皮肤集合，以供选用，您可以往这里加入新自定义的皮肤〔idea from 落羽行歌〕
local skinList = {
	{ field = '♥', empty = '♡' }, -- 皮肤1：爱心默认
	{ field = '▉', empty = '▁' }, -- 皮肤2
	{ field = '━', empty = '┄' }, -- 皮肤3
	{ field = '●', empty = '○' }, -- 皮肤4
	{ field = '■', empty = '□' }, -- 皮肤5
	{ field = '▲', empty = '△' }, -- 皮肤6
	{ field = '◆', empty = '◇' }, -- 皮肤7
	{ field = '▶', empty = '▷' }, -- 皮肤8
	{ field = '◀', empty = '◁' }, -- 皮肤9
	{ field = '▼', empty = '▽' }, -- 皮肤10
	{ field = '▶', empty = '▁' }, -- 皮肤11
	{ field = '▉', empty = '┄' }, -- 皮肤12
	{ field = '━', empty = '▁' }, -- 皮肤13
	{ field = '●', empty = '▁' }, -- 皮肤14
	{ field = '■', empty = '┄' }, -- 皮肤15
	{ field = '▲', empty = '▁' }, -- 皮肤16
	{ field = '◆', empty = '┄' }, -- 皮肤17
	{ field = '▉', empty = '○' }, -- 皮肤18
	{ field = '━', empty = '□' }, -- 皮肤19
	{ field = '●', empty = '△' }, -- 皮肤20
	{ field = '■', empty = '◇' }, -- 皮肤21
	{ field = '★', empty = '☆' }, -- 皮肤22
	{ field = '✭', empty = '✩' }, -- 皮肤23
	{ field = '▓', empty = '░' }, -- 皮肤24
}

-- 支持的统计指令集合
local reportCommands = {
  ["//1"] = true,
  ["//11"] = true,
  ["//2"] = true,
  ["//22"] = true,
  ["//3"] = true,
  ["//33"] = true,
  ["//4"] = true,
  ["//44"] = true,
  ["/rtj"] = true,
  ["/rtjj"] = true,
  ["/ztj"] = true,
  ["/ztjj"] = true,
  ["/ytj"] = true,
  ["/ytjj"] = true,
  ["/ntj"] = true,
  ["/ntjj"] = true,
}

-- 分配一个变量，用于字符串拼接
local strTable = {}
-- 一个用于存放名人名言的表
local quotes = {}
local quoteCnt = 0
-- 分隔线
local splitorLen = 10 -- ♡ 少点花，一行刚好
local splitorChar = '🌸'
-- local splitor = string.rep("─", splitorLen)
local splitor = string.rep(splitorChar, splitorLen)
-- 记录前一次的code字符
local lastCode = ''
local keyTouchCnt = 0 --记录编码键按下次数
-- 精确计数（提前上屏会清空 input，不能用 input 反推）：
--   proc_* 由链首 processor 累计；capture 从 commit_history 差量结算上屏单元。
local proc_keys, proc_code = 0, 0
local round_start_ts, last_key_ts = nil, nil
local round_active = false
local pending_raw_chars = 0
local capture_snapshot = nil
-- 上一次真正上屏的时刻（毫秒），只给「生字词」判定用。
-- 不能拿 avgSpdInfo.commitTime 代替：它会被 translator 的空闲重置改写，语义不稳定。
local last_commit_ms = nil

-- 毫秒时间：os.time() 只有秒精度，机器速度的输入会被算成 720+ 字/分
local function now_ms()
	if rime_api and rime_api.get_time_ms then return rime_api.get_time_ms() end
	return os.time() * 1000
end

-- 统计口径参数
-- 单轮样本的合理性：短于 0.3s（一两键）噪声太大；单字耗时超过 3s（≈20 字/分）
-- 基本是思考/选词停顿，不是打字速度；400 字/分以上按非人类速度丢弃。
-- 旧存档里被「挂着候选窗发呆」污染的超长样本由同一套规则清掉。
local MIN_SAMPLE_S = 0.3
local MAX_SAMPLE_S = 300
local MAX_SAMPLE_PER_CHAR_S = 3
local MAX_SAMPLE_SPD = 400
-- 每个周期只保留最近 120 个样本（10s 极速窗口够用）。平均速度另用 avgGapSum /
-- avgCntSum 按全周期累计，不因截尾变成滑动平均；旧存档能涨到 1MB+ 就是数组无限增长。
local AVG_TAIL_KEEP = 120
-- 生词判定门限（毫秒）
local BOGGLE_MS = boggleThd_s * 1000

-- 一个速度样本是否可信（写入和清洗历史共用同一套规则）
local function valid_sample(gap, cnt)
	if not gap or not cnt or gap <= 0 or cnt <= 0 then return false end
	local spd = cnt / gap * 60
	return spd <= MAX_SAMPLE_SPD and gap <= MAX_SAMPLE_S
		and gap <= math.max(3, cnt * MAX_SAMPLE_PER_CHAR_S)
end

-- 一轮（一个上屏单元）结束：清空计键与缓冲，下一键重新计时。
local function reset_round()
	proc_keys, proc_code = 0, 0
	pending_raw_chars = 0
	round_active = false
	round_start_ts = nil
end

-- 标记log版本
local verOfStatsFormat = 4
-- 报告风格， 0: 短款（默认），1: 长款
local reportStyle = 0

-- 下面的信息是自动获取的
local software_name = rime_api.get_distribution_code_name()
local software_version = rime_api.get_distribution_version()
local schema_name

-- 一个数据结构体，用于处理平均速度统计临时数据
local avgSpdInfo = {
	startTime = 0,               -- 如果正在记录，这里是开始的时间
	clickTime = 0,               -- 上次按键时间，通过记录按键间隔，判断是否输入超时
	commitTime = 0,              -- 这是最近一次上屏的时间
	gapThd = 5,                  -- 如果此次按键距离前一次按键的时间大于此门限值，则重新开始计时
	count = 0,                   -- 记录期间，上屏的字数
	codeLen = 0,                 -- 记录期间，输入的编码数量
}

-- 初始化统计表（若未加载）
local input_stats = input_stats or {
	daily = { count = 0, length = 0, fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }, ts = 0, lengths = {}, codeLengths = {}, avgGaps = {}, avgCnts = {}, keyTouchCnt = 0, totalCodeLenWithoutSpace = 0 },
	weekly = { count = 0, length = 0, fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }, ts = 0, lengths = {}, codeLengths = {}, avgGaps = {}, avgCnts = {}, keyTouchCnt = 0, totalCodeLenWithoutSpace = 0 },
	monthly = { count = 0, length = 0, fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }, ts = 0, lengths = {}, codeLengths = {}, avgGaps = {}, avgCnts = {}, keyTouchCnt = 0, totalCodeLenWithoutSpace = 0 },
	yearly = { count = 0, length = 0, fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }, ts = 0, lengths = {}, codeLengths = {}, avgGaps = {}, avgCnts = {}, keyTouchCnt = 0, totalCodeLenWithoutSpace = 0 },
	logVer = -1,
	daily_max = 0,
	newWords = { startTime = 0, words = {} },
	deviceType = deviceType,
	progressBarSkinIdx_word = 1, -- ♡ 爱心进度条（皮肤1）
	progressBarSkinIdx_code = 1 -- ♡ 爱心进度条（皮肤1）
}

local progressBarField_word = skinList[input_stats.progressBarSkinIdx_word].field
local progressBarEmpty_word = skinList[input_stats.progressBarSkinIdx_word].empty
local progressBarField_code = skinList[input_stats.progressBarSkinIdx_code].field
local progressBarEmpty_code = skinList[input_stats.progressBarSkinIdx_code].empty

-- ♡ 码道修行 — 20级称号体系
-- EXP = 累计输入字数（career.total），直接对应
local career_levels = {
	-- Lv,  EXP起点,  称号
	{ lv = 1,  exp = 0,        title = '🌱 初识键盘'   },
	{ lv = 2,  exp = 100,      title = '🍃 摸键学徒'   },
	{ lv = 3,  exp = 300,      title = '🌿 码字新人'   },
	{ lv = 4,  exp = 600,      title = '🌾 指尖练习生' },
	{ lv = 5,  exp = 1000,     title = '🌼 输入学徒'   },
	{ lv = 6,  exp = 2000,     title = '🌸 码流行者'   },
	{ lv = 7,  exp = 4000,     title = '🌺 飞键使'     },
	{ lv = 8,  exp = 7000,     title = '🌻 连击者'     },
	{ lv = 9,  exp = 12000,    title = '🌷 码阵构筑师' },
	{ lv = 10, exp = 20000,    title = '🌹 熟练输入师' },
	{ lv = 11, exp = 35000,    title = '⚔️ 码道武者'   },
	{ lv = 12, exp = 55000,    title = '🗡️ 飞码剑士'   },
	{ lv = 13, exp = 80000,    title = '🔥 码力掌控者' },
	{ lv = 14, exp = 120000,   title = '🌪️ 疾风键客'   },
	{ lv = 15, exp = 180000,   title = '✨ 码道宗师'   },
	{ lv = 16, exp = 280000,   title = '🌌 星码使'     },
	{ lv = 17, exp = 420000,   title = '🌠 破空键圣'   },
	{ lv = 18, exp = 620000,   title = '👑 万码之王'   },
	{ lv = 19, exp = 900000,   title = '🪽 羽化码仙'   },
	{ lv = 20, exp = 1300000,  title = '🐉 键道真君'   },
}

-- 七境界（按累计字数）
local career_realms = {
	{ base = 10000000, name = '码仙境'  },
	{ base = 5000000,  name = '码圣境'  },
	{ base = 1000000,  name = '通玄境'  },
	{ base = 200000,   name = '御码境'  },
	{ base = 50000,    name = '飞键境'  },
	{ base = 10000,    name = '熟键境'  },
	{ base = 0,        name = '凡键境'  },
}

-- 返回: 称号, lv(1-20), 当前级内EXP, 升级所需EXP
local function get_career_level(total_exp)
	local n = #career_levels
	for i = n, 1, -1 do
		if total_exp >= career_levels[i].exp then
			local lv        = career_levels[i].lv
			local exp_start = career_levels[i].exp
			local exp_end   = (i < n) and career_levels[i + 1].exp or (career_levels[n].exp + 500000)
			local exp_cur   = total_exp - exp_start
			local exp_max   = exp_end - exp_start
			return career_levels[i].title, lv, exp_cur, exp_max
		end
	end
	return career_levels[1].title, 1, total_exp, career_levels[2].exp
end

-- 返回境界名
local function get_realm(total_exp)
	for _, r in ipairs(career_realms) do
		if total_exp >= r.base then return r.name end
	end
	return '凡键境'
end

-- 向后兼容
local function get_career_rank(career_total)
	local title = get_career_level(career_total)
	return title
end

-- ♡ 今日状态（综合多维数据动态生成）
-- 参数: avgSpd, errKeyRatio, ratioTable(词长), fastest.spd
local function get_input_state(avgSpd, errKeyRatio, ratioTable, fastestSpd)
	ratioTable  = ratioTable  or {}
	fastestSpd  = fastestSpd  or 0
	local longWordRatio = ratioTable[3] or 0  -- >2字词占比

	-- 优先级从高到低，返回第一个命中的评语
	-- 综合神级
	if avgSpd >= 80 and errKeyRatio <= 5 then
		return '👑 封神了，请收下我的膝盖'
	end
	-- 极速冲刺
	if fastestSpd >= 100 then
		return '🚀 速度突破天际'
	end
	-- 高速低误触
	if avgSpd >= 60 and errKeyRatio <= 5 then
		return '✨ 键气逼人'
	end
	-- 高速
	if avgSpd >= 60 then
		return '🔥 指尖冒烟中'
	end
	-- 长词达人（>2字词占比>40%）
	if longWordRatio >= 40 and avgSpd >= 35 then
		return '📚 打词达人'
	end
	-- 低误触稳健
	if errKeyRatio <= 3 and avgSpd >= 25 then
		return '🎯 稳如老码农'
	end
	-- 中速稳定
	if avgSpd >= 40 and errKeyRatio <= 10 then
		return '🌸 状态不错哦'
	end
	-- 手滑严重
	if errKeyRatio >= 20 then
		return '🫠 手今天不太听话'
	end
	-- 手滑
	if errKeyRatio >= 12 then
		return '🌀 手有点滑捏'
	end
	-- 中速
	if avgSpd >= 30 then
		return '💫 稳步前进中'
	end
	-- 慢热
	if avgSpd >= 18 then
		return '🌱 慢慢热身中'
	end
	-- 新手/低速
	return '🐢 今天刚起步~'
end

-- ♡ 迅捷属性（基于均速）
local function get_attr_speed(avgSpd)
	if avgSpd >= 80 then return 'S+' end
	if avgSpd >= 60 then return 'S'  end
	if avgSpd >= 45 then return 'A+' end
	if avgSpd >= 35 then return 'A'  end
	if avgSpd >= 25 then return 'B+' end
	if avgSpd >= 18 then return 'B'  end
	return 'C'
end

-- ♡ 精准属性（基于误触率）
local function get_attr_accuracy(errKeyRatio)
	if errKeyRatio <= 1  then return 'S+' end
	if errKeyRatio <= 3  then return 'S'  end
	if errKeyRatio <= 6  then return 'A+' end
	if errKeyRatio <= 10 then return 'A'  end
	if errKeyRatio <= 15 then return 'B+' end
	if errKeyRatio <= 22 then return 'B'  end
	return 'C'
end

-- ♡ 博学属性（基于生字词数量）
local function get_attr_learning(word_count)
	if word_count >= 3000 then return 'S+' end
	if word_count >= 1500 then return 'S'  end
	if word_count >= 800  then return 'A+' end
	if word_count >= 400  then return 'A'  end
	if word_count >= 150  then return 'B+' end
	if word_count >= 50   then return 'B'  end
	return 'C'
end

-- ♡ EXP进度条（10格，可指定填充/空字符）
local function exp_bar(exp_cur, exp_max, fill_char, empty_char)
	fill_char  = fill_char  or '█'
	empty_char = empty_char or '░'
	local filled = math.floor(exp_cur / math.max(1, exp_max) * 10 + 0.5)
	filled = math.max(0, math.min(10, filled))
	return string.rep(fill_char, filled) .. string.rep(empty_char, 10 - filled)
end

-- ♡ 彩色进度条（词长/码长专用，带标签）
-- bar_char: 方块颜色emoji，label: 标签文字，ratio: 百分比(0-100)
local function color_bar(bar_char, label, ratio)
	local n = math.floor(ratio / 10 + 0.5)
	n = math.max(0, math.min(10, n))
	local bar   = string.rep('█', n) .. string.rep('░', 10 - n)
	local pct   = math.floor(ratio + 0.5) .. '%'
	return bar .. label .. pct
end

local function trim(str)
	if type(str) ~= "string" then
		return "" -- 非字符串返回空字符串，也可返回原值/报错，按需调整
	end
	return str:match("^%s*(.-)%s*$") or ""
end

local function currentDir()
	local info = debug.getinfo(2) --debug.getinfo(2), 2: 返回调用 currentDir 的函数的信息

	--解析info.source所在的路径
	local path = info.source
	path = string.sub(path, 2, -1)   -- 去掉开头的"@"
	path = string.gsub(path, '\\', '/') -- 路径格式由 c:\\Users\\san.zhang\\ 转换为 c:/Users/san.zhang/
	path = string.match(path, "^(.*)/") -- 捕获最后一个 "/" 之前的部分 就是我们最终要的目录部分

	return path
end

-- 定义平台检测函数
local function detect_platform()
	-- 1. 尝试从 RIME API 获取
	if rime_api and rime_api.get_distribution_code_name then
		local dist = rime_api.get_distribution_code_name()
		if dist and type(dist) == "string" then
			local lower_dist = dist:lower()
			if lower_dist == "trime" then return "android" end
			if lower_dist == "hamster" or lower_dist == "hamster3" then return "ios" end
			if lower_dist == "squirrel" then return "mac" end
			if lower_dist == "weasel" then return "windows" end
			if lower_dist == "ibus-rime" or lower_dist == "fcitx-rime" then
				-- 需要进一步区分
			end
		end
	end

	-- Android 前端可能只向 librime 报告通用发行名（例如 fcitx-rime），
	-- 结合 Android 环境变量或 Rime 用户目录识别设备平台。
	if os.getenv("ANDROID_ROOT") or os.getenv("ANDROID_DATA") or os.getenv("EXTERNAL_STORAGE") then
		return "android"
	end
	if rime_api and rime_api.get_user_data_dir then
		local ok_dir, dir = pcall(rime_api.get_user_data_dir)
		if ok_dir and type(dir) == "string" then
			local lower_dir = dir:lower()
			if lower_dir:find("/storage/", 1, true)
				or lower_dir:find("/sdcard", 1, true)
				or lower_dir:find("/data/data/", 1, true)
				or lower_dir:find("/data/user/", 1, true)
				or lower_dir:find("/data/user_de/", 1, true) then
				return "android"
			end
		end
	end

	-- 2. 使用 LuaJIT 的 jit.os
	if jit and jit.os then
		local jit_os = jit.os:lower()
		if jit_os == "android" then return "android" end
		if jit_os == "linux" then return "linux" end
		if jit_os == "osx" or jit_os == "macos" then return "mac" end
		if jit_os == "windows" then return "windows" end
	end

	-- 3. 初始化
	local is_mac = false
	local is_windows = false

	-- 检查路径分隔符
	if package.config:sub(1, 1) == "\\" then
		is_windows = true
	end

	-- 检查环境变量
	if not is_windows then
		local home = os.getenv("HOME")
		if home and (home:find("/Users/") or home:find("/home/")) then
			-- 检查是否 macOS
			local ok, file = pcall(io.open, "/Applications", "r")
			if ok and file then
				file:close()
				is_mac = true
			end
		end
	end

	if is_windows then return "windows" end
	if is_mac then return "mac" end

	-- 4. 默认unknown
	return "unknown"
end

-- 判断给定的utf8.codepoint值是否为汉字
local function IsChineseCharacter(codepoint)
	return (codepoint >= 0x4e00 and codepoint <= 0x9fff) -- 基本区
		or (codepoint >= 0x3400 and codepoint <= 0x4dbf) -- 扩A
		or (codepoint >= 0x20000 and codepoint <= 0x2a6df) -- 扩B
		or (codepoint >= 0x2a700 and codepoint <= 0x2b73f) -- 扩C
		or (codepoint >= 0x2b740 and codepoint <= 0x2b81f) -- 扩D
		or (codepoint >= 0x2b820 and codepoint <= 0x2ceaf) -- 扩E
		or (codepoint >= 0x2ceb0 and codepoint <= 0x2ebef) -- 扩F
		or (codepoint >= 0x30000 and codepoint <= 0x3134f) -- 扩G
		or (codepoint >= 0x31350 and codepoint <= 0x323af) -- 扩H
		or (codepoint >= 0x2ebf0 and codepoint <= 0x2ee5f) -- 扩I
		or (codepoint >= 0x31c0 and codepoint <= 0x31ef) -- 笔画
		or (codepoint >= 0x2e80 and codepoint <= 0x2eff) -- 部首扩展
		or (codepoint >= 0x2f00 and codepoint <= 0x2fdf) -- 康熙部首
		or (codepoint >= 0xf900 and codepoint <= 0xfadf) -- 兼容
		or (codepoint >= 0x2f800 and codepoint <= 0x2fa1f) -- 兼补
		or (codepoint >= 0x2ff0 and codepoint <= 0x2fff) -- 汉字结构
		or (codepoint >= 0x3100 and codepoint <= 0x312f) -- 注音
		or (codepoint >= 0x31a0 and codepoint <= 0x31bf) -- 注音扩展
end

-- 判断给定的字符串是否全部是汉字
local function isAllChineseCharacter(text)
	for _, c in utf8.codes(text) do
		if not IsChineseCharacter(c) then
			return false
		end
	end
	return true
end

local function getDeviceType()
	if ({ ['📱'] = true, ['💻'] = true })[deviceType] then
		return deviceType
	else
		local platform = detect_platform()
		if platform == "android" then
			return '📱'
		elseif platform == "ios" then
			return '📱'
		elseif platform == "mac" then
			return '💻'
		elseif platform == "windows" then
			return '💻'
		elseif platform == "linux" then
			return '💻'
		else
			if ({ ['📱'] = true, ['💻'] = true })[input_stats.deviceType] then
				return input_stats.deviceType
			else
				return ''
			end
		end
	end
end

-- 前端统一显示英文代号。Android 上的 Fcitx Rime 也返回 fcitx-rime。
local SOFTWARE_DISPLAY = {
	trime = 'trime',
	hamster = 'hamster',
	hamster3 = 'hamster3',
	squirrel = 'squirrel',
	weasel = 'Weasel',
	fcitx5 = 'fcitx-rime',
	['fcitx5-android'] = 'fcitx-rime',
	['fcitx5_android'] = 'fcitx-rime',
	['fcitx5-android-x86'] = 'fcitx-rime',
	['fcitx-rime'] = 'fcitx-rime',
	['ibus-rime'] = 'ibus-rime',
	fcitx = 'fcitx',
	ibus = 'ibus',
	rime = 'rime',
	foxy = 'foxy',
}
local PLATFORM_DISPLAY = {
	android = 'android',
	ios = 'iOS',
	mac = 'squirrel',
	windows = 'Weasel',
	linux = 'linux',
}
local function softwareDisplayName()
	if type(software_name) == "string" and software_name ~= "" then
		local name = software_name:lower()
		return SOFTWARE_DISPLAY[name] or software_name
	end
	return PLATFORM_DISPLAY[detect_platform()] or 'unknown'
end
local function softwareDisplayVersion()
	if type(software_version) == "string" and software_version ~= "" then
		return ' ' .. software_version
	end
	if type(software_version) == "number" then
		return ' ' .. tostring(software_version)
	end
	return ''
end

-- 将指定的文档处理成行数组
local function files_to_lines(...)
	local tab = setmetatable({}, { __index = table })
	local index = 1
	for i, filename in next, { ... } do
		local fn = io.open(filename)
		if fn then
			for line in fn:lines() do
				if not line or #line > 0 then
					tab:insert(line)
				end
			end
			fn:close()
		end
	end
	return tab
end

-- 定义一个求和函数，用于求取一个table内的数字的和
local function tableSum(tb)
	local sum = 0
	for i = 1, #tb do
		sum = sum + tb[i]
	end
	return sum
end

-- 定义一个求和函数，用于求取一个table内尾部指定数量项的和
local function tableTailSum(tb, n)
	if type(tb) ~= "table" then return 0 end
	local len = #tb
	local n = tonumber(n) or 0 -- 非数字转 0
	if n < 1 or len < 1 then return 0 end

	local sum = 0
	local takeCount = math.min(n, len)
	for i = 1, takeCount do
		sum = sum + (tb[len - takeCount + i] or 0)
	end
	return sum
end

-- 根据传入的百分比和皮肤字符，生成一个进度条（统一实现）
local function makeProgressBar(p, filled, empty)
	local n = 0
	if p >= 95.0 then n = 10
	elseif p >= 85.0 then n = 9
	elseif p >= 75.0 then n = 8
	elseif p >= 65.0 then n = 7
	elseif p >= 55.0 then n = 6
	elseif p >= 45.0 then n = 5
	elseif p >= 35.0 then n = 4
	elseif p >= 25.0 then n = 3
	elseif p >= 15.0 then n = 2
	elseif p >= 5.0  then n = 1
	end
	return string.rep(filled, n) .. string.rep(empty, 10 - n)
end

local function progressBar_code(p)
	return makeProgressBar(p, progressBarField_code, progressBarEmpty_code)
end

local function progressBar_word(p)
	return makeProgressBar(p, progressBarField_word, progressBarEmpty_word)
end

-- 时间戳工具函数
local function get_timezone() -- 计算时区偏移
	local local_t = os.date("*t")
	local local_ts = os.time(local_t)
	local utc_ts = os.time(os.date("!*t", local_ts))
	local offset_min = (local_ts - utc_ts) / 60
	local offset_hour = math.floor(offset_min / 60)
	local offset_minute = math.abs(offset_min % 60)
	return string.format("UTC%+03d:%02d", offset_hour, offset_minute)
end
local function start_of_day(t)
	return os.time { year = t.year, month = t.month, day = t.day, hour = 0 }
end
local function start_of_week(t)
	local d = t.wday == 1 and 6 or (t.wday - 2)
	return os.time { year = t.year, month = t.month, day = t.day - d, hour = 0 }
end
local function start_of_month(t)
	return os.time { year = t.year, month = t.month, day = 1, hour = 0 }
end
local function start_of_year(t)
	return os.time { year = t.year, month = 1, day = 1, hour = 0 }
end

-- 只保留数组尾部 keep 个元素（返回新表，避免 table.remove 的 O(n) 位移）
local function trim_tail(t, keep)
	local n = #t
	if n <= keep then return t end
	local out = {}
	for i = n - keep + 1, n do
		out[#out + 1] = t[i]
	end
	return out
end

-- 追加一个速度样本：
--   总和单独累加（平均速度按整个周期算，截尾不影响读数）；
--   数组只留最近 AVG_TAIL_KEEP 个（10s 极速窗口够用），避免存档无限膨胀。
local function append_avg(p, gap, cnt, code)
	p.avgGapSum = (p.avgGapSum or 0) + gap
	p.avgCntSum = (p.avgCntSum or 0) + cnt
	p.avgCodeSum = (p.avgCodeSum or 0) + code
	p.avgGaps[#p.avgGaps + 1] = gap
	p.avgCnts[#p.avgCnts + 1] = cnt
	p.avgCodeLen[#p.avgCodeLen + 1] = code
	if #p.avgGaps > AVG_TAIL_KEEP + 30 then
		p.avgGaps = trim_tail(p.avgGaps, AVG_TAIL_KEEP)
		p.avgCnts = trim_tail(p.avgCnts, AVG_TAIL_KEEP)
		p.avgCodeLen = trim_tail(p.avgCodeLen, AVG_TAIL_KEEP)
	end
end

-- 更新统计数据
local function update_stats(input_length, codeLen, codeLenWithoutSpace, avgAvailable)
	local now = os.date("*t")
	local now_ts = os.time(now)

	local day_ts = start_of_day(now)
	local week_ts = start_of_week(now)
	local month_ts = start_of_month(now)
	local year_ts = start_of_year(now)

	if input_stats.daily.ts ~= day_ts then
		input_stats.daily = { count = 0, length = 0, fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }, ts = day_ts, lengths = {}, codeLengths = {}, avgGaps = {}, avgCnts = {}, avgCodeLen = {}, keyTouchCnt = 0, totalCodeLenWithoutSpace = 0 }
		input_stats.daily_max = 0
	end
	if input_stats.weekly.ts ~= week_ts then
		input_stats.weekly = { count = 0, length = 0, fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }, ts =
		week_ts, lengths = {}, codeLengths = {}, avgGaps = {}, avgCnts = {}, avgCodeLen = {}, keyTouchCnt = 0, totalCodeLenWithoutSpace = 0 }
	end
	if input_stats.monthly.ts ~= month_ts then
		input_stats.monthly = { count = 0, length = 0, fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }, ts =
		month_ts, lengths = {}, codeLengths = {}, avgGaps = {}, avgCnts = {}, avgCodeLen = {}, keyTouchCnt = 0, totalCodeLenWithoutSpace = 0 }
	end
	if input_stats.yearly.ts ~= year_ts then
		input_stats.yearly = { count = 0, length = 0, fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }, ts =
		year_ts, lengths = {}, codeLengths = {}, avgGaps = {}, avgCnts = {}, avgCodeLen = {}, keyTouchCnt = 0, totalCodeLenWithoutSpace = 0 }
	end

	-- 更新平均分速统计数据
	if 1 == avgAvailable then
		-- 时间统一用毫秒算，落盘时换成秒（带小数），旧存档里的整数秒可以直接混用
		local delt = (avgSpdInfo.commitTime - avgSpdInfo.startTime) / 1000
		local cnt  = avgSpdInfo.count
		local code = avgSpdInfo.codeLen

		-- 只收「像打字」的样本：时间太短（一两键）、太长（挂着候选窗发呆）或非人类速度
		-- 都丢掉。旧版本把几小时的空闲算进本轮，平均分速会掉到 1 字/分。
		if delt >= MIN_SAMPLE_S and valid_sample(delt, cnt) then
			append_avg(input_stats.daily, delt, cnt, code)
			append_avg(input_stats.weekly, delt, cnt, code)
			append_avg(input_stats.monthly, delt, cnt, code)
			append_avg(input_stats.yearly, delt, cnt, code)

			-- 用最近这些样本凑够 10s，计算瞬时速度，作为最大分速的参考
			local latestGapsSum, latestCntsSum, latestCodeLenSum = 0, 0, 0
			local latestSpd, latestKeyTouchSpd, latestAvgCodeLen = 0, 0, 0
			local gaps, cnts, lens = input_stats.yearly.avgGaps, input_stats.yearly.avgCnts,
				input_stats.yearly.avgCodeLen
			for i = #gaps, 1, -1 do
				latestGapsSum = latestGapsSum + (gaps[i] or 0)
				latestCntsSum = latestCntsSum + (cnts[i] or 0)
				latestCodeLenSum = latestCodeLenSum + (lens[i] or 0)
				if latestGapsSum >= 10 then -- 最后10s的平均速度做为瞬时速度
					break
				end
			end
			if latestGapsSum >= 10 then -- 如果数据的时长小于10s，则不计算最大速度，避免瞬时偏差过大
				latestSpd = latestCntsSum / latestGapsSum * 60
				latestKeyTouchSpd = latestCodeLenSum / latestGapsSum
				if latestCntsSum > 0 then
					latestAvgCodeLen = latestCodeLenSum / latestCntsSum
				end
				if latestSpd > 400 then latestSpd = 0 end -- 非人类速度，丢弃

				-- 更新最大分速值
				if latestSpd > input_stats.daily.fastest.spd then
					input_stats.daily.fastest.spd = latestSpd
					input_stats.daily.fastest.keyTouchSpd = latestKeyTouchSpd
					input_stats.daily.fastest.avgCodeLen = latestAvgCodeLen
				end
				if latestSpd > input_stats.weekly.fastest.spd then
					input_stats.weekly.fastest.spd = latestSpd
					input_stats.weekly.fastest.keyTouchSpd = latestKeyTouchSpd
					input_stats.weekly.fastest.avgCodeLen = latestAvgCodeLen
				end
				if latestSpd > input_stats.monthly.fastest.spd then
					input_stats.monthly.fastest.spd = latestSpd
					input_stats.monthly.fastest.keyTouchSpd = latestKeyTouchSpd
					input_stats.monthly.fastest.avgCodeLen = latestAvgCodeLen
				end
				if latestSpd > input_stats.yearly.fastest.spd then
					input_stats.yearly.fastest.spd = latestSpd
					input_stats.yearly.fastest.keyTouchSpd = latestKeyTouchSpd
					input_stats.yearly.fastest.avgCodeLen = latestAvgCodeLen
				end
			end
		end

		avgSpdInfo.count = 0
		avgSpdInfo.codeLen = 0
	end

	-- 如果输入字/词长度小于1（即为空），则不做后续的处理
	if input_length < 1 then return end

	-- 更新总按键数
	input_stats.daily.keyTouchCnt = input_stats.daily.keyTouchCnt + keyTouchCnt
	input_stats.weekly.keyTouchCnt = input_stats.weekly.keyTouchCnt + keyTouchCnt
	input_stats.monthly.keyTouchCnt = input_stats.monthly.keyTouchCnt + keyTouchCnt
	input_stats.yearly.keyTouchCnt = input_stats.yearly.keyTouchCnt + keyTouchCnt
	keyTouchCnt = 0

	-- 更新不含空格的编码数量
	input_stats.daily.totalCodeLenWithoutSpace = input_stats.daily.totalCodeLenWithoutSpace + codeLenWithoutSpace
	input_stats.weekly.totalCodeLenWithoutSpace = input_stats.weekly.totalCodeLenWithoutSpace + codeLenWithoutSpace
	input_stats.monthly.totalCodeLenWithoutSpace = input_stats.monthly.totalCodeLenWithoutSpace + codeLenWithoutSpace
	input_stats.yearly.totalCodeLenWithoutSpace = input_stats.yearly.totalCodeLenWithoutSpace + codeLenWithoutSpace

	-- 更新记录
	local update = function(stat)
		stat.count = stat.count + 1
		stat.length = stat.length + input_length
	end
	update(input_stats.daily)
	update(input_stats.weekly)
	update(input_stats.monthly)
	update(input_stats.yearly)

	if input_length > input_stats.daily_max then
		input_stats.daily_max = input_length
	end

	-- 更新输入字/词组数据
	input_stats.daily.lengths[input_length] = (input_stats.daily.lengths[input_length] or 0) + 1
	input_stats.weekly.lengths[input_length] = (input_stats.weekly.lengths[input_length] or 0) + 1
	input_stats.monthly.lengths[input_length] = (input_stats.monthly.lengths[input_length] or 0) + 1
	input_stats.yearly.lengths[input_length] = (input_stats.yearly.lengths[input_length] or 0) + 1

	-- 更新输入码长数据
	input_stats.daily.codeLengths[codeLen] = (input_stats.daily.codeLengths[codeLen] or 0) + 1
	input_stats.weekly.codeLengths[codeLen] = (input_stats.weekly.codeLengths[codeLen] or 0) + 1
	input_stats.monthly.codeLengths[codeLen] = (input_stats.monthly.codeLengths[codeLen] or 0) + 1
	input_stats.yearly.codeLengths[codeLen] = (input_stats.yearly.codeLengths[codeLen] or 0) + 1

	-- 更新生涯累计字数（EXP）
	if not input_stats.career then input_stats.career = { total = 0 } end
	input_stats.career.total = (input_stats.career.total or 0) + input_length
end

-- 表序列化工具（本地函数，避免污染全局 table）
local serialize_table
serialize_table = function(tbl)
	local lines = { "{" }
	for k, v in pairs(tbl) do
		local key = (type(k) == "string") and ("[\"" .. k .. "\"]") or ("[" .. k .. "]")
		local val
		if type(v) == "table" then
			val = serialize_table(v)
		elseif type(v) == "string" then
			val = '"' .. v .. '"'
		else
			val = tostring(v)
		end
		table.insert(lines, string.format("	%s = %s,", key, val))
	end
	table.insert(lines, "}")
	return table.concat(lines, "\n")
end

-- 保存至文件
local function save_stats(schema_id)
	local path = rime_api.get_user_data_dir() .. "/lua/input_stats_" .. schema_id .. ".lua"
	local file = io.open(path, "w")
	if not file then return end
	file:write("input_stats = " .. serialize_table(input_stats) .. "\n")
	file:close()
end

-- -- 节流保存（2026-10 芝士虎整性能修复）
-- 热路径是 commit_notifier：每次上屏都 save_stats()，把整个统计表序列化后
-- 整体重写档案（日/周/月/年会随使用时间增长，手机上每词一次大写盘会卡顿）。
-- 改为「脏标记 + 距上次落盘 ≥ SAVE_STATS_INTERVAL 秒才真正写」：
-- 面板/指令仍走 save_stats() 即时写（低频，要求立即生效）；
-- normal_exit 的 finit 会把未保存的脏数据补写，正常退出不丢数据。
local SAVE_STATS_INTERVAL = 30       -- 两次全量落盘的最小间隔（秒）
local save_dirty = false
local last_save_time = 0

local function request_save(schema_id, immediate)
	if immediate then
		save_stats(schema_id)
		save_dirty = false
		last_save_time = os.time()
		return
	end
	local now = os.time()
	if save_dirty and now - last_save_time >= SAVE_STATS_INTERVAL then
		save_stats(schema_id)
		save_dirty = false
		last_save_time = now
	else
		save_dirty = true
	end
end
local function flush_save(schema_id)
	if save_dirty then
		save_stats(schema_id)
		save_dirty = false
		last_save_time = os.time()
	end
end

-- 将一段文字嵌入 splitor 中间（♡ 前后花朵数相等）
local function embedTextIntoSplitor(myText)
	local tmpLen = utf8.len(myText)
	local each = math.max(1, math.ceil((splitorLen - tmpLen) / 2))
	return string.rep(splitorChar, each) .. myText .. string.rep(splitorChar, each)
end

-- 格式化皮肤列表〔from 落羽行歌〕
local function formatSkinList()
	local skinListText = {}
	table.insert(skinListText, "🎀 可用皮肤列表：")

	local pfIdxa = 0
	local pfIdxb = 0

	for i = 1, #skinList do
		local prefix = (input_stats.progressBarSkinIdx_word == i) and '-w-' or '--- '
		prefix = prefix .. ((input_stats.progressBarSkinIdx_code == i) and '-c-' or '---')
		pfIdxa = math.floor(i / 10)
		pfIdxb = i - pfIdxa * 10
		local skinStr = string.format("%s%02d %s%s %s%s", prefix, i, string.char(97 + pfIdxa), string.char(97 + pfIdxb),
			string.rep(skinList[i].field, 4), string.rep(skinList[i].empty, 4))
		table.insert(skinListText, skinStr)
	end

	table.insert(skinListText, "w 当前字词统计皮肤 / c 当前码长统计皮肤")
	table.insert(skinListText, "输入 //60 或 /pf 查看皮肤列表")
	table.insert(skinListText, "输入 /6xx1 或 /hfwyy 或 /pfwyy 切换字词统计皮肤(xx为数字，yy为字母)")
	table.insert(skinListText, "输入 /6xx2 或 /hfcyy 或 /pfcyy 切换码长统计皮肤(xx为数字，yy为字母)")

	return table.concat(skinListText, "\n"):gsub("\n+", "\n"):gsub("^%n", ""):gsub("%n$", "")
end


-- 根据给定的样本，计算并返回统计指标
local function statisticsCal(s)
	-- 记录最大值
	local fastest = { spd = s.fastest.spd, keyTouchSpd = s.fastest.keyTouchSpd, avgCodeLen = s.fastest.avgCodeLen }

	-- 统计各类输入组合的占比
	local val1 = s.lengths[1] or 0 -- 防止索引不存在时报错，默认0
	local val2 = (s.lengths[2] or 0) * 2
	local val3 = 0
	local total = 0               -- 总字数
	for key, value in pairs(s.lengths) do
		total = total + key * value -- 累加所有值
	end
	if total == 0 then total = 1 end -- 防止除以0报错
	val3 = total - val1 - val2
	local ratio1 = (val1 / total) * 100
	local ratio2 = (val2 / total) * 100
	local ratio3 = (val3 / total) * 100
	local ratioTable = { ratio1, ratio2, ratio3 } -- 和输入字符长度的占比：1字词占比，2字词占比，其它长度词占比

	-- 统计码长的占比（分类为：频率最高的3种码长，和其它码长）
	local codeTable_sorted = {}
	local totalCodeLen = 0 -- 总码长
	local totalCodeCnt = 0 -- 总码数
	local codeTypeCnt = 0 -- 码长的种类数量
	for k, v in pairs(s.codeLengths) do
		totalCodeLen = totalCodeLen + v * k
		totalCodeCnt = totalCodeCnt + v
		codeTypeCnt = codeTypeCnt + 1
		table.insert(codeTable_sorted, { clen = k, count = v })
	end
	-- 平均码长
	local avgCodeLen = totalCodeLen / total

	-- 统计码长占比
	table.sort(codeTable_sorted, function(a, b)
		return a.count > b.count
	end)
	if totalCodeCnt == 0 then totalCodeCnt = 1 end -- 防止除以0报错
	local codeTableFirstN = {}                  -- 输入码长最多的前N码（4码）码长占比数据
	local ratioSumOfFirstN = 0
	for i = 1, 3 do
		if i <= codeTypeCnt then
			codeTableFirstN[i] = { codeLen = codeTable_sorted[i].clen, ratio = codeTable_sorted[i].count / totalCodeCnt *
			100 }
		else
			codeTableFirstN[i] = { codeLen = 0, ratio = 0 }
		end
		ratioSumOfFirstN = ratioSumOfFirstN + codeTableFirstN[i].ratio
	end
	codeTableFirstN[4] = { codeLen = 0, ratio = 100 - ratioSumOfFirstN }

	-- 计算平均分速
	-- 优先用累计和（v0.3.28 起每次追加样本都累加），旧存档没有这两个字段时退回数组求和
	local avgDelt = s.avgGapSum or tableSum(s.avgGaps)
	local avgCnt  = s.avgCntSum or tableSum(s.avgCnts)
	local avgSpd = 0
	if avgDelt > 0.1 then
		avgSpd = avgCnt / avgDelt * 60
		if avgSpd > fastest.spd and avgSpd <= 400 then
			fastest.spd = avgSpd
			fastest.keyTouchSpd = avgSpd * avgCodeLen / 60
			fastest.avgCodeLen = avgCodeLen
		end
	end

	return fastest, avgSpd, avgCodeLen, ratioTable, codeTableFirstN
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 短版：6~7行，适合发朋友圈/群聊
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
local function displayWidth(str)
	local w = 0
	for _, cp in utf8.codes(str) do
		local n = 1
		if (cp >= 0x0300 and cp <= 0x036F) or (cp >= 0xFE00 and cp <= 0xFE0F) or cp == 0x200D then
			n = 0
		elseif (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0xA4CF)
			or (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF)
			or (cp >= 0xFE30 and cp <= 0xFE6F) or (cp >= 0xFF00 and cp <= 0xFF60)
			or (cp >= 0xFFE0 and cp <= 0xFFE6) or (cp >= 0x1F300 and cp <= 0x1FAFF)
			or (cp >= 0x20000 and cp <= 0x3FFFD) then
			n = 2
		end
		w = w + n
	end
	return w
end

-- 按显示宽度把文本折成多行（每行不超过 maxCols 列）
local function wrapByWidth(str, maxCols)
	local positions = {}
	for pos in utf8.codes(str) do positions[#positions + 1] = pos end
	positions[#positions + 1] = #str + 1
	local out, curStart, curW = {}, 1, 0
	for i = 1, #positions - 1 do
		local chStart = positions[i]
		local chEnd = positions[i + 1] - 1
		local cw = displayWidth(str:sub(chStart, chEnd))
		if curW > 0 and curW + cw > maxCols then
			table.insert(out, str:sub(curStart, chStart - 1))
			curStart = chStart
			curW = 0
		end
		curW = curW + cw
	end
	if curStart <= #str then table.insert(out, str:sub(curStart)) end
	return out
end

local function format_short(s, label, empty_msg)
	if s.count == 0 then return empty_msg end

	local fastest, avgSpd, avgCodeLen, ratioTable, codeTableFirstN = statisticsCal(s)

	local errKeyCnt   = math.max(0, s.keyTouchCnt - s.totalCodeLenWithoutSpace)
	local errKeyRatio = s.keyTouchCnt > 0 and (100 * errKeyCnt / s.keyTouchCnt) or 0

	local state = get_input_state(avgSpd, errKeyRatio, ratioTable, fastest.spd)

	local career_total = (input_stats.career and input_stats.career.total) or 0
	local rank_title, lv = get_career_level(career_total)
	local rank_short = rank_title:match("%s(.+)$") or rank_title
	local label_map = { ["日统计"] = "今日打字", ["周统计"] = "本周打字", ["月统计"] = "本月打字", ["年统计"] = "年度打字" }
	local title_line = '🌷 ' .. (label_map[label] or label)

	local lines = {
		title_line,
		string.format('📝 %d次·⌨️%d字', s.count, s.length),
		string.format('⚡ %.1f  击键%.1f  码长%.1f', fastest.spd, fastest.keyTouchSpd, fastest.avgCodeLen),
		string.format('💫 %.1f  击键%.1f  码长%.1f', avgSpd, avgSpd * avgCodeLen / 60, avgCodeLen),
		string.format('🌀 误触%d次（%.0f%%）', errKeyCnt, errKeyRatio),
	}

	-- 词长分布（彩色进度条）
	table.insert(lines, '📖 词长分布')
	if ratioTable[1] > 0 then table.insert(lines, color_bar('🟩', '单字', ratioTable[1])) end
	if ratioTable[2] > 0 then table.insert(lines, color_bar('🟩', '双字', ratioTable[2])) end
	if ratioTable[3] > 0 then table.insert(lines, color_bar('🟩', '多字', ratioTable[3])) end

	-- 码长分布（彩色进度条，不同颜色区分码长）
	local code_colors = { '🟦', '🟨', '🟧', '🟪' }
	table.insert(lines, '📚 编码分布')
	for i = 1, 3 do
		local ct = codeTableFirstN[i]
		if ct.ratio > 0 then
			table.insert(lines, color_bar(code_colors[i] or '🟦', ct.codeLen .. '码', ct.ratio))
		end
	end
	if codeTableFirstN[4].ratio > 0 then
		table.insert(lines, color_bar('🟪', '其它', codeTableFirstN[4].ratio))
	end

	table.insert(lines, state .. '  🎀' .. rank_short .. ' Lv.' .. lv)
	table.insert(lines, getDeviceType() .. softwareDisplayName() .. softwareDisplayVersion() .. '・' .. schema_name)

	-- 结尾随机名言（受 showQuoteShort 控制，按显示宽度折行）
	if showQuoteShort and quoteCnt > 0 then
		local q = quotes[math.floor(math.random() * quoteCnt) + 1]
		if q and #q > 0 then
			table.insert(lines, '━━━━━━━━━━━━')
			for _, ln in ipairs(wrapByWidth('『' .. q .. '』', quoteLineWidth)) do
				table.insert(lines, ln)
			end
		end
	end

	return table.concat(lines, '\n')
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 长版：完整专业复盘
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
local function format_long(s, label, empty_msg)
	if s.count == 0 then return empty_msg end

	local fastest, avgSpd, avgCodeLen, ratioTable, codeTableFirstN = statisticsCal(s)

	local errKeyCnt   = math.max(0, s.keyTouchCnt - s.totalCodeLenWithoutSpace)
	local errKeyRatio = s.keyTouchCnt > 0 and (100 * errKeyCnt / s.keyTouchCnt) or 0

	local state = get_input_state(avgSpd, errKeyRatio, ratioTable, fastest.spd)
	local career_total = (input_stats.career and input_stats.career.total) or 0
	local rank_title, lv, exp_cur, exp_max = get_career_level(career_total)
	local realm = get_realm(career_total)

	-- 三属性
	local attr_spd = get_attr_speed(avgSpd)
	local attr_acc = get_attr_accuracy(errKeyRatio)
	local word_count = 0
	if input_stats.newWords and input_stats.newWords.words then
		for _ in pairs(input_stats.newWords.words) do word_count = word_count + 1 end
	end
	local attr_learn = get_attr_learning(word_count)

	local sep  = '━━━━━━━━━━━━'
	local label_map = { ["日统计"] = "今日打字报告", ["周统计"] = "本周打字报告", ["月统计"] = "本月打字报告", ["年统计"] = "年度打字报告" }
	local report_title = label_map[label] or label

	local lines = {}
	table.insert(lines, string.format('🌸 %s 🌸', report_title))
	table.insert(lines, os.date("📅 %Y/%m/%d  %H:%M", os.time()))
	table.insert(lines, string.format('📝 上屏%d次·⌨️输入%d字', s.count, s.length))
	table.insert(lines, sep)

	-- 速度
	table.insert(lines, string.format('⚡ %.1f  击键%.1f  码长%.1f', fastest.spd, fastest.keyTouchSpd, fastest.avgCodeLen))
	table.insert(lines, string.format('💫 %.1f  击键%.1f  码长%.1f', avgSpd, avgSpd * avgCodeLen / 60, avgCodeLen))
	table.insert(lines, string.format('🌀 误触%d次（%.0f%%）', errKeyCnt, errKeyRatio))
	table.insert(lines, sep)

	-- 词长分布
	table.insert(lines, '📖 词长分布')
	if ratioTable[1] > 0 then table.insert(lines, color_bar('🟩', '单字', ratioTable[1])) end
	if ratioTable[2] > 0 then table.insert(lines, color_bar('🟩', '双字', ratioTable[2])) end
	if ratioTable[3] > 0 then table.insert(lines, color_bar('🟩', '多字', ratioTable[3])) end
	table.insert(lines, sep)

	-- 码长分布
	local code_colors = { '🟦', '🟨', '🟧', '🟪' }
	table.insert(lines, '📚 编码分布')
	for i = 1, 3 do
		local ct = codeTableFirstN[i]
		if ct.ratio > 0 then
			table.insert(lines, color_bar(code_colors[i], ct.codeLen .. '码', ct.ratio))
		end
	end
	if codeTableFirstN[4].ratio > 0 then
		table.insert(lines, color_bar('🟪', '其它', codeTableFirstN[4].ratio))
	end
	table.insert(lines, sep)

	-- 码道修行
	table.insert(lines, '🎮 码道修行')
	table.insert(lines, string.format('境界：%s', realm))
	table.insert(lines, string.format('%s  Lv.%d', rank_title, lv))
	table.insert(lines, exp_bar(exp_cur, exp_max, '█', '░'))
	table.insert(lines, string.format('%d / %d EXP', exp_cur, exp_max))
	table.insert(lines, sep)

	-- 三属性
	table.insert(lines, '⚔️ 属性')
	table.insert(lines, string.format('⚡迅捷：%s  🎯精准：%s  📚博学：%s', attr_spd, attr_acc, attr_learn))
	table.insert(lines, sep)

	-- 今日状态
	table.insert(lines, '💬 今日状态  ' .. state)
	table.insert(lines, sep)

	-- 生涯累计
	table.insert(lines, string.format('📖 累计输入  %d 字', career_total))
	table.insert(lines, string.format('🌱 已掌握生词  %d 个', word_count))
	table.insert(lines, sep)

	table.insert(lines, string.format('%s %s%s × %s', getDeviceType(), softwareDisplayName(), softwareDisplayVersion(), schema_name))
	table.insert(lines, '📜 脚本：咩₂₀₂₆0612')

	if quoteCnt > 0 then
		local q = quotes[math.floor(math.random() * quoteCnt) + 1]
		if q and #q > 0 then
			table.insert(lines, sep)
			for _, ln in ipairs(wrapByWidth('『' .. q .. '』', quoteLineWidth)) do
				table.insert(lines, ln)
			end
		end
	end

	return table.concat(lines, '\n')
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- 通用入口：根据 reportStyle 分派
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
local function format_period_summary(s, label, empty_msg)
	if reportStyle == 1 then
		return format_long(s, label, empty_msg)
	else
		return format_short(s, label, empty_msg)
	end
end
local function format_daily_summary()
	return format_period_summary(input_stats.daily, "日统计", "🌱 今天还没开始打字哦，加油！")
end

-- 显示函数（周统计）
local function format_weekly_summary()
	return format_period_summary(input_stats.weekly, "周统计", "🌸 本周还没有记录，快来打字吧～")
end

-- 显示函数（月统计）
local function format_monthly_summary()
	return format_period_summary(input_stats.monthly, "月统计", "🌷 这个月还没有记录哦～")
end

-- 显示函数（年统计）
local function format_yearly_summary()
	return format_period_summary(input_stats.yearly, "年统计", "✨ 今年还没有记录，元气满满出发！")
end

-- 显示记录的生字/词
local function format_shengzi()
	if input_stats.newWords == nil or input_stats.newWords.words == nil then
		return "🌱 暂时没有生字词记录哦，继续加油～"
	end

	local newWords = {}
	for k, v in pairs(input_stats.newWords.words) do
		table.insert(newWords, k)
	end
	local wordsCnt = #newWords
	if wordsCnt < 1 then
		return "🌱 暂时没有生字词记录哦，继续加油～"
	end

	local tmpTable = {}
	tmpTable[1] = embedTextIntoSplitor('🌸 生字/词本 💕')
	tmpTable[2] = ''
	if input_stats.newWords.startTime and input_stats.newWords.startTime > 0 then
		tmpTable[2] = os.date("自 %Y/%m/%d %H:%M:%S 以来，", input_stats.newWords.startTime)
	end
	tmpTable[3] = string.format("共记录到生字/词 %d 个", wordsCnt)
	tmpTable[4] = splitor
	tmpTable[5] = table.concat(newWords, '，')
	tmpTable[6] = splitor

	return trim(table.concat(tmpTable, '\n'):gsub("\n+", "\n"):gsub("^%n", ""):gsub("%n$", ""))
end

-- 加载保存的统计数据（input_stats.lua）
-- 清洗历史脏数据：
--   ① 探针/机器速度留下的 >400 字/分记录；
--   ② v0.3.27 及以前把「挂着候选窗发呆」的时长（可达数小时）也算进本轮，
--      平均分速被拖到 1 字/分。这里按同一套口径（0.3s~每字3s、≤400 字/分）重筛，
--      并顺手把无限增长的数组截到最近 120 个样本。
local function sanitize_period(p)
	if type(p) ~= "table" then return end
	if type(p.fastest) == "table" and (p.fastest.spd or 0) > 400 then
		p.fastest.spd, p.fastest.keyTouchSpd, p.fastest.avgCodeLen = 0, 0, 0
	end

	-- 新口径存档（带累计和）：数组只是尾部窗口，不能按数组重算总和，
	-- 否则每次启动都会把「全周期平均」退化成「最近 120 个样本的滑动平均」。
	if type(p.avgGapSum) == "number" and type(p.avgCntSum) == "number" then
		p.avgGaps = trim_tail(type(p.avgGaps) == "table" and p.avgGaps or {}, AVG_TAIL_KEEP)
		p.avgCnts = trim_tail(type(p.avgCnts) == "table" and p.avgCnts or {}, AVG_TAIL_KEEP)
		p.avgCodeLen = trim_tail(type(p.avgCodeLen) == "table" and p.avgCodeLen or {}, AVG_TAIL_KEEP)
		return
	end

	-- 旧存档：没有累计和，只能逐样本重筛并重算
	local gaps, cnts, lens = {}, {}, {}
	local gapSum, cntSum, codeSum = 0, 0, 0
	if type(p.avgGaps) == "table" then
		local oldCnts = type(p.avgCnts) == "table" and p.avgCnts or {}
		local oldLens = type(p.avgCodeLen) == "table" and p.avgCodeLen or {}
		for i = 1, #p.avgGaps do
			local gap = tonumber(p.avgGaps[i]) or 0
			local cnt = tonumber(oldCnts[i]) or 0
			local code = tonumber(oldLens[i]) or 0
			if gap >= MIN_SAMPLE_S and valid_sample(gap, cnt) then
				gaps[#gaps + 1] = gap
				cnts[#cnts + 1] = cnt
				lens[#lens + 1] = code
				gapSum = gapSum + gap
				cntSum = cntSum + cnt
				codeSum = codeSum + code
			end
		end
	end
	p.avgGaps = trim_tail(gaps, AVG_TAIL_KEEP)
	p.avgCnts = trim_tail(cnts, AVG_TAIL_KEEP)
	p.avgCodeLen = trim_tail(lens, AVG_TAIL_KEEP)
	p.avgGapSum, p.avgCntSum, p.avgCodeSum = gapSum, cntSum, codeSum
end

local function sanitize_stats()
	for _, key in ipairs({ "daily", "weekly", "monthly", "yearly" }) do
		sanitize_period(input_stats[key])
	end
end

local function load_stats_from_lua_file(schema_id)
	local path = rime_api.get_user_data_dir() .. "/lua/input_stats_" .. schema_id .. ".lua"
	local ok, result = pcall(function()
		local env = {}
		local f = loadfile(path, "t", env)
		if f then f() end
		return env.input_stats
	end)
	if ok and type(result) == "table" then
		input_stats = result
	end

	-- 如果log的版本过低，则更新 input_stats 结构
	if nil == input_stats.logVer or input_stats.logVer < verOfStatsFormat then
		local int1 = 21
		local int2 = 21
		local deviceType = ''
		if nil ~= input_stats.progressBarSkinIdx_word then
			int1 = input_stats.progressBarSkinIdx_word
			int2 = input_stats.progressBarSkinIdx_code
		end
		if nil ~= input_stats.deviceType then
			deviceType = input_stats.deviceType
		end

		input_stats = {
			daily = { count = 0, length = 0, fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }, ts = 0, lengths = {}, codeLengths = {}, avgGaps = {}, avgCnts = {}, avgCodeLen = {}, keyTouchCnt = 0, totalCodeLenWithoutSpace = 0 },
			weekly = { count = 0, length = 0, fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }, ts = 0, lengths = {}, codeLengths = {}, avgGaps = {}, avgCnts = {}, avgCodeLen = {}, keyTouchCnt = 0, totalCodeLenWithoutSpace = 0 },
			monthly = { count = 0, length = 0, fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }, ts = 0, lengths = {}, codeLengths = {}, avgGaps = {}, avgCnts = {}, avgCodeLen = {}, keyTouchCnt = 0, totalCodeLenWithoutSpace = 0 },
			yearly = { count = 0, length = 0, fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }, ts = 0, lengths = {}, codeLengths = {}, avgGaps = {}, avgCnts = {}, avgCodeLen = {}, keyTouchCnt = 0, totalCodeLenWithoutSpace = 0 },
			logVer = verOfStatsFormat,
			daily_max = 0,
			newWords = { startTime = 0, words = {} },
			deviceType = deviceType,
			progressBarSkinIdx_word = int1,
			progressBarSkinIdx_code = int2
		}
	end

	-- v0.3.28：生词判定里的毫秒/秒混用已修复。旧存档中的「生字词」是每次上屏都记的
	-- 脏数据（「的」「我们」这类常用词也在里面），清空一次，避免面板显示「已掌握生词 2400 个」。
	if (input_stats.wordsFix or 0) < 1 then
		input_stats.newWords = { startTime = 0, words = {} }
		input_stats.wordsFix = 1
	end

	-- v0.3.28：旧口径把上屏用的空格/回车也算进击键，于是「误触」每上屏一次就多一次
	-- （实测 37%，真正的手误没有这么多）。按上屏次数扣掉这部分；自动顶屏的方案
	-- 不满足 keyTouch >= 上屏次数 + 码长 就不动，避免扣成负值。
	if (input_stats.keysFix or 0) < 1 then
		for _, key in ipairs({ "daily", "weekly", "monthly", "yearly" }) do
			local p = input_stats[key]
			if type(p) == "table" and (p.keyTouchCnt or 0) >= (p.count or 0) + (p.totalCodeLenWithoutSpace or 0) then
				p.keyTouchCnt = p.keyTouchCnt - p.count
			end
		end
		input_stats.keysFix = 1
	end

	-- 识别设备类型
	input_stats.deviceType = getDeviceType()
end

-- 翻译器：处理统计命令
local function translator(input, seg, env)
	-- 计时统一用毫秒；旧代码这里用 os.time()，与 commit_unit 的毫秒时间戳混用，
	-- 导致生词判定的间隔永远是天文数字（每个词都被当成生词）。
	local timeNow = now_ms()
	if timeNow - avgSpdInfo.clickTime > avgSpdInfo.gapThd * 1000 then
		-- 如果距离上次按键超时了，即输入已经中断，这是重新开始的输入行为
		-- （上一轮的统计已由 commit_unit 结算，这里只重置计时锚点）
		avgSpdInfo.startTime = timeNow
		avgSpdInfo.commitTime = timeNow
	end
	avgSpdInfo.clickTime = timeNow

	lastCode = input

	if input:sub(1, 1) ~= "/" then
		lastCode = input
		return
	else
		-- 如果输入是以/引导的，则不检测是否回改
		lastCode = ''
	end

	local summary = ""
	local avgAvailable = 0
	if avgSpdInfo.commitTime - avgSpdInfo.startTime >= 1000 and avgSpdInfo.count > 0 then avgAvailable = 1 end

	if reportCommands[input] then
		if avgAvailable == 1 then -- 如果此时已经有统计数据，则记录该统计数据
			-- 上屏单元已由 capture_history 结算
			-- 清除计时
			avgSpdInfo.startTime = timeNow
			avgSpdInfo.commitTime = timeNow
		end

		if #input > 1 then
			if input:sub(-2,-2) == input:sub(-1,-1) then
				reportStyle = 1  -- 长版
			else
				reportStyle = 0  -- 短版
			end
		end

		if ({ ['📱'] = true, ['💻'] = true })[input_stats.deviceType] then
			if ({['//1'] = true, ['/rtj'] = true, ['//11'] = true, ['/rtjj'] = true})[input] then
				summary = format_daily_summary()
			elseif ({['//2'] = true, ['/ztj'] = true, ['//22'] = true, ['/ztjj'] = true})[input] then
				summary = format_weekly_summary()
			elseif ({['//3'] = true, ['/ytj'] = true, ['//33'] = true, ['/ytjj'] = true})[input] then
				summary = format_monthly_summary()
			elseif ({['//4'] = true, ['/ntj'] = true, ['//44'] = true, ['/ntjj'] = true})[input] then
				summary = format_yearly_summary()
			else
				summary = '🌸 没认出这个指令呢，再看看使用说明吧～'
			end
		else
			summary = '🌷 设备类型识别失败，请手动设置 deviceType 后重新部署哦～'
		end
	elseif input == "//5" or input == "/sztj" then
		if avgAvailable == 1 then -- 如果此时已经有统计数据，则记录该统计数据
			-- 上屏单元已由 capture_history 结算

			-- 清除计时
			avgSpdInfo.startTime = timeNow
			avgSpdInfo.commitTime = timeNow
		end
		summary = format_shengzi()
	elseif input == "//07" or input == "/qcjs" then
		input_stats.daily.fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }
		input_stats.weekly.fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }
		input_stats.monthly.fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }
		input_stats.yearly.fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }
		save_stats(env.engine.schema.schema_id)
		summary = '⚡ 极速记录已清空，重新冲鸭！🌸'
	elseif input == "//08" or input == "/qcsz" then
		input_stats.newWords = { startTime = 0, words = {} }
		save_stats(env.engine.schema.schema_id)
		summary = "🌱 生字词本已清空，重新记录吧～"
	elseif input == "//09" or input == "/qctj" then
		local int1 = input_stats.progressBarSkinIdx_code
		local int2 = input_stats.progressBarSkinIdx_word
		local deviceType = input_stats.deviceType
		local logV = input_stats.logVer
		-- ♡ 保留生涯数据不重置
		local savedCareer = input_stats.career or { total = 0 }
		keyTouchCnt = 0
		lastCode = 0
		input_stats = {
			daily = { count = 0, length = 0, fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }, ts = 0, lengths = {}, codeLengths = {}, avgGaps = {}, avgCnts = {}, avgCodeLen = {}, keyTouchCnt = 0, totalCodeLenWithoutSpace = 0 },
			weekly = { count = 0, length = 0, fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }, ts = 0, lengths = {}, codeLengths = {}, avgGaps = {}, avgCnts = {}, avgCodeLen = {}, keyTouchCnt = 0, totalCodeLenWithoutSpace = 0 },
			monthly = { count = 0, length = 0, fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }, ts = 0, lengths = {}, codeLengths = {}, avgGaps = {}, avgCnts = {}, avgCodeLen = {}, keyTouchCnt = 0, totalCodeLenWithoutSpace = 0 },
			yearly = { count = 0, length = 0, fastest = { spd = 0, keyTouchSpd = 0, avgCodeLen = 0 }, ts = 0, lengths = {}, codeLengths = {}, avgGaps = {}, avgCnts = {}, avgCodeLen = {}, keyTouchCnt = 0, totalCodeLenWithoutSpace = 0 },
			logVer = logV,
			daily_max = 0,
			newWords = { startTime = 0, words = {} },
			deviceType = deviceType,
			progressBarSkinIdx_word = 1,
			progressBarSkinIdx_code = 1,
			career = savedCareer,
			-- 迁移标记要跟着走：否则下次启动会把新口径的数据再「修」一次（误触被重复扣减）
			wordsFix = input_stats.wordsFix or 1,
			keysFix = input_stats.keysFix or 1
		}
		input_stats.progressBarSkinIdx_code = int1
		input_stats.progressBarSkinIdx_word = int2
		save_stats(env.engine.schema.schema_id)

		avgSpdInfo.count = 0
		avgSpdInfo.codeLen = 0

		summary = "🌸 统计数据已清空啦～ 生涯段位保留哦 💗"
	elseif input == "//6" or input == "/scj" then -- ♡ 查看生涯段位
		local career_total = (input_stats.career and input_stats.career.total) or 0
		local rank_title, lv, exp_cur, exp_max = get_career_level(career_total)
		local realm = get_realm(career_total)
		local word_count = 0
		if input_stats.newWords and input_stats.newWords.words then
			for _ in pairs(input_stats.newWords.words) do word_count = word_count + 1 end
		end
		summary = string.format(
			"🎮 码道修行\n境界：%s\n%s  Lv.%d\n%s\n%d / %d EXP\n📚博学：%s  累计生词 %d 个\n✨ 累计输入：%d 字",
			realm, rank_title, lv,
			exp_bar(exp_cur, exp_max, '█', '░'),
			exp_cur, exp_max,
			get_attr_learning(word_count), word_count,
			career_total
		)
	elseif ({ ['//6'] = true, ['/pf'] = true })[input:sub(1, 3)] or ({ ['/pfw'] = true, ['/pfc'] = true, ['/hfw'] = true, ['/hfc'] = true })[input:sub(1, 4)] then
		if (input == "//60") or (input == "/pf") then -- 展示皮肤列表
			summary = formatSkinList()
		elseif input:match("^//6(%d%d)1$") then -- 设置字词统计皮肤
			local skinIndex = tonumber(input:match("^//6(%d%d)1$"))
			if skinIndex and skinIndex >= 1 and skinIndex <= #skinList then
				input_stats.progressBarSkinIdx_word = skinIndex
				progressBarField_word = skinList[input_stats.progressBarSkinIdx_word].field
				progressBarEmpty_word = skinList[input_stats.progressBarSkinIdx_word].empty
				summary = string.format("🎀 字词皮肤已换成 //6%02d1 → %s%s  可爱吧～",
					skinIndex, progressBarField_word, progressBarEmpty_word)

				save_stats(env.engine.schema.schema_id)
			else
				summary = "🌸 没有这个皮肤编号哦：〔" .. input:sub(4, 5) .. '〕'
			end
		elseif input:match("^//6(%d%d)2$") then -- 设置码长统计皮肤
			local skinIndex = tonumber(input:match("^//6(%d%d)2$"))
			if skinIndex and skinIndex >= 1 and skinIndex <= #skinList then
				input_stats.progressBarSkinIdx_code = skinIndex
				progressBarField_code = skinList[input_stats.progressBarSkinIdx_code].field
				progressBarEmpty_code = skinList[input_stats.progressBarSkinIdx_code].empty
				summary = string.format("🎀 码长皮肤已换成 //6%02d2 → %s%s  喜欢吗～",
					skinIndex, progressBarField_code, progressBarEmpty_code)

				save_stats(env.engine.schema.schema_id)
			else
				summary = "🌸 没有这个皮肤编号哦：〔" .. input:sub(4, 5) .. '〕'
			end
		elseif input:match("^/[hp]fw[a-z][a-z]$") then -- 设置字词统计皮肤
			local skinIndex = (string.byte(input:sub(5, 5)) - 97) * 10 + string.byte(input:sub(6, 6)) - 97
			if skinIndex and skinIndex >= 1 and skinIndex <= #skinList then
				input_stats.progressBarSkinIdx_word = skinIndex
				progressBarField_word = skinList[input_stats.progressBarSkinIdx_word].field
				progressBarEmpty_word = skinList[input_stats.progressBarSkinIdx_word].empty
				summary = string.format("🎀 字词皮肤已换成 /[ph]fw%s → %s%s  可爱吧～",
					input:sub(5, 6), progressBarField_word, progressBarEmpty_word)

				save_stats(env.engine.schema.schema_id)
			else
				summary = "🌸 没有这个皮肤编号哦：〔" .. input:sub(5, 6) .. '〕'
			end
		elseif input:match("^/[hp]fc[a-z][a-z]$") then -- 设置码长统计皮肤
			local skinIndex = (string.byte(input:sub(5, 5)) - 97) * 10 + string.byte(input:sub(6, 6)) - 97
			if skinIndex and skinIndex >= 1 and skinIndex <= #skinList then
				input_stats.progressBarSkinIdx_code = skinIndex
				progressBarField_code = skinList[input_stats.progressBarSkinIdx_code].field
				progressBarEmpty_code = skinList[input_stats.progressBarSkinIdx_code].empty
				summary = string.format("🎀 码长皮肤已换成 /[ph]fc%s → %s%s  喜欢吗～",
					input:sub(5, 6), progressBarField_code, progressBarEmpty_code)

				save_stats(env.engine.schema.schema_id)
			else
				summary = "🌸 没有这个皮肤编号哦：〔" .. input:sub(5, 6) .. '〕'
			end
		end
	end

	if summary ~= "" then
		summary = summary:gsub("\n", "\r\n")
		yield(Candidate("stat", seg.start, seg._end, summary, ""))
	end
end

-- 加载文档里的短语短句
local function quoteLoad()
	local quoteFile = currentDir() .. "/quote.txt"

	local lines = files_to_lines(quoteFile)
	for i, line in next, lines do
		table.insert(quotes, line)
		quoteCnt = quoteCnt + 1
	end
end

local function commit_unit(env, chars, text)
	if chars <= 0 then return end
	if type(input_stats.newWords) ~= "table" then
		input_stats.newWords = { startTime = 0, words = {} }
	end
	if type(input_stats.newWords.words) ~= "table" then
		input_stats.newWords.words = {}
	end
	local now = now_ms()
	local start = round_start_ts or now
	local keys, code = proc_keys, proc_code
	-- 生词判定：距上一次上屏的真实间隔（毫秒）。
	-- 旧代码写成 now(ms) - avgSpdInfo.commitTime(s)，间隔恒为 1e12 级，
	-- 于是每个上屏都被记成生词（用户的生词本一度涨到 2400 多个）。
	local gap = last_commit_ms and (now - last_commit_ms) or 0
	if last_commit_ms and gap >= BOGGLE_MS then
		if not input_stats.newWords.startTime or input_stats.newWords.startTime < 1
			or #input_stats.newWords.words < 1 then
			-- startTime 是给 os.date() 显示的，必须是秒
			input_stats.newWords.startTime = os.time()
		end
		input_stats.newWords.words[text] = 1
	else
		input_stats.newWords.words[text] = nil
	end
	last_commit_ms = now
	-- avgSpdInfo 全程用毫秒（与 now_ms 一致），落盘时才换成秒
	avgSpdInfo.startTime = start
	avgSpdInfo.commitTime = now
	avgSpdInfo.count = chars
	avgSpdInfo.codeLen = code
	keyTouchCnt = keys
	update_stats(chars, code, code, 1)
	request_save(env.engine.schema.schema_id, false)
	reset_round()
end

local function capture_history(env)
	local ok, tbl = pcall(function()
		return env.engine.context.commit_history:to_table()
	end)
	if not ok or type(tbl) ~= "table" then return end
	local sig = {}
	for i = 1, #tbl do
		sig[i] = tostring(tbl[i].type) .. "\0" .. tostring(tbl[i].text)
	end
	local prev = capture_snapshot
	capture_snapshot = sig
	if not prev then return end
	local n, m = #sig, #prev
	local overlap = 0
	for j = math.min(n, m), 0, -1 do
		local match = true
		for i = 1, j do
			if prev[m - j + i] ~= sig[i] then match = false break end
		end
		if match then overlap = j break end
	end
	local added = n - overlap
	if added <= 0 then return end
	-- 历史被重置/异常批量插入：无法判断归属，清空本轮计键，绝不把旧键算到下一次上屏
	if added > 8 then
		reset_round()
		return
	end

	local unit_chars, unit_text, saw_final = 0, nil, false
	for i = overlap + 1, n do
		local r = tbl[i]
		local text = r.text or ""
		if text ~= "" and text:sub(1, 1) ~= "/" and r.type ~= "stat" then
			local count = utf8.len(text) or #text
			if r.type == "raw" then
				-- 提前上屏的片段：先攒着，并入其后的正式提交
				if isAllChineseCharacter(text) then
					pending_raw_chars = pending_raw_chars + count
				end
			elseif r.type ~= "punct" then
				-- punct 是句中标点，不算上屏单元，也不打断本轮计键；
				-- 其余（sentence/phrase/thru/…）都是一次正式提交。
				saw_final = true
				if isAllChineseCharacter(text) then
					unit_chars = unit_chars + pending_raw_chars + count
					pending_raw_chars = 0
					unit_text = text
				end
			end
		end
	end

	if unit_chars > 0 then
		commit_unit(env, unit_chars, unit_text)
	elseif saw_final then
		-- 非汉字上屏（英文/编码/数字）也算一次「上屏」，刷新卡壳基准，
		-- 否则打完一段英文再打中文，会被误判成「想了很久的新词」。
		last_commit_ms = now_ms()
	end
	-- 这一批里出现了正式提交（不论是不是汉字）：本轮结束。
	-- 旧代码只在汉字上屏时结算，英文/数字/编码上屏的按键会一直攒到下一次汉字上屏，
	-- 既把码长算大，也把中间的发呆算进打字时间。
	if saw_final and not env.engine.context:is_composing() then
		reset_round()
	end
end

local function processor(key_event, env)
	if key_event:release() then return 2 end
	-- 统计指令（//1、/qctj 等）的按键不计入击键/码长：以 / 开头的输入整段跳过
	local ctx = env.engine.context
	local inp = ctx.input or ""
	if inp:sub(1, 1) == "/" then return 2 end
	if key_event:repr() == "/" and not ctx:is_composing() then return 2 end
	if key_event:ctrl() or key_event:alt() or key_event:super() then return 2 end
	local kc = key_event.keycode
	if kc == 0 then return 2 end

	local now = now_ms()
	-- 两次按键间隔超过 gapThd：视为新一轮开始，本轮计时从这一键算起。
	-- 否则「打一半去接水再回来上屏」的十分钟会整段算进平均速度。
	if not round_active or (last_key_ts and now - last_key_ts > avgSpdInfo.gapThd * 1000) then
		round_start_ts = now
		round_active = true
	end
	last_key_ts = now

	-- 按键分类（旧代码把所有可打印键都当编码键）：
	--   编码键 = 字母/符号（不含数字）→ 计击键 + 码长
	--   退格/Esc/Delete            → 计击键，不计码长（这就是「误触」的来源）
	--   空格/回车/Tab、数字选重     → 都不计（上屏键和选重键不是打字成本）
	local is_commit_key = (kc == 0x20 or kc == 0x0d or kc == 0xff0d or kc == 0xff09)
	local is_edit_key = (kc == 0xff08 or kc == 0x08 or kc == 0x7f or kc == 0xffff or kc == 0x1b)
	local is_digit = (kc >= 0x30 and kc <= 0x39)
	local is_code_key = (kc >= 0x21 and kc <= 0x7e) and not is_digit and not is_commit_key
	if is_code_key then
		proc_keys = proc_keys + 1
		proc_code = proc_code + 1
	elseif is_edit_key then
		proc_keys = proc_keys + 1
	end
	return 2
end

local function init(env)
	schema_name = env.engine.schema.schema_name or '未知'
	-- 模块可能被多个方案/多个引擎复用（require 有缓存），初始化时先把上一轮的状态清干净
	reset_round()
	last_commit_ms = nil
	capture_snapshot = nil
	keyTouchCnt = 0
	avgSpdInfo.startTime, avgSpdInfo.commitTime = 0, 0
	avgSpdInfo.clickTime, avgSpdInfo.count, avgSpdInfo.codeLen = 0, 0, 0

	-- 加载指定输入方案的历史统计数据
	load_stats_from_lua_file(env.engine.schema.schema_id)
	sanitize_stats()
	-- 清洗/迁移结果立即落盘：旧存档 1MB+ 的数组、被污染的 2400 个生词都要马上收掉
	pcall(function() save_stats(env.engine.schema.schema_id) end)
	save_dirty, last_save_time = false, os.time()
	-- 更新皮肤
	progressBarField_word = skinList[input_stats.progressBarSkinIdx_word].field
	progressBarEmpty_word = skinList[input_stats.progressBarSkinIdx_word].empty
	progressBarField_code = skinList[input_stats.progressBarSkinIdx_code].field
	progressBarEmpty_code = skinList[input_stats.progressBarSkinIdx_code].empty
	-- 加载名人名言
	quoteLoad()

	-- 初始化随机数种子
	math.randomseed(os.time())

	-- 注册提交通知回调
	env.notifier = env.engine.context.commit_notifier:connect(function(ctx)
		capture_history(env)
	end)
	env._cap_len = 0
	env.update_notifier = env.engine.context.update_notifier:connect(function(ctx)
		-- 只在输入变短（提前上屏/回删）或组合结束时扫描历史；普通打字每键都在变长，
		-- 每键都 to_table() 会制造大量临时表，间接抬高插件全量 GC 的成本。
		local len = #(ctx.input or "")
		if ctx:is_composing() and len >= (env._cap_len or 0) then
			env._cap_len = len
			return
		end
		env._cap_len = len
		capture_history(env)
	end)
	capture_history(env)
end
function finit(env)
	if env.notifier then
		env.notifier:disconnect()
		env.notifier = nil
	end
	if env.update_notifier then
		env.update_notifier:disconnect()
		env.update_notifier = nil
	end
	-- 正常退出（卸载环境/切方案）时把尚未节流落盘的统计补写，不丢数据
	flush_save(env.engine.schema.schema_id)
	reset_round()
	last_commit_ms = nil
end

return { init = init, fini = finit, func = translator, processor = processor }
