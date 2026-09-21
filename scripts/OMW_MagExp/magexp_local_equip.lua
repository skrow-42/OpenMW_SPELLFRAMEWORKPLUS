-- ============================================================
-- Spell Framework Plus — equipment hand-off (shared local helper)
--
-- `types.Actor.setEquipment` is a *self-only* binding: the engine declares it
-- as `(const SelfObject&, const sol::table&)`, so a global script that writes
-- the equipment of another actor raises
--     Allowed only in local scripts for 'openmw.self'
-- and takes the whole timer callback down with it.  The effect-penalty sweep
-- runs in the GLOBAL script, so it cannot equip the reduced twin of a bound
-- item (or of a summon's gear) itself - it has to ask the actor that owns the
-- slot, which is what this module is for.
--
-- The global side prepares everything a local script cannot do: it generates
-- the reduced record, creates the instance and moves it into the actor's
-- inventory.  It then sends `MagExp_EquipReducedItem` with
--     { slot = <number>, recordId = <string>, token = <string> }
-- to the actor.  The local host - `magexp_actor_stats.lua` on a summon,
-- `magexp_player.lua` on the player, the two scripts already attached to the
-- actors the penalty touches - calls `onRequest(self, data)`, which equips the
-- new instance in the requested slot and reports the outcome back with
-- `MagExp_EquipReducedItemApplied`.  The sweep repeats the request until that
-- report arrives (the same bounded retry it uses for the stat scale) and only
-- then removes the full-strength original.
--
-- Every value in the table is a record-id *string*: the engine resolves a
-- string through `findInInventory` (a search of the actor's own store), while
-- an unresolvable object reference would be refused.  `setEquipment` also
-- unequips every slot the table does not mention, so the table is rebuilt from
-- the actor's whole current equipment and only the requested slot changes.
-- ============================================================

local core = require('openmw.core')
local types = require('openmw.types')

local debugLog = require('scripts/OMW_MagExp/magexp_logger').new('[MagExp Equip]')

local M = {}

local function recordIdText(value)
    if type(value) == 'string' then return value end
    if (type(value) == 'userdata' or type(value) == 'table') and value.recordId ~= nil then
        return tostring(value.recordId)
    end
    return nil
end

--- The actor's equipment, with `slot` set to `recordId` (a nil `recordId` clears
--- the slot). `getEquipment` hands out a fresh table, so mutating it is safe.
--- Existing equipped items in all other slots are preserved so quickcasting a
--- bound weapon does not unequip the actor's armor, jewelry or clothing.
function M.equipmentTable(self, slot, recordId)
    local out = {}
    local current = types.Actor.getEquipment(self)
    if type(current) == 'table' then
        for currentSlot, item in pairs(current) do
            if currentSlot ~= slot then
                if type(item) == 'userdata' or type(item) == 'table' then
                    if not item.isValid or item:isValid() then
                        out[currentSlot] = item
                    end
                elseif type(item) == 'string' then
                    out[currentSlot] = item
                end
            end
        end
    end
    if recordId ~= nil then
        out[slot] = recordId
    end
    return out
end

--- Equip (or clear) one slot on `self`.  Returns ok, reason.  Nothing here can
--- raise on a request this actor cannot honour: a missing engine function is
--- reported instead.
function M.applySlotSwap(self, data)
    if type(data) ~= 'table' then return false, 'no request data' end
    local slot = tonumber(data.slot)
    if not slot then return false, 'no slot in the request' end
    local recordId = data.recordId
    if recordId ~= nil and (type(recordId) ~= 'string' or recordId == '') then
        return false, 'recordId is not a non-empty string'
    end
    if type(types.Actor.getEquipment) ~= 'function'
        or type(types.Actor.setEquipment) ~= 'function' then
        return false, 'this engine cannot read/write equipment'
    end
    types.Actor.setEquipment(self, M.equipmentTable(self, slot, recordId))
    return true
end

--- One request from the global penalty sweep, plus the report back.  Hosts wire
--- this straight into their `eventHandlers`; `self` is passed in because a
--- shared module must not cache one script's `openmw.self`.
function M.onRequest(self, data)
    local token = type(data) == 'table' and data.token or nil
    local ok, reason = M.applySlotSwap(self, data)
    if not ok then
        debugLog(string.format('%s: slot %s refused (%s)',
            tostring(self.recordId), tostring(type(data) == 'table' and data.slot),
            tostring(reason)))
    end
    core.sendGlobalEvent('MagExp_EquipReducedItemApplied', {
        token = token,
        objectId = self.id,
        slot = type(data) == 'table' and tonumber(data.slot) or nil,
        ok = ok,
    })
    return ok
end

return M
