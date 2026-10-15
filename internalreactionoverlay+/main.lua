-- ============================================================
--  左下角叠加动画 Mod  (Overlay Mod)  v3 —— 多角色素材池版
--  适用：以撒的结合：忏悔+ (Repentance+)
--  功能：游戏左下角叠加一张 256×256 动画桌宠；【触发事件后】播放由
--        多张贴图组成的动画，播放完毕回到 main 动画循环随机播放；
--        main 播放期间偶尔随机触发待机动画。
--  角色素材池：resources/gfx/pets/<角色名>/（一个角色一个文件夹，最多 5 个），
--        通过 config.activePet / 模组配置菜单(MCM)切换使用的角色。
--  事件：卡牌/药丸、主动/副主动道具使用、Boss 战、半血、房间道具质量(item0~item4，依赖 ReactionAPI)。
--  动画帧来源：resources/gfx/pets/<角色>/（由 gen_anim.py 生成
--        internalreactionoverlay_frames.lua 多角色帧清单）。
--  API 参考：IsaacDocs (https://wofsauge.github.io/IsaacDocs/rep/)
-- ============================================================

local mod = RegisterMod("InternalReactionOverlay", 1)

-- ---------------------------------------------------------
--  配置与帧清单
-- ---------------------------------------------------------
local config = require("internalreactionoverlay_config")

local function dlog(msg)
    Isaac.DebugString("[InternalReactionOverlay] " .. msg .. "\n")
end

-- 帧清单：角色素材池。
-- 新格式（gen_anim.py 多角色版生成）：
--   { pets = {角色名...}, frames = { [角色名] = { [动画键] = {帧 PNG 路径...} } } }
-- 旧格式（顶层即动画键的单角色清单）：归一化包装为 default 角色。
mod.petList = {}      -- 角色名列表（素材池顺序，最多 5 个）
mod.petFrames = {}    -- 角色名 -> { 动画键 -> {帧 PNG 路径...} }（resources 相对路径，带 gfx/ 前缀）
do
    local rawFrames = {}
    pcall(function() rawFrames = require("internalreactionoverlay_frames") end)
    if type(rawFrames) ~= "table" then rawFrames = {} end
    if type(rawFrames.pets) == "table" and type(rawFrames.frames) == "table" then
        for _, name in ipairs(rawFrames.pets) do
            if type(name) == "string" and type(rawFrames.frames[name]) == "table" then
                mod.petList[#mod.petList + 1] = name
                mod.petFrames[name] = rawFrames.frames[name]
            end
        end
    else
        -- 旧版单角色清单（顶层键即动画键）-> 当作唯一角色 default
        mod.petList = { "default" }
        mod.petFrames["default"] = rawFrames
    end
end

-- 当前生效角色名：config.activePet 失效（角色被删/改名）时回退素材池第一个
function mod:GetPet()
    local name = config.activePet
    if type(name) == "string" and mod.petFrames[name] then return name end
    return mod.petList[1]
end

-- 取动画键的帧表：先查当前角色；缺失且 petFallback 开启时按素材池顺序
-- 回退到其它角色的同名动画（角色素材不全也能跑）。
function mod:GetFrames(animKey)
    if type(animKey) ~= "string" then return nil end
    local pet = mod:GetPet()
    local own = mod.petFrames[pet]
    if own and type(own[animKey]) == "table" and #own[animKey] > 0 then
        return own[animKey]
    end
    if config.petFallback then
        for _, name in ipairs(mod.petList) do
            if name ~= pet then
                local alt = mod.petFrames[name]
                if alt and type(alt[animKey]) == "table" and #alt[animKey] > 0 then
                    return alt[animKey]
                end
            end
        end
    end
    return nil
end

-- 切换桌宠角色（校验存在性；刷新缓存与当前动画并存档）
function mod:SetPet(name)
    if type(name) ~= "string" or not mod.petFrames[name] then return false end
    if config.activePet == name then return true end
    config.activePet = name
    mod:RefreshPet()
    dlog("切换桌宠角色: " .. name)
    return true
end

-- 角色/读档后刷新：清空帧 Sprite 缓存（缓存键已含路径，理论上可不清，
-- 但清掉可立刻释放旧角色显存并让素材热替换生效），重校验配置并重启 main 动画
function mod:RefreshPet()
    mod.frameSprites = {}
    mod.frameErrors = {}
    mod:SanitizeConfig()
    mod.curState = nil
    mod.curAnimKey = nil
    mod.curFrame = 1
    mod.frameTimer = 0
    mod.idlePlaying = false
    mod.winkPlaying = false
    mod.winkTimer = mod:NextWinkDelay()
    mod:StartMain()
end

-- 叠加图位置在 OnRender 内按【物理像素坐标系】计算（见下方 physW/physH）。
-- 采用“左下角”布局：水平偏移用 config.margin（正=距左边缘右移），垂直贴底用 botPad*
-- config.scale 后再叠加 config.offsetY（正=上移）。图片整体按 config.scale 倍数缩放，
-- 定位、贴边均基于缩放后的有效尺寸 efw/efh。与窗口/分辨率/Repentogon 无关，稳定贴左下角。

-- ---------------------------------------------------------
--  帧 Sprite 加载：懒加载 + 缓存
--  每个 (帧 PNG 路径) 独立一个 Sprite：从模板 anm2 加载后
--  ReplaceSpritesheet 换成对应帧 PNG。不要在文件顶层直接加载
--  （渲染器未就绪会成空壳）；在 MC_POST_RENDER 内首次需要时才加载。
--  缓存键用完整 PNG 路径（天然区分角色），切换角色不会串缓存。
-- ---------------------------------------------------------
mod.frameSprites = {}   -- 缓存：帧 PNG 路径 -> Sprite
mod.frameErrors = {}    -- 已加载失败的路径（避免每帧重试）

-- ---------------------------------------------------------
--  配置-素材一致性校验：素材缺失时自动禁用引用它的状态（不报错能跑）；
--  被自动禁用的状态记入 config._autoDisabled（与用户手动关闭区分），
--  日后切换到素材齐全的角色时自动恢复开启。
--  多角色版：hasKey 走当前角色 + 素材池回退链（GetFrames）。
-- ---------------------------------------------------------
function mod:SanitizeConfig()
    if type(config) ~= "table" then return end

    local function hasKey(k)
        return mod:GetFrames(k) ~= nil
    end

    -- 事件 spec -> 动画键集合（固定 key 或 variants 列表）
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

    -- 状态素材判定：该状态引用的动画键当前是否有任一可用
    local function stateHasAssets(stateKey)
        if stateKey == "item" then
            local animKeys = (config.itemQuality and config.itemQuality.animKeys) or {}
            for _, k in pairs(animKeys) do
                if hasKey(k) then return true end
            end
            return false
        elseif stateKey == "idle" then
            -- entries 可能已被过滤空，判定用保留的原始池
            local idleCfg = (type(config.idle) == "table" and config.idle) or {}
            local entries = idleCfg._origEntries or idleCfg.entries or {}
            for _, e in ipairs(entries) do
                if type(e) == "table" and hasKey(e.key) then return true end
            end
            return false
        else
            local spec = config.events and config.events[stateKey]
            for _, k in ipairs(eventKeys(spec)) do
                if hasKey(k) then return true end
            end
            return false
        end
    end

    -- 0) 角色有效性：activePet 不在素材池（被删/改名）时回退第一个可用角色
    if #mod.petList > 0 then
        local cur = config.activePet
        if type(cur) ~= "string" or not mod.petFrames[cur] then
            dlog("角色「" .. tostring(cur) .. "」不在素材池中，回退到: " .. tostring(mod.petList[1]))
            config.activePet = mod.petList[1]
        end
    end

    -- 0.5) 恢复段：此前因素材缺失被自动禁用的状态，素材恢复可用后重新开启
    --     （_autoDisabled 是 config 表内临时标记，不写入存档）
    if type(config._autoDisabled) ~= "table" then config._autoDisabled = {} end
    for stateKey in pairs(config._autoDisabled) do
        if stateHasAssets(stateKey) then
            if config.states[stateKey] == false then
                config.states[stateKey] = true
                dlog("素材已可用，自动恢复状态: " .. tostring(stateKey))
            end
            config._autoDisabled[stateKey] = nil
        end
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
                config._autoDisabled[stateKey] = true
                dlog("素材缺失，已禁用状态: " .. tostring(stateKey))
            end
        end
    end

    -- 2) item 状态：item0~item4 全部缺失 -> 禁用
    if config.states and config.states.item then
        if not stateHasAssets("item") then
            config.states.item = false
            config._autoDisabled.item = true
            dlog("素材缺失，已禁用状态: item")
        end
    end

    -- 3) idle：从原始池过滤出存在的键；一个都没有 -> 禁用 idle
    if config.states and config.states.idle
        and type(config.idle) == "table" and type(config.idle.entries) == "table" then
        -- 备份原始待机池（首次），素材恢复后可从中重新过滤
        config.idle._origEntries = config.idle._origEntries or config.idle.entries
        local kept = {}
        for _, e in ipairs(config.idle._origEntries) do
            if type(e) == "table" and hasKey(e.key) then
                kept[#kept + 1] = e
            end
        end
        config.idle.entries = kept
        if #kept == 0 then
            config.states.idle = false
            config._autoDisabled.idle = true
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
    local frames = mod:GetFrames(animKey)
    if not frames or not frames[frameIdx] then return nil end
    local pngPath = frames[frameIdx]
    local cacheKey = pngPath   -- 缓存键=完整路径：不同角色同键动画天然隔离
    if mod.frameSprites[cacheKey] then return mod.frameSprites[cacheKey] end
    if mod.frameErrors[cacheKey] then return nil end
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
-- 未覆盖则用全局 animFps 换算（渲染 60fps）；再整体除以 animSpeed 倍率
-- （>1 加速、<1 减速），最小 1 渲染帧。
local function frameDelay(animKey)
    local hold = config.animHold and config.animHold[animKey]
    if not hold then
        hold = 60 / (config.animFps or 30)
    end
    local speed = tonumber(config.animSpeed) or 1.0
    if speed <= 0 then speed = 1.0 end
    return math.max(1, math.floor(hold / speed))
end

-- 事件状态时长（渲染帧）：按 1/animSpeed 缩放——animSpeed<1 时动画变慢，
-- 固定帧数会在动画播完前结束状态将其截断，故时长同步拉长
local function eventDuration(base)
    local speed = tonumber(config.animSpeed) or 1.0
    if speed <= 0 then speed = 1.0 end
    return math.max(1, math.floor(base / speed + 0.5))
end

-- 开始播放某动画（从第 1 帧）
function mod:StartAnim(key, mode)
    local frames = mod:GetFrames(key)
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
    local frames = mod:GetFrames(mod.curAnimKey)
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
    if k and mod:GetFrames(k) then return k end
    return nil
end

-- item 动画播放模式：itemQuality.mode = "loop" 时持续循环（房间存在道具期间常驻，
-- 质量变化时切换动画）；否则按 playback.item（once：播一遍回 main）
function mod:ItemPlaybackMode()
    local iq = config.itemQuality or {}
    if (iq.mode or "once") == "loop" then return "loop" end
    return config.playback.item or "once"
end

-- 使用卡牌 -> 触发卡牌/药丸动画（Medicine）
function mod:OnUseCard(cardType, player, useFlags)
    if config.states.cardpill then
        mod.cardpillTimer = eventDuration(config.cardpillDuration)
    end
    return nil   -- 不拦截卡牌使用
end

-- 使用药丸 -> 触发卡牌/药丸动画（Medicine）
function mod:OnUsePill(pillColor, player, useFlags)
    if config.states.cardpill then
        mod.cardpillTimer = eventDuration(config.cardpillDuration)
    end
    return nil   -- 不拦截药丸使用
end

-- 使用主动道具 / 副主动道具 -> 触发 activity 动画。
-- MC_USE_ITEM 仅在主动道具【真正使用】时触发，覆盖所有槽位
-- （主槽 SLOT_PRIMARY / 副槽 SLOT_POCKET 等）；
-- 药丸走 MC_USE_PILL、卡牌走 MC_USE_CARD，天然不会命中本回调。
function mod:OnUseActiveItem(collectibleType, rng, player, useFlags, activeSlot, varData)
    if config.states.active then
        mod.activeItemTimer = eventDuration(config.activeItemDuration)
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
        mod.hurtTimer = eventDuration((config.hurt and config.hurt.duration) or 90)
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
        if config.toggleKey and config.toggleKey >= 0 then
            toggled = Input.IsButtonTriggered(config.toggleKey, 0)
        end
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
    -- 不被受击/卡牌等更高优先级事件打断（它们顺延到动画结束后再响应）。
    -- 必须同时要求 states.item 仍激活：loop+lock 组合下若道具被捡完/
    -- 换房后条件消失，锁定必须放行，否则状态机永久卡死在 item 动画。
    local topKey = nil
    local itemLocked = (mod.curState == "item" and mod.curAnimKey ~= nil
        and config.itemQuality and config.itemQuality.lock and states.item)
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
                mod:StartAnim(ak, mod:ItemPlaybackMode())
                mod.itemPlayedQ = q   -- 记录已播放质量
            else
                mod.curState = nil
                mod.itemPlayedQ = nil
                -- 该质量档素材缺失：抑制到条件消失（换房/质量变化），避免每帧重进
                -- 触发分支清掉眨眼/待机计时
                mod.suppressed["item"] = true
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
        -- item 锁定期间：房间最高质量变化时切换到新质量的动画
        -- （loop 模式常驻展示最新质量；once 模式下也会打断当前遍重播新质量）
        if topKey == "item" and config.itemQuality and config.itemQuality.enabled then
            local curQ = mod:ComputeItemQuality()
            if curQ and curQ ~= mod.itemPlayedQ then
                local ak = mod:ItemQualityAnimKey(curQ)
                if ak then
                    mod:StartAnim(ak, mod:ItemPlaybackMode())
                    mod.itemPlayedQ = curQ
                end
            end
        end
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
-- 受击检测（仅玩家；EARLY 优先级保证其它 mod 的回调抛错也不会跳过本判定）
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

-- 序列化：除 states/位置外，MCM 可调的全部配置项一并持久化，
-- 保证游戏内调整重启后不丢
local function serializeSettings()
    local st = {}
    for k, v in pairs(config.states) do st[k] = v end
    local w = config.wink or {}
    return {
        globalEnabled    = mod.enabled,
        toggleKey        = config.toggleKey,
        states           = st,
        activePet        = config.activePet,
        petFallback      = config.petFallback,
        scale            = config.scale,
        margin           = config.margin,
        offsetY          = config.offsetY,
        topData          = config.topData,
        animSpeed        = config.animSpeed,
        animFps          = config.animFps,
        winkEnabled      = w.enabled,
        winkMode         = w.mode,
        winkDelayMin     = w.delayMin,
        winkDelayMax     = w.delayMax,
        winkDelayFixed   = w.delayFixed,
        winkSadMode      = w.sadMode,
        winkSadDelayMin  = w.sadDelayMin,
        winkSadDelayMax  = w.sadDelayMax,
        winkSadDelayFixed = w.sadDelayFixed,
        idleMinMainTime  = config.idle and config.idle.minMainTime,
        idleChance       = config.idle and config.idle.triggerChancePerSec,
        hurtDuration     = config.hurt and config.hurt.duration,
        hurtNoPenalty    = config.hurt and config.hurt.ignoreNoPenalties,
        hurtMonster      = config.hurt and config.hurt.monsterDamage,
        cardpillDuration = config.cardpillDuration,
        activeItemDuration = config.activeItemDuration,
        iqEnabled        = config.itemQuality and config.itemQuality.enabled,
        iqMode           = config.itemQuality and config.itemQuality.mode,
        iqLock           = config.itemQuality and config.itemQuality.lock,
        iqGraceFrames    = config.itemQuality and config.itemQuality.graceFrames,
        hhThreshold      = config.halfHealth and config.halfHealth.threshold,
        hhSoulHearts     = config.halfHealth and config.halfHealth.countSoulHearts,
        hhOneThreshold   = config.halfHealth and config.halfHealth.oneHealthThreshold,
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
    if type(s.activePet)   == "string" and mod.petFrames[s.activePet] then
        config.activePet   = s.activePet
    end
    if type(s.petFallback) == "boolean" then config.petFallback = s.petFallback end
    if type(s.animSpeed)   == "number" and s.animSpeed > 0 then config.animSpeed = s.animSpeed end
    -- MCM 可调配置项（旧存档缺这些键时保持 config 默认值不动）
    if type(s.animFps) == "number" and config.animFps then config.animFps = s.animFps end
    local w = config.wink
    if type(w) == "table" then
        if type(s.winkEnabled) == "boolean" then w.enabled = s.winkEnabled end
        if (s.winkMode == "random" or s.winkMode == "fixed") then w.mode = s.winkMode end
        if type(s.winkDelayMin) == "number" then w.delayMin = s.winkDelayMin end
        if type(s.winkDelayMax) == "number" then w.delayMax = s.winkDelayMax end
        if type(s.winkDelayFixed) == "number" then w.delayFixed = s.winkDelayFixed end
        if (s.winkSadMode == "random" or s.winkSadMode == "fixed") then w.sadMode = s.winkSadMode end
        if type(s.winkSadDelayMin) == "number" then w.sadDelayMin = s.winkSadDelayMin end
        if type(s.winkSadDelayMax) == "number" then w.sadDelayMax = s.winkSadDelayMax end
        if type(s.winkSadDelayFixed) == "number" then w.sadDelayFixed = s.winkSadDelayFixed end
    end
    if type(config.idle) == "table" then
        if type(s.idleMinMainTime) == "number" then config.idle.minMainTime = s.idleMinMainTime end
        if type(s.idleChance) == "number" then config.idle.triggerChancePerSec = s.idleChance end
    end
    if type(config.hurt) == "table" then
        if type(s.hurtDuration) == "number" then config.hurt.duration = s.hurtDuration end
        if type(s.hurtNoPenalty) == "boolean" then config.hurt.ignoreNoPenalties = s.hurtNoPenalty end
        if type(s.hurtMonster) == "boolean" then config.hurt.monsterDamage = s.hurtMonster end
    end
    if type(s.cardpillDuration) == "number" then config.cardpillDuration = s.cardpillDuration end
    if type(s.activeItemDuration) == "number" then config.activeItemDuration = s.activeItemDuration end
    if type(config.itemQuality) == "table" then
        if type(s.iqEnabled) == "boolean" then config.itemQuality.enabled = s.iqEnabled end
        if (s.iqMode == "once" or s.iqMode == "loop") then config.itemQuality.mode = s.iqMode end
        if type(s.iqLock) == "boolean" then config.itemQuality.lock = s.iqLock end
        if type(s.iqGraceFrames) == "number" then config.itemQuality.graceFrames = s.iqGraceFrames end
    end
    if type(config.halfHealth) == "table" then
        if type(s.hhThreshold) == "number" then config.halfHealth.threshold = s.hhThreshold end
        if type(s.hhSoulHearts) == "boolean" then config.halfHealth.countSoulHearts = s.hhSoulHearts end
        if type(s.hhOneThreshold) == "number" then config.halfHealth.oneHealthThreshold = s.hhOneThreshold end
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
    mod:RefreshPet()   -- 读档后清缓存+重校验（存档可能换了角色/重新打开了缺失素材的状态）
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

    -- 选项循环选择：options = { {value=..., label=...}, ... }，NUMBER 1..#options
    local function addChoice(sub, get, set, options, label, info)
        MCM.AddSetting(N, sub, {
            Type = MCM.OptionType.NUMBER,
            CurrentSetting = function()
                local v = get()
                for i, o in ipairs(options) do
                    if o.value == v then return i end
                end
                return 1
            end,
            Minimum = 1, Maximum = math.max(1, #options), ModifyBy = 1,
            Display = function()
                local v = get()
                for _, o in ipairs(options) do
                    if o.value == v then return label .. "：" .. o.label end
                end
                return label .. "：" .. tostring(v)
            end,
            OnChange = function(i)
                local o = options[i]
                if o then set(o.value); mod:SaveSettings() end
            end,
            Info = info,
        })
    end

    -- 时长类设置：菜单里以秒为单位（step 0.5），存档/配置内为渲染帧（60帧=1秒）
    local function addNumSec(sub, getFrame, setFrame, minSec, maxSec, stepSec, label, info)
        MCM.AddSetting(N, sub, {
            Type = MCM.OptionType.NUMBER,
            CurrentSetting = function() return math.floor((getFrame() or 0) / 6 + 0.5) / 10 end,
            Minimum = minSec, Maximum = maxSec, ModifyBy = stepSec,
            Display = function()
                return label .. string.format("：%.1f 秒", (getFrame() or 0) / 60)
            end,
            OnChange = function(sec)
                setFrame(math.floor(sec * 60 + 0.5)); mod:SaveSettings()
            end,
            Info = info,
        })
    end

    -- 概率类设置：菜单里以百分比为单位，配置内为 0~1 小数
    local function addNumPct(sub, get, set, minPct, maxPct, stepPct, label, info)
        MCM.AddSetting(N, sub, {
            Type = MCM.OptionType.NUMBER,
            CurrentSetting = function() return math.floor((get() or 0) * 100 + 0.5) end,
            Minimum = minPct, Maximum = maxPct, ModifyBy = stepPct,
            Display = function()
                return label .. "：" .. tostring(math.floor((get() or 0) * 100 + 0.5)) .. "%"
            end,
            OnChange = function(pct) set(pct / 100); mod:SaveSettings() end,
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
            -- MCM 中按 ESC/左键会传入 nil（清键位语义）：保持原键不变，避免热键失效
            if type(k) ~= "number" or k < 0 then return end
            config.toggleKey = k
            config.toggleKeyName = keyName(k)
            mod:SaveSettings()
        end,
        Default = Keyboard.KEY_F3,   -- MCM 的 RESET 键恢复默认
        Info = { "游戏中按此键一键启用/停用叠加层" },
        PopupGfx = MCM.PopupGfx and MCM.PopupGfx.WIDE_SMALL or nil,
        Popup = function()
            return "当前：" .. keyName(config.toggleKey) .. "\n按新键设置，或 ESC 取消"
        end,
    })

    -- ---------- 桌宠角色（素材池切换） ----------
    MCM.AddText(N, "桌宠角色", function() return "桌宠角色素材池（最多 5 个角色）" end)
    MCM.AddSpace(N, "桌宠角色")
    MCM.AddText(N, "桌宠角色", function()
        return "可用角色(" .. #mod.petList .. ")：" .. table.concat(mod.petList, ", ")
    end)
    MCM.AddSpace(N, "桌宠角色")
    MCM.AddSetting(N, "桌宠角色", {
        Type = MCM.OptionType.NUMBER,
        CurrentSetting = function()
            local cur = mod:GetPet()
            for i, name in ipairs(mod.petList) do
                if name == cur then return i end
            end
            return 1
        end,
        Minimum = 1, Maximum = math.max(1, #mod.petList), ModifyBy = 1,
        Display = function() return "当前角色：" .. tostring(mod:GetPet()) end,
        OnChange = function(i)
            local name = mod.petList[i]
            if name then
                mod:SetPet(name)
                mod:SaveSettings()
            end
        end,
        Info = { "左右切换素材池中的桌宠角色，立即生效并存档",
                 "角色文件夹：resources/gfx/pets/<角色名>/",
                 "新增角色后运行 python gen_anim.py 重建清单" },
    })
    MCM.AddSpace(N, "桌宠角色")
    addBool("桌宠角色",
        function() return config.petFallback end,
        function(v) config.petFallback = v end,
        "缺素材时借用其它角色",
        { "开启：当前角色没有某动画时，按素材池顺序借用其它角色的同名动画",
          "关闭（默认）：缺失动画对应的事件不触发，桌宠保持待机动画",
          "切换后立即按新角色的素材重新校验各状态开关" })

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
    MCM.AddSpace(N, "状态开关")
    addBool("状态开关",
        function() return config.wink.enabled end,
        function(v) config.wink.enabled = v end,
        "眨眼循环动画",
        { "main 状态下循环眨眼，间隔在「眨眼间隔」页调整" })

    -- ---------- 动画速度 ----------
    MCM.AddText(N, "动画速度", function() return "全局动画播放速度" end)
    MCM.AddSpace(N, "动画速度")
    addNum("动画速度",
        function() return config.animSpeed end,
        function(v) config.animSpeed = v end,
        0.25, 4, 0.25, "动画速度倍率",
        { ">1 加速、<1 减速，作用在全部动画上", "实际每帧停留 = 原停留 / 倍率" })
    addNum("动画速度",
        function() return config.animFps end,
        function(v) config.animFps = v end,
        5, 60, 5, "默认动画帧率(fps)",
        { "未在 animHold 单独指定的动画：15 = 每 4 渲染帧换 1 帧", "越小越慢、越大越快" })

    -- ---------- 眨眼间隔 ----------
    MCM.AddText(N, "眨眼间隔", function() return "眨眼频率（满血/半血两档）" end)
    MCM.AddSpace(N, "眨眼间隔")
    local winkModeOptions = {
        { value = "random", label = "随机(random)" },
        { value = "fixed",  label = "固定(fixed)" },
    }
    addChoice("眨眼间隔",
        function() return config.wink.mode end,
        function(v) config.wink.mode = v end,
        winkModeOptions, "满血眨眼间隔模式",
        { "随机=每次眨眼后等 间隔下限~上限 的随机秒数", "固定=每两次眨眼间隔固定秒数" })
    addNumSec("眨眼间隔",
        function() return config.wink.delayMin end,
        function(v) config.wink.delayMin = v end,
        0.5, 30, 0.5, "满血随机间隔下限",
        { "仅随机(random)模式生效" })
    addNumSec("眨眼间隔",
        function() return config.wink.delayMax end,
        function(v) config.wink.delayMax = v end,
        0.5, 30, 0.5, "满血随机间隔上限",
        { "仅随机(random)模式生效" })
    addNumSec("眨眼间隔",
        function() return config.wink.delayFixed end,
        function(v) config.wink.delayFixed = v end,
        0.5, 30, 0.5, "满血固定间隔",
        { "仅固定(fixed)模式生效" })
    MCM.AddSpace(N, "眨眼间隔")
    addChoice("眨眼间隔",
        function() return config.wink.sadMode end,
        function(v) config.wink.sadMode = v end,
        winkModeOptions, "半血眨眼间隔模式",
        { "半血档的间隔模式，与满血档独立" })
    addNumSec("眨眼间隔",
        function() return config.wink.sadDelayMin end,
        function(v) config.wink.sadDelayMin = v end,
        0.5, 30, 0.5, "半血随机间隔下限",
        { "仅随机(random)模式生效" })
    addNumSec("眨眼间隔",
        function() return config.wink.sadDelayMax end,
        function(v) config.wink.sadDelayMax = v end,
        0.5, 30, 0.5, "半血随机间隔上限",
        { "仅随机(random)模式生效" })
    addNumSec("眨眼间隔",
        function() return config.wink.sadDelayFixed end,
        function(v) config.wink.sadDelayFixed = v end,
        0.5, 30, 0.5, "半血固定间隔",
        { "仅固定(fixed)模式生效" })

    -- ---------- 待机 ----------
    MCM.AddText(N, "待机", function() return "待机随机动画触发条件" end)
    MCM.AddSpace(N, "待机")
    addNumSec("待机",
        function() return config.idle.minMainTime end,
        function(v) config.idle.minMainTime = v end,
        1, 120, 1, "静置多久后开始待机",
        { "连续处于 main 状态满该时长后，才有概率触发待机动画" })
    addNumPct("待机",
        function() return config.idle.triggerChancePerSec end,
        function(v) config.idle.triggerChancePerSec = v end,
        0, 100, 5, "每秒触发概率",
        { "满足静置时长后，每秒按此概率随机播放一个待机动画" })

    -- ---------- 事件时长 ----------
    MCM.AddText(N, "事件时长", function() return "各事件状态持续时间" end)
    MCM.AddSpace(N, "事件时长")
    addNumSec("事件时长",
        function() return config.hurt.duration end,
        function(v) config.hurt.duration = v end,
        0.5, 10, 0.5, "受击动画持续时长",
        { "受击触发后的状态持续时间" })
    addNumSec("事件时长",
        function() return config.cardpillDuration end,
        function(v) config.cardpillDuration = v end,
        0.5, 10, 0.5, "卡牌/药丸动画持续时长",
        { "使用卡牌/药丸后的状态持续时间" })
    addNumSec("事件时长",
        function() return config.activeItemDuration end,
        function(v) config.activeItemDuration = v end,
        0.5, 10, 0.5, "主动道具动画持续时长",
        { "使用主动/副主动道具后的状态持续时间" })

    -- ---------- 受击 ----------
    MCM.AddText(N, "受击", function() return "受击动画触发范围" end)
    MCM.AddSpace(N, "受击")
    addBool("受击",
        function() return config.hurt.monsterDamage end,
        function(v) config.hurt.monsterDamage = v end,
        "怪物攻击也触发受击",
        { "角色受到怪物本体/敌方弹幕/激光/怪物炸弹伤害时也播放 hurt", "环境伤害判定不受影响" })
    addBool("受击",
        function() return config.hurt.ignoreNoPenalties end,
        function(v) config.hurt.ignoreNoPenalties = v end,
        "忽略非惩罚性伤害",
        { "带 DAMAGE_NO_PENALTIES 的伤害（不扣恶魔房概率等）不触发受击动画" })

    -- ---------- 道具质量 ----------
    MCM.AddText(N, "道具质量", function() return "房间道具质量动画（依赖 ReactionAPI）" end)
    MCM.AddSpace(N, "道具质量")
    addBool("道具质量",
        function() return config.itemQuality.enabled end,
        function(v) config.itemQuality.enabled = v end,
        "房间道具质量动画",
        { "房间存在未拾取道具时按最高质量播放 item0~item4", "需安装 ReactionAPI" })
    addChoice("道具质量",
        function() return config.itemQuality.mode end,
        function(v) config.itemQuality.mode = v end,
        { { value = "once", label = "播一遍(once)" }, { value = "loop", label = "持续循环(loop)" } },
        "播放模式",
        { "once=检测到质量变化时播一遍回 main", "loop=房间存在道具期间持续循环，质量变化时切换动画" })
    addBool("道具质量",
        function() return config.itemQuality.lock end,
        function(v) config.itemQuality.lock = v end,
        "道具动画播放期间不被打断",
        { "item 动画开始后播完为止", "受击/卡牌等事件顺延到结束后再响应" })
    addNumSec("道具质量",
        function() return config.itemQuality.graceFrames end,
        function(v) config.itemQuality.graceFrames = v end,
        0, 5, 0.5, "进新房检测冷却",
        { "进新房间后等待该时长再检测道具质量", "避免上一房间残留数据误触发（0.5秒=30帧）" })

    -- ---------- 半血判定 ----------
    MCM.AddText(N, "半血判定", function() return "半血状态触发阈值" end)
    MCM.AddSpace(N, "半血判定")
    addNum("半血判定",
        function() return config.halfHealth.threshold end,
        function(v) config.halfHealth.threshold = v end,
        0, 6, 1, "普通角色阈值(半心数)",
        { "总血量(半心为单位) <= 阈值时进入半血状态", "1 = 剩半颗红心触发（默认）" })
    addBool("半血判定",
        function() return config.halfHealth.countSoulHearts end,
        function(v) config.halfHealth.countSoulHearts = v end,
        "灵魂心/黑心计入总血量",
        { "开启后有魂心时更难触发半血" })
    addNum("半血判定",
        function() return config.halfHealth.oneHealthThreshold end,
        function(v) config.halfHealth.oneHealthThreshold = v end,
        0, 6, 1, "店主类角色阈值(半心数)",
        { "店主(Keeper)以整数心计算：2 = 1 整心（默认）" })

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
    MCM.AddText(N, "其它", function() return "调试选项" end)
    MCM.AddSpace(N, "其它")
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
