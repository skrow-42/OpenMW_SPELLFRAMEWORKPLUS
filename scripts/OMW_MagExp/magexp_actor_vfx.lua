-- ============================================================
-- magexp_actor_vfx.lua (LOCAL script - attached to NPC/Creature targets)
-- ============================================================
--
-- Spell Framework Plus renders a hit static by sending `AddVfx` to the TARGET,
-- and this is the handler for a non-player actor.
--
-- PLACEMENT — `Animation::addEffect` (OpenMW, mwrender/animation.cpp) shifts a
-- boneless, transform-less effect by `height - 128` (and scales it by a factor
-- derived from 128), but only when `!mPtr.getClass().isNpc()`: creatures and
-- the Player get that centring, an NPC does not. So on an NPC the static stays
-- where its geometry is authored — around the 128-unit reference height, i.e.
-- at or above the top of the head — while on the Player it blooms around the
-- middle of the body. That is the difference this handler closes.
--
-- The correction is the engine's own, with the sign it has in the engine: move
-- the effect DOWN by `middle - 128`, where `middle` is the rise from the
-- actor's feet to the CENTRE of its bounding box, clamped into a 25..110 torso
-- band. `getBoundingBox` is a CULL-SAFE box (it merges every drawable's
-- `getInitialBound()`), so its half-size is deliberately generous and must
-- never be used as "the middle"; an earlier version did exactly that, and then
-- ADDED it on top of the reference height, which is what put the flash above
-- the actor's head.
--
-- Nothing is shifted when the placement is already decided: an explicit
-- `boneName` (the cast swirls pass the root bone "") or `transform` is handed
-- through untouched, and a creature/Player keeps the engine's centring.

local self = require('openmw.self')
local anim = require('openmw.animation')
local util = require('openmw.util')
local types = require('openmw.types')

local debugLog = require('scripts/OMW_MagExp/magexp_logger').new('[MagExp VFX Actor]')

-- anim.addVfx and anim.removeVfx both raise "Object has no animation" on an
-- actor that has none. These handlers used to wrap each call in pcall and
-- swallow the result, which hid the failure and also hid every other error the
-- call could raise. Ask first instead: the condition is queryable, and there
-- is nothing to undo when it is false.
local function hasAnimation()
    return anim.hasAnimation(self)
end

-- The height the vanilla hit statics are authored at (the engine's `128.f`
-- reference). Same constant, and same reasoning, as OSSC's
-- ossc_body_anchor.REFERENCE_HEIGHT: the two handlers must place an effect
-- identically, whichever one a target happens to carry.
local REFERENCE_HEIGHT = 128
-- The same torso band OSSC's ossc_body_anchor uses (25..80, fallback 70), so the
-- two handlers cannot place the same effect at two different heights.
local MIN_MIDDLE, MAX_MIDDLE = 25, 80

local function middleAboveBase()
    local bbox = self:getBoundingBox()
    local fallback = 70
    if not bbox then return fallback end
    local half = bbox.halfSize and bbox.halfSize.z
    local rise = (bbox.center and bbox.center.z and self.position)
        and (bbox.center.z - self.position.z) or nil
    local z = rise
    if half and half > 0 and z and z > half then z = half end
    if not z or z <= 0 then z = fallback end
    if z < MIN_MIDDLE then z = MIN_MIDDLE elseif z > MAX_MIDDLE then z = MAX_MIDDLE end
    return z
end

--- How far an attached static has to move along Z to sit on the body.
--- Zero when the engine already centres this actor (anything that is not an
--- NPC), so the caller can apply it unconditionally.
local function attachedOffset()
    if self.type ~= types.NPC then return 0 end
    return middleAboveBase() - REFERENCE_HEIGHT
end

--- The options a hit static is added with: the sender's table untouched when it
--- places the effect itself (or when the engine does), otherwise a copy
--- carrying the downward reference-height correction.
local function placedOptions(options)
    local offset = attachedOffset()
    if offset == 0 then return options end
    if type(options) == 'table' and (options.transform ~= nil or options.boneName ~= nil) then
        return options
    end
    local out = {}
    if type(options) == 'table' then
        for key, value in pairs(options) do out[key] = value end
    end
    out.transform = util.transform.move(0, 0, offset)
    return out
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
            anim.addVfx(self, data.model, placedOptions(data.options))
        end,
    }
}
