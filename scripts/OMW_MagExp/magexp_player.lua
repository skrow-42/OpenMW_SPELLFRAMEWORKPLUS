-- ============================================================
-- OMW_MagExp: Magic Expansion Framework for OpenMW
-- magexp_player.lua (PLAYER script)
--
-- Exposes the SharedRay targeting service to all mods.
-- ============================================================

local SharedRay = require('scripts.SharedRay_v1')

local anim      = require('openmw.animation')
local core      = require('openmw.core')

return {
    interfaceName = SharedRay.interfaceName,
    interface     = SharedRay.interface,
    engineHandlers = SharedRay.engineHandlers,
    eventHandlers = {
        AddVfx = function(data)
            pcall(function() anim.addVfx(self, data.model, data.options) end)
        end,
        RemoveVfx = function(vfxId)
            pcall(function() anim.removeVfx(self, vfxId) end)
        end,
        PlaySound3d = function(data)
            pcall(function() core.sound.playSound3d(data.sound, self) end)
        end,
        -- Framework hit broadcast
        MagExp_Local_MagicHit = function(data)
            -- Handled by player-specific logic if needed
        end,
    }
}
