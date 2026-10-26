-- ==== InternalReactionOverlay+ v1.6 新功能回归测试 ====
-- 由 .tmp_verify/verify.mjs 在 fengari (Lua 5.3) 中执行，前置加载 mock_env.lua。
-- 覆盖：药丸/卡牌事件拆分（含缺素材回退）、桌宠突脸五阶段序列、
--       Lost/Tainted Lost 无圣盾悲伤常态、popup/lostSad 每角色存档往返。

local MODDIR = (os and os.getenv and os.getenv("IRO_MODDIR"))
    or "D:/RemoteStorge/InternalActionOverly-/internalreactionoverlay+"

local passCnt, failList = 0, {}
local function ok(cond, msg)
    if cond then
        passCnt = passCnt + 1
    else
        failList[#failList + 1] = msg
        print("[FAIL] " .. msg)
    end
end
local function eq(got, want, msg)
    ok(got == want, msg .. "（实际=" .. tostring(got) .. "，期望=" .. tostring(want) .. "）")
end

local function freshRequire()
    package.loaded["internalreactionoverlay_config"] = nil
    package.loaded["internalreactionoverlay_profiles"] = nil
    package.loaded["internalreactionoverlay_frames"] = nil
end

-- 启动一次干净会话：普通满血 Isaac 玩家、无房间道具、眨眼关闭（防随机干扰）
local function boot()
    freshRequire()
    _G.__testPlayer = _G.__makePlayer{ playerType = 0, hearts = 6, mantle = false }
    _G.__testQuality = nil
    _G.__lastRender = nil
    dofile(MODDIR .. "/main.lua")
    local m = _G.__mod
    local cfg = require("internalreactionoverlay_config")
    cfg.wink.enabled = false   -- 测试会话关闭眨眼循环（随机的 wink 会打断断言）
    return m, cfg
end

local function drive(m, n)
    for _ = 1, (n or 1) do m:OnRender() end
end

-- 轮询驱动直到条件成立，返回消耗帧数（超时返回 nil）
local function driveUntil(m, cond, maxF)
    for i = 1, (maxF or 1200) do
        m:OnRender()
        if cond() then return i end
    end
    return nil
end

-- ============================================================
--  P 组：药丸 / 卡牌事件拆分
-- ============================================================
do
    local m, cfg = boot()
    eq(m.pillPending, false, "P0 初始 pillPending=false")
    eq(m.cardPending, false, "P0 初始 cardPending=false")

    -- P1 药丸事件：Angle 无 pill 素材 -> 回退 cardpill 共用动画 Medicine
    m:OnUsePill(1, nil, 0)
    eq(m.pillPending, true, "P1 使用药丸置 pillPending")
    eq(m.cardPending, false, "P1 药丸不置 cardPending")
    drive(m, 1)
    eq(m.curState, "pill", "P1 药丸进入 pill 状态")
    eq(m.curAnimKey, "Medicine", "P1 缺 pill 素材回退 Medicine")
    drive(m, 100)
    eq(m.pillPending, false, "P1 药丸动画播完消费 pending")
    eq(m.curState, nil, "P1 播完回 main")

    -- P2 卡牌事件：同样回退 Medicine，但状态独立
    m:OnUseCard(1, nil, 0)
    eq(m.cardPending, true, "P2 使用卡牌置 cardPending")
    drive(m, 1)
    eq(m.curState, "card", "P2 卡牌进入 card 状态（与 pill 区分）")
    eq(m.curAnimKey, "Medicine", "P2 缺 card 素材回退 Medicine")
    drive(m, 100)

    -- P3 补上 pill 专属素材后不再回退；card 仍回退（区分两事件动画）
    m.petFrames[m:GetPet()]["pill"] = { "gfx/fake_pill.png" }
    m:OnUsePill(1, nil, 0)
    drive(m, 1)
    eq(m.curAnimKey, "pill", "P3 有 pill 素材时播专属 pill 动画")
    drive(m, 100)
    m:OnUseCard(1, nil, 0)
    drive(m, 1)
    eq(m.curAnimKey, "Medicine", "P3 card 无专属素材仍回退 Medicine")
    drive(m, 100)

    -- P4 状态开关独立：关 card 后卡牌无动画，药丸不受影响
    cfg.states.card = false
    m:OnUseCard(1, nil, 0)
    drive(m, 2)
    eq(m.curState, nil, "P4 关闭 card 状态后卡牌不触发")
    cfg.states.card = true

    -- P5 素材校验：缺专属素材但共用动画可用时，pill/card 状态不被自动禁用
    m:SanitizeConfig()
    eq(cfg.states.pill, true, "P5 pill 状态因回退链保持开启")
    eq(cfg.states.card, true, "P5 card 状态因回退链保持开启")
end

-- ============================================================
--  Q 组：桌宠突脸（默认事件 item4，方向 left）
-- ============================================================
do
    local m, cfg = boot()
    -- mock 屏幕 512×320；scale=0.5、素材 256 -> 有效尺寸 128；
    -- margin=-50 clamp 到 0、offsetY=-30 -> home=(0,192)
    _G.__testQuality = 4

    -- Q1 武装：item4 触发突脸（吞掉常规 item 动画）
    drive(m, 1)
    ok(m.popupArmed ~= nil, "Q1 item4 武装突脸")
    eq(m.itemPlayedQ, 4, "Q1 突脸消费 item 事件（记录质量）")
    eq(m.suppressed["item"], true, "Q1 突脸后抑制 item 常规重触发")
    eq(m.curState, nil, "Q1 未进入常规 item 状态")
    ok(m.popup == nil, "Q1 序列尚未启动（等渲染段取原位置）")

    -- Q2 启动：exit 阶段，原位置 = (0,192)
    drive(m, 1)
    ok(m.popup ~= nil and m.popup.phase == "exit", "Q2 序列启动 exit 阶段")
    eq(m.popup.homeX, 0, "Q2 原位置 X=0")
    eq(m.popup.homeY, 192, "Q2 原位置 Y=192")
    eq(m.curAnimKey, "main_static", "Q2 突脸期间回 main 常态")

    -- Q3 exit：向左滑出（x 单调递减出屏）
    drive(m, 15)
    ok(_G.__lastRender.x < 0, "Q3 exit 中途已向左移出（x<0）")
    ok(_G.__lastRender.sx == 0.5, "Q3 exit 期间保持常规缩放")
    ok(driveUntil(m, function() return m.popup and m.popup.phase == "enter" end) ~= nil,
       "Q3 exit 完成 -> enter")

    -- Q4 enter：宽度放大为窗口高度（320/256=1.25），从底部中点滑入至正中央
    drive(m, 15)
    ok(_G.__lastRender.sx == 1.25, "Q4 enter 放大倍率=窗口高/帧宽=1.25")
    ok(_G.__lastRender.x == 96, "Q4 enter 水平居中（中点 x=96）")
    ok(_G.__lastRender.y > 0, "Q4 enter 中途仍在自底部滑入（y>0）")
    ok(driveUntil(m, function() return m.popup and m.popup.phase == "play" end) ~= nil,
       "Q4 enter 完成 -> play")

    -- Q5 play：正中央播放 item4 事件动画（放大版）
    eq(_G.__lastRender.x, 96, "Q5 play 定位正中 x=96")
    eq(_G.__lastRender.y, 0, "Q5 play 定位正中 y=0（垂直居中）")
    ok(_G.__lastRender.sx == 1.25, "Q5 play 保持放大")
    -- 突脸期间事件冻结：药丸 pending 不打断序列
    m:OnUsePill(1, nil, 0)
    ok(driveUntil(m, function() return m.popup and m.popup.phase == "leave" end, 400) ~= nil,
       "Q5 item4（8帧×22hold）播完 -> leave")

    -- Q6 leave + return：原路退出、滑回原位置、恢复常态并进入冷却
    ok(driveUntil(m, function() return m.popup and m.popup.phase == "return" end) ~= nil,
       "Q6 leave 完成 -> return")
    ok(driveUntil(m, function() return m.popup == nil end) ~= nil, "Q6 return 完成，序列结束")
    eq(m.popupCooldown, cfg.popup.cooldownFrames, "Q6 结束后进入冷却(300)")
    eq(m.curAnimKey, "main_static", "Q6 结束回 main 常态")
    drive(m, 1)   -- 序列结束帧不渲染（结束判定在渲染前），下一帧常规渲染回原位
    ok(_G.__lastRender.x == 0 and _G.__lastRender.y == 192, "Q6 滑回原位置 (0,192)")
    ok(_G.__lastRender.sx == 0.5, "Q6 恢复常规缩放")
    -- 冻结的 pending 在序列结束后被响应（顺延不丢失）
    drive(m, 2)
    eq(m.curAnimKey, "Medicine", "Q6 突脸期间的药丸事件顺延播放")

    -- Q7 冷却：同事件再触发时走常规小动画，不再突脸
    drive(m, 100)
    m.suppressed["item"] = nil
    m.itemPlayedQ = nil
    drive(m, 2)
    eq(m.curState, "item", "Q7 冷却期 item 走常规状态")
    ok(m.popup == nil and m.popupArmed == nil, "Q7 冷却期不触发突脸")
    drive(m, 200)
    eq(m.curState, nil, "Q7 常规 item4 播完回 main")

    -- Q8 触发事件可换：popup.event="hurt"，受击触发突脸
    cfg.popup.event = "hurt"
    m.popupCooldown = 0
    m:OnPlayerTakeDmg(_G.__testPlayer, 1, DamageFlag.DAMAGE_FIRE, nil, 0)
    eq(m.hurtPending, true, "Q8 受击置 hurtPending")
    driveUntil(m, function() return m.popup ~= nil end, 10)
    ok(m.popup ~= nil, "Q8 popup.event=hurt 时受击触发突脸")
    eq(m.popup.animKey, "hurt", "Q8 突脸播放 hurt 动画")
    eq(m.hurtPending, false, "Q8 突脸消费 hurtPending")
    m:AbortPopup()   -- 后续组不再受本序列影响
end

-- ============================================================
--  L 组：Lost / Tainted Lost 无圣盾悲伤常态
-- ============================================================
do
    local m, cfg = boot()

    -- L1 Lost 无盾 -> main_sad（Lost 不判半血，纯圣盾判定）
    _G.__testPlayer = _G.__makePlayer{ playerType = PlayerType.PLAYER_THELOST, hearts = 0, mantle = false }
    drive(m, 2)
    eq(m.curAnimKey, "main_sad", "L1 Lost 无圣盾 -> main_sad")

    -- L2 拿到圣盾（Holy Mantle null effect）-> 即时切回 main_static
    _G.__testPlayer = _G.__makePlayer{ playerType = PlayerType.PLAYER_THELOST, hearts = 0, mantle = true }
    drive(m, 1)
    eq(m.curAnimKey, "main_static", "L2 Lost 有圣盾 -> main_static（即时切换）")

    -- L3 Tainted Lost 无盾 -> main_sad
    _G.__testPlayer = _G.__makePlayer{ playerType = PlayerType.PLAYER_THELOST_B, hearts = 0, mantle = false }
    drive(m, 1)
    eq(m.curAnimKey, "main_sad", "L3 堕化Lost 无圣盾 -> main_sad")

    -- L4 开关关闭：无盾也保持 main_static
    cfg.lostSad.enabled = false
    drive(m, 1)
    eq(m.curAnimKey, "main_static", "L4 lostSad 关闭 -> main_static")
    cfg.lostSad.enabled = true

    -- L5 普通角色不受影响：半血先播 half 事件动画（条件型），播完抑制后
    --     常态贴图才是 main_sad；满血为 main_static
    _G.__testPlayer = _G.__makePlayer{ playerType = 0, hearts = 1, mantle = false }
    drive(m, 1)
    eq(m.curAnimKey, "half", "L5 普通角色半血 -> 先播 half 事件动画（原有行为）")
    drive(m, 120)   -- half 10帧×hold9 播完 -> 抑制 -> 回 main（半血常态贴图）
    eq(m.curAnimKey, "main_sad", "L5 半血事件播完 -> 常态 main_sad（原有行为）")
    _G.__testPlayer = _G.__makePlayer{ playerType = 0, hearts = 6, mantle = false }
    drive(m, 1)
    eq(m.curAnimKey, "main_static", "L5 普通角色满血 -> main_static")

    -- L6 眨眼档位跟随：Lost 无盾时 IsSad()=true（用半血眨眼档 wink1）
    _G.__testPlayer = _G.__makePlayer{ playerType = PlayerType.PLAYER_THELOST, hearts = 0, mantle = false }
    drive(m, 1)
    eq(m:IsSad(), true, "L6 Lost 无盾 IsSad=true（眨眼走悲伤档）")
    _G.__testPlayer = _G.__makePlayer{ playerType = 0, hearts = 6, mantle = false }
    eq(m:IsSad(), false, "L6 普通满血 IsSad=false")

    -- L7 实测回归（2026-10-26）：游戏内无 NullItemEffect.ID_HOLY_MANTLE 枚举
    --    曾致检测被跳过恒 false——现走 HasCollectibleEffect(COLLECTIBLE_HOLY_MANTLE)
    eq(m:ComputeLostSad(_G.__makePlayer{ playerType = PlayerType.PLAYER_THELOST, mantle = false }),
       true, "L7 无盾 Lost 判悲伤（HasCollectibleEffect 路径）")
    eq(m:ComputeLostSad(_G.__makePlayer{ playerType = PlayerType.PLAYER_THELOST, mantle = true }),
       false, "L7 有盾 Lost 判正常")
    -- 玩家桩无 HasCollectibleEffect 方法（API 异常）：不误判悲伤
    eq(m:ComputeLostSad(_G.__makePlayer{ playerType = PlayerType.PLAYER_THELOST, noShieldApi = true }),
       false, "L7 检测方法缺失时跳过不误判")
    -- 非 Lost 角色（有盾无盾都不判悲伤）
    eq(m:ComputeLostSad(_G.__makePlayer{ playerType = 0, mantle = false }),
       false, "L7 非 Lost 角色不触发 Lost 悲伤")

    -- L8 Bug2 回归（2026-10-26）：pill/card 动画键须有 animHold，否则走
    --    animFps 兜底（60/15=4）导致比 Medicine（18）快 4.5 倍
    eq(require("internalreactionoverlay_config").animHold.pill, 18, "L8 animHold.pill=18")
    eq(require("internalreactionoverlay_config").animHold.card, 18, "L8 animHold.card=18")
end

-- ============================================================
--  R 组：popup / lostSad / pill / card 的每角色存档往返
-- ============================================================
do
    local m, cfg = boot()
    cfg.popup.event = "hurt"
    cfg.popup.exitDir = "up"
    cfg.popup.moveFrames = 45
    cfg.states.pill = false
    cfg.lostSad.enabled = false
    m:SaveSettings()
    local saved = m.savedData
    eq(saved.profiles[cfg.activePet].popupEvent, "hurt", "R1 popupEvent 入档")
    eq(saved.profiles[cfg.activePet].popupDir, "up", "R1 popupDir 入档")
    eq(saved.profiles[cfg.activePet].states.pill, false, "R1 states.pill 入档")

    -- R2 重启恢复
    local m2, cfg2 = boot()
    m2.savedData = saved
    m2:LoadSettings()
    m2:RefreshPet()
    eq(cfg2.popup.event, "hurt", "R2 popup.event 恢复")
    eq(cfg2.popup.exitDir, "up", "R2 popup.exitDir 恢复")
    eq(cfg2.states.pill, false, "R2 states.pill 恢复")
    eq(cfg2.lostSad.enabled, false, "R2 lostSad.enabled 恢复")

    -- R3 旧存档（v1.6 前无 popup/lostSad 键）：清洗后补出厂默认
    local m3, cfg3 = boot()
    m3.savedData = {
        version = 2, activePet = cfg3.activePet, globalEnabled = true,
        profiles = { [cfg3.activePet] = { scale = 0.7 } },
    }
    m3:LoadSettings()
    m3:RefreshPet()
    eq(cfg3.popup.event, "item4", "R3 旧档缺 popup 键补默认 item4")
    eq(cfg3.popup.exitDir, "left", "R3 旧档缺 popupDir 补默认 left")
    eq(cfg3.lostSad.enabled, true, "R3 旧档缺 lostSad 补默认开")
    eq(cfg3.scale, 0.7, "R3 旧档合法 scale 照常应用")
end

print(string.format("RESULT v16: pass=%d fail=%d", passCnt, #failList))
if #failList == 0 then
    print("ALL_TESTS_PASS")
else
    for _, m in ipairs(failList) do print("FAILED: " .. m) end
end
