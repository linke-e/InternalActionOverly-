-- ============================================================
--  左下角叠加动画 Mod  (Overlay Mod)  v2
--  适用：以撒的结合：忏悔+ (Repentance+)
--  功能：游戏左下角叠加一张 256×256 动画；【触发事件后】播放由
--        多张贴图组成的动画，播放完毕回到 main 动画循环随机播放；
--        main 播放期间偶尔随机触发待机动画。
--  事件：卡牌/药丸、主动/副主动道具使用、Boss 战、半血、房间道具质量(item0~item4，依赖 ReactionAPI)。
--  动画帧来源：resources/gfx/overlay_anim/（由 gen_anim.py 生成
--        internalreactionoverlay_frames.lua 帧清单）。
--  API 参考：IsaacDocs (https://wofsauge.github.io/IsaacDocs/rep/)
-- ============================================================

local mod = RegisterMod("InternalReactionOverlay", 1)

-- ---------------------------------------------------------
--  配置与帧清单
-- ---------------------------------------------------------
local config = require("internalreactionoverlay_config")

-- 帧清单：动画键 -> 帧 PNG 路径列表（resources 相对路径，带 gfx/ 前缀）
mod.frames = {}
pcall(function() mod.frames = require("internalreactionoverlay_frames") end)
if type(mod.frames) ~= "table" then mod.frames = {} end

-- 叠加图位置在 OnRender 内按【物理像素坐标系】计算（见下方 physW/physH）。
-- 采用“左下角”布局：水平偏移用 config.margin（正=距左边缘右移），垂直贴底用 botPad*
-- config.scale 后再叠加 config.offsetY（正=上移）。图片整体按 config.scale 倍数缩放，
-- 定位、贴边均基于缩放后的有效尺寸 efw/efh。与窗口/分辨率/Repentogon 无关，稳定贴左下角。

-- ---------------------------------------------------------
--  帧 Sprite 加载：懒加载 + 缓存
--  每个 (动画键, 帧号) 独立一个 Sprite：从模板 anm2 加载后
--  ReplaceSpritesheet 换成对应帧 PNG。不要在文件顶层直接加载
--  （渲染器未就绪会成空壳）；在 MC_POST_RENDER 内首次需要时才加载。
-- ---------------------------------------------------------
mod.frameSprites = {}   -- 缓存：animKey.."#"..frameIdx -> Sprite
mod.frameErrors = {}    -- 已加载失败的 key（避免每帧重试）

local function dlog(msg)
    Isaac.DebugString("[InternalReactionOverlay] " .. msg .. "\n")
end

-- ---------------------------------------------------------
--  配置-素材一致性校验：用户替换素材后动画可能变少，
--  配置里引用了不存在的动画键时自动禁用对应状态/条目，
--  保证不出错能跑（缺失键的状态不触发，缺失的半血贴图回退 main_static）。
-- ---------------------------------------------------------
function mod:SanitizeConfig()
    if type(config) ~= "table" or type(mod.frames) ~= "table" then return end

    local function hasKey(k)
        return type(k) == "string"
            and type(mod.frames[k]) == "table"
            and #mod.frames[k] > 0
    end

    -- 事件动画键集合（固定 key 或 variants 列表）
    local function eventKeys(spec)
        local keys = {}
        if type(spec) == "table" and spec.key then
            keys[#keys + 1] = spec.key
        elseif type(spec) == "table" and type(spec.variants) == "table" then
            for _, v in ipairs(spec.variants) do
                if type(v) == "table" and v.key then keys[#keys + 1] = v.key end
            end
        end
        return keys
    end

    -- 1) 固定事件状态：动画键全缺失 -> 禁用该状态（item 单独处理）
    for stateKey, spec in pairs(config.events or {}) do
        if stateKey ~= "item" and config.states and config.states[stateKey] ~= nil then
            local keys = eventKeys(spec)
            local anyValid = false
            for _, k in ipairs(keys) do
                if hasKey(k) then anyValid = true; break end
            end
            if #keys > 0 and not anyValid then
                config.states[stateKey] = false
                dlog("素材缺失，已禁用状态: " .. tostring(stateKey))
            end
        end
    end

    -- 2) item 状态：item0~item4 全部缺失 -> 禁用
    if config.states and config.states.item then
        local anyValid = false
        local animKeys = (config.itemQuality and config.itemQuality.animKeys) or {}
        for _, k in pairs(animKeys) do
            if hasKey(k) then anyValid = true; break end
        end
        if not anyValid then
            config.states.item = false
            dlog("素材缺失，已禁用状态: item")
        end
    end

    -- 3) idle：过滤出存在的键；一个都没有 -> 禁用 idle
    if config.states and config.states.idle
        and type(config.idle) == "table" and type(config.idle.entries) == "table" then
        local kept = {}
        for _, e in ipairs(config.idle.entries) do
            if type(e) == "table" and hasKey(e.key) then
                kept[#kept + 1] = e
            end
        end
        config.idle.entries = kept
        if #kept == 0 then
            config.states.idle = false
            dlog("素材缺失，已禁用状态: idle")
        end
    end

    -- 4) main：过滤 entries；sadStatic 缺失 -> 置 nil（渲染时回退 main_static）
    if type(config.main) == "table" then
        if type(config.main.entries) == "table" and #config.main.entries > 0 then
            local kept = {}
            for _, e in ipairs(config.main.entries) do
                if type(e) == "table" and hasKey(e.key) then
                    kept[#kept + 1] = e
                end
            end
            if #kept > 0 then
                config.main.entries = kept
            else
                config.main.entries = { { key = "main_static", weight = 1 } }
            end
        end
        if config.main.sadStatic and not hasKey(config.main.sadStatic) then
            dlog("素材缺失，半血常态贴图回退 main_static: " .. tostring(config.main.sadStatic))
            config.main.sadStatic = nil
        end
    end

    -- 5) wink：主/半血眨眼键都缺失 -> 禁用眨眼
    if config.wink and config.wink.enabled then
        local okWink = hasKey(config.wink.animKey)
        local okWink1 = hasKey(config.wink.sadAnimKey)
        if not okWink and not okWink1 then
            config.wink.enabled = false
            dlog("素材缺失，已禁用眨眼")
        end
    end
end

mod:SanitizeConfig()


function mod:GetFrameSprite(animKey, frameIdx)
    local cacheKey = animKey .. "#" .. tostring(frameIdx)
    if mod.frameSprites[cacheKey] then return mod.frameSprites[cacheKey] end
    if mod.frameErrors[cacheKey] then return nil end
    local frames = mod.frames[animKey]
    if not frames or not frames[frameIdx] then return nil end
    local pngPath = frames[frameIdx]
    local s = Sprite()
    local ok, err = pcall(function()
        s:Load(config.frameTemplateAnm2)   -- 模板 anm2（1 帧 256×256）
        s:ReplaceSpritesheet(0, pngPath)   -- 换成当前帧 PNG
        s:LoadGraphics()
        s:Play("Idle", true)
    end)
    if not ok then
        mod.frameErrors[cacheKey] = tostring(err)
        dlog("加载帧失败: " .. tostring(pngPath) .. " -> " .. tostring(err))
        return nil
    end
    mod.frameSprites[cacheKey] = s
    return s
end

-- ---------------------------------------------------------
--  动画播放状态机
-- ---------------------------------------------------------
mod.curState = nil       -- 当前占据显示的状态键（nil = main）
mod.curAnimKey = nil     -- 当前动画键
mod.curFrame = 1         -- 当前帧号
mod.frameTimer = 0       -- 帧计时（每 frameDelay 游戏帧换 1 动画帧）
mod.animMode = "loop"    -- "loop" 循环 / "once" 播完即止

-- 事件计时（触发闩锁；动画自身决定播放时长）

mod.cardpillTimer = 0   -- 使用卡牌/药丸
mod.activeItemTimer = 0 -- 使用主动道具/副主动道具（药丸/卡牌不走此计时）
mod.hurtTimer = 0       -- 受击（触发类型见 config.hurt.damageFlags）

-- 抑制标记：once 动画播完后，若其触发条件仍然持续（如 Boss 房/半血），
-- 抑制该状态直到条件消失，避免立刻重新触发（除 main 外都只播一次）
mod.suppressed = {}

-- 道具质量：最近一次已播放的质量（用于检测质量变化后重触发）
mod.itemPlayedQ = nil
-- 进新房后的道具质量检测冷却（帧）：房间切换瞬间 ReactionAPI 可能返回
-- 上一房间的残留道具质量，冷却期内忽略道具检测，避免空房误触发
mod.itemGraceTimer = 0

-- main 状态计时与待机触发
mod.mainTimer = 0        -- 连续处于 main 的帧数
mod.idleSecAccum = 0     -- 每秒滚动计时
mod.idlePlaying = false  -- 待机动画正在播放
mod.idleKey = nil        -- 当前待机动画键

-- 眨眼循环：仅满血 main 状态下循环眨眼（半血时 main 常驻 sadAnim，计时暂停）
mod.winkPlaying = false     -- 眨眼动画正在播放
mod.winkTimer = 0           -- 距下次眨眼的渲染帧数（<=0 时立即眨）

mod.enabled = true       -- 全局启用开关（toggleKey 切换）

-- 动画帧间隔（渲染帧/动画帧）：优先取该动画的 animHold 覆盖值，
-- 未覆盖则用全局 animFps 换算（渲染 60fps）
local function frameDelay(animKey)
    local hold = config.animHold and config.animHold[animKey]
    if hold then
        return math.max(1, math.floor(hold))
    end
    return math.max(1, math.floor(60 / (config.animFps or 30)))
end

-- 开始播放某动画（从第 1 帧）
function mod:StartAnim(key, mode)
    local frames = mod.frames[key]
    if not frames or #frames == 0 then
        mod.curAnimKey = nil
        return
    end
    mod.curAnimKey = key
    mod.curFrame = 1
    mod.frameTimer = 0
    mod.animMode = mode or "loop"
end

-- 推进动画；返回 true=仍在播放，false=once 模式已播完
function mod:AdvanceAnim()
    if not mod.curAnimKey then return true end
    local frames = mod.frames[mod.curAnimKey]
    if not frames or #frames == 0 then return true end
    local delay = frameDelay(mod.curAnimKey)
    mod.frameTimer = mod.frameTimer + 1
    if mod.frameTimer < delay then return true end
    mod.frameTimer = 0
    mod.curFrame = mod.curFrame + 1
    if mod.curFrame > #frames then
        if mod.animMode == "loop" then
            mod.curFrame = 1
            return true
        end
        return false   -- once 播完
    end
    return true
end

-- 按权重从 entries 随机挑一个
function mod:PickWeighted(entries)
    if not entries or #entries == 0 then return nil end
    local total = 0
    for _, e in ipairs(entries) do total = total + (e.weight or 1) end
    local r = math.random() * total
    for _, e in ipairs(entries) do
        r = r - (e.weight or 1)
        if r <= 0 then return e end
    end
    return entries[#entries]
end

-- 事件 spec -> 动画键（固定 key 或按权重选 variant）
function mod:PickEventKey(spec)
    if not spec then return nil end
    if spec.key then return spec.key end
    if spec.variants then
        local e = mod:PickWeighted(spec.variants)
        return e and e.key or nil
    end
    return nil
end

-- 进入 main：随机挑一个主动画循环播放。
-- 半血时常态贴图切换为 sadStatic（main_sad）。
function mod:StartMain()
    local key = "main_static"
    local p = Game():GetPlayer(0)
    if p then
        local ok, sad = pcall(function() return mod:ComputeHalfHealth(p) end)
        if ok and sad and config.main.sadStatic then
            key = config.main.sadStatic
        end
    end
    mod:StartAnim(key, "loop")
end

-- 眨眼间隔（渲染帧，60fps）：
--   mode = "fixed"  -> 固定等待 delayFixed 秒
--   mode = "random" -> 随机等待 delayMin~delayMax 秒（默认）
-- 半血档用 sadMode/sadDelayFixed/sadDelayMin/sadDelayMax
function mod:NextWinkDelay()
    local cfg = config.wink or {}
    if mod:IsSad() then
        if (cfg.sadMode or "random") == "fixed" then
            return math.max(0, (cfg.sadDelayFixed or 5) * 60)
        end
        local minF = math.max(0, (cfg.sadDelayMin or 3) * 60)
        local maxF = math.max(minF, (cfg.sadDelayMax or 7) * 60)
        return math.random(minF, maxF)
    end
    if (cfg.mode or "random") == "fixed" then
        return math.max(0, (cfg.delayFixed or 4) * 60)
    end
    local minF = math.max(0, (cfg.delayMin or 3) * 60)
    local maxF = math.max(minF, (cfg.delayMax or 5) * 60)
    return math.random(minF, maxF)
end

-- 半血状态（总血量<=半颗心）
function mod:IsSad()
    local p = Game():GetPlayer(0)
    if not p then return false end
    local ok, sad = pcall(function() return mod:ComputeHalfHealth(p) end)
    return ok and sad
end

-- 眨眼动画键：满血 wink（overlay_wink），半血 wink1（overlay_wink1）
function mod:WinkKey()
    local cfg = config.wink or {}
    if mod:IsSad() then
        return cfg.sadAnimKey or "wink1"
    end
    return cfg.animKey or "wink"
end

-- ---------------------------------------------------------
--  半血判定（含游魂跳过 / 店主 1 血生效）
-- ---------------------------------------------------------
function mod:ComputeHalfHealth(player)
    local pType = player:GetPlayerType()

    if config.halfHealth.ghostPlayerTypes[pType] then
        return false
    end

    local totalHp = player:GetHearts()
    if config.halfHealth.countSoulHearts then
        totalHp = totalHp + player:GetSoulHearts()
    end

    local threshold = config.halfHealth.threshold
    if config.halfHealth.oneHealthPlayerTypes[pType] then
        threshold = config.halfHealth.oneHealthThreshold
    end

    return totalHp <= threshold
end

-- ---------------------------------------------------------
--  Boss 战判定（Boss 房且房间未清空）
-- ---------------------------------------------------------
function mod:ComputeBossFight()
    local room = Game():GetRoom()
    local roomType = room:GetType()

    local isBossRoom = false
    for _, rt in ipairs(config.bossRoomTypes) do
        if roomType == rt then isBossRoom = true; break end
    end
    if not isBossRoom then return false end

    return not room:IsClear()
end

-- ---------------------------------------------------------
--  道具质量检测（依赖 ReactionAPI）：
--  返回当前房间可见道具的最高质量（0~4），无道具返回 nil。
--  高等级优先：房间同时有 2 级与 4 级道具时返回 4。
-- ---------------------------------------------------------
function mod:ComputeItemQuality()
    if not config.itemQuality or not config.itemQuality.enabled then return nil end
    -- 进新房冷却期：忽略上一房间残留的道具质量检测
    if mod.itemGraceTimer and mod.itemGraceTimer > 0 then return nil end
    if not ReactionAPI or not ReactionAPI.Interface then return nil end
    local ok, q = pcall(function()
        return ReactionAPI.Interface.cGetBestQuality(ReactionAPI.Visibility.VISIBLE)
    end)
    if not ok then return nil end
    if type(q) ~= "number" then return nil end
    if q < 0 or q > 4 then return nil end   -- -2=无道具 / -1=故障，均不触发
    return math.floor(q)
end

-- 道具质量 -> 动画键（item0~item4）
function mod:ItemQualityAnimKey(q)
    local cfg = config.itemQuality or {}
    local keys = cfg.animKeys or {}
    local k = keys[q]
    if k and mod.frames[k] and #mod.frames[k] > 0 then return k end
    return nil
end

-- 使用卡牌 -> 触发卡牌/药丸动画（Medicine）
function mod:OnUseCard(cardType, player, useFlags)
    if config.states.cardpill then
        mod.cardpillTimer = config.cardpillDuration
    end
    return nil   -- 不拦截卡牌使用
end

-- 使用药丸 -> 触发卡牌/药丸动画（Medicine）
function mod:OnUsePill(pillColor, player, useFlags)
    if config.states.cardpill then
        mod.cardpillTimer = config.cardpillDuration
    end
    return nil   -- 不拦截药丸使用
end

-- 使用主动道具 / 副主动道具 -> 触发 activity 动画。
-- MC_USE_ITEM 仅在主动道具【真正使用】时触发，覆盖所有槽位
-- （主槽 SLOT_PRIMARY / 副槽 SLOT_POCKET 等）；
-- 药丸走 MC_USE_PILL、卡牌走 MC_USE_CARD，天然不会命中本回调。
function mod:OnUseActiveItem(collectibleType, rng, player, useFlags, activeSlot, varData)
    if config.states.active then
        mod.activeItemTimer = config.activeItemDuration
    end
    return nil   -- 不拦截主动道具使用
end

-- ---------------------------------------------------------
--  受击检测：角色受到指定类型伤害时触发 hurt 动画。
--  使用 MC_ENTITY_TAKE_DMG（仅玩家）+ CallbackPriority.EARLY：
--  EARLY 在其它 mod 的默认优先级回调之前执行，保证本回调一定会
--  被调用（若某个默认优先级 mod 的回调抛错，其后的回调可能被跳过）。
--  仅做视觉反馈，即使伤害随后被其它 mod 取消也无副作用。
--  回调返回 nil，不拦截伤害。
-- ---------------------------------------------------------
mod.hurtFlagSet = {}   -- config.hurt.damageFlags -> 位标志查重表
for _, flag in ipairs(config.hurt and config.hurt.damageFlags or {}) do
    if type(flag) == "number" and flag > 0 then
        mod.hurtFlagSet[flag] = true
    end
end

-- 非怪物伤害标志：命中任一即强制判定为“非怪物伤害”（兜底修正）
mod.nonMonsterFlagSet = {}
local nonMonsterFlags = {
    DamageFlag.DAMAGE_FIRE,        DamageFlag.DAMAGE_SPIKES,     DamageFlag.DAMAGE_ACID,
    DamageFlag.DAMAGE_POISON_BURN, DamageFlag.DAMAGE_DEVIL,      DamageFlag.DAMAGE_IV_BAG,
    DamageFlag.DAMAGE_PITFALL,     DamageFlag.DAMAGE_CHEST,      DamageFlag.DAMAGE_CURSED_DOOR,
    DamageFlag.DAMAGE_TIMER,       DamageFlag.DAMAGE_TNT,        DamageFlag.DAMAGE_POOP,
    DamageFlag.DAMAGE_RED_HEARTS,  DamageFlag.DAMAGE_COUNTDOWN,  DamageFlag.DAMAGE_CLONES,
    DamageFlag.DAMAGE_ISSAC_HEART,
}
for _, flag in ipairs(nonMonsterFlags) do
    mod.nonMonsterFlagSet[flag] = true
end

-- 怪物伤害判定（决策树）：
--   Step 3 flags 兜底：命中任一非怪物标志 → 非怪物伤害
--   Step 2 source 分类：
--     source.Entity == nil                     → 环境伤害（尖刺/火/诅咒等）→ 非怪物
--     source.Entity:IsEnemy()                  → 怪物本体（接触/爪击/自爆）→ 怪物
--     source.Type == ENTITY_TEAR 且非友方      → 敌方弹幕 → 怪物
--     source.Type ∈ {LASER, PROJECTILE} 且非友方 → 敌方激光/子弹 → 怪物
--     source.Type == ENTITY_BOMB               → 查 SpawnerType 区分敌我
--     source.Type == ENTITY_PLAYER / 友方      → 自伤（献血机/剃刀/血袋）→ 非怪物
--     source.Type == ENTITY_EFFECT             → 环境效果（creep/火/红便便）→ 非怪物
function mod:IsMonsterDamage(source, damageFlags)
    if not source then return false end
    for flag in pairs(mod.nonMonsterFlagSet) do
        if damageFlags & flag ~= 0 then return false end
    end
    local ent = source.Entity
    if ent == nil then return false end
    if ent:IsEnemy() then return true end
    local sType = source.Type
    if sType == EntityType.ENTITY_TEAR
        or sType == EntityType.ENTITY_LASER
        or sType == EntityType.ENTITY_PROJECTILE then
        -- 敌方弹幕 / 激光 / 子弹（友方的不算；优先用实体自身 IsFriendly）
        local friendly = source.IsFriendly == true
        if ent and ent.IsFriendly then
            pcall(function() friendly = ent:IsFriendly() end)
        end
        return not friendly
    end
    if sType == EntityType.ENTITY_BOMB then
        -- 爆炸：玩家自己放的炸弹不算怪物伤害
        return source.SpawnerType ~= EntityType.ENTITY_PLAYER
    end
    -- 玩家自伤 / 友方单位 / 环境效果等 → 非怪物
    return false
end

function mod:OnPlayerTakeDmg(entity, amount, damageFlags, source, countdownFrames)
    if not config.states.hurt then return nil end
    if amount <= 0 then return nil end
    -- 注意：不能因 flags == 0 提前返回——怪物本体接触/爪击伤害的 flags 通常为 0，
    -- 仍要靠下方 source 判定是否为怪物伤害
    if not damageFlags then return nil end
    -- 非惩罚性伤害（DAMAGE_NO_PENALTIES，不扣恶魔房概率等惩罚）不触发受击动画
    if config.hurt and config.hurt.ignoreNoPenalties
        and damageFlags & DamageFlag.DAMAGE_NO_PENALTIES ~= 0 then
        return nil
    end
    -- 触发判定：① 指定的环境伤害类型命中；② 或怪物攻击伤害
    local trigger = false
    for flag in pairs(mod.hurtFlagSet) do
        if damageFlags & flag ~= 0 then
            trigger = true
            break
        end
    end
    if not trigger and config.hurt and config.hurt.monsterDamage then
        trigger = mod:IsMonsterDamage(source, damageFlags)
    end
    if trigger then
        mod.hurtTimer = (config.hurt and config.hurt.duration) or 90
    end
    return nil   -- 不拦截伤害
end

-- ---------------------------------------------------------
--  渲染：左下角叠加动画，按优先级选择状态
-- ---------------------------------------------------------
function mod:OnRender()
    local player = Game():GetPlayer(0)
    if player == nil then return end

    -- 全局开关
    local toggled = false
    pcall(function()
        toggled = Input.IsButtonTriggered(config.toggleKey, 0)
    end)
    if toggled then
        mod.enabled = not mod.enabled
    end
    if not mod.enabled then
        return
    end

    -- 道具质量冷却递减（房间切换后暂不检测，等 ReactionAPI 更新为新房间数据）
    if mod.itemGraceTimer and mod.itemGraceTimer > 0 then
        mod.itemGraceTimer = mod.itemGraceTimer - 1
    end

    local function safe(fn, def)
        local ok, v = pcall(fn)
        if not ok then dlog("状态计算抛错: " .. tostring(v)) end
        return ok and v or def
    end

    -- 计算各状态激活与否
    local states = {

        hurt     = config.states.hurt     and mod.hurtTimer > 0,
        cardpill = config.states.cardpill and mod.cardpillTimer > 0,
        active   = config.states.active   and mod.activeItemTimer > 0,
        boss     = config.states.boss     and safe(function() return mod:ComputeBossFight() end, false),
        item     = config.states.item     and mod:ComputeItemQuality() ~= nil,
        half     = config.states.half     and safe(function() return mod:ComputeHalfHealth(player) end, false),
        idle     = config.states.idle     and mod.idlePlaying,
        wink     = config.wink and config.wink.enabled and mod.winkPlaying,
    }

    -- 清除已失效状态的抑制标记（条件消失后才能再次触发）
    for key in pairs(mod.suppressed) do
        if not states[key] then
            mod.suppressed[key] = nil
        end
    end

    -- 道具质量变化：若当前最高质量与已播放的不同，解除抑制以便重触发
    if config.itemQuality and config.itemQuality.enabled then
        local curQ = mod:ComputeItemQuality()
        if curQ and mod.itemPlayedQ and curQ ~= mod.itemPlayedQ then
            mod.suppressed["item"] = nil
        end
        if curQ == nil then
            mod.itemPlayedQ = nil
        end
    end

    -- 按优先级取第一个激活且未被抑制的状态（main 是兜底不参与扫描）
    -- 道具动画锁定：item 动画播放期间锁定当前状态直到播完，
    -- 不被受击/卡牌等更高优先级事件打断（它们顺延到动画结束后再响应）
    local topKey = nil
    local itemLocked = (mod.curState == "item" and mod.curAnimKey ~= nil
        and config.itemQuality and config.itemQuality.lock)
    if itemLocked then
        topKey = "item"
    else
        for _, key in ipairs(config.priority) do
            if key == "main" then break end
            if states[key] and not mod.suppressed[key] then topKey = key; break end
        end
    end

    if topKey and topKey ~= mod.curState then
        -- 进入 / 切换到某事件状态：开始播放对应动画
        mod.curState = topKey
        if topKey == "idle" then
            mod:StartAnim(mod.idleKey or "idle1", "once")
        elseif topKey == "wink" then
            mod:StartAnim(mod:WinkKey(), "once")   -- 眨眼循环（独立于 idle；动画随血量切换）
        elseif topKey == "item" then
            -- 道具质量事件：按房间最高质量动态选择 item0~item4
            local q = mod:ComputeItemQuality()
            local ak = q and mod:ItemQualityAnimKey(q)
            if ak then
                mod:StartAnim(ak, config.playback[topKey] or "once")
                mod.itemPlayedQ = q   -- 记录已播放质量
            else
                mod.curState = nil
                mod.itemPlayedQ = nil
            end
            mod.idlePlaying = false
            mod.winkPlaying = false
            mod.winkTimer = mod:NextWinkDelay()
        else
            local spec = config.events[topKey]
            local vkey = mod:PickEventKey(spec)
            mod:StartAnim(vkey, config.playback[topKey] or "once")
            -- 非待机/眨眼事件打断：清掉标记，事件结束后不续播
            mod.idlePlaying = false
            mod.winkPlaying = false
            mod.winkTimer = mod:NextWinkDelay()   -- 重新计时
        end
        mod.mainTimer = 0
        mod.idleSecAccum = 0
    elseif topKey == nil then
        -- main 状态
        if mod.curState ~= nil then
            mod.curState = nil
            mod:StartMain()          -- 事件结束/被打断 -> 重新随机主动画
        elseif not mod.curAnimKey then
            mod:StartMain()
        end
        mod:AdvanceAnim()

        -- 待机随机触发：连续 main 满 minMainTime 后每秒概率触发一次
        if config.states.idle then
            mod.mainTimer = mod.mainTimer + 1
            if mod.mainTimer >= config.idle.minMainTime then
                mod.idleSecAccum = mod.idleSecAccum + 1
                if mod.idleSecAccum >= 60 then
                    mod.idleSecAccum = 0
                    if math.random() < config.idle.triggerChancePerSec then
                        local e = mod:PickWeighted(config.idle.entries)
                        if e then
                            mod.idleKey = e.key
                            mod.idlePlaying = true
                            mod.mainTimer = 0
                        end
                    end
                end
            end
        end

        -- 眨眼循环：main 状态下计时到 0 播放眨眼
        -- （满血/半血共用计时器；动画与间隔由 NextWinkDelay/WinkKey 按血量切换）
        if config.wink and config.wink.enabled and not mod.idlePlaying then
            mod.winkTimer = mod.winkTimer - 1
            if mod.winkTimer <= 0 then
                mod.winkPlaying = true
            end
        end
    else
        -- 同一事件状态延续：推进动画
        local still = mod:AdvanceAnim()
        if not still then
            -- once 播完 -> 清除该事件闩锁，抑制该状态直到条件消失，立即回 main
            -- 注：death 为锁定状态（loop 播放 death.png），不进入此分支
            if topKey == "cardpill" then mod.cardpillTimer = 0
            elseif topKey == "active" then mod.activeItemTimer = 0
            elseif topKey == "hurt" then mod.hurtTimer = 0
            elseif topKey == "idle" then mod.idlePlaying = false
            elseif topKey == "wink" then
                -- 眨眼播完：重置随机间隔，等待下一次眨眼（仅满血）
                mod.winkPlaying = false
                mod.winkTimer = mod:NextWinkDelay()
            end
            if topKey ~= "idle" and topKey ~= "wink" then
                mod.suppressed[topKey] = true
            end
            mod.curState = nil
            mod:StartMain()
        end
    end

    -- 事件计时递减（每渲染帧 -1）

    if mod.cardpillTimer > 0 then mod.cardpillTimer = mod.cardpillTimer - 1 end
    if mod.activeItemTimer > 0 then mod.activeItemTimer = mod.activeItemTimer - 1 end
    if mod.hurtTimer > 0 then mod.hurtTimer = mod.hurtTimer - 1 end

    -- 计算叠加图位置（物理像素坐标系）
    local physW, physH = 512, 320
    pcall(function()
        local w = Isaac.GetScreenWidth()
        local h = Isaac.GetScreenHeight()
        if w and h and w > 0 and h > 0 then physW, physH = w, h end
    end)
    local sw, sh = physW, physH

    local s = nil
    if mod.curAnimKey then
        s = mod:GetFrameSprite(mod.curAnimKey, mod.curFrame)
    end
    if not s then
        -- 兜底：至少显示 main_static
        s = mod:GetFrameSprite("main_static", 1)
    end

    local fw, fh = config.frameSize, config.frameSize
    if s then
        pcall(function()
            local res = s:GetSpriteResolution()
            if res and res.X and res.Y then fw, fh = res.X, res.Y end
        end)
    end
    -- 防御：素材非 256×256 或解析失败时回退到模板尺寸，避免算出屏外坐标
    if type(fw) ~= "number" or fw <= 0 then fw = config.frameSize end
    if type(fh) ~= "number" or fh <= 0 then fh = config.frameSize end

    local scale = config.scale
    local efw, efh = fw * scale, fh * scale
    local botPad = (fh >= 256) and 0 or 2
    local botPadScaled = botPad * scale
    -- 左下角布局：左对齐 + 贴底。margin 正=距左边缘右移，负=可超出左边缘；
    -- offsetY 正=上移，负=下移，0=贴底。
    local posX = config.margin
    local posY = sh - efh + botPadScaled - config.offsetY

    -- 限制在屏幕内（素材尺寸异常时也不至于整张跑到屏外）
    local drawX = math.min(math.max(0, posX), math.max(0, sw - efw))
    local drawY = math.min(math.max(0, posY), math.max(0, sh - efh))

    if s then
        local ok, err = pcall(function()
            s.Scale = Vector(scale, scale)
            s:Update()
            s:Render(Vector(drawX, drawY), Vector.Zero, Vector.Zero)
        end)
        if not ok then dlog("渲染失败: " .. tostring(err)) end
    end
end

-- ---------------------------------------------------------
--  调试文本（左上角数据行）
-- ---------------------------------------------------------
function mod:OnRenderDebug()
    if not mod.enabled then return end
    if not config.topData then return end
    local function g(fn, d) local ok, v = pcall(fn); return ok and v or d end
    local player = Game():GetPlayer(0)
    if player == nil then return end
    local game  = Game()
    local room  = g(function() return game:GetRoom() end, nil)
    local level = g(function() return game:GetLevel() end, nil)
    local roomDesc = g(function() return level and level:GetCurrentRoomDesc() end, nil)
    local rid, rtype, rshape, gridIdx = -1, -1, -1, -1
    if room then
        pcall(function() gridIdx = room:GetGridIndex() end)
        pcall(function() rtype  = room:GetType() end)
        pcall(function() rshape = room:GetRoomShape() end)
    end
    if roomDesc then
        pcall(function() gridIdx = roomDesc.GridIndex end)
        pcall(function() rtype  = roomDesc.Data.Type end)
        pcall(function() rshape = roomDesc.Data.Shape end)
        pcall(function() rid = roomDesc.Data.Variant end)
    end
    local stage  = g(function() return level and level:GetStage() end, -1)
    local ptype  = g(function() return player:GetPlayerType() end, -1)
    local pos    = player.Position
    local vel    = player.Velocity
    local now = g(function() return Isaac.GetTime() end, 0)
    local fps = 0
    if mod.lastTime and now > mod.lastTime then
        local dt = now - mod.lastTime
        if dt > 0 then
            local inst = 1000 / dt
            mod.fpsSmooth = (mod.fpsSmooth or inst) * 0.9 + inst * 0.1
            fps = mod.fpsSmooth
        end
    end
    mod.lastTime = now
    local curses = 0
    pcall(function() curses = Game():GetLevel():GetCurses() end)
    local top = string.format(
        "d=%d G=%d T=%d S=%d Stg=%d P=%d fps=%.0f | pos=(%.0f,%.0f) vel=(%.2f,%.2f) | curses=%d | anim=%s",
        rid, gridIdx, rtype, rshape, stage, ptype, fps, pos.X, pos.Y, vel.X, vel.Y,
        curses, tostring(mod.curAnimKey))
    Isaac.RenderText(top, 5, 5, 1, 1, 1, 1)
end

-- ---------------------------------------------------------
--  新一局/玩家初始化：重置状态
-- ---------------------------------------------------------
function mod:OnPlayerInit(player)
    mod.curState = nil
    mod.curAnimKey = nil
    mod.curFrame = 1
    mod.frameTimer = 0

    mod.cardpillTimer = 0
    mod.activeItemTimer = 0
    mod.hurtTimer = 0
    mod.suppressed = {}
    mod.itemPlayedQ = nil
    mod.itemGraceTimer = 0
    mod.mainTimer = 0
    mod.idleSecAccum = 0
    mod.idlePlaying = false
    mod.idleKey = nil
    mod.winkPlaying = false
    mod.winkTimer = mod:NextWinkDelay()   -- 新一局：随机延迟后第一次眨眼
end

-- ---------------------------------------------------------
--  渲染层：固定世界层(MC_POST_RENDER)
-- ---------------------------------------------------------
function mod:ApplyRenderLayer()
    pcall(mod.RemoveCallback, mod, ModCallbacks.MC_POST_RENDER, mod.OnRender)
    pcall(mod.RemoveCallback, mod, ModCallbacks.MC_POST_HUD_RENDER, mod.OnRender)
    mod:AddCallback(ModCallbacks.MC_POST_RENDER, mod.OnRender)
    mod.activeRenderLayer = "WORLD"
end

-- ---------------------------------------------------------
--  注册回调
-- ---------------------------------------------------------
mod:AddCallback(ModCallbacks.MC_POST_RENDER, mod.OnRenderDebug)
mod:ApplyRenderLayer()

mod:AddCallback(ModCallbacks.MC_USE_CARD, mod.OnUseCard)
mod:AddCallback(ModCallbacks.MC_USE_PILL, mod.OnUsePill)
mod:AddCallback(ModCallbacks.MC_USE_ITEM, mod.OnUseActiveItem)
-- 受击检测（仅玩家；LATE 优先级避免伤害被取消后仍触发）
mod:AddPriorityCallback(ModCallbacks.MC_ENTITY_TAKE_DMG, CallbackPriority.EARLY, mod.OnPlayerTakeDmg, EntityType.ENTITY_PLAYER)
mod:AddCallback(ModCallbacks.MC_POST_PLAYER_INIT, mod.OnPlayerInit)
-- 进新房：重置道具质量状态（房间道具变化后重新检测）
mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
    mod.suppressed["item"] = nil
    mod.itemPlayedQ = nil
    -- 进入新房间后冷却一段时间再检测道具质量，避免旧房残留数据误触发
    mod.itemGraceTimer = (config.itemQuality and config.itemQuality.graceFrames) or 30
end)

-- =========================================================
--  设置持久化（存档）
-- =========================================================
local json = nil
pcall(function() json = require("json") end)

local KEY_NAMES = {
    [Keyboard.KEY_F1] = "F1", [Keyboard.KEY_F2] = "F2", [Keyboard.KEY_F3] = "F3",
    [Keyboard.KEY_F4] = "F4", [Keyboard.KEY_F5] = "F5", [Keyboard.KEY_F6] = "F6",
    [Keyboard.KEY_F7] = "F7", [Keyboard.KEY_F8] = "F8", [Keyboard.KEY_F9] = "F9",
    [Keyboard.KEY_F10] = "F10", [Keyboard.KEY_F11] = "F11", [Keyboard.KEY_F12] = "F12",
}
local function keyName(k)
    return KEY_NAMES[k] or ("KEY#" .. tostring(k))
end

local function serializeSettings()
    local st = {}
    for k, v in pairs(config.states) do st[k] = v end
    return {
        globalEnabled    = mod.enabled,
        toggleKey        = config.toggleKey,
        states           = st,
        scale            = config.scale,
        margin           = config.margin,
        offsetY          = config.offsetY,
        topData          = config.topData,
    }
end

local function applySettings(s)
    if type(s) ~= "table" then return end
    if type(s.globalEnabled) == "boolean" then mod.enabled = s.globalEnabled end
    if type(s.toggleKey) == "number" then
        config.toggleKey = s.toggleKey
        config.toggleKeyName = keyName(s.toggleKey)
    end
    if type(s.states) == "table" then
        for k, v in pairs(s.states) do
            if type(v) == "boolean" and config.states[k] ~= nil then
                config.states[k] = v
            end
        end
    end
    if type(s.scale)           == "number" then config.scale           = s.scale end
    if type(s.margin) == "number" then
        local extra = (type(s.cardSlotReserve) == "number") and s.cardSlotReserve or 0
        config.margin = s.margin + extra
    end
    if type(s.offsetY) == "number" then config.offsetY = s.offsetY end
    if type(s.topData)         == "boolean" then config.topData         = s.topData end
    if type(s.debug)           == "boolean" then config.topData         = s.debug end
end

function mod:SaveSettings()
    if not json then return end
    pcall(function() mod:SaveData(json.encode(serializeSettings())) end)
end

function mod:LoadSettings()
    if not json then return end
    if not mod:HasData() then return end
    pcall(function()
        local raw = mod:LoadData()
        local ok, data = pcall(json.decode, raw)
        if ok then applySettings(data) end
    end)
end

mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
    mod:LoadSettings()
    mod:SanitizeConfig()   -- 读档后再次校验（存档可能重新打开了缺失素材的状态）
end)

-- =========================================================
--  Mod Config Menu (MCM) 适配
-- =========================================================

local function registerMCM(MCM)
    local N = "InternalReactionOverlay"

    local function addBool(sub, get, set, text, info)
        MCM.AddSetting(N, sub, {
            Type = MCM.OptionType.BOOLEAN,
            CurrentSetting = function() return get() end,
            Display = function() return (get() and "[开] " or "[关] ") .. text end,
            OnChange = function(v) set(v); mod:SaveSettings() end,
            Info = info,
        })
    end

    local function addNum(sub, get, set, min, max, step, label, info)
        MCM.AddSetting(N, sub, {
            Type = MCM.OptionType.NUMBER,
            CurrentSetting = function() return get() end,
            Minimum = min, Maximum = max, ModifyBy = step,
            Display = function() return label .. "：" .. tostring(get()) end,
            OnChange = function(v) set(v); mod:SaveSettings() end,
            Info = info,
        })
    end

    -- ---------- 总开关 ----------
    MCM.AddText(N, "总开关", function() return "InternalReactionOverlay —— 总控制" end)
    MCM.AddSpace(N, "总开关")
    addBool("总开关",
        function() return mod.enabled end,
        function(v) mod.enabled = v end,
        "启用整个叠加层",
        { "关闭后完全不显示叠加动画", "游戏内也可按快捷键切换" })
    MCM.AddSpace(N, "总开关")
    MCM.AddSetting(N, "总开关", {
        Type = MCM.OptionType.KEYBIND_KEYBOARD,
        CurrentSetting = function() return config.toggleKey end,
        Display = function() return "切换快捷键：" .. keyName(config.toggleKey) end,
        OnChange = function(k)
            config.toggleKey = k
            config.toggleKeyName = keyName(k)
            mod:SaveSettings()
        end,
        Info = { "游戏中按此键一键启用/停用叠加层" },
        PopupGfx = MCM.PopupGfx and MCM.PopupGfx.WIDE_SMALL or nil,
        Popup = function()
            return "当前：" .. keyName(config.toggleKey) .. "\n按新键设置，或 ESC 取消"
        end,
    })

    -- ---------- 状态开关 ----------
    MCM.AddText(N, "状态开关", function() return "各状态动画的独立开关" end)
    MCM.AddSpace(N, "状态开关")
    local stateLabels = {

        { "hurt",     "受击动画(火焰/爆炸/激光等)" },
        { "cardpill", "卡牌/药丸动画" },
        { "active",   "使用主动/副主动道具动画" },
        { "boss",     "Boss 战动画" },
        { "item",     "房间道具质量动画" },
        { "half",     "半血动画" },
        { "idle",     "待机随机动画" },
    }
    for _, it in ipairs(stateLabels) do
        local key, label = it[1], it[2]
        addBool("状态开关",
            function() return config.states[key] end,
            function(v) config.states[key] = v end,
            label,
            { "关闭后该状态永不触发" })
    end

    -- ---------- 受击 ----------
    MCM.AddText(N, "受击", function() return "受击动画触发范围" end)
    MCM.AddSpace(N, "受击")
    addBool("受击",
        function() return config.hurt.monsterDamage end,
        function(v) config.hurt.monsterDamage = v end,
        "怪物攻击也触发受击",
        { "角色受到怪物本体/敌方弹幕/激光/怪物炸弹伤害时也播放 hurt", "环境伤害判定不受影响" })

    -- ---------- 道具质量 ----------
    MCM.AddText(N, "道具质量", function() return "房间道具质量动画（依赖 ReactionAPI）" end)
    MCM.AddSpace(N, "道具质量")
    addBool("道具质量",
        function() return config.itemQuality.enabled end,
        function(v) config.itemQuality.enabled = v end,
        "房间道具质量动画",
        { "房间存在未拾取道具时按最高质量播放 item0~item4", "需安装 ReactionAPI" })
    addBool("道具质量",
        function() return config.itemQuality.lock end,
        function(v) config.itemQuality.lock = v end,
        "道具动画播放期间不被打断",
        { "item 动画开始后播完为止", "受击/卡牌等事件顺延到结束后再响应" })

    -- ---------- 外观 / 位置 ----------
    MCM.AddText(N, "外观位置", function() return "叠加动画尺寸与左下角位置" end)
    MCM.AddSpace(N, "外观位置")
    addNum("外观位置",
        function() return config.scale end,
        function(v) config.scale = v end,
        0.05, 5, 0.05, "图片缩放(倍数)",
        { "1.0=原始尺寸(256px)；0.05~5 倍" })
    addNum("外观位置",
        function() return config.margin end,
        function(v) config.margin = v end,
        -500, 800, 2, "水平偏移(右正左负)",
        { "正=图向右移(距左边缘更远)", "负=图向左移(可超出左边缘)" })
    addNum("外观位置",
        function() return config.offsetY end,
        function(v) config.offsetY = v end,
        -500, 800, 1, "上下偏移(上正下负)",
        { "正=上移(距底更远)，负=下移(超出屏幕底)，0=贴底" })

    -- ---------- 其它 ----------
    MCM.AddText(N, "其它", function() return "动画速度与调试" end)
    MCM.AddSpace(N, "其它")
    addNum("其它",
        function() return config.animFps end,
        function(v) config.animFps = v end,
        5, 60, 5, "全局动画帧率(fps)",
        { "未单独指定的动画：15 = 每 4 渲染帧换 1 帧", "越小越慢、越大越快",
          "各动画实际速度见 config.animHold（已按帧数调至约 1 秒）" })
    addBool("其它",
        function() return config.topData end,
        function(v) config.topData = v end,
        "左上角数据(房间/坐标/FPS)",
        { "游戏内左上角显示调试数据" })
end

local function tryRegisterMCM()
    if mod.mcmRegistered then return end
    local ok, MCM = pcall(require, "scripts.modconfig")
    if ok and MCM then
        registerMCM(MCM)
        mod.mcmRegistered = true
    end
end

tryRegisterMCM()
mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
    tryRegisterMCM()
end)
