-- ==== 以撒 API mock（仅 .tmp_verify 测试用，不进游戏） ====
-- 提供最小全局面，让 config/profiles/frames/main 四个真文件可加载、可驱动

-- require 搜索路径指向 mod 根目录（config/profiles/frames 均加载真实文件）
package.path = "E:/Cache/RemoteStore/Isaac/internalreactionoverlay+/?.lua;" .. package.path

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

Sprite = function()
    return {
        Load = function() end, ReplaceSpritesheet = function() end,
        LoadGraphics = function() end, Play = function() end,
        GetSpriteResolution = function() return { X = 256, Y = 256 } end,
    }
end
Vector = function(x, y) return { X = x, Y = y, Zero = { X = 0, Y = 0 } } end
Color = function(r, g, b, a) return { R = r, G = g, B = b, A = a } end
Input = { IsButtonTriggered = function() return false end }

Isaac = {
    DebugString = function(s) print("[log] " .. tostring(s)) end,
    GetScreenWidth = function() return 512 end,
    GetScreenHeight = function() return 320 end,
    RenderText = function() end,
    GetTime = function() return 0 end,
}

Game = function()
    return {
        GetPlayer = function() return nil end,
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
