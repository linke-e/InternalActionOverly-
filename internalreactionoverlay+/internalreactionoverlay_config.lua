-- ============================================================
--  InternalReactionOverlay+ —— 配置文件
--  本文件被 main.lua 通过 require("internalreactionoverlay_config") 加载。
--  所有可调参数集中在此，修改配置无需改动 main.lua 逻辑。
--  适用：以撒的结合：忏悔+ (Repentance+)
--  参考：IsaacDocs (https://wofsauge.github.io/IsaacDocs/rep/)
-- ============================================================

-- ---------------------------------------------------------
--  桌宠角色素材池
--  素材目录：resources/gfx/pets/<角色名>/（一个角色一个文件夹，最多 5 个）
--    pets/<角色名>/main.png、main_sad.png   常态/半血静态单帧
--    pets/<角色名>/<动画键>/xxx_000.png     每个动画一个子文件夹
--  可用角色列表由 gen_anim.py 扫描生成（internalreactionoverlay_frames.lua），
--  新增角色文件夹后重新运行 python gen_anim.py 即可。
-- ---------------------------------------------------------

-- ---------------------------------------------------------
--  配置区（按需修改）
-- ---------------------------------------------------------
local config = {
    -- 当前使用的桌宠角色（素材池中的文件夹名）。
    -- 也可在游戏内 Mod Config Menu 的「桌宠角色」页切换（会存入存档）。
    activePet = "Angle",
    -- 当前角色缺少某动画时，是否按素材池顺序回退到其它角色的同名动画
    -- （关闭后缺就缺，对应功能自动禁用）
    petFallback = true,

    -- 动画帧模板 anm2（1 帧 256×256；运行时用 ReplaceSpritesheet 换成各帧 PNG）
    frameTemplateAnm2 = "gfx/overlay_frame_template.anm2",
    -- 动画播放速度（渲染帧/秒；游戏渲染 60fps）
    -- 未在 animHold 中单独指定的动画使用此值：
    -- 15fps = 每 4 渲染帧换 1 帧
    animFps = 15,
    -- 全局动画速度倍率：>1 加速、<1 减速，作用在 animFps 与 animHold 之上
    -- （实际每帧停留 = 原停留 / animSpeed，最小 1 渲染帧）
    animSpeed = 1.0,

    -- 按动画键单独设置【每帧停留的渲染帧数】（60 帧 ≈ 1 秒）。
    -- 动画帧数很少（2~18 帧），统一 fps 会让短动画一闪而过，
    -- 这里按帧数调慢，使每个动画总时长约 1 秒左右。
    -- 键与各角色的动画文件夹名一致；未列出的用 animFps 兜底。
    -- （ animSpeed 不为 1 时，实际停留 = 此值 / animSpeed ）
    animHold = {                    --每个动画帧渲染多少个游戏帧
        activity  = 18,  -- 5 帧
        Medicine   = 18,  -- 5 帧
        wink      = 45,  -- 2 帧
        wink1     = 45,  -- 2 帧
        boss      = 45,  -- 2 帧
        bad       = 45,  -- 2 帧
        item2     = 18,  -- 5 帧
        idle2     = 15,  -- 6 帧
        idle4     = 30,  -- 3 帧
        idle3     = 11,   -- 8 帧
        idle1     = 45,  -- 2 帧
        item0     = 6,   -- 15 帧
        item1     = 18,  -- 5 帧
        item3     = 15,  -- 6 帧
        item4     = 22,   -- 8 帧
        half      = 9,   -- 10 帧
        hurt      = 30,  -- 3 帧
    },
    -- 所有动画帧均为 256×256
    frameSize = 256,

    -- 图片缩放倍数：1.0 = 原始分辨率(256px)。定位/贴边均按缩放后实际尺寸计算。
    scale = 0.5,
    -- 水平偏移(像素)：正=图向右移(距左边缘更远)，负=图向左移(可超出左边缘)。
    margin = -50,
    -- 垂直偏移(像素)：正=上移(距底更远)，负=下移(超出屏幕底)，0=贴底。
    offsetY = -30,

    -- ---------------------------------------------------------
    --  主动画：回到 main 状态时循环播放的动画。
    --  entries 每项：{ key = 动画键, weight = 权重 }
    --  动画键定义见各角色素材文件夹（internalreactionoverlay_frames.lua）。
    --  满血：静态贴图 main.png（main_static）。
    --  半血（总血量<=半颗心）：半血事件动画（half）播放完回
    --  main 后，常态贴图切换为 sadStatic（main_sad.png）。
    -- ---------------------------------------------------------
    main = {
        entries = {
            { key = "main_static", weight = 1 },  -- main.png 单帧静态（满血）
        },
        sadStatic = "main_sad",   -- 半血常态贴图（main_sad.png 单帧）
    },

    -- ---------------------------------------------------------
    --  眨眼循环：main 状态（无事件）下循环眨眼，播完等待后眨下一次。
    --  满血：眨眼动画 wink；半血：眨眼动画 wink1。
    --  眨眼频率（每档可选两种模式）：
    --    mode = "random" —— 每次眨眼后随机等待 delayMin~delayMax 秒
    --    mode = "fixed"  —— 每两次眨眼之间固定等待 delayFixed 秒
    --  （半血用 sadMode/sadDelayMin/sadDelayMax/sadDelayFixed）
    -- ---------------------------------------------------------
    wink = {
        enabled = true,     -- 眨眼循环总开关
        animKey = "wink",   -- 满血眨眼动画（2 帧）
        mode = "random",    -- 满血眨眼模式：random / fixed
        delayMin = 3,       -- 满血 random：间隔最小值（秒）
        delayMax = 5,       -- 满血 random：间隔最大值（秒）
        delayFixed = 4,     -- 满血 fixed：固定间隔（秒）
        sadAnimKey = "wink1",   -- 半血眨眼动画（2 帧）
        sadMode = "random",     -- 半血眨眼模式：random / fixed
        sadDelayMin = 3,        -- 半血 random：间隔最小值（秒）
        sadDelayMax = 7,        -- 半血 random：间隔最大值（秒）
        sadDelayFixed = 5,      -- 半血 fixed：固定间隔（秒）
    },

    -- ---------------------------------------------------------
    --  待机动画：处于 main 状态（无任何事件）时，偶尔随机触发。
    --  逻辑：连续 main 满 minMainTime 帧后，每秒按 triggerChancePerSec
    --        概率随机挑一个待机动画播放一遍，播完回到 main。
    --  注意：TangTang 等角色若有多余的 idle5 等素材，想启用就在
    --        entries 里加 { key = "idle5", weight = 2 }。
    -- ---------------------------------------------------------
    idle = {
        minMainTime = 600,           -- 连续 main 满 10 秒(600 帧@60fps)才开始
        triggerChancePerSec = 0.30,  -- 每秒触发概率（30%）
        entries = {
            { key = "idle1", weight = 5 },  -- 待机①
            { key = "idle2", weight = 3 },  -- 待机②
            { key = "idle3", weight = 2 },  -- 待机③
            { key = "idle4", weight = 2 },  -- 待机④
        },
    },

    -- ---------------------------------------------------------
    --  道具质量事件：当前房间存在未拾取道具时，按其【最高质量】播放
    --  item0~item4 动画（依赖 ReactionAPI 提供房间道具质量检测）。
    --  质量映射：Quality 0->item0, 1->item1, 2->item2, 3->item3, 4->item4。
    --  高等级道具优先：房间同时有 2 级与 4 级道具时只播放 item4。
    --  依赖：ReactionAPI 已安装（reactionapi_3096181411）。
    -- ---------------------------------------------------------
    itemQuality = {
        enabled = true,          -- 总开关（ReactionAPI 未加载时自动失效）
        -- 播放模式：once = 检测到质量变化时播一遍回 main
        --            loop = 房间存在道具期间持续循环播放（质量变化时切换动画）
        mode = "once",
        -- 播放不打断：item 动画一旦开始播放，直到播完为止；
        -- 期间不响应受击/卡牌等更高优先级事件（它们顺延到动画结束后再响应）。
        -- 仅配合 once 模式使用。
        lock = true,
        -- 进新房后的道具质量检测冷却帧数：房间切换瞬间 ReactionAPI 可能
        -- 短暂返回上一房间的残留道具质量，导致空房也重复播放一次 item 动画；
        -- 冷却期内忽略道具质量检测（默认 30 渲染帧 ≈ 0.5 秒）。
        graceFrames = 30,
        animKeys = {
            [0] = "item0",   -- Quality 0 道具
            [1] = "item1",   -- Quality 1 道具
            [2] = "item2",   -- Quality 2 道具
            [3] = "item3",   -- Quality 3 道具
            [4] = "item4",   -- Quality 4 道具
        },
    },

    -- ---------------------------------------------------------
    --  受击动画：角色受到指定类型伤害时播放 hurt 动画。
    --  触发条件：伤害 DamageFlag 与下方任一标志匹配（按位与）。
    --  伤害类型参考：https://cuerzor.github.io/IsaacDocs/rep/enums/DamageFlag.html
    -- ---------------------------------------------------------
    hurt = {
        duration = 90,   -- 受击状态持续时间（渲染帧；hurt 动画约 1 秒，留余量）
        -- 非惩罚性伤害（带 DamageFlag.DAMAGE_NO_PENALTIES，不扣恶魔房概率等惩罚）
        -- 不触发受击动画
        ignoreNoPenalties = true,
        -- 怪物伤害：角色受到来自怪物的攻击（本体接触/爪击/敌方弹幕/激光/怪物炸弹）
        -- 也触发受击动画（判定决策树见 main.lua mod:IsMonsterDamage）
        monsterDamage = true,
        damageFlags = {
            DamageFlag.DAMAGE_FIRE,          -- 火焰伤害（壁炉等）
            DamageFlag.DAMAGE_EXPLOSION,     -- 爆炸伤害
            DamageFlag.DAMAGE_LASER,         -- 激光伤害
            DamageFlag.DAMAGE_ACID,          -- 酸液伤害
            DamageFlag.DAMAGE_SPIKES,        -- 尖刺伤害
            DamageFlag.DAMAGE_POOP,          -- 红屎伤害
            DamageFlag.DAMAGE_TNT,           -- TNT 桶伤害
            DamageFlag.DAMAGE_POISON_BURN,   -- 中毒/燃烧伤害
            DamageFlag.DAMAGE_PITFALL,       -- 塌陷坑洞伤害
        },
    },

    -- ---------------------------------------------------------
    --  事件 → 动画映射。
    --  每项两种写法：
    --    * { key = "动画键" }                     —— 固定动画
    --    * { variants = { {key=...,weight=...}, ... } } —— 按权重随机选一个
    --
    --  播放规则见下方 playback。
    -- ---------------------------------------------------------
    events = {
        active   = { key = "activity" },           -- 使用主动/副主动道具
        boss     = { key = "boss" },               -- Boss 场景
        half     = { key = "half" },               -- 半血/半残
        hurt     = { key = "hurt" },               -- 受击（伤害类型见 hurt.damageFlags）
        cardpill = { key = "Medicine" },           -- 使用卡牌/药丸
        item     = { key = "item_auto" },          -- 道具质量：动态选择 item0~item4（见 itemQuality）
    },

    -- ---------------------------------------------------------
    --  播放模式（除 main 外全部只播放一遍 once，播完回 main）：
    --    once = 播放一遍后回到 main。
    --  说明：Boss 战/半血这类持续条件，动画播完一次后会被“抑制”，
    --        直到条件消失才再次触发，避免持续状态导致动画反复重播。
    -- ---------------------------------------------------------
    playback = {
        active   = "once",
        boss     = "once",
        half     = "once",
        hurt     = "once",
        cardpill = "once",
        item     = "once",
    },

    cardpillDuration = 90,
    -- 主动/副主动道具使用状态持续时间（渲染帧）
    activeItemDuration = 90,

    -- 半血判定
    halfHealth = {
        threshold = 1,                -- 普通角色：总血量(半心单位) <= 1 即触发
        countSoulHearts = true,       -- 是否把灵魂心/黑心计入总血量
        ghostPlayerTypes = {          -- 游魂状态（无实体红心）不生效
            [PlayerType.PLAYER_THELOST] = true,
            [PlayerType.PLAYER_THELOST_B] = true,
        },
        oneHealthPlayerTypes = {      -- 店主改为 1 整心生效
            [PlayerType.PLAYER_KEEPER] = true,
            [PlayerType.PLAYER_KEEPER_B] = true,
        },
        oneHealthThreshold = 2,       -- 半心单位：2 = 1 整心
    },

    -- Boss 房类型（未清空 = 正在战斗）
    bossRoomTypes = {
        RoomType.ROOM_BOSS,
        RoomType.ROOM_BOSSRUSH,
    },

    -- 状态优先级（靠前者优先；main 是兜底不参与扫描）
    -- hurt（受击）最高优先级：任何事件动画都会被受击动画打断
    -- 注：wink（眨眼循环）属于 main 级装饰，排在 idle 之后、main 之前
    priority = { "hurt", "cardpill", "active", "boss", "item", "half", "idle", "wink", "main" },

    -- 每个状态的独立开关
    states = {
        hurt     = true,   -- 受击（火焰/爆炸/激光/尖刺等）
        cardpill = true,   -- 使用卡牌/药丸
        active   = true,   -- 使用主动/副主动道具
        boss     = true,   -- Boss 战
        item     = true,   -- 房间道具质量（item0~item4）
        half     = true,   -- 半血
        idle     = true,   -- 待机随机触发
    },

    -- 全局开关键（默认 F3）
    toggleKey = Keyboard.KEY_F3,
    toggleKeyName = "F3",

    -- 左上角数据行（调试用）
    topData = false,
}

-- 随机种子
pcall(function() math.randomseed(Isaac.GetTime()) end)

return config
