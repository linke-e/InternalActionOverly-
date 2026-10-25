-- ==== 以撒 API mock（仅 .tmp_verify 测试用，不进游戏） ====
-- 提供最小全局面，让 config/profiles/frames/main 四个真文件可加载、可驱动。
-- 模组目录优先取环境变量 IRO_MODDIR（verify.mjs 注入），否则回退硬编码。

local MODDIR = (os and os.getenv and os.getenv("IRO_MODDIR"))
    or "D:/RemoteStorge/InternalActionOverly-/internalreactionoverlay+"
package.path = MODDIR .. "/?.lua;" .. package.path

Keyboard = {
    KEY_F1 = 301, KEY_F2 = 302, KEY_F3 = 303, KEY_F4 = 304, KEY_F5 = 305,
    KEY_F6 = 306, KEY_F7 = 307, KEY_F8 = 308, KEY_F9 = 309, KEY_F10 = 310,
    KEY_F11 = 311, KEY_F12 = 312,
}

DamageFlag = {
    DAMAGE_FIRE = 1, DAMAGE_EXPLOSION = 2, DAMAGE_LASER = 4, DAMAGE_ACID = 8,
    DAMAGE_SPIKES = 16, DAMAGE_POOP = 32, DAMAGE_TNT = 64, DAMAGE_POISON_BURN = 128,
    DAMAGE_PITFALL = 256, DAMAGE_DEVIL = 512, DAMAGE_IV_BAG = 1024,
    DAMAGE_CHEST = 2048, DAMAGE_CURSED_DOOR = 4096, DAMAGE_TIMER = 8192,
    DAMAGE_RED_HEARTS = 16384, DAMAGE_COUNTDOWN = 32768, DAMAGE_CLONES = 65536,
    DAMAGE_ISSAC_HEART = 131072, DAMAGE_NO_PENALTIES = 1048576,
}

PlayerType = { PLAYER_THELOST = 10, PLAYER_THELOST_B = 11, PLAYER_KEEPER = 14, PLAYER_KEEPER_B = 15 }
RoomType = { ROOM_BOSS = 5, ROOM_BOSSRUSH = 9 }
EntityType = { ENTITY_PLAYER = 1, ENTITY_TEAR = 2, ENTITY_BOMB = 4, ENTITY_LASER = 7,
               ENTITY_PROJECTILE = 9, ENTITY_EFFECT = 1000 }
ModCallbacks = {
    MC_POST_RENDER = 1, MC_POST_HUD_RENDER = 2, MC_USE_CARD = 3, MC_USE_PILL = 4,
    MC_USE_ITEM = 5, MC_ENTITY_TAKE_DMG = 6, MC_POST_PLAYER_INIT = 7,
    MC_POST_NEW_ROOM = 8, MC_POST_GAME_STARTED = 9,
}
CallbackPriority = { EARLY = 0 }

-- Holy Mantle 圣盾 null effect 枚举（真实 API 见 IsaacDocs/NullItemEffect）
NullItemEffect = { ID_HOLY_MANTLE = 4 }

-- ReactionAPI mock：房间道具最高质量由测试变量控制
_G.__testQuality = nil
ReactionAPI = {
    Interface = {
        cGetBestQuality = function() return _G.__testQuality end,
    },
    Visibility = { VISIBLE = 1, ANY = 2 },
}

Sprite = function()
    return {
        Load = function() end, ReplaceSpritesheet = function() end,
        LoadGraphics = function() end, Play = function() end, Update = function() end,
        GetSpriteResolution = function() return { X = 256, Y = 256 } end,
        Render = function(self, pos)
            _G.__lastRender = {
                x = pos.X, y = pos.Y,
                sx = self.Scale and self.Scale.X, sy = self.Scale and self.Scale.Y,
            }
        end,
    }
end
-- Vector 需可调用且带静态 Zero（真实 API 的 Vector 是类）；Lua 不允许给
-- function 赋字段，故用 __call 元方法的 table 模拟
Vector = setmetatable(
    { Zero = { X = 0, Y = 0 } },
    { __call = function(_, x, y) return { X = x or 0, Y = y or 0 } end }
)
Color = function(r, g, b, a) return { R = r, G = g, B = b, A = a } end
Input = { IsButtonTriggered = function() return false end }

Isaac = {
    DebugString = function(s) end,
    GetScreenWidth = function() return 512 end,
    GetScreenHeight = function() return 320 end,
    RenderText = function() end,
    GetTime = function() return 0 end,
}

-- 可配置玩家桩：__makePlayer{playerType=, hearts=, soul=, mantle=}
function _G.__makePlayer(o)
    o = o or {}
    return {
        GetPlayerType = function() return o.playerType or 0 end,
        GetHearts = function() return o.hearts or 6 end,
        GetSoulHearts = function() return o.soul or 0 end,
        HasNullEffect = function(_, id)
            return (o.mantle == true) and id == NullItemEffect.ID_HOLY_MANTLE or false
        end,
        Position = { X = 0, Y = 0 },
        Velocity = { X = 0, Y = 0 },
    }
end
_G.__testPlayer = nil   -- 测试注入；nil = 游戏无玩家（OnRender 早退）

Game = function()
    return {
        GetPlayer = function() return _G.__testPlayer end,
        GetRoom = function()
            return { GetType = function() return 0 end, IsClear = function() return true end }
        end,
        GetLevel = function() return nil end,
    }
end

-- 存档 mock：encode/decode 以引用直传（存档内容=serializeSettings 原表）
package.preload["json"] = function()
    return {
        encode = function(t) return t end,
        decode = function(s) return s end,
    }
end

-- RegisterMod mock：暴露 _G.__mod 供测试驱动
function RegisterMod(name, ver)
    local m = { savedData = nil, Name = name }
    function m:AddCallback() end
    function m:RemoveCallback() end
    function m:AddPriorityCallback() end
    function m:SaveData(s) self.savedData = s end
    function m:LoadData() return self.savedData end
    function m:HasData() return self.savedData ~= nil end
    _G.__mod = m
    return m
end
