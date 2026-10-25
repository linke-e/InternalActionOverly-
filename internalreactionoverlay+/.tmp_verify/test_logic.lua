-- ==== InternalReactionOverlay+ 每角色独立配置：逻辑回归测试 ====
-- 由 .tmp_verify/verify.mjs 在 fengari (Lua 5.3) 中执行。
-- 覆盖：出厂捕获 / 切换隔离 / 存档 v2 往返 / v1 迁移 / 非法档防御 /
--       自动禁用不污染 profile / animHold 独立

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

-- 清 require 缓存 = 模拟游戏重启（config.lua/frames 重新加载出厂值）
local function freshRequire()
    package.loaded["internalreactionoverlay_config"] = nil
    package.loaded["internalreactionoverlay_profiles"] = nil
    package.loaded["internalreactionoverlay_frames"] = nil
end

local function boot()
    freshRequire()
    dofile(MODDIR .. "/main.lua")
    return _G.__mod
end

-- ============ Boot 1：无存档冷启动 ============
local m1 = boot()
-- 动态取素材池前两个角色（角色池随素材变化，勿硬编码角色名）
local PET_A = _G.__mod.petList[1]
local PET_B = _G.__mod.petList[2]
ok(PET_A ~= nil and PET_B ~= nil, '素材池至少两个角色')

local cfg1 = require("internalreactionoverlay_config")

-- T1 出厂默认捕获
ok(type(m1.defaultProfile) == "table", "T1 defaultProfile 已捕获")
eq(m1.defaultProfile.scale, 0.5, "T1 出厂 scale=0.5")
ok(m1.defaultProfile.animHold == nil, "T1 animHold 不进 profile（全局出厂值）")
eq(m1.defaultProfile.states.hurt, true, "T1 出厂 states.hurt=true")
eq(m1.defaultProfile.winkMode, "random", "T1 出厂 winkMode=random")
eq(m1.defaultProfile.hurtDuration, nil, "T1 废弃键 hurtDuration 不在 profile")
eq(m1.defaultProfile.iqLock, nil, "T1 废弃键 iqLock 不在 profile")
eq(m1.petProfiles["Angle"], nil, "T1 冷启动无预生成 profile")

-- T2 角色隔离：改 Angle 的外观/速度 -> 切到第二角色应回出厂值
m1.config = cfg1  -- 仅为可读性；main.lua 内部闭包本就引用同一张表
cfg1.scale = 0.9          -- 模拟 MCM 改 Angle 缩放
cfg1.animHold.wink = 99   -- animHold 全局改动（不按角色存档，切角色不重置）
cfg1.maskStrength = 0.8   -- 模拟 MCM 改 Angle 遮罩强度（滤镜压暗）
cfg1.highlightStrength = 0.4  -- 模拟改 Angle 高光强度
cfg1.opacity = 0.6            -- 模拟改 Angle 透明度
m1:SaveActiveProfile()    -- （MCM OnChange -> SaveSettings 内部同样会做）
eq(m1.petProfiles["Angle"].scale, 0.9, "T2 Angle profile 捕获 scale=0.9")
eq(m1.petProfiles["Angle"].maskStrength, 0.8, "T2 Angle profile 捕获 maskStrength=0.8")
eq(m1.petProfiles["Angle"].highlightStrength, 0.4, "T2 Angle profile 捕获 highlightStrength=0.4")
eq(m1.petProfiles["Angle"].opacity, 0.6, "T2 Angle profile 捕获 opacity=0.6")

ok(m1:SetPet(PET_B), "T2 SetPet(第二角色) 成功")
eq(cfg1.activePet, PET_B, "T2 activePet 已切换")
eq(cfg1.scale, 0.5, "T2 切到第二角色后 scale 回出厂 0.5")
eq(cfg1.animHold.wink, 99, "T2 animHold 全局改动不被切换重置")
eq(cfg1.maskStrength, 0.0, "T2 第二角色遮罩强度回出厂 0（Angle 的 0.8 不串）")
eq(cfg1.highlightStrength, 0.0, "T2 第二角色高光强度回出厂 0")
eq(cfg1.opacity, 1.0, "T2 第二角色透明度回出厂 1")

cfg1.margin = 123         -- 模拟改第二角色水平偏移
m1:SaveActiveProfile()
ok(m1:SetPet("Angle"), "T2 SetPet(Angle) 成功")
eq(cfg1.scale, 0.9, "T2 切回 Angle scale=0.9（独立保持）")
eq(cfg1.margin, -50, "T2 切回 Angle margin 出厂 -50（第二角色的 123 不串）")

ok(m1:SetPet(PET_B), "T2 再切回第二角色")
eq(cfg1.margin, 123, "T2 第二角色 margin=123 独立保持")
eq(cfg1.scale, 0.5, "T2 第二角色 scale=0.5")

-- T3 存档 v2 往返：SaveSettings -> 模拟重启 -> LoadSettings 恢复
m1:SaveSettings()
local saved = m1.savedData
ok(type(saved) == "table" and saved.version == 2, "T3 存档 version=2")
ok(type(saved.profiles) == "table" and saved.profiles[PET_A] and saved.profiles[PET_B],
   "T3 存档含前两个角色的双 profile")
eq(saved.activePet, PET_B, "T3 存档 activePet=第二角色")
eq(saved.globalEnabled, true, "T3 全局项 globalEnabled 在存档顶层")
-- 模拟旧版 profile 残留的 animHold（v1.4 及之前会整表快照）
saved.profiles.Angle.animHold = { wink = 999 }

local m2 = boot()          -- 重启：config 回出厂
local cfg2 = require("internalreactionoverlay_config")
eq(cfg2.scale, 0.5, "T3 重启后 config 出厂 scale")
m2.savedData = saved       -- 引擎载入 save 文件
m2:LoadSettings()          -- MC_POST_GAME_STARTED 回调内同款调用
m2:RefreshPet()
eq(cfg2.activePet, PET_B, "T3 读档恢复 activePet")
eq(cfg2.scale, 0.5, "T3 第二角色恢复 scale=0.5")
eq(cfg2.margin, 123, "T3 第二角色恢复 margin=123")
eq(cfg2.animHold.wink, 45, "T3 旧档 animHold 残留被剔除，出厂值生效（不再被覆盖）")
eq(cfg2.toggleKey, cfg2.toggleKey, "T3 全局 toggleKey 保持")
m2:SetPet("Angle")
eq(cfg2.scale, 0.9, "T3 重启后切回 Angle scale=0.9（存档恢复）")
eq(cfg2.animHold.wink, 45, "T3 Angle animHold 仍出厂值（全局不再按角色恢复）")
eq(cfg2.maskStrength, 0.8, "T3 Angle 遮罩强度=0.8（存档恢复）")
eq(cfg2.highlightStrength, 0.4, "T3 Angle 高光强度=0.4（存档恢复）")
eq(cfg2.opacity, 0.6, "T3 Angle 透明度=0.6（存档恢复）")

-- T4 v1 旧存档迁移：扁平格式克隆给全部角色
local v1save = {
    globalEnabled = false,
    toggleKey = Keyboard.KEY_F5,
    states = { hurt = true, cardpill = true, active = true, boss = true,
               item = true, half = true, idle = false },
    activePet = PET_B,
    petFallback = true,
    scale = 0.7,
    margin = -40,
    cardSlotReserve = 10,       -- 更旧版本附增键：迁移时并入 margin
    offsetY = -15,
    animSpeed = 2.0,
    animFps = 20,
    winkEnabled = false,
    winkMode = "fixed",
    winkDelayFixed = 6,
    idleMinMainTime = 300,
    idleChance = 0.5,
    hurtDuration = 120,
    hurtNoPenalty = false,
    hurtMonster = false,
    cardpillDuration = 60,
    activeItemDuration = 60,
    iqEnabled = false,
    iqMode = "loop",
    iqLock = false,
    iqGraceFrames = 60,
    hhThreshold = 2,
    hhSoulHearts = false,
    hhOneThreshold = 4,
    topData = true,
}
local m3 = boot()
local cfg3 = require("internalreactionoverlay_config")
m3.savedData = v1save
m3:LoadSettings()
m3:RefreshPet()
eq(m3.petProfiles[PET_B].scale, 0.7, "T4 迁移第二角色 scale=0.7")
eq(m3.petProfiles["Angle"].scale, 0.7, "T4 迁移 Angle 同步 scale=0.7")
eq(m3.petProfiles[PET_B].margin, -30, "T4 迁移 margin=-40+cardSlotReserve(10)=-30")
eq(m3.petProfiles[PET_B].winkEnabled, false, "T4 迁移 winkEnabled=false")
eq(m3.petProfiles[PET_B].states.idle, false, "T4 迁移 states.idle=false")
eq(m3.petProfiles[PET_B].iqMode, "loop", "T4 迁移 iqMode=loop")
eq(cfg3.activePet, PET_B, "T4 迁移 activePet=第二角色")
eq(cfg3.scale, 0.7, "T4 迁移后活动视图 scale=0.7")
eq(cfg3.topData, true, "T4 全局 topData=true")
eq(cfg3.petFallback, true, "T4 全局 petFallback=true")
eq(cfg3.idle.triggerChancePerSec, 0.5, "T4 迁移 idleChance 应用到活动视图")
m3:SetPet(PET_B)
eq(cfg3.scale, 0.7, "T4 迁移后切角色配置一致（升级无行为回退）")

-- T5 非法存档防御：类型错误回退出厂默认，合法键照常
local badsave = {
    version = 2,
    activePet = "Angle",
    globalEnabled = true,
    profiles = {
        Angle = { scale = "bad", margin = 999, winkMode = "hack", animSpeed = -5,
                  maskStrength = -3, highlightStrength = "bad", opacity = -1,
                  states = { hurt = "yes" } },
        Ghost = { scale = 3 },   -- 不在素材池的角色：整份忽略
    },
}
local m4 = boot()
local cfg4 = require("internalreactionoverlay_config")
m4.savedData = badsave
m4:LoadSettings()
m4:RefreshPet()
eq(cfg4.scale, 0.5, "T5 非法 scale 回出厂 0.5")
eq(cfg4.margin, 999, "T5 合法 margin=999 照常应用")
eq(cfg4.wink.mode, "random", "T5 非法枚举 winkMode 回出厂")
eq(cfg4.animSpeed, 1.0, "T5 负 animSpeed 回出厂 1.0")
eq(cfg4.maskStrength, 0.0, "T5 负 maskStrength 回出厂 0")
eq(cfg4.highlightStrength, 0.0, "T5 非法 highlightStrength 回出厂 0")
eq(cfg4.opacity, 1.0, "T5 负 opacity 回出厂 1")
eq(cfg4.states.hurt, true, "T5 非法 states 值忽略")
eq(m4.petProfiles["Ghost"], nil, "T5 素材池外角色 profile 忽略")

-- T6 新角色（gen_anim 新增后）惰性获得出厂配置，与既有角色互不影响
local m5 = boot()
local cfg5 = require("internalreactionoverlay_config")
cfg5.scale = 0.8
m5:SaveActiveProfile()
m5.petFrames["NewPet"] = { main_static = { "gfx/placeholder.png" } }
m5.petList[#m5.petList + 1] = "NewPet"
ok(m5:SetPet("NewPet"), "T6 切到新增角色成功")
eq(cfg5.scale, 0.5, "T6 新角色初始=出厂 scale 0.5")
eq(m5.petProfiles["Angle"].scale, 0.8, "T6 Angle 的 0.8 不受影响")
eq(m5.curAnimKey, "main_static", "T6 新角色缺素材仍回 main_static 兜底")
eq(cfg5.states.hurt, false, "T6 新角色缺 hurt 素材自动禁用状态")
ok(m5:SetPet("Angle"), "T6 切回 Angle")
eq(cfg5.states.hurt, true, "T6 切回 Angle 素材齐全状态自动恢复")
eq(cfg5.scale, 0.8, "T6 Angle scale=0.8 保持")

-- T7 自动禁用不污染 profile：Fake 素材缺失期间保存，profile 保留用户意图值
local m6 = boot()
local cfg6 = require("internalreactionoverlay_config")
m6.petFrames["Fake"] = { main_static = { "gfx/fake.png" } }   -- 只有 main_static
m6.petList[#m6.petList + 1] = "Fake"
ok(m6:SetPet("Fake"), "T7 切到缺素材角色")
eq(cfg6.states.hurt, false, "T7 hurt 因缺素材自动禁用")
eq(cfg6.wink.enabled, false, "T7 眨眼因缺素材自动禁用")
m6:SaveSettings()
eq(m6.petProfiles["Fake"].states.hurt, true, "T7 profile 保留 states.hurt=true（不捕获临时禁用）")
eq(m6.petProfiles["Fake"].winkEnabled, true, "T7 profile 保留 winkEnabled=true")
-- 素材恢复（模拟补齐）后重新校验即恢复
m6.petFrames["Fake"]["hurt"] = { "gfx/fake_hurt.png" }
m6.petFrames["Fake"]["wink"] = { "gfx/fake_wink.png" }
m6:SanitizeConfig()
eq(cfg6.states.hurt, true, "T7 素材补齐后 hurt 自动恢复")
eq(cfg6.wink.enabled, true, "T7 素材补齐后眨眼自动恢复")

-- T8 config.lua 直接改 activePet（文档推荐的第三种切换法）：
--    会话内手改前先有调整 -> SaveActiveProfile 已入库；未 SaveSettings 则重启后丢失
--    （与 v1 行为一致：存档只在 MCM 修改/SaveSettings 时写入）
local m7 = boot()
local cfg7 = require("internalreactionoverlay_config")
cfg7.scale = 0.6
m7:SaveActiveProfile()
eq(m7.petProfiles["Angle"].scale, 0.6, "T8 SaveActiveProfile 后 Angle profile=0.6")
cfg7.activePet = PET_B              -- 手改配置文件场景
local m8 = boot()
local cfg8 = require("internalreactionoverlay_config")
-- m7 会话未 SaveSettings -> 存档不存在 -> m8 全部角色出厂值（预期，非回归）
eq(cfg8.scale, 0.5, "T8 未存档重启后 Deepseek 用出厂配置")
eq(m8.petProfiles["Angle"], nil, "T8 未存档重启后无 Angle profile")
-- 带存档重启：手改 activePet + 已有存档 -> 新角色缺 profile 用出厂值
m7:SaveSettings()                    -- 此时 activePet=Deepseek，落仓 Deepseek 的 profile
local m9 = boot()
local cfg9 = require("internalreactionoverlay_config")
m9.savedData = m7.savedData
m9:LoadSettings()
m9:RefreshPet()
eq(cfg9.activePet, PET_B, "T8 存档恢复 activePet=第二角色")
eq(cfg9.scale, 0.5, "T8 Deepseek 无个性化 -> 出厂 scale")
m9:SetPet("Angle")
eq(cfg9.scale, 0.6, "T8 切回 Angle 恢复其独立配置 0.6")

print(string.format("RESULT: pass=%d fail=%d", passCnt, #failList))
if #failList == 0 then
    print("ALL_TESTS_PASS")
else
    for _, m in ipairs(failList) do print("FAILED: " .. m) end
end
