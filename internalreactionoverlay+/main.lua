-- ============================================================
--  左下角叠加动画 Mod  (Overlay Mod)  v3 —— 多角色素材池版
--  适用：以撒的结合：忏悔+ (Repentance+)
--  功能：游戏左下角叠加一张 256×256 动画桌宠；【触发事件后】播放由
--        多张贴图组成的动画，播放完毕回到 main 动画循环随机播放；
--        main 播放期间偶尔随机触发待机动画。
--  角色素材池：resources/gfx/pets/<角色名>/（一个角色一个文件夹，最多 5 个），
--        通过 config.activePet / 模组配置菜单(MCM)切换使用的角色。
--  事件：药丸、卡牌（各自独立动画，缺素材回退共用动画）、主动/副主动道具使用、
--        Boss 战、半血、房间道具质量(item0~item4，依赖 ReactionAPI)、
--        桌宠突脸（触发指定事件时放大冲入画面中央播放后返回）。
--  动画帧来源：resources/gfx/pets/<角色>/（由 gen_anim.py 生成
--        internalreactionoverlay_frames.lua 多角色帧清单）。
--  API 参考：IsaacDocs (https://wofsauge.github.io/IsaacDocs/rep/)
-- ============================================================

local mod = RegisterMod("InternalReactionOverlay", 1)

-- ---------------------------------------------------------
--  配置与帧清单
-- ---------------------------------------------------------
local config = require("internalreactionoverlay_config")
-- 每桌宠角色独立配置模块：config 表是「当前角色的活动视图」，
-- 切换角色时整体换血；MCM/状态机照旧读写 config，无需感知 profile。
local Profiles = require("internalreactionoverlay_profiles")

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

-- ---------------------------------------------------------
--  每角色独立配置（profile）仓库
--  mod.petProfiles[角色名] = profile（出厂默认的个性化覆盖）。
--  新角色首次被选中时用出厂默认（defaultProfile）惰性生成。
-- ---------------------------------------------------------
-- 出厂默认快照：必须在 SanitizeConfig / 存档应用之前捕获，
-- 保证是 config.lua 的原始值而非运行期被改写后的值。
mod.defaultProfile = Profiles.CaptureFromConfig(config)
mod.petProfiles = {}
-- 活动视图当前归属的角色名（SaveActiveProfile 以它为准落仓，
-- 与 config.activePet 指针解耦：即使指针被手改也不至于把旧视图的
-- 调整记到新角色名下）
mod.activeProfilePet = config.activePet

-- 取角色 profile（惰性创建：新角色/存档缺失时回退出厂默认）
function mod:GetProfile(name)
    local p = mod.petProfiles[name]
    if type(p) ~= "table" then
        p = Profiles.DeepCopy(mod.defaultProfile)
        mod.petProfiles[name] = p
    end
    return p
end

-- 当前角色的活动 config 值写回其 profile（切换角色前/存档前调用）
function mod:SaveActiveProfile()
    local name = mod.activeProfilePet
    if type(name) ~= "string" or not mod.petFrames[name] then return end
    mod.petProfiles[name] = Profiles.CaptureFromConfig(config, mod.petProfiles[name])
end

-- 当前角色 profile 应用到 config（切换视图：之后 MCM/状态机读到的全是该角色的值）
function mod:LoadActiveProfile()
    local name = config.activePet
    if type(name) ~= "string" or not mod.petFrames[name] then return end
    Profiles.ApplyToConfig(mod:GetProfile(name), config)
    mod.activeProfilePet = name
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

-- 切换桌宠角色（校验存在性；换上该角色专属配置；刷新缓存与当前动画并存档）。
-- 每个角色的全部动画/外观设置（profile）互相独立：
--   1) 当前角色的最新调整写回其 profile；
--   2) 应用目标角色的 profile 到 config；
--   3) 按新角色素材重校验并重启动画。
function mod:SetPet(name)
    if type(name) ~= "string" or not mod.petFrames[name] then return false end
    if config.activePet == name then return true end
    mod:SaveActiveProfile()
    config.activePet = name
    mod:LoadActiveProfile()
    mod:RefreshPet()
    dlog("切换桌宠角色: " .. name .. "（已应用该角色独立配置）")
    return true
end

-- 角色/读档后刷新：清空帧 Sprite 缓存（缓存键已含路径，理论上可不清，
-- 但清掉可立刻释放旧角色显存并让素材热替换生效），重校验配置并重启 main 动画
function mod:RefreshPet()
    mod.frameSprites = {}
    mod.frameErrors = {}
    mod:AbortPopup()   -- 切换角色/读档：中止进行中的突脸序列
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

    -- 事件 spec -> 动画键集合（固定 key 或 variants 列表）。
    -- pill/card 额外并入 cardpill 共用动画键：专属素材缺失时回退共用动画，
    -- 状态不因缺专属素材而被禁用（老素材集行为不变）。
    local function eventKeys(stateKey, spec)
        local keys = {}
        if type(spec) == "table" and spec.key then
            keys[#keys + 1] = spec.key
        elseif type(spec) == "table" and type(spec.variants) == "table" then
            for _, v in ipairs(spec.variants) do
                if type(v) == "table" and v.key then keys[#keys + 1] = v.key end
            end
        end
        if stateKey == "pill" or stateKey == "card" then
            local cp = config.events and config.events.cardpill
            if type(cp) == "table" and cp.key then keys[#keys + 1] = cp.key end
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
        elseif stateKey == "wink" then
            -- 眨眼不属于 states 表（开关在 config.wink.enabled），单独判定
            local wc = (type(config.wink) == "table" and config.wink) or {}
            return hasKey(wc.animKey) or hasKey(wc.sadAnimKey)
        else
            local spec = config.events and config.events[stateKey]
            for _, k in ipairs(eventKeys(stateKey, spec)) do
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
    --     （_autoDisabled 是 config 表内临时标记，不写入存档/profile）
    if type(config._autoDisabled) ~= "table" then config._autoDisabled = {} end
    for stateKey in pairs(config._autoDisabled) do
        if stateHasAssets(stateKey) then
            if stateKey == "wink" then
                if config.wink and config.wink.enabled == false then
                    config.wink.enabled = true
                    dlog("素材已可用，自动恢复: wink")
                end
            elseif config.states[stateKey] == false then
                config.states[stateKey] = true
                dlog("素材已可用，自动恢复状态: " .. tostring(stateKey))
            end
            config._autoDisabled[stateKey] = nil
        end
    end

    -- 1) 固定事件状态：动画键全缺失 -> 禁用该状态（item 单独处理；
    --    pill/card 的键集已并入 cardpill 回退键，共用动画可用即不禁用）
    for stateKey, spec in pairs(config.events or {}) do
        if stateKey ~= "item" and stateKey ~= "cardpill"
            and config.states and config.states[stateKey] ~= nil then
            local keys = eventKeys(stateKey, spec)
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

    -- 4) main：从原始池过滤 entries（会话内反复切角色不会越滤越少）；
    --    sadStatic 缺失 -> 置 nil（渲染时回退 main_static）
    if type(config.main) == "table" then
        if type(config.main.entries) == "table" and #config.main.entries > 0 then
            -- 备份原始池（首次），切角色后仍从完整池按新角色素材重新过滤
            config.main._origEntries = config.main._origEntries or config.main.entries
            local kept = {}
            for _, e in ipairs(config.main._origEntries) do
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

    -- 5) wink：主/半血眨眼键都缺失 -> 禁用眨眼（打临时标记，素材恢复后自动重开）
    if config.wink and config.wink.enabled then
        local okWink = hasKey(config.wink.animKey)
        local okWink1 = hasKey(config.wink.sadAnimKey)
        if not okWink and not okWink1 then
            config.wink.enabled = false
            config._autoDisabled.wink = true
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

-- 事件触发闩锁（pending）：事件发生置 true，对应动画 once 播完才清——
-- 动画播多长状态就持续多久（帧数 × animHold ÷ animSpeed），无固定时长截断；
-- 被更高优先级动画打断时保持 pending，顺延到其播完后重新完整播放

mod.pillPending = false     -- 使用药丸（动画缺素材时回退 cardpill 共用动画）
mod.cardPending = false     -- 使用卡牌（动画缺素材时回退 cardpill 共用动画）
mod.activePending = false   -- 使用主动道具/副主动道具（药丸/卡牌不走此标记）
mod.hurtPending = false     -- 受击（触发类型见 config.hurt.damageFlags）

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

-- ---------------------------------------------------------
--  动画优先级（数值越大越优先，只有更高优先级能打断正在播放的动画）：
--    item4(90) > half(80) > item3(70) > item2(60) > item1(50) > item0(40)
--    > pill/card/Medicine(30) > active/Activity(20) > hurt(10) = boss(10)
--    > idle(5) > wink(2) > main(0，兜底不参与扫描)
--  item 状态按当前房间最高质量动态插入序列，因此 half 与 item 的相对
--  优先级随质量变化。同级（hurt = boss）不互相打断：先播者保持，
--  另一个顺延到其播完后再响应。
-- ---------------------------------------------------------
local STATE_PRIO = {
    half = 80, pill = 30, card = 30, active = 20, hurt = 10, boss = 10, idle = 5, wink = 2,
}
local ITEM_PRIO = { [0] = 40, [1] = 50, [2] = 60, [3] = 70, [4] = 90 }
local function statePrio(key, itemQ)
    if key == "item" then
        return ITEM_PRIO[itemQ] or 40
    end
    return STATE_PRIO[key] or 0
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

-- 事件状态 -> 实际可播放的动画键：先按 spec 解析，素材缺失时
-- pill/card 回退到 cardpill 共用动画（老素材集行为保持不变）。
-- 返回 nil = 该状态本次无素材可播。
function mod:ResolveEventKey(stateKey, spec)
    local key = mod:PickEventKey(spec)
    if key and mod:GetFrames(key) then return key end
    if stateKey == "pill" or stateKey == "card" then
        local cp = config.events and config.events.cardpill
        local fb = cp and mod:PickEventKey(cp)
        if fb and mod:GetFrames(fb) then return fb end
    end
    return nil
end

-- ---------------------------------------------------------
--  Lost / 堕化Lost 悲伤判定：角色在 lostSad.playerTypes 中且身上
--  没有 Holy Mantle 圣盾效果（圣斗篷道具/圣卡/堕化Lost固有盾均计入）
--  时返回 true。API 缺 NullItemEffect 枚举时按「有盾」处理（不误悲伤）。
-- ---------------------------------------------------------
function mod:ComputeLostSad(player)
    local ls = config.lostSad
    if not ls or not ls.enabled then return false end
    local okT, pType = pcall(function() return player:GetPlayerType() end)
    if not okT or not (ls.playerTypes and ls.playerTypes[pType]) then return false end
    local mantleId = (type(NullItemEffect) == "table") and NullItemEffect.ID_HOLY_MANTLE
    if not mantleId then return false end   -- 无该枚举的旧 API：跳过检测
    local ok, has = pcall(function() return player:HasNullEffect(mantleId) end)
    if ok and has then return false end     -- 有圣盾：正常形态
    return true
end

-- 常态贴图目标键：半血或 Lost 无盾 -> sadStatic（main_sad.png），否则 main_static
function mod:MainTargetKey(player)
    if config.main and config.main.sadStatic then
        local sad = mod:ComputeHalfHealth(player) or mod:ComputeLostSad(player)
        if sad then return config.main.sadStatic end
    end
    return "main_static"
end

-- 进入 main：常态贴图循环播放（半血/Lost 无盾时为 sadStatic）
function mod:StartMain()
    local key = "main_static"
    local p = Game():GetPlayer(0)
    if p then
        local ok, k = pcall(function() return mod:MainTargetKey(p) end)
        if ok and k then key = k end
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

-- 悲伤状态（半血 或 Lost/Tainted Lost 无圣盾）
function mod:IsSad()
    local p = Game():GetPlayer(0)
    if not p then return false end
    local ok, sad = pcall(function()
        return mod:ComputeHalfHealth(p) or mod:ComputeLostSad(p)
    end)
    if not ok then return false end
    return sad == true
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

-- 使用卡牌 -> 触发卡牌动画（专属素材缺失时回退 cardpill 共用动画）
function mod:OnUseCard(cardType, player, useFlags)
    if config.states.card then
        mod.cardPending = true   -- once 播完自动消费，无固定时长
    end
    return nil   -- 不拦截卡牌使用
end

-- 使用药丸 -> 触发药丸动画（专属素材缺失时回退 cardpill 共用动画）
function mod:OnUsePill(pillEffect, player, useFlags)
    if config.states.pill then
        mod.pillPending = true
    end
    return nil   -- 不拦截药丸使用
end

-- 使用主动道具 / 副主动道具 -> 触发 activity 动画。
-- MC_USE_ITEM 仅在主动道具【真正使用】时触发，覆盖所有槽位
-- （主槽 SLOT_PRIMARY / 副槽 SLOT_POCKET 等）；
-- 药丸走 MC_USE_PILL、卡牌走 MC_USE_CARD，天然不会命中本回调。
function mod:OnUseActiveItem(collectibleType, rng, player, useFlags, activeSlot, varData)
    if config.states.active then
        mod.activePending = true
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
        mod.hurtPending = true   -- once 播完自动消费，无固定时长；每次受伤都会置位
    end
    return nil   -- 不拦截伤害
end

-- ---------------------------------------------------------
--  桌宠突脸（Popup）序列
--  触发 config.popup.event 指定的事件时接管渲染，五阶段状态机：
--    exit   桌宠从原位置平滑滑出画面（方向 config.popup.exitDir）
--    enter  默认动画放大到「宽度 = 游戏窗口高度」，从窗口底部
--           边缘中点平滑滑入至画面正中央
--    play   在正中央播放该事件的动画（放大版，once 播完为止）
--    leave  从中央沿原路（底部中点方向）平滑滑出画面
--    return 桌宠沿移出方向原路平滑滑回原位置，恢复常态动画
--  序列期间常规状态机冻结（事件 pending 顺延到序列结束后处理）；
--  一次完整突脸结束后进入冷却（cooldownFrames），防连续事件刷屏。
-- ---------------------------------------------------------
mod.popup = nil           -- 激活中的突脸序列（nil = 未激活）
mod.popupArmed = nil      -- 待启动参数（状态机段解析事件后置位，
                          -- 渲染段算出常规渲染坐标后转正启动）
mod.popupCooldown = 0     -- 冷却剩余渲染帧

-- popup.event 是否匹配当前要触发的事件状态（itemN = item 状态且质量为 N）
function mod:PopupEventMatches(topKey, curQ)
    local pc = config.popup
    if not pc or not pc.enabled then return false end
    local ev = pc.event or "item4"
    local q = tonumber(ev:match("^item([0-4])$"))
    if q then
        return topKey == "item" and curQ == q
    end
    return topKey == ev
end

-- 突脸要播放的事件动画键（item 按质量，其余走事件 spec+回退链）
function mod:PopupAnimKey(topKey, curQ)
    if topKey == "item" then
        return curQ and mod:ItemQualityAnimKey(curQ) or nil
    end
    return mod:ResolveEventKey(topKey, config.events[topKey])
end

-- 状态机选出新高优先级事件时调用：命中突脸配置则武装序列并
-- 吞掉本次常规触发（返回 true）。无素材/冷却中返回 false 走常规动画。
function mod:TryArmPopup(topKey, curQ)
    if not mod:PopupEventMatches(topKey, curQ) then return false end
    if mod.popup or mod.popupArmed then return true end
    if mod.popupCooldown > 0 then return false end
    local animKey = mod:PopupAnimKey(topKey, curQ)
    if not animKey then return false end
    -- 该事件按「已由突脸播放完毕」处理：pending 型清闩锁，
    -- 条件型（boss/half/item）置抑制，序列结束后不立刻重触发
    if topKey == "hurt" then mod.hurtPending = false
    elseif topKey == "active" then mod.activePending = false
    elseif topKey == "pill" then mod.pillPending = false
    elseif topKey == "card" then mod.cardPending = false
    elseif topKey == "item" then
        mod.itemPlayedQ = curQ
        mod.suppressed["item"] = true
    else
        mod.suppressed[topKey] = true
    end
    mod.popupArmed = { animKey = animKey }
    dlog("突脸触发: " .. tostring(animKey))
    return true
end

-- 渲染段启动序列（homeX/homeY = 本帧常规渲染位置，即原位置）
function mod:BeginPopup(homeX, homeY, efw, efh)
    local armed = mod.popupArmed
    mod.popupArmed = nil
    if not armed then return end
    -- 序列期间常规状态机冻结：回 main 常态（exit/return 段渲染常态动画）
    mod.curState = nil
    mod.idlePlaying = false
    mod.idleKey = nil
    mod.winkPlaying = false
    mod.winkTimer = mod:NextWinkDelay()
    mod:StartMain()
    mod.popup = {
        phase = "exit", t = 0,
        animKey = armed.animKey,
        animFrame = 1, animTimer = 0,
        homeX = homeX, homeY = homeY,
        efw = efw, efh = efh,
    }
end

-- 突脸中途强行中止（总开关关闭/切换角色/新一局）：不进入冷却
function mod:AbortPopup()
    mod.popup = nil
    mod.popupArmed = nil
end

-- smoothstep 缓入缓出插值：t∈[0,1]
local function popupSmooth(t)
    return t * t * (3 - 2 * t)
end

-- 每渲染帧推进突脸序列并渲染放大/移动中的桌宠。
-- 返回 true = 序列仍在进行（调用方跳过常规渲染）。
-- colorMod = 与常规渲染一致的 (Color) 调制参数封装。
function mod:StepPopup(sw, sh)
    local P = mod.popup
    if not P then return false end
    local pc = config.popup or {}
    local moveF = tonumber(pc.moveFrames) or 30
    if moveF < 1 then moveF = 1 end
    local dir = pc.exitDir or "left"

    -- 移出画面的目标点（按方向完全出屏；每帧按当前窗口尺寸重算）
    local exitX, exitY = P.homeX, P.homeY
    if dir == "left" then exitX = -P.efw
    elseif dir == "right" then exitX = sw
    elseif dir == "up" then exitY = -P.efh
    else exitY = sh end

    -- 放大渲染参数：宽度 = 窗口高度（等比缩放），帧宽从主帧精灵读取
    local mainKey = "main_static"
    local pl = Game():GetPlayer(0)
    if pl then
        local ok, k = pcall(function() return mod:MainTargetKey(pl) end)
        if ok and k then mainKey = k end
    end
    local ms = mod:GetFrameSprite(mainKey, 1)
    local fw, fh = config.frameSize, config.frameSize
    if ms then
        pcall(function()
            local res = ms:GetSpriteResolution()
            if res and res.X and res.X > 0 then fw, fh = res.X, res.Y or res.Y end
        end)
    end
    local popScale = sh / fw
    local popW, popH = fw * popScale, fh * popScale
    local centerX = (sw - popW) / 2
    local centerY = (sh - popH) / 2

    P.t = P.t + 1
    local k = popupSmooth(math.min(1, P.t / moveF))

    -- 各阶段位置与显示内容
    local drawX, drawY, scale, animKey, frameIdx
    if P.phase == "exit" then
        drawX = P.homeX + (exitX - P.homeX) * k
        drawY = P.homeY + (exitY - P.homeY) * k
        scale = config.scale
        animKey, frameIdx = mod.curAnimKey, mod.curFrame   -- 常态动画滑出
        if P.t >= moveF then P.phase, P.t = "enter", 0 end
    elseif P.phase == "enter" then
        -- 从底部边缘中点外（顶边贴窗口底缘）滑入至正中央
        drawX = centerX
        drawY = sh + (centerY - sh) * k
        scale = popScale
        animKey, frameIdx = mainKey, 1
        if P.t >= moveF then P.phase, P.t = "play", 0 end
    elseif P.phase == "play" then
        drawX, drawY = centerX, centerY
        scale = popScale
        animKey, frameIdx = P.animKey, P.animFrame
        -- 事件动画帧推进（与常规状态机同一套节奏）
        local frames = mod:GetFrames(P.animKey)
        local delay = frameDelay(P.animKey)
        P.animTimer = P.animTimer + 1
        if P.animTimer >= delay and frames then
            P.animTimer = 0
            P.animFrame = P.animFrame + 1
            if P.animFrame > #frames then
                P.phase, P.t = "leave", 0   -- 播完 -> 原路退出
            end
        end
    elseif P.phase == "leave" then
        drawX = centerX
        drawY = centerY + (sh - centerY) * k
        scale = popScale
        animKey, frameIdx = mainKey, 1
        if P.t >= moveF then P.phase, P.t = "return", 0 end
    else   -- return：从屏外沿移出方向滑回原位置
        drawX = exitX + (P.homeX - exitX) * k
        drawY = exitY + (P.homeY - exitY) * k
        scale = config.scale
        animKey, frameIdx = mod.curAnimKey, mod.curFrame
        if P.t >= moveF then
            -- 序列结束：恢复常态，进入冷却
            mod.popup = nil
            mod.popupCooldown = tonumber(pc.cooldownFrames) or 300
            mod.curState = nil
            mod:StartMain()
            return false
        end
    end

    local s = (animKey and mod:GetFrameSprite(animKey, frameIdx)) or ms
    if s then
        local ok, err = pcall(function()
            s.Scale = Vector(scale, scale)
            s.Color = mod:OverlayColor()
            s:Update()
            s:Render(Vector(drawX, drawY), Vector.Zero, Vector.Zero)
        end)
        if not ok then dlog("突脸渲染失败: " .. tostring(err)) end
    end
    return true
end

-- 遮罩/高光/透明度调制色（常规渲染与突脸渲染共用同一套外观参数）
function mod:OverlayColor()
    local mask = tonumber(config.maskStrength) or 0
    if mask < 0 then mask = 0 elseif mask > 1 then mask = 1 end
    local bright = 1 - mask
    local hl = tonumber(config.highlightStrength) or 0
    if hl < 0 then hl = 0 elseif hl > 1 then hl = 1 end
    local opacity = tonumber(config.opacity)
    if type(opacity) ~= "number" then opacity = 1 end
    if opacity < 0 then opacity = 0 elseif opacity > 1 then opacity = 1 end
    return Color(bright, bright, bright, opacity, -hl, -hl, -hl)
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
        mod:AbortPopup()   -- 总开关关闭：中止进行中的突脸序列
        return
    end

    -- 突脸冷却递减
    if mod.popupCooldown > 0 then
        mod.popupCooldown = mod.popupCooldown - 1
    end

    -- 计算叠加图位置（物理像素坐标系）；突脸序列也用它取窗口尺寸
    local physW, physH = 512, 320
    pcall(function()
        local w = Isaac.GetScreenWidth()
        local h = Isaac.GetScreenHeight()
        if w and h and w > 0 and h > 0 then physW, physH = w, h end
    end)
    local sw, sh = physW, physH

    -- 突脸序列进行中：只推进/渲染突脸，常规状态机冻结
    -- （事件 pending 闩锁保持，序列结束后自然响应）
    if mod.popup then
        mod:StepPopup(sw, sh)
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

    -- 当前房间道具最高质量（item 状态激活判定 + 动态优先级共用）
    local curQ = safe(function() return mod:ComputeItemQuality() end, nil)

    -- 计算各状态激活与否（hurt/cardpill/active 为 pending 闩锁：
    -- 事件发生置位，动画 once 播完才消费，无固定时长截断）
    local states = {
        hurt     = config.states.hurt     and mod.hurtPending == true,
        pill     = config.states.pill     and mod.pillPending == true,
        card     = config.states.card     and mod.cardPending == true,
        active   = config.states.active   and mod.activePending == true,
        boss     = config.states.boss     and safe(function() return mod:ComputeBossFight() end, false),
        item     = config.states.item     and curQ ~= nil,
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
        if curQ and mod.itemPlayedQ and curQ ~= mod.itemPlayedQ then
            mod.suppressed["item"] = nil
        end
        if curQ == nil then
            mod.itemPlayedQ = nil
        end
    end

    -- 按动态优先级取最高激活且未被抑制的状态（main 是兜底不参与扫描）。
    -- 只有更高优先级能打断正在播放的动画；同级（hurt = boss）不互相打断，
    -- 落选的 pending 事件顺延，当前动画播完后重新完整播放。
    local topKey, topPrio = nil, -1
    for key, on in pairs(states) do
        if on and not mod.suppressed[key] then
            local p = statePrio(key, curQ)
            if p > topPrio or (p == topPrio and key == mod.curState) then
                topKey, topPrio = key, p
            end
        end
    end

    if topKey and topKey ~= mod.curState then
        -- 突脸接管：命中 popup 配置的事件时武装序列并吞掉本次常规触发
        if mod:TryArmPopup(topKey, curQ) then
            return   -- 本帧余下工作交给渲染段的 BeginPopup/StepPopup
        end
        -- 进入 / 切换到某事件状态：开始播放对应动画
        mod.curState = topKey
        if topKey == "idle" then
            mod:StartAnim(mod.idleKey or "idle1", "once")
        elseif topKey == "wink" then
            mod:StartAnim(mod:WinkKey(), "once")   -- 眨眼循环（独立于 idle；动画随血量切换）
        elseif topKey == "item" then
            -- 道具质量事件：按房间最高质量动态选择 item0~item4
            local q = curQ
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
            local vkey = mod:ResolveEventKey(topKey, spec)
            if vkey then
                mod:StartAnim(vkey, config.playback[topKey] or "once")
            else
                -- 选中键素材不可用（variants 部分缺失等）：回 main 并抑制，
                -- 防止每帧重进该状态（pill/card 回退链已在 ResolveEventKey 处理）
                mod.curState = nil
                mod.suppressed[topKey] = true
            end
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
        -- 常态贴图即时切换：半血 / Lost 无圣盾状态进入或解除时立即换图
        -- （StartMain 只在进入 main 时判定一次，条件中途翻转由这里响应）
        if mod.curAnimKey and config.main and config.main.sadStatic then
            local okTK, tk = pcall(function() return mod:MainTargetKey(player) end)
            if okTK and tk and tk ~= mod.curAnimKey then
                mod:StartMain()
            end
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
        -- 房间最高质量变化时切换到新质量的动画（优先级随质量变化：
        -- loop 模式常驻展示最新质量；once 模式下也会打断当前遍重播新质量）
        if topKey == "item" and config.itemQuality and config.itemQuality.enabled then
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
            -- once 播完 -> 消费该状态，立即回 main：
            --   pending 型（hurt/cardpill/active）：清闩锁（不置抑制——
            --     pending 无超时，若被抑制且 pending 恒真会永久卡死；
            --     连续受伤在下一次回调重新置位，自然重新触发）
            --   条件型（boss/half/item）：置抑制，条件消失后才可再触发
            if topKey == "pill" then mod.pillPending = false
            elseif topKey == "card" then mod.cardPending = false
            elseif topKey == "active" then mod.activePending = false
            elseif topKey == "hurt" then mod.hurtPending = false
            elseif topKey == "idle" then mod.idlePlaying = false
            elseif topKey == "wink" then
                -- 眨眼播完：重置随机间隔，等待下一次眨眼（仅满血）
                mod.winkPlaying = false
                mod.winkTimer = mod:NextWinkDelay()
            else
                mod.suppressed[topKey] = true
            end
            mod.curState = nil
            mod:StartMain()
        end
    end

    -- 叠加图渲染精灵与帧尺寸
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

    local drawX = math.min(math.max(0, posX), math.max(0, sw - efw))
    local drawY = math.min(math.max(0, posY), math.max(0, sh - efh))

    -- 突脸序列启动（状态机段已武装）：以本帧常规位置为「原位置」。
    -- 当帧仍按常规渲染（= exit 起点位置），下帧起由 StepPopup 接管。
    if mod.popupArmed then
        mod:BeginPopup(drawX, drawY, efw, efh)
    end

    if s then
        local ok, err = pcall(function()
            s.Scale = Vector(scale, scale)
            s.Color = mod:OverlayColor()
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

    mod.pillPending = false
    mod.cardPending = false
    mod.activePending = false
    mod.hurtPending = false
    mod.suppressed = {}
    mod.itemPlayedQ = nil
    mod.itemGraceTimer = 0
    mod.mainTimer = 0
    mod.idleSecAccum = 0
    mod.idlePlaying = false
    mod.idleKey = nil
    mod.winkPlaying = false
    mod.winkTimer = mod:NextWinkDelay()   -- 新一局：随机延迟后第一次眨眼
    mod:AbortPopup()      -- 新一局：中止残留的突脸序列
    mod.popupCooldown = 0
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

-- 序列化（存档格式 v2）：
--   * 全局项：总开关/快捷键/调试行/素材借用开关（所有角色共享）
--   * profiles：每角色一份独立配置（键集见 internalreactionoverlay_profiles.lua）
-- 当前角色的最新调整先写回 profile，再整体入库，保证 MCM 改动不丢。
local function serializeSettings()
    mod:SaveActiveProfile()
    return {
        version       = 2,
        globalEnabled = mod.enabled,
        toggleKey     = config.toggleKey,
        topData       = config.topData,
        petFallback   = config.petFallback,
        activePet     = config.activePet,
        profiles      = mod.petProfiles,
    }
end

local function applySettings(s)
    if type(s) ~= "table" then return end

    -- 全局项（所有角色共享；类型不合法时保持 config/mod 默认值不动）
    if type(s.globalEnabled) == "boolean" then mod.enabled = s.globalEnabled end
    if type(s.toggleKey) == "number" then
        config.toggleKey = s.toggleKey
        config.toggleKeyName = keyName(s.toggleKey)
    end
    if type(s.topData) == "boolean" then config.topData = s.topData end
    if type(s.debug) == "boolean" then config.topData = s.debug end   -- 更旧版本的键名
    if type(s.petFallback) == "boolean" then config.petFallback = s.petFallback end
    if type(s.activePet) == "string" and mod.petFrames[s.activePet] then
        config.activePet = s.activePet
    end

    if type(s.profiles) == "table" then
        -- v2：按角色还原 profile（只接受素材池中存在的角色；
        -- 每份 profile 白名单清洗，非法/缺失键回退出厂默认）
        for name, p in pairs(s.profiles) do
            if type(p) == "table" and mod.petFrames[name] then
                mod.petProfiles[name] = Profiles.SanitizeProfile(p, mod.defaultProfile)
            end
        end
    elseif s.version == nil then
        -- v1 旧存档迁移：旧格式是「全角色共享一份扁平配置」，提取为一份
        -- profile 克隆给素材池全部角色——升级后每个角色的行为与升级前一致，
        -- 之后再各自调整互不影响。
        local legacy = s
        -- 更旧版本的 margin 附增键兼容（与 v1 applySettings 行为一致）
        if type(s.cardSlotReserve) == "number" and type(s.margin) == "number" then
            legacy = Profiles.DeepCopy(s)
            legacy.margin = s.margin + s.cardSlotReserve
        end
        local migrated = Profiles.SanitizeProfile(legacy, mod.defaultProfile)
        for _, name in ipairs(mod.petList) do
            mod.petProfiles[name] = Profiles.DeepCopy(migrated)
        end
        dlog("检测到 v1 旧存档，已迁移为每角色独立配置")
    end

    mod:LoadActiveProfile()   -- 当前角色 profile -> config（切换活动视图）
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

    -- 每角色独立配置页的标题后缀：提示当前编辑的是哪个角色的配置
    local function petTag()
        return "｜当前角色：" .. tostring(mod:GetPet())
    end

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
        return "每个角色的全部设置独立保存，切换即应用其专属配置"
    end)
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
    MCM.AddText(N, "状态开关", function() return "各状态动画的独立开关" .. petTag() end)
    MCM.AddSpace(N, "状态开关")
    local stateLabels = {
        { "hurt",     "受击动画(火焰/爆炸/激光等)" },
        { "pill",     "药丸动画" },
        { "card",     "卡牌动画" },
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
    MCM.AddText(N, "动画速度", function() return "全局动画播放速度" .. petTag() end)
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
    MCM.AddText(N, "眨眼间隔", function() return "眨眼频率（满血/半血两档）" .. petTag() end)
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
    MCM.AddText(N, "待机", function() return "待机随机动画触发条件" .. petTag() end)
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

    -- ---------- 受击 ----------
    -- 注：v1.5 起事件动画不再有固定时长限制（pending 闩锁：播完整段才结束），
    -- 原「事件时长」页（hurt/cardpill/active 持续时长）随之移除；
    -- 播放节奏由「动画速度」页的 animHold/animFps/速度倍率决定。
    MCM.AddText(N, "受击", function() return "受击动画触发范围" .. petTag() end)
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
    MCM.AddText(N, "道具质量", function() return "房间道具质量动画（依赖 ReactionAPI）" .. petTag() end)
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
    addNumSec("道具质量",
        function() return config.itemQuality.graceFrames end,
        function(v) config.itemQuality.graceFrames = v end,
        0, 5, 0.5, "进新房检测冷却",
        { "进新房间后等待该时长再检测道具质量", "避免上一房间残留数据误触发（0.5秒=30帧）" })

    -- ---------- 半血判定 ----------
    MCM.AddText(N, "半血判定", function() return "半血状态触发阈值" .. petTag() end)
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
    MCM.AddSpace(N, "半血判定")
    addBool("半血判定",
        function() return config.lostSad.enabled end,
        function(v) config.lostSad.enabled = v end,
        "Lost无圣盾时悲伤常态",
        { "角色为 Lost/堕化Lost 且没有圣盾(Holy Mantle)时",
          "常态贴图切换为 main_sad.png，眨眼用半血档",
          "拿到圣斗篷/圣卡等圣盾效果后恢复 main.png" })

    -- ---------- 突脸 ----------
    MCM.AddText(N, "突脸", function() return "桌宠突脸（触发事件后放大冲入画面中央）" .. petTag() end)
    MCM.AddSpace(N, "突脸")
    addBool("突脸",
        function() return config.popup.enabled end,
        function(v) config.popup.enabled = v end,
        "启用桌宠突脸",
        { "触发下方所选事件时：桌宠滑出画面 -> 放大到宽度=窗口高度",
          "从底部中点滑入至正中央播放该事件动画 -> 原路退出滑回原位" })
    local popupEventOptions = {
        { value = "item0", label = "item0（0级道具）" },
        { value = "item1", label = "item1（1级道具）" },
        { value = "item2", label = "item2（2级道具）" },
        { value = "item3", label = "item3（3级道具）" },
        { value = "item4", label = "item4（4级道具）" },
        { value = "hurt",  label = "hurt（受击）" },
        { value = "boss",  label = "boss（Boss战）" },
        { value = "half",  label = "half（半血）" },
        { value = "active", label = "active（用主动道具）" },
        { value = "card",  label = "card（用卡牌）" },
        { value = "pill",  label = "pill（吃药丸）" },
    }
    addChoice("突脸",
        function() return config.popup.event end,
        function(v) config.popup.event = v end,
        popupEventOptions, "触发事件",
        { "该事件触发时以突脸方式播放（替代常规小动画）" })
    addChoice("突脸",
        function() return config.popup.exitDir end,
        function(v) config.popup.exitDir = v end,
        { { value = "left",  label = "向左(left)" },
          { value = "right", label = "向右(right)" },
          { value = "up",    label = "向上(up)" },
          { value = "down",  label = "向下(down)" } },
        "桌宠移出方向",
        { "突脸开始时桌宠按此方向滑出游戏画面" })
    addNumSec("突脸",
        function() return config.popup.moveFrames end,
        function(v) config.popup.moveFrames = v end,
        0.1, 3, 0.1, "每段移动时长",
        { "滑出/滑入/退出/滑回每段的时长（秒）" })
    addNumSec("突脸",
        function() return config.popup.cooldownFrames end,
        function(v) config.popup.cooldownFrames = v end,
        0, 60, 0.5, "结束后冷却",
        { "一次突脸结束后多久内不再触发（防连续事件刷屏）" })

    -- ---------- 外观 / 位置 ----------
    MCM.AddText(N, "外观位置", function() return "叠加动画尺寸与左下角位置" .. petTag() end)
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
    addNumPct("外观位置",
        function() return config.maskStrength end,
        function(v) config.maskStrength = v end,
        0, 100, 5, "遮罩强度",
        { "把桌宠整体按比例压暗：0%=原始亮度，100%=全黑", "暗部几乎不变；游戏滤镜过曝看不清面部时调大" })
    addNumPct("外观位置",
        function() return config.highlightStrength end,
        function(v) config.highlightStrength = v end,
        0, 100, 5, "高光强度",
        { "把桌宠整体线性减亮：越大压得越狠", "过曝亮部下降最明显，与遮罩强度互补可叠加" })
    addNumPct("外观位置",
        function() return config.opacity end,
        function(v) config.opacity = v end,
        0, 100, 5, "透明度",
        { "桌宠不透明度：100%=完全不透明，0%=全透", "调小可透出背后的游戏画面" })

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
