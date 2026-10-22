-- ============================================================
--  InternalReactionOverlay+ —— 每桌宠角色独立配置（profile）模块
--  职责：
--    * 声明「每角色独立」的配置字段（SCHEMA，读写共用一份）
--    * config(活动视图) <-> profile(角色档案) 的捕获 / 应用 / 清洗
--  设计约定：
--    * 纯表操作、零游戏 API 依赖，可脱离以撒独立单测（.tmp_verify）。
--    * main.lua 中的 config 表始终是「当前角色的活动视图」：
--      MCM / 状态机照旧读写 config，切换角色时整体换血，
--      因此 MCM 适配层零改动即获得 per-pet 语义。
--    * profile 字段沿用 v1 存档的扁平键名（states/animHold 为嵌套表），
--      旧版单份配置存档可直接迁移（见 main.lua applySettings）。
--    * 持久化由 main.lua 统一负责：mod.petProfiles = { [角色名] = profile }
--      随 mod:SaveData 整体写入存档（以撒 API 只提供单存档槽，
--      「每角色一个文件」在存档内按角色名分节实现）。
-- ============================================================

local Profiles = {}

-- ---------------------------------------------------------
--  字段声明（key = profile 扁平键，沿用 v1 存档键名；
--  path = config 内取值路径；kind = "number"/"boolean" 或枚举数组；
--  gt/min = 可选数值下界约束）
-- ---------------------------------------------------------
Profiles.SCHEMA = {
    { key = "scale",              path = { "scale" },                          kind = "number" },
    { key = "margin",             path = { "margin" },                         kind = "number" },
    { key = "offsetY",            path = { "offsetY" },                        kind = "number" },
    { key = "maskStrength",       path = { "maskStrength" },                   kind = "number", min = 0 },
    { key = "highlightStrength",  path = { "highlightStrength" },              kind = "number", min = 0 },
    { key = "opacity",            path = { "opacity" },                        kind = "number", min = 0 },
    { key = "animSpeed",          path = { "animSpeed" },                      kind = "number", gt = 0 },
    { key = "animFps",            path = { "animFps" },                        kind = "number" },

    { key = "winkEnabled",        path = { "wink", "enabled" },                kind = "boolean",
      autoKey = "wink" },   -- _autoDisabled 中眨眼的键名为 "wink"（非 states 键）
    { key = "winkMode",           path = { "wink", "mode" },                   kind = { "random", "fixed" } },
    { key = "winkDelayMin",       path = { "wink", "delayMin" },               kind = "number" },
    { key = "winkDelayMax",       path = { "wink", "delayMax" },               kind = "number" },
    { key = "winkDelayFixed",     path = { "wink", "delayFixed" },             kind = "number" },
    { key = "winkSadMode",        path = { "wink", "sadMode" },                kind = { "random", "fixed" } },
    { key = "winkSadDelayMin",    path = { "wink", "sadDelayMin" },            kind = "number" },
    { key = "winkSadDelayMax",    path = { "wink", "sadDelayMax" },            kind = "number" },
    { key = "winkSadDelayFixed",  path = { "wink", "sadDelayFixed" },          kind = "number" },

    { key = "idleMinMainTime",    path = { "idle", "minMainTime" },            kind = "number" },
    { key = "idleChance",         path = { "idle", "triggerChancePerSec" },    kind = "number" },

    { key = "hurtNoPenalty",      path = { "hurt", "ignoreNoPenalties" },      kind = "boolean" },
    { key = "hurtMonster",        path = { "hurt", "monsterDamage" },          kind = "boolean" },

    { key = "iqEnabled",          path = { "itemQuality", "enabled" },         kind = "boolean" },
    { key = "iqMode",             path = { "itemQuality", "mode" },            kind = { "once", "loop" } },
    { key = "iqGraceFrames",      path = { "itemQuality", "graceFrames" },     kind = "number" },

    { key = "hhThreshold",        path = { "halfHealth", "threshold" },        kind = "number" },
    { key = "hhSoulHearts",       path = { "halfHealth", "countSoulHearts" },  kind = "boolean" },
    { key = "hhOneThreshold",     path = { "halfHealth", "oneHealthThreshold" }, kind = "number" },
}

-- 深拷贝（profile / defaults 均为纯数据表：number/string/boolean + 嵌套表）
function Profiles.DeepCopy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = Profiles.DeepCopy(v) end
    return r
end

-- 字段值是否满足声明（类型 / 枚举 / 下界）
function Profiles.ValidField(f, v)
    local kind = f.kind
    if type(kind) == "table" then
        for _, e in ipairs(kind) do
            if v == e then return true end
        end
        return false
    end
    if type(v) ~= kind then return false end
    if f.gt and not (v > f.gt) then return false end
    if f.min and not (v >= f.min) then return false end
    return true
end

-- 安全取嵌套路径（中间层非 table 视为缺失）
function Profiles.GetPath(t, path)
    local cur = t
    for i, k in ipairs(path) do
        if type(cur) ~= "table" then return nil end
        cur = cur[k]
    end
    return cur
end

-- 安全写嵌套路径（中间层非 table 则跳过，不隐式建表——config 由 config.lua 保证完整）
function Profiles.SetPath(t, path, v)
    local cur = t
    for i = 1, #path - 1 do
        if type(cur) ~= "table" then return end
        cur = cur[path[i]]
    end
    if type(cur) == "table" then cur[path[#path]] = v end
end

-- ---------------------------------------------------------
--  从 config(活动视图) 捕获当前角色的 profile。
--  prev（可选）：该角色旧 profile——被「素材缺失自动禁用」
--  （config._autoDisabled 标记）波及的字段不从 config 捕获，
--  改从 prev 继承，避免临时降级污染用户已保存的意图值。
-- ---------------------------------------------------------
function Profiles.CaptureFromConfig(config, prev)
    local p = {}
    local autoDis = (type(config) == "table" and type(config._autoDisabled) == "table")
        and config._autoDisabled or {}
    local prevTbl = (type(prev) == "table") and prev or {}

    for _, f in ipairs(Profiles.SCHEMA) do
        if autoDis[f.autoKey or f.key] then
            p[f.key] = prevTbl[f.key]     -- 临时自动禁用：保留原意图值
        else
            p[f.key] = Profiles.GetPath(config, f.path)
        end
    end

    -- states：autoDisabled 中的状态保留原意图值，其余照常捕获
    local st = {}
    local prevStates = (type(prevTbl.states) == "table") and prevTbl.states or {}
    for k, v in pairs((type(config) == "table" and config.states) or {}) do
        if autoDis[k] then
            if prevStates[k] ~= nil then st[k] = prevStates[k] end
        else
            st[k] = v
        end
    end
    p.states = st

    -- 注：animHold 不进 profile（无 MCM 编辑入口，per-role 快照只会阻断
    -- config.lua 出厂值更新传播），保持全局生效；旧存档里的 animHold
    -- 由 SanitizeProfile 白名单自动剔除。

    return p
end

-- ---------------------------------------------------------
--  把 profile 应用到 config(活动视图)。
--  合并语义：profile 中有的键覆盖，没有的键保留 config 现值
--  （config 现值即 config.lua 出厂值——新版本新增的出厂键
--  不会被旧 profile 丢掉）。只应用类型合法的键。
-- ---------------------------------------------------------
function Profiles.ApplyToConfig(p, config)
    if type(p) ~= "table" or type(config) ~= "table" then return end

    for _, f in ipairs(Profiles.SCHEMA) do
        local v = p[f.key]
        if Profiles.ValidField(f, v) then
            Profiles.SetPath(config, f.path, v)
        end
    end

    if type(p.states) == "table" and type(config.states) == "table" then
        for k, v in pairs(p.states) do
            if type(v) == "boolean" and config.states[k] ~= nil then
                config.states[k] = v
            end
        end
    end

    -- 注：animHold 不从 profile 应用（全局出厂值，见 CaptureFromConfig 注释）
end

-- 嵌套表字段清洗：只保留值类型合法的键；整表非法且 defaults 有合法表时用 defaults 深拷贝
function Profiles.SanitizeTableMap(t, defaults, valKind)
    if type(t) == "table" then
        local out = {}
        for k, v in pairs(t) do
            if type(v) == valKind then out[k] = v end
        end
        return out
    end
    if type(defaults) == "table" then
        return Profiles.DeepCopy(defaults)
    end
    return nil
end

-- ---------------------------------------------------------
--  清洗外部来源的 profile（存档/迁移）：按 SCHEMA 白名单重建，
--  非法或缺失的键用 defaults（出厂默认）补齐，剔除一切未知键，
--  保证写入 mod.petProfiles 的表结构恒定。
-- ---------------------------------------------------------
function Profiles.SanitizeProfile(p, defaults)
    local src = (type(p) == "table") and p or {}
    local def = (type(defaults) == "table") and defaults or {}
    local out = {}

    for _, f in ipairs(Profiles.SCHEMA) do
        if Profiles.ValidField(f, src[f.key]) then
            out[f.key] = src[f.key]
        elseif Profiles.ValidField(f, def[f.key]) then
            out[f.key] = def[f.key]
        end
    end

    out.states = Profiles.SanitizeTableMap(src.states, def.states, "boolean")

    return out
end

return Profiles
