-- ============================================================
-- magexp_actor_vfx.lua (LOCAL script - attached to NPC/Creature targets)
-- ============================================================

local self = require('openmw.self')
local anim = require('openmw.animation')

local debugLog = require('scripts/OMW_MagExp/magexp_logger').new('[MagExp VFX Actor]')

-- anim.addVfx and anim.removeVfx both raise "Object has no animation" on an
-- actor that has none. These handlers used to wrap each call in pcall and
-- swallow the result, which hid the failure and also hid every other error the
-- call could raise. Ask first instead: the condition is queryable, and there
-- is nothing to undo when it is false.
local function hasAnimation()
    return anim.hasAnimation(self)
end

return {
    engineHandlers = {
        onActive = function()
            --debugLog("Script activated on " .. (self.recordId or "unknown"))
        end
    },
    eventHandlers = {
        RemoveVfx = function(tag)
            if not hasAnimation() then
                debugLog("RemoveVfx skipped - actor has no animation: "
                    .. tostring(self.recordId))
                return
            end
            anim.removeVfx(self, tag)
        end,
        AddVfx = function(data)
            if not data or not data.model then
                debugLog("AddVfx called with invalid data")
                return
            end
            if not hasAnimation() then
                debugLog("AddVfx skipped - actor has no animation: "
                    .. tostring(self.recordId))
                return
            end
            local opts = data.options or {}
            anim.addVfx(self, data.model, opts)
        end,
    }
}
