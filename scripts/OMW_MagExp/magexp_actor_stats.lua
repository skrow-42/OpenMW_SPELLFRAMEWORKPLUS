-- ============================================================
-- magexp_actor_stats.lua (LOCAL script - attached to summoned actors)
--
-- A quick-cast penalty scales the numbers a spell record carries, but the
-- summoned creature the engine spawns for that spell is not a spell number:
-- its health / magicka / fatigue, its attributes and (for an NPC summon) its
-- skills all come from the creature's own record and arrive at full strength.
-- This script is what brings them down to the penalty percentage.
--
-- Why it has to be a local script
-- --------------------------------
-- Stats are read and written through the documented openmw.types tables
-- (openmw_types.html - ActorStats / AttributeStats / DynamicStat / SkillStat):
--
--   types.Actor.stats.dynamic.health(self)     -> DynamicStat   { base, current, modified, modifier }
--   types.Actor.stats.attributes.strength(self)-> AttributeStat { base, damage, modified, modifier }
--   types.NPC.stats.skills.longblade(self)     -> SkillStat     { base, damage, modified, modifier }
--
-- `base` (plus a dynamic stat's `current`) is writable, `modified` is
-- read-only and is recomputed by the engine from the fields we do write.
-- The writable fields are a *self-only* binding: the engine caches the write
-- on its SelfObject and, for anything else, raises
--     Allowed only in local scripts for 'openmw.self'.
-- A global script therefore cannot scale a summon's stats itself - not even
-- "try it and see", because the only way to see is to catch a raise.  So the
-- global sweep attaches this script to the actor it just found and the
-- scaling happens here, on `self`, where the engine allows it.
--
-- This script is also the actor's local agent for the *equipment* half of the
-- penalty: writing `openmw.self`'s equipment is a self-only operation, so the
-- global sweep sends `MagExp_EquipReducedItem` here for a reduced twin to be
-- equipped in the slot the full-strength item occupied (see
-- magexp_local_equip.lua, which both local hosts share).
--
-- Two delivery channels, both de-duplicated by token
-- ---------------------------------------------------
--   * engineHandlers.onInit(initData) - `GameObject:addScript(path, initData)`
--     hands initData straight to onInit when the script instance is created.
--     This is the channel that matters for a fresh summon: a script that was
--     attached a moment ago has no event handler yet, so an event sent in the
--     same breath can be dropped before anything is listening.
--   * eventHandlers.MagExp_ScaleStats - for an actor that already carries the
--     script (a second penalised summon of the same creature), and as the
--     retry channel the global sweep keeps using until this script confirms.
--
-- Every request carries the id of the cast that produced it, so a duplicated
-- delivery can never scale the same actor twice for the same spell.  Once
-- applied, the actor reports back with MagExp_StatScaleApplied, which is what
-- lets the sweep stop retrying.
-- ============================================================

local self = require('openmw.self')
local core = require('openmw.core')
local types = require('openmw.types')
local async = require('openmw.async')

local LocalEquip = require('scripts/OMW_MagExp/magexp_local_equip')

local debugLog = require('scripts/OMW_MagExp/magexp_logger').new('[MagExp Stats]')

local DYNAMIC_NAMES = { 'health', 'magicka', 'fatigue' }
local ATTRIBUTE_NAMES = {
    'strength', 'intelligence', 'willpower', 'agility',
    'speed', 'endurance', 'personality', 'luck',
}
local SKILL_NAMES = {
    'block', 'armorer', 'mediumarmor', 'heavyarmor', 'bluntweapon',
    'longblade', 'axe', 'spear', 'athletics', 'enchant', 'destruction',
    'alteration', 'illusion', 'conjuration', 'mysticism', 'restoration',
    'alchemy', 'unarmored', 'security', 'sneak', 'acrobatics', 'lightarmor',
    'shortblade', 'marksman', 'mercantile', 'speechcraft', 'handtohand',
}

-- [token] = { scale, stats } already applied.  A token is "<generated spell
-- id>|<object id>", so a re-delivered request (initData plus event, or a sweep
-- retry) cannot compound the penalty.
local applied = {}

--- One documented stats group (`dynamic`, `attributes`, `skills`) for this
--- actor.  The actor's own type table comes first - types.NPC and
--- types.Player carry one, and the NPC one is the only place `skills` lives -
--- and the shared types.Actor table (the documented ActorStats) is the
--- fallback for every group it does not have: types.Creature exposes no
--- attributes of its own, so a summoned creature's attributes resolve through
--- ActorStats.attributes.  Resolving per group is what makes both work.
local function statGroup(groupName)
    local own = self.type and self.type.stats
    if (type(own) == 'table' or type(own) == 'userdata') and (type(own[groupName]) == 'table' or type(own[groupName]) == 'userdata') then
        return own[groupName]
    end
    local shared = types.Actor and types.Actor.stats
    if (type(shared) == 'table' or type(shared) == 'userdata') and (type(shared[groupName]) == 'table' or type(shared[groupName]) == 'userdata') then
        return shared[groupName]
    end
    local npc = types.NPC and types.NPC.stats
    if (type(npc) == 'table' or type(npc) == 'userdata') and (type(npc[groupName]) == 'table' or type(npc[groupName]) == 'userdata') then
        return npc[groupName]
    end
    return nil
end

local function scaled(value, scale, round)
    if type(value) ~= 'number' then return nil end
    local result = value * scale
    if round then result = math.floor(result + 0.5) end
    if result < 0 then result = 0 end
    return result
end

--- Scale one stat's writable fields in place.  `accessor` is the documented
--- `stats.<group>.<name>` function, called with `self`; `extraProps` are the
--- writable fields beyond `base` (a dynamic stat's `current`).  Returns true
--- when something was written.  Nothing here can raise on a stat this actor
--- does not have: a missing accessor or a missing field is simply skipped.
local function scaleStat(accessor, scale, round, extraProps)
    if type(accessor) ~= 'function' then return false end
    local stat = accessor(self)
    if type(stat) ~= 'table' and type(stat) ~= 'userdata' then return false end
    local wrote = false
    local base = scaled(stat.base, scale, round)
    if base then
        stat.base = base
        wrote = true
    end
    for _, prop in ipairs(extraProps or {}) do
        local value = scaled(stat[prop], scale, round)
        if value then
            stat[prop] = value
            wrote = true
        end
    end
    return wrote
end

local function scaleGroup(groupName, names, scale, round, extraProps)
    local group = statGroup(groupName)
    if not group then return 0 end
    local count = 0
    for _, name in ipairs(names) do
        if scaleStat(group[name], scale, round, extraProps) then
            count = count + 1
        end
    end
    return count
end

--- Health / magicka / fatigue: base *and* current, so a summon does not keep
--- a full-strength pool it can no longer refill into.
local function scaleDynamic(scale)
    return scaleGroup('dynamic', DYNAMIC_NAMES, scale, false, { 'current' })
end

--- Attributes are integers in Morrowind, so they are rounded like the engine's
--- own stat math.  Creature attributes come through the same table.
local function scaleAttributes(scale)
    return scaleGroup('attributes', ATTRIBUTE_NAMES, scale, true)
end

--- Skills are an NPC-only group: a summoned creature has none, and asking for
--- them on one would be asking the engine about a stat it does not have.
local function scaleSkills(scale)
    if not (types.NPC and types.NPC.objectIsInstance
        and types.NPC.objectIsInstance(self)) then
        return 0
    end
    return scaleGroup('skills', SKILL_NAMES, scale, true)
end

--- Tell the global sweep this token is done, so it stops retrying.  The
--- report carries only plain values: an object reference would have to be
--- serialised across environments for nothing.
local function reportApplied(token, scale, statCount)
    core.sendGlobalEvent('MagExp_StatScaleApplied', {
        token = token,
        objectId = self.id,
        recordId = self.recordId,
        scale = scale,
        stats = statCount,
    })
end

local function applyScale(scale, token)
    local previous = applied[token]
    if previous then
        -- Already scaled for this cast.  Announce it again instead of scaling
        -- a second time: the global side keeps a bounded confirmation
        -- registry, and a sweep that lost the first answer must still be able
        -- to settle rather than retry until its deadline.
        reportApplied(token, previous.scale, previous.stats)
        return false
    end

    local dynamic = scaleDynamic(scale)
    local attributes = scaleAttributes(scale)
    local skills = scaleSkills(scale)
    local statCount = dynamic + attributes + skills
    applied[token] = { scale = scale, stats = statCount }
    reportApplied(token, scale, statCount)

    debugLog(string.format(
        '%s scaled to %d%% (%d dynamic, %d attribute, %d skill stat(s); token %s)',
        tostring(self.recordId), math.floor(scale * 100 + 0.5),
        dynamic, attributes, skills, token))
    return true
end

local pending = {}

--- One scaling request, from either channel.  A scale outside (0, 1) is not a
--- penalty (1 = no penalty, 0 or less would zero the summon out), and a
--- request without a scale is content-file init data we know nothing about.
--- The actual stat reduction is delayed by 0.2 seconds so the engine has time
--- to finish registering/initializing the spawned creature before stats are cut.
local function handleRequest(data)
    if type(data) ~= 'table' then return end
    local scale = tonumber(data.scale)
    if not scale or scale <= 0 or scale >= 1 then return end
    local token = tostring(data.token or data.spellId or 'default')

    local previous = applied[token]
    if previous then
        reportApplied(token, previous.scale, previous.stats)
        return
    end

    if pending[token] then return end
    pending[token] = true

    if async and type(async.newUnsavableSimulationTimer) == 'function' then
        async:newUnsavableSimulationTimer(0.2, function()
            pending[token] = nil
            if self and (not self.isValid or self:isValid()) then
                applyScale(scale, token)
            end
        end)
    else
        pending[token] = nil
        applyScale(scale, token)
    end
end

return {
    engineHandlers = {
        -- addScript(path, initData): the engine calls onInit with the data the
        -- global sweep attached, in this actor's own scope.
        onInit = function(initData)
            handleRequest(initData)
        end,
    },
    eventHandlers = {
        MagExp_ScaleStats = handleRequest,
        -- The global penalty sweep hands each reduced item to its owner's
        -- local script; only this scope may equip it.
        MagExp_EquipReducedItem = function(data)
            return LocalEquip.onRequest(self, data)
        end,
    },
}
