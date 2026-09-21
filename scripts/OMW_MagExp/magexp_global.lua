-- ============================================================
-- Spell Framework Plus for OpenMW - skrow42
-- magexp_global.lua (GLOBAL script)
--
-- Public Interface: I.MagExp
-- Usage from another global script:
--   local I = require('openmw.interfaces')
--   I.MagExp.launchSpell({ attacker=..., spellId=..., startPos=..., direction=... })
--
-- Usage from a player script:
--   core.sendGlobalEvent('MagExp_CastRequest', { attacker=self, spellId=..., startPos=..., direction=... })
--
-- Contract note: `attacker` is always a game object — the casting actor —
-- for EVERY spell, Self-range spells included.  The event handler validates
-- `type(data.attacker) == 'userdata'` and drops malformed requests (with a
-- log line); a nil attacker for a self cast therefore makes the whole cast
-- (and every penalty mechanic downstream) silently not happen.
-- ============================================================

local world   = require('openmw.world')
local core    = require('openmw.core')
local types   = require('openmw.types')
local util    = require('openmw.util')
local storage = require('openmw.storage')
local I       = require('openmw.interfaces')
local async   = require('openmw.async')

local C = require('scripts/OMW_MagExp/magexp_constants')
local Helpers = require('scripts/OMW_MagExp/magexp_helpers')
local debugLog = require('scripts/OMW_MagExp/magexp_logger').new('[MagExp]')

-- ---- SFP runtime settings ----
-- These live in the global SettingsMagExp_General storage section so any
-- script (including OSSC) can change them at runtime.
--
-- normaliseRaceSpeed mirrors OpenMW's "normalise race speed" launcher setting
-- for magic projectiles, with the exact same meaning.  OpenMW applies the
-- caster's race weight to magic bolt speed only when "normalise race speed"
-- is false (the Morrowind default; see ProjectileManager::moveMagicBolts in
-- OpenMW's projectilemanager.cpp).  Lua cannot read that engine setting, so
-- SFP exposes its own flag:
--   * true  = race weight IS normalised (matches normalise race speed = true)
--   * false = race weight is NOT normalised (matches normalise race speed = false)
-- The default is false to match the vanilla Morrowind/OpenMW default. Set it
-- to the same value as your launcher's "normalise race speed" so SFP
-- quick-casts fly at exactly the same speed as vanilla casting.
local magExpSettings = {
    normaliseRaceSpeed = false, -- default: vanilla OpenMW normalise race speed = false
    blockTargetSpellsWhileSwimming = true, -- default: no target-range launches while the caster swims
}

local function loadMagExpSettings()
    local sec = storage.globalSection('SettingsMagExp_General')
    magExpSettings.normaliseRaceSpeed = (sec:get('NormaliseRaceSpeed') == true)
    magExpSettings.blockTargetSpellsWhileSwimming = (sec:get('BlockTargetSpellsWhileSwimming') ~= false)
end

loadMagExpSettings()
storage.globalSection('SettingsMagExp_General'):subscribe(async:callback(loadMagExpSettings))

local activeVfxRegistry      = {}
local projectileItemRegistry = {} -- [proj.id] = live item object, kept until projectile dies
local casterLinkedSpells     = {} -- list of {caster, target, spellId} for casterLinked effects
local customFilters          = {}
local trackedEffectRegistry  = {}
local cachedDynamicRecords   = {} -- [hash_key] = record_string_id

-- [FEATURE] continuousVFX Actor Registry - Track actors with continuous VFX
local continuousVfxActors    = {} -- [actorId] = {actor, spellId, vfxTag, registrationTime}

-- [FEATURE 6] Cross-mod charge key registry: [keyId] = isPressed function
-- Populated by player scripts via I.MagExp.registerChargeKey()
local chargeKeyRegistry = {}

--- Live projectile registry.
--- [proj.id] = { projectile, spellId, attacker, launchTime, maxSpeed }
--- Populated by launchSpell, removed on collision or expiry.
local activeSpellRegistry = {}
local pendingProjectileMoves = {}

-- Only Lua data waits across a world pause; no native teleport is queued.
-- Ordinary move events remain visible to consumers once, at local simulation
-- time. Flushing their native placement must not rebroadcast warp callbacks.
local pauseWork = { moves = {}, anchors = {}, anchorIds = {}, sounds = {}, lights = {}, casts = {} }
local MAX_PAUSED_CAST_REQUESTS = 128

local function queueAnchorMove(anchor, cell, position, projectile)
    if anchor and anchor:isValid() and position then
        pauseWork.anchors[anchor.id] = { anchor = anchor, cell = cell, position = position, projectile = projectile }
        if projectile then
            local ids = pauseWork.anchorIds[projectile.id] or {}
            pauseWork.anchorIds[projectile.id] = ids
            ids[anchor.id] = true
        end
    end
end
local PROJECTILE_MOVE_RETRY_INTERVAL = 1 / 30
local PROJECTILE_MOVE_RETRY_MAX_AGE = 0.25
local PROJECTILE_MOVE_RETRY_MAX_ATTEMPTS = 8
local PROJECTILE_LIFECYCLE_SWEEP_INTERVAL = 0.1
local PROJECTILE_LIFECYCLE_CANCEL_GRACE = 0.25
local nextProjectileLifecycleSweepAt = 0

-- Script paths are virtual-filesystem identifiers, not filesystem fallbacks.
-- Retrying the same registered CUSTOM script with different path casing can
-- leave duplicate attachments on dynamically created objects.
local function addScriptOnce(object, scriptPath)
    if not object or not object:isValid() then
        return false, "invalid object"
    end
    if object:hasScript(scriptPath) then
        return true
    end
    object:addScript(scriptPath)
    return true
end
local OFFENSE_TYPE_IDS = types.OFFENSE_TYPE_IDS or {
    Theft               = 0,
    Assault             = 1,
    Murder              = 2,
    Trespassing         = 3,
    SleepingInOwnedBed  = 4,
    Pickpocket          = 5,
}
--- Internal unified target validator.
--- Checks for basic validity (exists, is not a corpse) and then runs all registered custom filters.
local function checkTarget(target)
    if not target or not target:isValid() then return false end
    
    -- Default Veto: Don't affect dead actors (unless specific resurrection/necromancy logic exists)
    if types.Actor.objectIsInstance(target) then
        if types.Actor.isDead(target) then
            return false
        end
    end

    -- Run custom filters from other mods
    for _, filter in ipairs(customFilters) do
        if not filter(target) then return false end
    end

    return true
end

local function playerNotifyCastIssue(actor, msg)
    if not msg or type(msg) ~= "string" then return end
    if not actor or not actor:isValid() or actor.type ~= types.Player then return end
    actor:sendEvent('Ui_ShowMessage', msg)
end

--- Read current enchant charge (types.Item.enchantmentCharge is not available in all API versions).
local function magExpReadItemEnchantmentCharge(item)
    local ch, ok = 0, false
    if not item or not item:isValid() then return 0, false end
    local itemData = types.Item.itemData(item)
    if itemData and itemData.enchantmentCharge ~= nil then
        ch = itemData.enchantmentCharge
        ok = true
    end
    return ch, ok
end

--- Scroll stacks and enchantment charge must be mutated from a **global** script
--- (see OpenMW docs: GameObject:remove / item charge writes are not allowed from local player scripts).
--- Prefer `data.item` (the equipped / selected GameObject) so the correct stack or instance is used.
local function magExpApplyInventoryResourceConsumption(attacker, data)
    if not data or not attacker or not attacker:isValid() then return end
    local inv = types.Actor.inventory(attacker)

    local function resolveItem()
        if data.item and type(data.item) ~= "string" and data.item:isValid() then
            return data.item
        end
        if data.itemRecordId and inv then
            return inv:find(data.itemRecordId)
        end
        return nil
    end

    if data.itemCountCost and data.itemCountCost > 0 then
        local item = resolveItem()
        if item and item:isValid() then
            item:remove(data.itemCountCost)
        end
    end
    if data.itemChargeCost and data.itemChargeCost > 0 then
        local item = resolveItem()
        if item and item:isValid() then
            local itemData = types.Item.itemData(item)
            if itemData then
                local old = itemData.enchantmentCharge
                if old == nil then old = 0 end
                itemData.enchantmentCharge = math.max(0, old - data.itemChargeCost)
            end
        end
    end
end

--- The OSSC settings toggle that exempts scrolls from the effect penalty is
--- mirrored into global storage (SettingsOSSC_General) by OSSC's settings
--- script; read it defensively from a GLOBAL script.  The OSSC cast launches
--- already compute an exempted 1.0 scale, so nothing here re-derives the
--- exemption from the spell record — this is a backstop for any caller that
--- forgot to honour the toggle.  Powers are exempt unconditionally and are
--- recognized by the spell record's own type; with the toggle on, scrolls
--- (CastOnce enchantments) are exempt too.  Regular spells and enchanted
--- *item* casts (CastOnUse / ConstantEffect) are never exempt.
local function effectPenaltyExemptSpell(spellRec, isEnchantment)
    if not spellRec then return false end
    if not isEnchantment and spellRec.type == core.magic.SPELL_TYPE.Power then return true end
    -- Only a scroll can be exempted by the toggle.
    if not isEnchantment then return false end
    if spellRec.type ~= core.magic.ENCHANTMENT_TYPE.CastOnce then return false end
    local s = storage.globalSection('SettingsOSSC_General')
    if not s then return false end
    if s:get('QuickCastEffectPenaltyScrollsExempt') == true then return true end
    -- Older OSSC releases mirrored the toggle under this key (it exempted
    -- regular spells as well back then; scrolls are the only part honoured
    -- here).
    return s:get('QuickCastEffectPenaltyScrollsSpellsExempt') == true
end

--- Quick-cast / global-event payload may be a number or a serialized string key.
local function coerceEffectScale(v)
    if v == nil then return 1.0 end
    if type(v) == "number" and v == v then
        if v < 0 then return 0 end
        if v > 1 then return 1 end
        return v
    end
    if type(v) == "string" then
        local s = tostring(v):lower():gsub('^%s+', ''):gsub('%s+$', '')
        if s == "reduce_25" or s == "reduce 25%" or s == "ossc_penalty_25" then return 0.75 end
        if s == "reduce_50" or s == "reduce 50%" or s == "ossc_penalty_50" then return 0.50 end
        if s == "off" or s == "disabled" or s == "ossc_penalty_off" or s == "" then return 1.0 end
        local n = tonumber(s)
        if n then return math.max(0, math.min(1, n)) end
    end
    local tn = tonumber(v)
    if tn then return math.max(0, math.min(1, tn)) end
    return 1.0
end

--- OpenMW uses MagicEffectWithParams (.effect) but some tables still expose .id; modify()/getEffect() want the engine id string (often lowercase, no spaces).
local function magicEffectIdCandidates(rawEff)
    local seen = {}
    local out = {}
    local function add(x)
        if x == nil then return end
        local s = tostring(x):lower()
        if s == "" then return end
        if not seen[s] then seen[s] = true; table.insert(out, s) end
        local c = s:gsub('%s+', ''):gsub('_', '')
        if c ~= s and c ~= "" and not seen[c] then seen[c] = true; table.insert(out, c) end
    end
    if rawEff then
        add(rawEff.id)
        if rawEff.effect and rawEff.effect.id then add(rawEff.effect.id) end
        local probe = rawEff.id
        if (not probe or probe == "") and rawEff.effect then
            probe = rawEff.effect.id
        end
        if probe then
            local rec = core.magic.effects.records[probe]
            if rec and rec.id then add(rec.id) end
        end
    end
    return out
end

local function magicEffectExtraParam(rawEff)
    if not rawEff then return nil end
    if type(rawEff.affectedAttribute) == "string" and rawEff.affectedAttribute ~= "" then
        return rawEff.affectedAttribute
    end
    if type(rawEff.affectedSkill) == "string" and rawEff.affectedSkill ~= "" then
        return rawEff.affectedSkill
    end
    return nil
end

local function pickEffectIdForModify(activeEffects, candidates, extra)
    if not activeEffects or not candidates or #candidates == 0 then return nil end
    for _, cid in ipairs(candidates) do
        local eff = activeEffects:getEffect(cid, extra)
        if eff then return cid end
    end
    return candidates[1]
end

-- ============================================================
-- [EFFECT PENALTY] On-the-fly reduced spell records
--
-- activeSpells:add only accepts effect indexes from a record.  It cannot
-- override an effect's magnitude, duration, or area for one cast.  Therefore
-- a quick-cast penalty is represented by a real, runtime-created Spell record:
-- clone the source effects with reduced values, register the clone in the
-- world database, and add the clone instead of the source record.  This keeps
-- every effect on the engine's normal application path (resistances,
-- absorption, caster links, expiry, and non-stat effects included).
--
-- The engine reads such a draft back with tableToEnamStruct()
-- (apps/openmw/mwlua/magictypebindings.cpp):
--
--     ESM::IndexedENAMstruct out;
--     addPropertyFromTable(table, "id", out.mData.mEffectID);      -- string
--     if (!store.search(out.mData.mEffectID))
--         throw std::runtime_error("EffectParams require a valid magic effect id");
--     out.mData.mRange = table.get_or("range", 0);                 -- 0/1/2
--     if (range != RT_Self && range != RT_Touch && range != RT_Target)
--         throw std::runtime_error("invalid range type");
--     out.mData.mArea = std::max(table.get_or("area", 0), 0);
--     out.mData.mMagnMin = table.get_or("magnitudeMin", 0);
--     out.mData.mMagnMax = std::max(table.get_or("magnitudeMax", 0), mMagnMin);
--     out.mData.mDuration = std::max(table.get_or("duration", 0), 0);
--
-- so a cloned effect is a *plain Lua table* carrying exactly those keys.  A
-- missing "range" silently reads back as 0 (Self) — a Touch/Target effect would
-- become a self effect — which is why the range is always written out.
--
-- Effect entries of a record are NOT Lua tables: the store's read-only record
-- types expose `effects` as a Lua array of ESM3_EffectParams usertypes
-- (`res[toLuaIndex(i)] = rec.mEffects.mList[i]` in addEffectsProperty), and
-- their fields are usertype properties.  Both representations must be readable
-- here, so every field goes through effectFieldValue() instead of plain
-- table indexing or a `type(entry) == "table"` gate.
-- ============================================================

local function roundScaledEffectValue(value, scale, minimum)
    if type(value) ~= "number" then return nil end
    local result = math.floor(value * scale + 0.5)
    if minimum and result < minimum then result = minimum end
    return result
end

--- Read one field of a spell/enchantment effect entry.
--- Record effects are ESM3_EffectParams usertypes; effects built in Lua (by
--- this file, by another mod, or handed back from a record draft) are plain
--- tables.  Field lookup works for both, and anything else has no fields.
local function effectFieldValue(rawEff, field)
    if rawEff == nil or field == nil then return nil end
    local kind = type(rawEff)
    if kind ~= "table" and kind ~= "userdata" then return nil end
    return rawEff[field]
end

--- ENAM ranges are the engine's own 0 = Self, 1 = Touch, 2 = Target.  Anything
--- else is rejected here, because the record reader would not reject it: a
--- missing/!numeric range silently becomes Self.
local function normalizeEffectRange(range)
    if type(range) == "string" then
        local key = range:lower():gsub("%s+", "")
        if key == "self" or key == "onself" then return 0 end
        if key == "touch" then return 1 end
        if key == "target" then return 2 end
        range = tonumber(key)
    end
    if type(range) == "number" and range >= 0 and range <= 2 then
        return math.floor(range)
    end
    return nil
end

local function scaledEffectParams(rawEff, scale)
    local out = {}
    local magnitudeMin = effectFieldValue(rawEff, "magnitudeMin")
    if magnitudeMin == nil then magnitudeMin = effectFieldValue(rawEff, "minMagnitude") end
    local magnitudeMax = effectFieldValue(rawEff, "magnitudeMax")
    if magnitudeMax == nil then magnitudeMax = effectFieldValue(rawEff, "maxMagnitude") end
    if type(magnitudeMin) == "number" then
        out.magnitudeMin = roundScaledEffectValue(magnitudeMin, scale, 0)
    end
    if type(magnitudeMax) == "number" then
        out.magnitudeMax = roundScaledEffectValue(magnitudeMax, scale, 0)
    elseif out.magnitudeMin ~= nil then
        out.magnitudeMax = out.magnitudeMin
    end
    if out.magnitudeMin ~= nil and out.magnitudeMax ~= nil
        and out.magnitudeMax < out.magnitudeMin then
        out.magnitudeMax = out.magnitudeMin
    end
    local duration = effectFieldValue(rawEff, "duration")
    if type(duration) == "number" then
        -- OpenMW represents temporary magic durations in whole seconds. Keep
        -- a positive source duration alive for at least one second.
        out.duration = roundScaledEffectValue(duration, scale,
            duration > 0 and 1 or 0)
    end
    local area = effectFieldValue(rawEff, "area")
    if type(area) == "number" then
        out.area = roundScaledEffectValue(area, scale, 0)
    end
    return out
end

local reducedSpellRecords = {}       -- [source-kind-scale] = generated Spell
local reducedSpellIdsBySource = {}   -- [source-key][generated-id] = true

local function reducedSpellSourceKey(spell, isEnchantment)
    return tostring(spell.id or "") .. (isEnchantment and "|enchantment" or "|spell")
end

--- Canonical form of an active-spell id, for every comparison between an id
--- this script generated and an id the engine hands back.  The registry stores
--- whatever `world.createRecord` gave Lua, while the engine reports the same
--- spell in its own serialized form: a generated id's hex digits can come back
--- in either case, and a path that round-trips the id through `toString()`
--- drops the 'Generated:' prefix.  A mismatch here is silent - the entry is
--- dropped and matched by nothing - which is how a quick-cast summon survived
--- a spell-stance recast in game.  Fold case and the prefix, nothing else.
local function activeSpellIdKey(id)
    return (tostring(id or ""):lower():gsub("^generated:", ""))
end

--- True when the (lowercased, alphanumeric-normalised) effect id is a kind
--- the engine treats as binary: summons and bound items always carry a
--- magnitude of 1 in vanilla — the engine ignores the magnitude fields
--- entirely and either spawns the creature / equips the item or does not.
--- A penalty must never scale that 1 down: a clone with magnitude 0 (what
--- a 60% penalty does to magnitude 1 with rounding) would stop the spawn
--- outright, and any other value still reads as the same binary effect.
--- Defined after the summon/bound effect tables below (it needs them at
--- call time); the forward declaration lets cloneReducedEffect above
--- capture the same local.
local isVanillaForcedMagnitudeEffect

--- One reduced effect, in the exact shape the engine's tableToEnamStruct reads.
--- Returns nil when the effect cannot be reproduced faithfully, so the caller
--- refuses the whole cast instead of registering a shorter record.
local function cloneReducedEffect(rawEff, scale)
    -- The id must be the magic effect's id *string*: the engine calls
    -- `rec["id"].get<std::string_view>()` and then resolves it in the
    -- MagicEffect store.  (Record fields holding an ESM::RefId are pushed to
    -- Lua as strings, so this is the record's own id text, not userdata.)
    local id = effectFieldValue(rawEff, "id")
    if type(id) ~= "string" or id == "" then
        -- MagicEffectWithParams-shaped entries (the `.effect` accessor some
        -- API revisions expose on effect params) carry the MagicEffect record
        -- instead of a direct id; read the id from there before giving up.
        local mgefRec = effectFieldValue(rawEff, "effect")
        if mgefRec ~= nil then
            id = effectFieldValue(mgefRec, "id")
        end
    end
    if type(id) == "number" and core.magic and core.magic.effects and core.magic.effects.records then
        local mgef = core.magic.effects.records[id]
        if mgef and mgef.id then id = tostring(mgef.id) end
    end
    if type(id) ~= "string" or id == "" then return nil end

    local range = normalizeEffectRange(effectFieldValue(rawEff, "range")) or 0

    local params = scaledEffectParams(rawEff, scale)
    local effect = {
        id           = id,
        range        = range,
        -- Written out even when the source has none: the reader defaults all
        -- of these to 0, so spelling them out keeps the clone complete and
        -- makes the reduced values explicit for every effect kind.
        magnitudeMin = params.magnitudeMin or 0,
        magnitudeMax = params.magnitudeMax or params.magnitudeMin or 0,
        duration     = params.duration or 0,
        area         = params.area or 0,
    }

    -- Restore/drain/fortify effects act on a skill or attribute argument;
    -- dropping it would apply the effect to nothing at all.
    local affectedAttribute = effectFieldValue(rawEff, "affectedAttribute")
    if (type(affectedAttribute) == "string" and affectedAttribute ~= "") or type(affectedAttribute) == "number" then
        effect.affectedAttribute = affectedAttribute
    end
    local affectedSkill = effectFieldValue(rawEff, "affectedSkill")
    if (type(affectedSkill) == "string" and affectedSkill ~= "") or type(affectedSkill) == "number" then
        effect.affectedSkill = affectedSkill
    end

    -- Vanilla parity: a summon or bound-item effect always lands at
    -- magnitude 1, whatever the penalty scale is.  Duration still carries
    -- the penalty — that is the summoning half of the reduced cast.
    if isVanillaForcedMagnitudeEffect((tostring(id):lower():gsub("[^%a%d]", ""))) then
        effect.magnitudeMin = 1
        effect.magnitudeMax = 1
    end

    return effect
end

local function createReducedSpellRecord(spell, isEnchantment, scale)
    local sourceKey = reducedSpellSourceKey(spell, isEnchantment)
    local cacheKey = sourceKey .. "|" .. string.format("%.8f", scale)
    local cached = reducedSpellRecords[cacheKey]
    if cached then return cached, sourceKey end

    local effects = {}
    local sourceEffectCount = 0
    for _, rawEff in ipairs(spell.effects or {}) do
        sourceEffectCount = sourceEffectCount + 1
        local effect = cloneReducedEffect(rawEff, scale)
        if effect then effects[#effects + 1] = effect end
    end

    -- The indexes handed to activeSpells:add are resolved by the engine with
    -- `effectList.mList.at(index)` (getNameAndMagicEffects in
    -- apps/openmw/mwlua/magicbindings.cpp).  A generated record with fewer
    -- effects than those indexes aborts the whole cast with the C++ exception
    -- `std::out_of_range` — surfaced in game as the bare Lua error
    -- "invalid vector subscript" — after the source spell has already been
    -- removed.  Paying for a cast that applies nothing is worse than not
    -- casting, so refuse to register an incomplete clone.
    if #effects ~= sourceEffectCount or #effects == 0 then
        debugLog(string.format(
            "Effect penalty: cloned %d of %d effect(s) for %s; cast skipped",
            #effects, sourceEffectCount, tostring(spell.id)))
        return nil, sourceKey
    end

    -- Do not use an enchantment as a Spell template: the engine requires the
    -- generated record passed to activeSpells:add to be a Spell.  Its effect
    -- list is still an exact reduced clone of the enchantment's list, while
    -- the original enchanted item is retained in ActiveSpellAddOptions.item.
    local draft = {
        name = tostring(spell.name or spell.id or "Spell") .. " (Quick Cast)",
        type = (not isEnchantment and spell.type) or core.magic.SPELL_TYPE.Spell,
        cost = spell.cost or 0,
        isAutocalc = false,
        autocalcFlag = false,
        effects = effects,
    }
    if not isEnchantment then draft.template = spell end

    if not core.magic.spells or type(core.magic.spells.createRecordDraft) ~= "function"
        or type(world.createRecord) ~= "function" then
        debugLog("Effect penalty: runtime spell-record API is unavailable")
        return nil, sourceKey
    end

    -- Neither call is guarded.  A draft the engine rejects (an unknown magic
    -- effect id, a range outside Self/Touch/Target) or a record it refuses to
    -- register is a fault in this file, not a runtime condition to paper over:
    -- the earlier checks already guarantee a complete, well-formed clone, so an
    -- exception here means the clone and the engine's reader have diverged.
    -- Absorbing it would turn that divergence into a cast that silently does
    -- nothing; letting it propagate surfaces it at the request boundary with
    -- its stack trace instead.
    local recordDraft = core.magic.spells.createRecordDraft(draft)
    local record = world.createRecord(recordDraft)
    if not record then
        debugLog("Effect penalty: world.createRecord returned no record for", tostring(spell.id))
        return nil, sourceKey
    end

    -- Read the registered record back before caching it.  If the effect list did
    -- not survive registration, caching it would turn every later cast of this
    -- spell and scale into a guaranteed-to-fail activeSpells:add call.
    -- The count is read leniently: `record.effects` may arrive as the plain
    -- table (record store shape) or as a userdata list (mutable record
    -- shape), and only the table shape may be counted — `#` on the userdata
    -- would raise.  Only a count that can actually be read and disagrees is a
    -- hard failure: the strict gate that skipped the cast instead silently
    -- dropped every reduced cast on the userdata shape ("cast skipped": cast
    -- VFX played, no effect dealt).
    local registeredCount = nil
    if type(record.effects) == "table" then
        registeredCount = #record.effects
    end
    if registeredCount == nil then
        debugLog(string.format(
            "Effect penalty: generated %s does not expose a countable effect list; trusting the validated clone",
            tostring(record.id)))
    elseif registeredCount ~= #effects then
        debugLog(string.format(
            "Effect penalty: generated %s carries %d effect(s), expected %d; cast skipped",
            tostring(record.id), registeredCount, #effects))
        return nil, sourceKey
    end

    reducedSpellRecords[cacheKey] = record
    local id = record.id
    if id then
        if not reducedSpellIdsBySource[sourceKey] then
            reducedSpellIdsBySource[sourceKey] = {}
        end
        reducedSpellIdsBySource[sourceKey][activeSpellIdKey(id)] = true
    end
    debugLog(string.format("Effect penalty: generated %s at %d%% as %s",
        tostring(spell.id), math.floor(scale * 100 + 0.5), tostring(id)))
    return record, sourceKey
end

--- Enchanted-item identity, read defensively.
---
--- A consumed scroll's handle is dead by the time the spell is applied: the
--- launch-time resource guard removes the stack first.  Accessing any member
--- of a dead handle raises in OpenMW Lua — `isValid()` is the one check that
--- answers safely on it — and one unguarded read here was enough to abort the
--- whole cast after its VFX had already played ("casting is visible but no
--- effect is done/dealt", and only for penalised scroll casts).  Item
--- identity is therefore folded to plain strings while the instance is still
--- alive, and every remaining handle read happens only after `isValid()`.
local function itemRefIsLive(itemRef)
    return type(itemRef) == "userdata" and itemRef:isValid() == true
end

local function itemRefRecordId(itemRef)
    if type(itemRef) == "string" then
        if itemRef ~= "" then return itemRef end
        return nil
    end
    if not itemRefIsLive(itemRef) then return nil end
    local rid = itemRef.recordId
    if type(rid) == "string" and rid ~= "" then return rid end
    return nil
end

local function itemRefHandleId(itemRef)
    if not itemRefIsLive(itemRef) then return nil end
    return itemRef.id
end

--- True when two item references point at the same instance (readable live
--- handles only) or at the same item record.  A consumed instance can no
--- longer prove its identity, so it matches nothing except `a == b`.
local function itemRefsMatch(a, b)
    if a == nil or b == nil then return false end
    if a == b then return true end
    local ia, ib = itemRefHandleId(a), itemRefHandleId(b)
    if ia ~= nil and ib ~= nil then return ia == ib end
    local ra, rb = itemRefRecordId(a), itemRefRecordId(b)
    return ra ~= nil and rb ~= nil and ra == rb
end

local function activeSpellMatchesSource(active, key, sourceId, itemObject)
    if not active then return false end
    local id = tostring(active.id or key or "")
    if activeSpellIdKey(id) ~= activeSpellIdKey(sourceId) then return false end
    if itemObject ~= nil then
        if active.item ~= nil then
            if itemRefIsLive(active.item) then
                return itemRefsMatch(active.item, itemObject)
            end
            -- The linked instance was consumed by this very cast (single-use
            -- enchantment) and can no longer prove a mismatch — fall through
            -- to record identity below.
        end
        -- The engine never links `item` to a single-use (scroll) cast — the
        -- active's id IS the item's record id in that case — so an item-less
        -- active matches on record identity instead of instance identity.
        local rid = itemRefRecordId(itemObject)
        return rid ~= nil and activeSpellIdKey(id) == activeSpellIdKey(rid)
    end
    return true
end

--- The name a reduced cast should be shown under.  The generated record is an
--- internal stand-in for one cast ("Fireball (Quick Cast)"); the player should
--- see the spell they actually cast, which for an enchanted item is the item.
local function reducedSpellDisplayName(spell, isEnchantment, itemObject)
    if isEnchantment and itemRefIsLive(itemObject) then
        local objectType = itemObject.type
        if objectType and type(objectType.record) == "function" then
            local rec = objectType.record(itemObject)
            if rec and type(rec.name) == "string" and rec.name ~= "" then
                return rec.name
            end
        end
    end
    if type(spell.name) == "string" and spell.name ~= "" then return spell.name end
    return nil
end

--- Remove the source active spell before adding its reduced replacement.  The
--- source is removed rather than briefly applying it and correcting stats one
--- frame later, so no unreduced effect can tick or trigger during that gap.
local function removeSourceForReducedSpell(activeSpells, sourceId, sourceKey, itemObject)
    if not activeSpells or type(activeSpells.remove) ~= "function" then return end
    local generatedIds = reducedSpellIdsBySource[sourceKey] or {}
    local removeIds = {}
    for key, active in pairs(activeSpells) do
        local id = tostring(active and active.id or key or "")
        -- A stand-in whose `item` cannot be resolved (a consumed scroll — the
        -- engine reports `item = nil` for single-use enchantments, and a
        -- consumed handle stops answering) is matched purely via the
        -- source-keyed generated-id set; an item-linked stand-in with a
        -- readable instance must still prove item identity so two items
        -- sharing one enchantment do not displace each other.
        local generated = generatedIds[activeSpellIdKey(id)] == true
            and (itemObject == nil or active.item == nil
                or not itemRefIsLive(active.item)
                or itemRefsMatch(active.item, itemObject))
        if (generated or activeSpellMatchesSource(active, key, sourceId, itemObject))
            and active and active.temporary and active.activeSpellId then
            removeIds[#removeIds + 1] = active.activeSpellId
        end
    end
    for _, activeSpellId in ipairs(removeIds) do
        activeSpells:remove(activeSpellId)
    end
end

-- Summon effect id (letters only, lowercase) → GMST holding the creature
-- record id the engine spawns for it (mirrors MWMechanics::getSummonMap).
-- Used to recognise a freshly summoned creature so the effect penalty can
-- scale its stats immediately after the spawn.
local SUMMON_EFFECT_GMST = {
    summonancestralghost    = 'sMagicAncestralGhostID',
    summonbonelord          = 'sMagicBonelordID',
    summonbonewalker        = 'sMagicLeastBonewalkerID',
    summoncenturionsphere   = 'sMagicCenturionSphereID',
    summonclannfear         = 'sMagicClannfearID',
    summondaedroth          = 'sMagicDaedrothID',
    summondremora           = 'sMagicDremoraID',
    summonfabricant         = 'sMagicFabricantID',
    summonflameatronach     = 'sMagicFlameAtronachID',
    summonfrostatronach     = 'sMagicFrostAtronachID',
    summongoldensaint       = 'sMagicGoldenSaintID',
    summongreaterbonewalker = 'sMagicGreaterBonewalkerID',
    summonhunger            = 'sMagicHungerID',
    summonscamp             = 'sMagicScampID',
    summonskeletalminion    = 'sMagicSkeletalMinionID',
    summonstormatronach     = 'sMagicStormAtronachID',
    summonwingedtwilight    = 'sMagicWingedTwilightID',
    summonwolf              = 'sMagicCreature01ID',
    summonbear              = 'sMagicCreature02ID',
    summonbonewolf          = 'sMagicCreature03ID',
    summoncreature04        = 'sMagicCreature04ID',
    summoncreature05        = 'sMagicCreature05ID',
}

-- The summon effect ids themselves, extracted from SUMMON_EFFECT_GMST rather
-- than listed a second time so the two can never drift apart.  OpenMW runs
-- summon bookkeeping per magic-effect id (CreatureStats::getSummonedCreatureMap
-- is a multimap keyed by the effect), so the effect id - not the spell id - is
-- how a second summon displaces an older one.
local SUMMON_EFFECT_IDS = {}
for effId in pairs(SUMMON_EFFECT_GMST) do
    SUMMON_EFFECT_IDS[effId] = true
end

--- True when the lowercased, alphanumeric-normalised effect id is one of the
--- engine's summon effects.  These are the only effects whose bookkeeping a
--- vanilla cast can disturb on an actor carrying a quick-cast stand-in.
local function isSummonEffectId(effectId)
    if type(effectId) ~= 'string' or effectId == '' then return false end
    return SUMMON_EFFECT_IDS[effectId] == true
end

-- Bound-item effect id (letters only, lowercase) → the item record ids the
-- engine adds and auto-equips while the effect is active.  The Lua API does
-- not expose a magic effect's Item field, so this mirrors the base game's
-- own bound-equipment list (the same ids OpenMW's MagicEffectId enum spells).
local BOUND_EFFECT_ITEMS = {
    boundbattleaxe = { 'bound_battle_axe' },
    bounddagger    = { 'bound_dagger' },
    boundlongbow   = { 'bound_longbow' },
    boundlongsword = { 'bound_longsword' },
    boundmace      = { 'bound_mace' },
    boundspear     = { 'bound_spear' },
    boundboots     = { 'bound_boots' },
    boundcuirass   = { 'bound_cuirass' },
    boundgloves    = { 'bound_gauntlet_left', 'bound_gauntlet_right' },
    boundhelm      = { 'bound_helm' },
    boundshield    = { 'bound_shield' },
}

--- Sentinel used in boundExpected to mean "any newly-spawned item whose record
--- id or name contains 'bound' should be treated as a bound item". This lets
--- bound-equipment effects added by other mods be reduced automatically even
--- when their exact item record id is not known (the engine only exposes the
--- Item field for effects defined through newer APIs; script-effect-style
--- additions from mods often don't have it).
local WILDCARD_BOUND_KEY = '__wildcard__'

--- True when lowercased string `s` contains the word "bound" with non-letter
--- (or string-start/end) boundaries on both sides. Used so we don't match
--- unrelated words like "rebound", "surround" or "unbounded".
local function containsWordBound(s)
    if type(s) ~= 'string' or s == '' then return false end
    local n = #s
    for i = 1, n - 4 do
        if s:sub(i, i + 4) == 'bound' then
            local before = (i == 1) or not s:sub(i - 1, i - 1):match('%a')
            local afterIdx = i + 5
            local after = (afterIdx > n) or not s:sub(afterIdx, afterIdx):match('%a')
            if before and after then return true end
        end
    end
    return false
end

--- True when the (already-lowercased, letters-only) effect id, or the magic
--- effect's display name, looks like a bound-equipment effect. Used to detect
--- modded bound effects that are not listed in BOUND_EFFECT_ITEMS and do not
--- expose mgef.item — they are still bound effects and must be swept.
local function effectLooksLikeBound(effId, mgef)
    if type(effId) == 'string' and effId ~= '' then
        if containsWordBound(effId:lower()) then return true end
    end
    if mgef then
        local name = mgef.name
        if type(name) == 'string' and name ~= '' then
            local nl = name:lower()
            -- Same word-boundary test as above, on the displayed effect name.
            -- "Bound Dagger", "Bound Longbow", etc. always start with "Bound ".
            if nl:find('^bound[%s%p]') or nl:find('[%s%p]bound[%s%p]')
                or nl:find('[%s%p]bound$') then
                return true
            end
        end
    end
    return false
end

--- The item record ids a bound-equipment effect equips, or nil.
local function boundEffectItemIds(effectId)
    -- A newer OpenMW may expose the magic effect's own Item field; prefer it
    -- so modded bound effects resolve without an entry in the table above.
    local records = core.magic.effects and core.magic.effects.records
    local mgef = records and records[effectId]
    local item = mgef and mgef.item
    if type(item) == 'string' and item ~= '' then return { item } end
    local fromTable = BOUND_EFFECT_ITEMS[effectId]
    if fromTable then return fromTable end
    -- Last resort: if the effect is clearly a bound-equipment effect by its
    -- id or name but we don't know its exact item id(s), signal the caller
    -- with an empty list so the wildcard sweep matches any new item with
    -- "bound" in its id or name. Returning nil would skip the effect entirely.
    if effectLooksLikeBound(effectId, mgef) then return { [WILDCARD_BOUND_KEY] = true } end
    return nil
end

--- Does this item record look like a bound item (record id or localized name
--- contains "bound" as a word)? Used for the wildcard fallback so other mods'
--- bound items are picked up without having to list them here.
local function recordLooksLikeBoundItem(record)
    if not record then return false end
    local rid = record.id
    if type(rid) == 'string' and containsWordBound(tostring(rid):lower()) then
        return true
    end
    local rname = record.name
    if type(rname) == 'string' and rname ~= '' then
        local n = rname:lower()
        -- Also accept the localized display name starting/ending with "Bound"
        -- (modders often give bound items a translated name that doesn't
        -- start with "bound" in the id, e.g. "Légendaire épée liée" wouldn't
        -- match, but "Bound Sword of Foo" does).
        if n:find('^bound[%s%p]') or n:find('[%s%p]bound[%s%p]')
            or n:find('[%s%p]bound$') then
            return true
        end
    end
    return false
end

--- (Body for the forward-declared isVanillaForcedMagnitudeEffect above: the
--- summon and bound-effect tables are all defined by this point.)
isVanillaForcedMagnitudeEffect = function(effKey)
    if type(effKey) ~= 'string' or effKey == '' then return false end
    if isSummonEffectId(effKey) then return true end
    return boundEffectItemIds(effKey) ~= nil
end

-- ============================================================
-- [EFFECT PENALTY] Summoned actors and bound items
--
-- A quick-cast penalty scales the numbers the spell record carries, but the
-- engine spawns summoned creatures and bound equipment at full record
-- strength: the summon's health / magicka / fatigue / attributes / skills,
-- the gear it spawns wearing, and the item a bound spell equips are not
-- spell magnitudes.  They are reduced the moment they appear:
--
--   * a summoned actor gets every stat scaled by the penalty share, and
--     every weapon / armor piece it spawns with is replaced by a runtime
--     record with scaled damage / armor rating;
--   * a bound item is replaced the same way, and taken back when the spell
--     that summoned it ends (the engine removes its own copy; the reduced
--     replacement is ours to clean up).
--
-- The engine spawns these on a mechanics update some time after
-- activeSpells:add — one frame later than a 0-delay timer in the worst
-- case — so each penalised cast that expects them keeps sweeping every
-- PENALISED_SPAWN_INTERVAL seconds until everything expected has been found
-- (or PENALISED_SPAWN_DEADLINE passes).
-- ============================================================
local PENALISED_SPAWN_INTERVAL = 0.05
local PENALISED_SPAWN_DEADLINE = 3.0

local reducedItemRecords = {}      -- [recordId|scale] = generated item record
local reducedItemRecordIds = {}    -- [generated record id] = true
local reducedEnchantmentRecords = {}  -- [enchantId|scale] = generated enchantment (false = tried, unavailable)
local reducedBoundItems = {}       -- [actorId|spellId] = replacement bookkeeping

-- The stat names a summon's stats are scaled by live in the local script that
-- is allowed to write them (scripts/OMW_MagExp/magexp_actor_stats.lua); a
-- global script can only ask.

local function scaledNumber(value, scale, minimum)
    if type(value) ~= 'number' then return nil end
    local result = math.floor(value * scale + 0.5)
    if minimum and result < minimum then result = minimum end
    return result
end

-- Engine-version note (verified against the engine sources): the runtime
-- enchantment record API —
--   core.magic.enchantments.createRecordDraft  (= tableToEnchantment)
-- exists in OpenMW 0.51 and later; earlier builds expose the enchantment
-- record store read-only.  On such a build a replaced enchanted bound item
-- keeps its full-strength template enchantment, and the sweep would say
-- nothing about why - exactly the kind of silent gap that made "the twin's
-- enchantment is not reduced" impossible to diagnose in game.  Report it
-- once, in the log the player sees (openmw.log needs no debug mode for
-- print()), and let debugLog carry the per-enchant detail.
local enchantRuntimeApiWarned = false

--- A runtime copy of an enchantment record with every effect scaled by the
--- penalty share.  A bound item's enchantment is a record of its own, so a twin
--- that kept the template's `enchant` would still strike (or fortify) at full
--- strength however far its own damage was cut.  Returns nil - keep the
--- template's enchantment - for an unenchanted item, an unknown enchantment, or
--- an engine without the runtime enchantment API; it never produces a partially
--- scaled list, because a half-cloned enchantment would be worse than none.
--- (Record fields typed ESM::RefId - like item record `enchant` - reach Lua as
--- plain id strings: components/lua/util.hpp pushes them as serializeText(),
--  and records-store lookup is case-insensitive, so no normalization is needed
--- here.  An unenchanted record reads as nil, which is the first return.)
local function createReducedEnchantmentRecord(enchantId, scale)
    if type(enchantId) ~= 'string' or enchantId == '' then return nil end
    local store = core.magic and core.magic.enchantments
    if not (store and type(store.createRecordDraft) == 'function'
        and type(world.createRecord) == 'function') then
        if not enchantRuntimeApiWarned then
            enchantRuntimeApiWarned = true
            print('[MagExp] Effect penalty: this engine has no runtime enchantment '
                .. 'records (needs OpenMW 0.51+); enchanted bound items keep their '
                .. 'full-strength template enchantment')
        end
        return nil
    end

    local cacheKey = enchantId .. '|' .. string.format('%.8f', scale)
    local cached = reducedEnchantmentRecords[cacheKey]
    if cached ~= nil then
        if cached ~= false then return cached end
        return nil
    end
    -- One attempt per enchantment and scale: without this the record store
    -- would be searched again on every sweep pass of every penalised cast.
    reducedEnchantmentRecords[cacheKey] = false

    local record = store.records and (store.records[enchantId] or store.records[enchantId:lower()]) or nil
    if not record and store.records then
        local targetKey = enchantId:lower()
        for _, rec in pairs(store.records) do
            local recId = rec.id
            if recId and tostring(recId):lower() == targetKey then
                record = rec
                break
            end
        end
    end
    if not record then return nil end

    local effects = {}
    local sourceEffectCount = 0
    for _, rawEff in ipairs(record.effects or {}) do
        sourceEffectCount = sourceEffectCount + 1
        local effect = cloneReducedEffect(rawEff, scale)
        if effect then effects[#effects + 1] = effect end
    end
    if #effects ~= sourceEffectCount or #effects == 0 then return nil end

    -- `type`, `cost` and `charge` come from the template: the twin's effects are
    -- weaker, its charge pool (and so its number of uses) is unchanged.
    local draft = core.magic.enchantments.createRecordDraft({
        template = record,
        type = record.type,
        cost = record.cost or 0,
        charge = record.charge or 0,
        autocalc = record.isAutocalc or false,
        isAutocalc = record.isAutocalc or false,
        autocalcFlag = record.isAutocalc or false,
        effects = effects,
    })
    local newRecord = world.createRecord(draft)
    if not (newRecord and newRecord.id) then return nil end

    reducedEnchantmentRecords[cacheKey] = newRecord
    debugLog(string.format('Effect penalty: enchantment %s scaled to %d%% as %s',
        tostring(enchantId), math.floor(scale * 100 + 0.5), tostring(newRecord.id)))
    return newRecord
end

--- A runtime copy of an item record with its combat values scaled by the
--- penalty share — the item twin of createReducedSpellRecord below.  Returns
--- nil for anything without reducible numbers (clothing, misc items) or when
--- the runtime record API is unavailable.
local function createReducedItemRecord(itemObject, scale)
    if not (itemObject and itemObject:isValid()) then return nil end
    local itemType = itemObject.type
    local isWeapon = itemType == types.Weapon
    local isArmor = itemType == types.Armor
    if not (isWeapon or isArmor) then return nil end
    if not (itemType.record and itemType.createRecordDraft
        and type(world.createRecord) == 'function') then
        return nil
    end

    local record = itemType.record(itemObject)
    if not record and itemType.records then
        record = itemType.records[itemObject.recordId]
    end
    if not record then return nil end
    local recordId = tostring(itemObject.recordId or record.id or '')
    local cacheKey = recordId .. '|' .. string.format('%.8f', scale)
    local cached = reducedItemRecords[cacheKey]
    if cached then return cached end

    local draft = {
        template = record,
        name = tostring(record.name or recordId) .. ' (Quick Cast)',
        -- A conjured copy must never be sellable gold, whatever the template
        -- is worth.
        value = 0,
    }
    if isWeapon then
        local chopMin = scaledNumber(record.chopMinDamage, scale, 0) or 0
        local slashMin = scaledNumber(record.slashMinDamage, scale, 0) or 0
        local thrustMin = scaledNumber(record.thrustMinDamage, scale, 0) or 0
        draft.chopMinDamage = chopMin
        draft.chopMaxDamage = math.max(scaledNumber(record.chopMaxDamage, scale, 0) or 0, chopMin)
        draft.slashMinDamage = slashMin
        draft.slashMaxDamage = math.max(scaledNumber(record.slashMaxDamage, scale, 0) or 0, slashMin)
        draft.thrustMinDamage = thrustMin
        draft.thrustMaxDamage = math.max(scaledNumber(record.thrustMaxDamage, scale, 0) or 0, thrustMin)
        draft.health = scaledNumber(record.health, scale, 1) or 1
    else
        draft.baseArmor = scaledNumber(record.baseArmor, scale, 0) or 0
        draft.health = scaledNumber(record.health, scale, 1) or 1
    end

    -- The enchantment is part of what the penalty has to cut, and it is its own
    -- record: point the twin at a reduced copy of it (nil keeps the template's,
    -- which is all an unenchanted item has).
    local enchantId = record.enchant
    if (not enchantId or enchantId == '') and itemType.records and itemType.records[itemObject.recordId] then
        enchantId = itemType.records[itemObject.recordId].enchant
    end
    local reducedEnchantment = createReducedEnchantmentRecord(enchantId, scale)
    if reducedEnchantment then
        draft.enchant = tostring(reducedEnchantment.id)
    end

    local recordDraft = itemType.createRecordDraft(draft)
    local newRecord = world.createRecord(recordDraft)
    if not (newRecord and newRecord.id) then return nil end
    reducedItemRecords[cacheKey] = newRecord
    reducedItemRecordIds[tostring(newRecord.id)] = true
    debugLog(string.format('Effect penalty: generated %s at %d%% as %s',
        recordId, math.floor(scale * 100 + 0.5), tostring(newRecord.id)))
    return newRecord
end

-- One line in the log is enough to say an engine build cannot hand an item to
-- another actor's local script; the sweep asks on every pass, so this keeps it
-- from repeating itself.
local equipmentApiWarned = false

-- ── Item swaps wait for the actor's own local script ───────────────────────
-- `types.Actor.setEquipment` is a self-only binding (the engine declares it as
-- `(const SelfObject&, ...)`): calling it for another actor from here raises
--     Allowed only in local scripts for 'openmw.self'
-- and takes the whole sweep callback down with it - which is exactly what left
-- summons unscaled and bound items unreplaced.  The global side therefore does
-- only what a local script cannot (generate the record, create the instance,
-- move it into the actor's inventory) and sends `MagExp_EquipReducedItem` to
-- the actor, which equips it in its own scope (see magexp_local_equip.lua).
--
-- The request is repeated until the actor reports back, because a request sent
-- on the frame the local script is being attached is dropped, and the
-- full-strength original is removed only once the reduced twin is really
-- equipped.  Replacement is post-processing of an already-successful cast, so
-- anything this engine build cannot do degrades to "the vanilla item stays";
-- every step is asked for before it is used, so no call here can raise behind
-- our back and there is nothing to catch.

--- Ask the actor's local script to equip (or clear) one slot.
local function sendItemSwapRequest(swap)
    local target = swap.target
    if not (target and target.isValid and target:isValid()) then return false end
    if type(target.sendEvent) ~= 'function' then return false end
    target:sendEvent('MagExp_EquipReducedItem', {
        slot = swap.slot,
        recordId = swap.recordId,
        token = swap.token,
    })
    return true
end

--- Create the reduced twin of one item instance and hand it to the actor that
--- owns the slot.  Returns a swap record (kept by the sweep until the actor
--- confirms), or nil.
local function requestReducedItemSwap(actor, itemObject, slot, scale, token)
    if not (actor and actor.isValid and actor:isValid()) then return nil end
    if not (itemObject and itemObject.isValid and itemObject:isValid()) then return nil end
    if type(types.Actor.inventory) ~= 'function' then
        if not equipmentApiWarned then
            equipmentApiWarned = true
            debugLog('Effect penalty: this engine cannot reach an actor inventory; items left as they are')
        end
        return nil
    end
    if type(actor.sendEvent) ~= 'function' then return nil end
    if type(itemObject.remove) ~= 'function' then return nil end

    local newRecord = createReducedItemRecord(itemObject, scale)
    if not newRecord then return nil end

    local inventory = types.Actor.inventory(actor)
    if not inventory then return nil end

    local newInstance = world.createObject(newRecord.id, 1)
    if not (newInstance and newInstance.isValid and newInstance:isValid()) then return nil end
    if type(newInstance.moveInto) ~= 'function' then return nil end

    newInstance:moveInto(inventory)
    local swap = {
        target = actor,
        slot = slot,
        recordId = tostring(newRecord.id),
        instance = newInstance,
        original = itemObject,
        token = token,
        attempts = 0,
    }
    sendItemSwapRequest(swap)
    return swap
end

-- ── Summon stat scaling: ask the actor, then wait to be told it happened ──
-- Scaling a summon's stats is a *self-only* operation.  The writable fields of
-- the documented openmw.types stat tables (ActorStats / AttributeStats /
-- DynamicStat / SkillStat: `base`, a dynamic stat's `current`, `modifier`) are
-- cached by the engine on its SelfObject, and a write from here raises
--     Allowed only in local scripts for 'openmw.self'.
-- which is what killed the sweep timer and left the summon at full strength.
-- So the global side does not write stats at all - not even "try it and see",
-- because the only way to see is to catch a raise.  It asks the actor's own
-- local script (scripts/OMW_MagExp/magexp_actor_stats.lua) instead, over both
-- channels the engine offers:
--
--   * `GameObject:addScript(path, initData)` passes initData to the script's
--     `onInit` when the instance is created - the channel that works for a
--     summon found a frame after it spawned, because a script attached this
--     tick has no event handler listening yet;
--   * `GameObject:sendEvent('MagExp_ScaleStats', ...)` for an actor that
--     already carries the script (a second penalised summon of the same
--     creature), and as the retry channel.
--
-- A single one-shot hand-off is exactly what left summons unmodified: whichever
-- of the two the engine dropped on the spawn frame, nothing ever asked again.
-- Every request is therefore repeated on each sweep pass until the actor
-- reports back with MagExp_StatScaleApplied (or the deadline passes), and the
-- actor side de-duplicates by token, so a request that arrives twice can never
-- scale the same summon twice.
local STAT_SCALE_SCRIPT = 'scripts/OMW_MagExp/magexp_actor_stats.lua'
local STAT_SCALE_MAX_ATTEMPTS = 40     -- 40 * PENALISED_SPAWN_INTERVAL = ~2s of retries
local STAT_SCALE_CONFIRM_LIMIT = 256   -- confirmations kept before the registry resets

local confirmedStatScales = {}         -- [token] = true once the actor says it applied
local confirmedStatScaleCount = 0
local statScaleApiWarned = false

--- The actor's own script reports a token it has applied (handled by
--- MagExp_StatScaleApplied in the event handlers at the bottom of this file).
local function markStatScaleConfirmed(token)
    if type(token) ~= 'string' or token == '' then return end
    if confirmedStatScales[token] == nil then
        confirmedStatScaleCount = confirmedStatScaleCount + 1
    end
    confirmedStatScales[token] = true
    -- A confirmation only gates the retry loop, and the actor script ignores a
    -- token it has already applied, so forgetting them is harmless: the worst
    -- case is one more request, which the actor drops on its own de-dupe.
    if confirmedStatScaleCount > STAT_SCALE_CONFIRM_LIMIT then
        confirmedStatScales = {}
        confirmedStatScaleCount = 0
    end
end

local function statScaleConfirmed(token)
    return confirmedStatScales[token] == true
end

-- ── Item-swap confirmations ────────────────────────────────────────────────
-- The actor's local script reports every slot swap it applied (see
-- magexp_local_equip.lua).  A swap is only done - the full-strength original is
-- only removed - once that report arrives, and until it does the sweep keeps
-- asking, exactly like the stat scale above: a request that lands on the frame
-- the local script is being attached is dropped by the engine.
local ITEM_SWAP_MAX_ATTEMPTS = 20      -- 20 * PENALISED_SPAWN_INTERVAL = ~1s of retries
local ITEM_SWAP_CONFIRM_LIMIT = 256    -- confirmations kept before the registry resets

local confirmedItemSwaps = {}          -- [token] = true once the actor says it equipped it
local confirmedItemSwapCount = 0
local warnedItemSwaps = {}             -- [token] = true, so a refusal is logged once

local function markItemSwapConfirmed(token)
    if type(token) ~= 'string' or token == '' then return end
    if confirmedItemSwaps[token] == nil then
        confirmedItemSwapCount = confirmedItemSwapCount + 1
    end
    confirmedItemSwaps[token] = true
    if confirmedItemSwapCount > ITEM_SWAP_CONFIRM_LIMIT then
        confirmedItemSwaps = {}
        confirmedItemSwapCount = 0
    end
end

local function itemSwapConfirmed(token)
    return confirmedItemSwaps[token] == true
end

--- The actor's local script could not equip the twin (no equipment API, item
--- not in its inventory, ...).  Log once per swap so a refusal is visible
--- without repeating on every retry pass.
local function reportItemSwapRefused(data)
    local token = data and data.token
    if type(token) ~= 'string' or token == '' then return end
    if warnedItemSwaps[token] then return end
    warnedItemSwaps[token] = true
    debugLog('Effect penalty: the actor refused the item swap for '
        .. tostring(token) .. '; the full-strength item stays')
end

--- Hand one scaling request to the actor.  Returns true when the request was
--- given to the engine - not when the stats are scaled; that is what the
--- confirmation above is for.
local function requestStatScale(actor, scale, token)
    if not (actor and actor.isValid and actor:isValid()) then return false end
    if type(actor.sendEvent) ~= 'function' then
        if not statScaleApiWarned then
            statScaleApiWarned = true
            debugLog('Effect penalty: this engine cannot deliver a stat scale request; summons stay full strength')
        end
        return false
    end
    local data = { scale = scale, token = token }
    local attached = type(actor.hasScript) == 'function' and actor:hasScript(STAT_SCALE_SCRIPT)
    if not attached and type(actor.addScript) == 'function' then
        -- initData reaches the script's onInit.  The engine ignores an
        -- addScript for a script the object already carries, so the hasScript
        -- check is only here to stop re-asking on every pass.
        actor:addScript(STAT_SCALE_SCRIPT, data)
    end
    actor:sendEvent('MagExp_ScaleStats', data)
    return true
end

--- Take our replaced bound items back: remove the instances.  The engine
--- unequips a slot when the item in it is removed (InventoryStore::remove), so
--- the take-back needs no equipment write of its own - which is just as well,
--- because writing another actor's equipment is a local-script operation.
--- Safe to call twice (the second pass finds every instance already invalid).
local function takeBackReducedBoundItem(state)
    local actor = state and state.actor
    if not (actor and actor:isValid()) then return end
    local inventory = types.Actor.inventory and types.Actor.inventory(actor) or nil
    for _, rec in ipairs(state.items or {}) do
        local item = rec.instance
        local count = item and item.count
        if item and item.isValid and item:isValid()
            and (not count or count > 0) then
            item:remove(1)
        elseif rec.recordId and rec.recordId ~= '' and inventory
            and type(inventory.find) == 'function' then
            -- The handle is spent (a moveInto already consumed it, count 0):
            -- the engine raises "Can't remove 0 of 0 items" for such a
            -- binding, so take the live twin by record id instead.
            local live = inventory:find(rec.recordId)
            if live and live.isValid and live:isValid() then live:remove(1) end
        end
    end
    -- A full-strength original whose swap was never confirmed is still ours to
    -- clean up: it belongs to this cast, and removing it now is better than
    -- leaving a full-strength conjured item behind.  Same count guard: an
    -- original that was equipped then dropped is a spent handle by now.
    for _, item in ipairs(state.originals or {}) do
        if item and item.isValid and item:isValid()
            and (not item.count or item.count > 0) then
            item:remove(1)
        end
    end
end

-- Savable backstop for the take-back: the in-memory registry below dies with
-- a save/load, but a registered timer callback survives it and fires after
-- the effect should have ended.
local reducedBoundItemExpireCallback = async:registerTimerCallback(
    'MagExp_ReducedBoundItemExpire',
    function(state) takeBackReducedBoundItem(state) end)

--- Remember one replaced bound item so it can be taken back when the spell
--- that summoned it ends.  `original` is the full-strength instance the swap
--- stands in for; the sweep removes it as soon as the actor confirms the
--- equip, and the take-back removes it if that confirmation never came.
local function registerReducedBoundItem(actor, spellId, newInstance, slot, delay, original)
    local key = tostring(actor.id) .. '|' .. tostring(spellId)
    local entry = reducedBoundItems[key]
    if not entry then
        entry = { actor = actor, spellId = spellId, items = {}, originals = {} }
        reducedBoundItems[key] = entry
    end
    -- The twin's initial moveInto the caster's inventory is a queued engine
    -- action (see its binding: context.mLuaManager->addAction): until it has
    -- run, an inventory scan cannot find the instance, and the drop
    -- protection below must not mistake that in-flight frame for a drop.
    -- Track both sim and real time: sim time freezes in Barter/Container
    -- menus where dropping is impossible, real time does not.
    entry.lastRegisteredAt = core.getSimulationTime()
    entry.lastRegisteredAtReal = (core.getRealTime and core.getRealTime()) or entry.lastRegisteredAt
    entry.items[#entry.items + 1] = {
        instance = newInstance,
        slot = slot,
        -- Kept alongside the handle: the handle is spent by the queued moveInto
        -- (see findTrackedInstance), the record id is not.
        recordId = tostring(newInstance and newInstance.recordId or ''),
    }
    if original then
        entry.originals[#entry.originals + 1] = original
    end
    if delay and delay > 0 then
        async:newSimulationTimer(delay, reducedBoundItemExpireCallback, entry)
    end
end

--- Replace every weapon / armor piece a found summon carries and has
--- equipped.  Already-replaced instances (and reduced records from an
--- earlier cast) are skipped.  Each replacement is handed to the summon's own
--- local script and confirmed there; returns how many were started.
local function reduceSummonEquipment(entry, summon)
    if not (summon and summon:isValid()) then return 0 end
    if type(types.Actor.getEquipment) ~= 'function' then return 0 end
    local eq = types.Actor.getEquipment(summon)
    if not eq then return 0 end
    local replaced = 0
    for slot, item in pairs(eq) do
        if item and item.isValid and item:isValid()
            and (item.type == types.Weapon or item.type == types.Armor)
            and not entry.replacedItemIds[item.id]
            and not reducedItemRecordIds[tostring(item.recordId)] then
            local token = tostring(entry.spellId) .. '|' .. tostring(item.id) .. '|equip'
            local swap = requestReducedItemSwap(summon, item, slot, entry.scale, token)
            if swap then
                entry.replacedItemIds[item.id] = true
                entry.replacedItemIds[swap.instance.id] = true
                entry.pendingSwaps[#entry.pendingSwaps + 1] = swap
                replaced = replaced + 1
            end
        end
    end
    return replaced
end

--- One pass of the post-spawn sweep for a penalised cast.  Reschedules
--- itself until both sides settle (nothing new found, nothing left to
--- replace) or the deadline passes.
local function runPenalisedSpawnSweep(entry)
    if entry.done then return end
    local summonSideSettled = true
    local boundSideSettled = true
    local itemSideSettled = true

    -- ── Item swaps the actor's local script has not confirmed yet ────────
    -- The equip itself happens in the actor's own scope (see
    -- requestReducedItemSwap); this side repeats the request until the actor
    -- says it applied it and only then removes the full-strength original.
    -- A request sent on the frame the local script is being attached is
    -- dropped by the engine, so one-shot requests are exactly what left the
    -- full-strength gear in place.
    for i = #entry.pendingSwaps, 1, -1 do
        local swap = entry.pendingSwaps[i]
        if itemSwapConfirmed(swap.token) then
            table.remove(entry.pendingSwaps, i)
            local original = swap.original
            if original and original.isValid and original:isValid() then
                original:remove(1)
                debugLog(string.format(
                    'Effect penalty: %s replaced by %s in slot %s',
                    tostring(original.recordId), tostring(swap.recordId),
                    tostring(swap.slot)))
            end
        elseif not (swap.target and swap.target:isValid()) then
            table.remove(entry.pendingSwaps, i)
        else
            swap.attempts = swap.attempts + 1
            if swap.attempts <= ITEM_SWAP_MAX_ATTEMPTS then
                sendItemSwapRequest(swap)
                itemSideSettled = false
            elseif swap.attempts == ITEM_SWAP_MAX_ATTEMPTS + 1 then
                debugLog('Effect penalty: item swap never confirmed ('
                    .. tostring(swap.token) .. '); leaving the item as it is')
            end
        end
    end

    -- ── Summoned actors: scale stats, then replace the gear they carry ──
    if entry.summonExpected and entry.summonSnapshot then
        local caster = entry.caster
        local cell = (caster and caster:isValid()) and caster.cell or nil
        if cell and cell.getAll
            and (not entry.summonCellId or cell.id == entry.summonCellId) then
            for _, obj in ipairs(cell:getAll()) do
                if not entry.summonSnapshot[obj.id] and not entry.summonDone[obj.id]
                    and (types.Creature.objectIsInstance(obj) or types.NPC.objectIsInstance(obj)) then
                    local rid = obj.recordId and tostring(obj.recordId):lower()
                    if rid and entry.summonExpected[rid] then
                        entry.summonDone[obj.id] = true
                        entry.summons[#entry.summons + 1] = obj
                        -- The token ties every retry (and the actor's own
                        -- de-dupe) to this cast and this summoned object, so a
                        -- second penalised summon of the same creature gets
                        -- scaled again while a repeated request for this one
                        -- does not.
                        entry.pendingScales[#entry.pendingScales + 1] = {
                            actor = obj,
                            token = tostring(entry.spellId) .. '|' .. tostring(obj.id),
                            scale = entry.scale,
                            attempts = 0,
                        }
                        summonSideSettled = false
                        debugLog(string.format(
                            'Effect penalty: summon %s queued for %d%% stats',
                            rid, math.floor(entry.scale * 100 + 0.5)))
                    end
                end
            end
        end

        -- ── Stat scaling: ask again until the summon says it is scaled ──
        -- The actor's local script applies the scale and answers with
        -- MagExp_StatScaleApplied; until that answer arrives (or the deadline
        -- does) this stays unsettled, so the sweep keeps polling and keeps
        -- asking.  That retry is the whole fix: a request delivered on the
        -- frame the script is being attached can be dropped, and a one-shot
        -- hand-off never asked again.
        for i = #entry.pendingScales, 1, -1 do
            local pending = entry.pendingScales[i]
            local actor = pending.actor
            if not (actor and actor.isValid and actor:isValid()) then
                table.remove(entry.pendingScales, i)
            elseif statScaleConfirmed(pending.token) then
                table.remove(entry.pendingScales, i)
            else
                pending.attempts = pending.attempts + 1
                if pending.attempts <= STAT_SCALE_MAX_ATTEMPTS then
                    requestStatScale(actor, pending.scale, pending.token)
                elseif pending.attempts == STAT_SCALE_MAX_ATTEMPTS + 1 then
                    debugLog('Effect penalty: summon stat scale never confirmed ('
                        .. tostring(pending.token) .. '); leaving it to the deadline')
                end
                summonSideSettled = false
            end
        end

        for i = #entry.summons, 1, -1 do
            local summon = entry.summons[i]
            if not (summon and summon:isValid()) then
                table.remove(entry.summons, i)
            elseif reduceSummonEquipment(entry, summon) > 0 then
                summonSideSettled = false
            end
        end
        -- Nothing found yet means the engine has not spawned the summon
        -- (or the summoner left the cell); keep looking until the deadline.
        if #entry.summons == 0 then summonSideSettled = false end
    end

    -- ── Bound items: swap the engine's copy for a reduced twin ──────────
    if entry.boundExpected and entry.boundSnapshot then
        local wildcardArmed = entry.boundExpected[WILDCARD_BOUND_KEY] == true
        for expectedId in pairs(entry.boundExpected) do
            if expectedId ~= WILDCARD_BOUND_KEY
                and not entry.boundDone[expectedId] then boundSideSettled = false end
        end
        -- A wildcard-armed sweep must run every tick until the deadline
        -- (the scan is by name/id, not by a fixed record id, so there is
        -- no per-id "not done" flag to latch on). Explicitly listed items
        -- still gate settled-ness via their exact ids above, and the
        -- deadline terminates the sweep once everything that can spawn
        -- before the timeout has been processed.
        if wildcardArmed then
            boundSideSettled = false
        end
        if not boundSideSettled then
            local target = entry.target
            if target and target:isValid() and types.Actor.inventory
                and types.Actor.getEquipment then
                local inv = types.Actor.inventory(target)
                local items = inv and inv.getAll and inv:getAll()
                if items then
                    local eq = types.Actor.getEquipment(target)
                    local hasWildcard = entry.boundExpected[WILDCARD_BOUND_KEY] == true
                    for _, obj in ipairs(items) do
                        if obj.isValid and obj:isValid() and not entry.boundSnapshot[obj.id]
                            and not reducedItemRecordIds[tostring(obj.recordId)] then
                            local rid = tostring(obj.recordId):lower()
                            local matches = false
                            if entry.boundExpected[rid] and not entry.boundDone[rid] then
                                matches = true
                            elseif hasWildcard and not entry.boundDone[rid] then
                                -- Wildcard fallback: any new item whose record
                                -- id or localized name contains the word
                                -- "bound" is treated as a bound item from
                                -- another mod (or a future OpenMW effect)
                                -- that we have no explicit table entry for.
                                local objType = obj.type
                                local objRec = objType and objType.record and objType.record(obj)
                                if recordLooksLikeBoundItem(objRec) then
                                    matches = true
                                end
                            end
                            if matches then
                                -- The engine auto-equips the bound item with
                                -- the spawn; until a slot is found the swap
                                -- waits for a later pass.
                                local slot = nil
                                if eq then
                                    for s, equipped in pairs(eq) do
                                        if equipped == obj
                                            or (equipped and equipped.id == obj.id) then
                                            slot = s
                                            break
                                        end
                                    end
                                end
                                if slot then
                                    local token = tostring(entry.spellId) .. '|'
                                        .. tostring(obj.id) .. '|equip'
                                    local swap = requestReducedItemSwap(
                                        target, obj, slot, entry.scale, token)
                                    if swap then
                                        entry.boundDone[rid] = true
                                        entry.pendingSwaps[#entry.pendingSwaps + 1] = swap
                                        -- The swap is not done until the actor
                                        -- confirms it, so this pass must not
                                        -- settle (the original is removed by
                                        -- the confirmation pass below).
                                        itemSideSettled = false
                                        registerReducedBoundItem(target, entry.spellId,
                                            swap.instance, slot, entry.boundDuration, obj)
                                    end
                                end
                            end
                        end
                    end
                end
            end
            boundSideSettled = true
            for expectedId in pairs(entry.boundExpected) do
                if expectedId ~= WILDCARD_BOUND_KEY
                    and not entry.boundDone[expectedId] then boundSideSettled = false end
            end
            -- When there are no explicit ids left to wait for AND the
            -- wildcard is armed, we never "fully settle" (we can't prove
            -- every name-matching item has spawned); rely on the deadline
            -- to terminate the sweep. This keeps wildcard-armed scans
            -- running every tick up to PENALISED_SPAWN_DEADLINE so items
            -- that spawn on a slightly later mechanics tick are still
            -- caught and reduced.
        end
    end

    if (summonSideSettled and boundSideSettled and itemSideSettled)
        or core.getSimulationTime() >= entry.deadline then
        entry.done = true
        return
    end
    async:newUnsavableSimulationTimer(PENALISED_SPAWN_INTERVAL,
        function() runPenalisedSpawnSweep(entry) end)
end

local function trackPenalisedSpawn(caster, target, scale, spellId,
    summonExpected, summonSnapshot, summonCellId,
    boundExpected, boundSnapshot, boundDuration)
    local entry = {
        caster = caster,
        target = target,
        scale = scale,
        spellId = spellId,
        summonExpected = summonExpected,
        summonSnapshot = summonSnapshot,
        summonCellId = summonCellId,
        boundExpected = boundExpected,
        boundSnapshot = boundSnapshot,
        boundDuration = boundDuration,
        summonDone = {},       -- [obj.id] = stat scaling already requested
        pendingScales = {},    -- stat requests awaiting the actor's confirmation
        summons = {},          -- found summoned actors
        replacedItemIds = {},  -- [obj.id] = already replaced by a reduced twin
        pendingSwaps = {},     -- equipment requests awaiting the actor's confirmation
        boundDone = {},        -- [record id] = already replaced
        deadline = core.getSimulationTime() + PENALISED_SPAWN_DEADLINE,
        done = false,
    }
    async:newUnsavableSimulationTimer(0, function() runPenalisedSpawnSweep(entry) end)
end

-- How long after registration the drop protection stays hands-off: the
-- initial moveInto of a fresh twin is a queued engine action, so a scan in
-- that window cannot find the instance and would misreport the hand-off as
-- a drop.  During this window a player cannot physically drop the item
-- either (the swap completes in well under one second), so an instant here
-- loses nothing.  Simulation time freezes in menus, where dropping is
-- impossible anyway, so this never unfreezes a real drop.
local BOUND_DROP_GRACE = 0.25

--- Weld every replaced bound item to its caster while the spell lasts: it
--- must never be droppable.
---
--- Engine contract, all verified against the installed Lua API:
---   * an equipped item is part of the actor's inventory, so one lookup —
---     types.Actor.inventory(actor):find(recordId), usable from a global
---     script — proves the item is still aboard, equipped or not;
---   * GameObject:moveInto(inventory) moves an instance from ANY store the
---     engine keeps items in (a cell, a container, another actor's
---     inventory); it is the documented "give item to actor" path and —
---     like every world mutation — is queued and executed between frames.
---
--- A dropped bound item is therefore simply put back on the next frame:
--- the drag animation finishes, the item lands in the world, and this sweep
--- pulls it straight into the caster's pack.  Nothing is ever deleted, so a
--- false positive cannot destroy an item; the worst case of an engine
--- quirk is a second moveInto to the same inventory, which leaves the item
--- exactly where it already was.
--- The inventory of an actor or a container, or nil when the object is
--- neither.  Used by the search below; the API exposes the two separately.
local function inventoryOf(obj)
    if types.Actor.objectIsInstance(obj) then return types.Actor.inventory(obj) end
    if types.Container and types.Container.objectIsInstance
        and types.Container.objectIsInstance(obj) then
        return types.Container.inventory(obj)
    end
    return nil
end

--- Find the live object behind a tracked conjured item.
---
--- The handle `world.createObject` returned is spent the moment the item is
--- handed to its owner: GObject:moveInto copies the object into the
--- destination and zeroes the source count immediately
--- (apps/openmw/mwlua/objectbindings.cpp, the moveInto action).  The Lua
--- handle keeps a resolvable Ptr with count 0 — isValid() stays true — and
--- every later moveInto/remove on it raises the engine's
---     Can't remove 0 of 0 items
--- because the binding checks the source count before moving.  That is what
--- filled openmw.log while a conjured item was out of the inventory, and
--- because the move came before the notice, the player heard nothing either.
---
--- So the sweep never trusts that handle: it resolves the item by record id,
--- which is unique per (base item, penalty) and therefore identifies this
--- cast's twin.  Looked up, in order:
---   1. the owner's own inventory — the twin is home, nothing to do;
---   2. the world: the item lying in the owner's cell (a drop);
---   3. another actor or container in that cell: a sale, a gift, a chest.
--- Returns the live object, the owner's inventory, and the storage the object
--- was found in (nil when it is home), so the caller can classify and report.
local function findTrackedInstance(actor, recordId, inventory)
    if recordId == '' then return nil, nil end
    local home = inventory:find(recordId)
    if home then return home, inventory, nil end

    local cell = actor.cell
    local holders = nil
    if cell and type(cell.getAll) == 'function' then
        for _, obj in ipairs(cell:getAll()) do
            if obj ~= actor then
                local objId = tostring(obj.recordId or '')
                if objId == recordId then
                    -- The item itself is in the world: it was dropped.
                    return obj, inventory, 'world'
                end
                holders = holders or {}
                holders[#holders + 1] = obj
            end
        end
        for _, obj in ipairs(holders or {}) do
            local store = inventoryOf(obj)
            if store and type(store.find) == 'function' then
                local held = store:find(recordId)
                if held then
                    -- Somebody else is holding it: sold to a merchant, given to a
                    -- companion, or dropped into a chest (a container store).
                    return held, inventory, obj
                end
            end
        end
    end

    -- The merchant may be in a different active cell (exterior vs interior
    -- border, or a companion in a nearby cell) — world.activeActors covers
    -- every actor in a currently loaded cell, not just actor.cell.
    if world.activeActors then
        for _, other in ipairs(world.activeActors) do
            if other ~= actor and other:isValid() then
                local store = inventoryOf(other)
                if store and type(store.find) == 'function' then
                    local held = store:find(recordId)
                    if held then
                        return held, inventory, other
                    end
                end
            end
        end
    end

    return nil, nil
end

--- True when the actor is the player the UI speaks to.  Read from world.players
--- rather than from the cast-time handle: the handle can be a stale proxy after
--- a load, and a notice that silently never fires is exactly what the drop
--- protection looked like in the field.
local function playerObjectFor(actor)
    for _, player in ipairs(world.players or {}) do
        if player and player:isValid() and tostring(player.id) == tostring(actor.id) then
            return player
        end
    end
    -- A scripted (multiplayer) or unusual setup may not list the actor in
    -- world.players; the engine's own answer still identifies the player, and
    -- a notice that silently never fires is exactly the bug this guards
    -- against.
    if types.Player and type(types.Player.objectIsInstance) == 'function'
        and types.Player.objectIsInstance(actor) then
        return actor
    end
    return nil
end

--- Weld every replaced bound item to its caster while the spell lasts: it
--- must never leave the caster's inventory.
local function pullBackDroppedBoundItems(entry)
    local actor = entry.actor
    if not (actor and actor:isValid()) then return end
    -- Use real time for the hand-off grace when available: simulation time
    -- freezes while Barter/Container menus are open, so a grace based on it
    -- would stall the sell protection for the whole time the menu is open.
    -- Real time keeps ticking in menus and lets the initial moveInto queue
    -- drain even while paused.
    local nowSim = core.getSimulationTime()
    local nowReal = (core.getRealTime and core.getRealTime()) or nowSim
    local lastAt = entry.lastRegisteredAtReal or entry.lastRegisteredAt or 0
    local ageReal = nowReal - lastAt
    local ageSim = nowSim - (entry.lastRegisteredAt or 0)
    -- If we have real time, use it; otherwise fall back to sim time.
    -- The grace is bypassed for a sale (found in another actor) because a
    -- sale can never be the initial hand-off to the caster.
    local function withinGrace(foundIn)
        if foundIn ~= nil and foundIn ~= 'world'
            and types.Actor.objectIsInstance(foundIn) then
            return false -- sold: never grace
        end
        if core.getRealTime then
            return ageReal < BOUND_DROP_GRACE
        else
            return ageSim < BOUND_DROP_GRACE
        end
    end
    if type(types.Actor.inventory) ~= 'function' then return end
    local inventory = types.Actor.inventory(actor)
    if not (inventory and type(inventory.find) == 'function') then return end
    local player = playerObjectFor(actor)
    -- The hand-off grace for the whole entry: the twin's initial moveInto
    -- is a queued engine action, so a scan in that window finds nothing and
    -- must not report a drop (branch A never had this guard — a penalised
    -- bound spell printed its "cannot drop" notice right at summon time).
    -- Same real-time preference as withinGrace: real time keeps ticking in
    -- the pausing menus, so the window closes even while one is open.
    local registrationGrace
    if core.getRealTime then
        registrationGrace = ageReal < BOUND_DROP_GRACE
    else
        registrationGrace = ageSim < BOUND_DROP_GRACE
    end
    for _, rec in ipairs(entry.items) do
        local recordId = rec.recordId
        if type(recordId) ~= 'string' or recordId == '' then
            recordId = tostring(rec.instance and rec.instance.recordId or '')
        end
        -- The pull-back moveInto lands between frames: by the next pass the
        -- move has either landed (the twin is home) or was lost (the twin is
        -- still out and needs a fresh pull). Either way the notice raised
        -- for the answered drop or sale is re-armed exactly one pass after
        -- it fired, so the in-flight frame can never print it twice — the
        -- old immediate re-arm did exactly that whenever the queued move had
        -- not drained within the same sweep.
        if rec.reArmNotice then
            rec.reArmNotice = nil
            rec.notified = nil
        end
        if recordId ~= '' then
            local item, _, foundIn = findTrackedInstance(actor, recordId, inventory)
            if not item then
                -- not home and not found in any scanned store
                if registrationGrace then
                    -- Fresh hand-off: the twin's initial moveInto is still
                    -- in flight, nothing was dropped and there is nothing
                    -- to report yet.
                elseif not rec.notified then
                    rec.notified = true
                    local fallback = rec.instance
                    if fallback and fallback.isValid and fallback:isValid()
                        and type(fallback.moveInto) == 'function'
                        and (not fallback.count or fallback.count > 0) then
                        fallback:moveInto(inventory)
                    end
                    debugLog(string.format(
                        'Effect penalty: conjured %s is out of reach; the spell will not take it back',
                        recordId))
                    if player and type(player.sendEvent) == 'function' then
                        player:sendEvent('MagExp_BoundItemDropBlocked', { recordId = recordId })
                    end
                end
            elseif foundIn == nil then
                -- Home again (or never left): re-arm the notice for the next
                -- drop or sale.
                rec.notified = nil
            else
                if withinGrace(foundIn) then
                    -- Still in hand-off window for a world drop; wait one more frame.
                elseif item and type(item.moveInto) == 'function' then
                    local sold = foundIn ~= 'world'
                        and types.Actor.objectIsInstance(foundIn)
                    item:moveInto(inventory)
                    if not rec.notified then
                        rec.notified = true
                        rec.reArmNotice = true
                        debugLog(string.format(
                            'Effect penalty: conjured %s was %s; returned to %s while the spell lasts',
                            recordId, sold and 'sold' or 'dropped', tostring(actor.recordId)))
                        if player and type(player.sendEvent) == 'function' then
                            player:sendEvent(sold and 'MagExp_BoundItemSellBlocked'
                                or 'MagExp_BoundItemDropBlocked', { recordId = recordId })
                        end
                    end
                end
            end
        end
    end
end

--- Every-frame bookkeeping for replaced bound items: after the spell that
--- summoned one is no longer active (expired or dispelled) the replacement
--- goes with it; while it is active the replacement cannot be dropped out of
--- the caster's inventory.
local function sweepReducedBoundItems()
    for key, entry in pairs(reducedBoundItems) do
        local actor = entry.actor
        if not (actor and actor:isValid()) then
            reducedBoundItems[key] = nil
        else
            pullBackDroppedBoundItems(entry)
            local stillActive = false
            local active = types.Actor.activeSpells(actor)
            if active then
                for _, inst in pairs(active) do
                    if inst.id == entry.spellId then
                        stillActive = true
                        break
                    end
                end
            end
            if not stillActive then
                takeBackReducedBoundItem(entry)
                reducedBoundItems[key] = nil
            end
        end
    end
end

-- ============================================================
-- [REDUCED CAST REGISTRY] Cross-path replacement
--
-- A reduced (quick-cast) spell lives on the target under a *generated* record
-- id.  The engine's own stacking rule replaces an active spell by record id,
-- so a later vanilla cast of the *same* spell cannot see the reduced one and
-- both stay active.  (The other order already worked: the penalised path
-- removes the source itself before adding its replacement.)  Every reduced
-- cast is recorded here with the source id it stands in for; the per-frame
-- sweep drops it as soon as the engine adds the real spell to the same actor.
--
-- A vanilla cast can also collide with a quick-cast *summon* without sharing
-- its spell id.  The engine's summon bookkeeping is keyed by the magic-effect
-- id (CreatureStats::getSummonedCreatureMap, a multimap filled by
-- summonCreature), so a vanilla summon of a DIFFERENT spell that carries the
-- same Summon effect spawns a second creature and leaves both active-spell
-- entries standing — the quick-cast summon is never disbanded, which is the
-- bug this registry exists to close.  Summons must not stack unless the spell
-- is explicitly stackable, so the same sweep that handles the record-id case
-- also disbands our reduced stand-in the moment a foreign vanilla summon of a
-- matching effect shows up in front of it, mirroring removeSourceForReducedSpell
-- ('quick-cast over a vanilla summon disbands it') in the reverse order.
-- Removing the stand-in runs the engine's own cleanup for its summon: the
-- creature, its VFX, and its ledger entry (cleanupSummonedCreature).
-- ============================================================
local reducedCastRegistry = {}   -- [actorId|generatedId] = record
local reducedGeneratedKeys = {} -- every generated stand-in id this script made

-- A quick-cast summon applied at FULL strength (no penalty) has no generated
-- stand-in, so sweepReducedCasts cannot see it; the next vanilla summon of the
-- same effect would spawn a second creature and the quick-cast one would never
-- be disbanded.  Those casts are registered here too, keyed by target and
-- source spell, and re-checked below on the same "overlapping summon effect"
-- rule: the first later vanilla active spell whose summon effect overlaps ours
-- wins, and the quick-cast summon — which the engine still disbands when the
-- active spell carrying SummonX is purged — is purged right there.
local unpenalizedSummonRegistry = {} -- [actorId|spellKey] = { target, sourceKey, summonEffects }
local UNPENALIZED_SUMMON_INTERVAL = 0.1  -- per-entry re-check cadence (seconds)
local UNPENALIZED_SUMMON_EXPIRY  = 6.0  -- stop polling a target long after the cast

--- Register a reduced cast so the sweep can recognise what replaced it.
--- `summonEffects` is the set of normalised summon-effect ids the reduced
--- cast carries (empty for a non-summon); it arms the summon guard below.
local function registerReducedCast(target, generatedId, sourceId, summonEffects)
    if not (target and target:isValid()) then return end
    if type(generatedId) ~= 'string' or type(sourceId) ~= 'string' then return end
    if generatedId == sourceId then return end

    local effectSet = {}
    if type(summonEffects) == 'table' then
        for effId in pairs(summonEffects) do
            effectSet[effId] = true
        end
    end

    local generatedKey = activeSpellIdKey(generatedId)
    reducedGeneratedKeys[generatedKey] = true

    reducedCastRegistry[tostring(target.id) .. '|' .. generatedKey] = {
        target = target,
        targetId = tostring(target.id),
        generatedId = generatedId,
        generatedKey = generatedKey,
        sourceId = sourceId,
        sourceKey = activeSpellIdKey(sourceId),
        summonEffects = effectSet,                 -- normalised summon effect ids
        summonGuard = next(effectSet) ~= nil,      -- true when this cast summoned
    }
end

--- The effect ids of one kind (summon or bound) that an active-spell entry
--- carries, read from `inst.effects[].id` (and, after a reload or on older
--- engines, resolved through the record the entry's id points at).  Returns
--- a set of normalised effect-id keys, or nil when the entry has
--- none/unknown.  `isKindEffect` decides membership; the summon sweep and
--- the bound/summon displacement sweep below share this reader.
local function collectActiveEffectIds(inst, isKindEffect)
    local kindEffects, count = {}, 0
    local function addEffectId(rawId)
        if rawId == nil then return end
        local key = tostring(rawId):lower():gsub('[^%a%d]', '')
        if key ~= '' and isKindEffect(key) and not kindEffects[key] then
            kindEffects[key] = true
            count = count + 1
        end
    end

    local effects = inst and inst.effects
    if effects then
        for _, eff in pairs(effects) do
            -- ESM::ActiveEffect userdata: expose the effect id as either field.
            addEffectId(eff and (eff.id or eff.effectId))
        end
    end
    if count > 0 then return kindEffects end

    -- Reloads (and older engines) may not expose per-effect ids on the entry;
    -- fall back to the record the entry's id points at. Record lookups are
    -- case-insensitive because the engine may hand back ids in varying case
    -- (e.g. FormId vs lowercase) and the store itself is case-insensitive in
    -- vanilla but the Lua proxy may not be on older builds.
    local rid = inst and inst.id
    if type(rid) ~= 'string' or rid == '' then return nil end

    local function collectRecordEffects(record)
        if not record then return false end
        local found = false
        for _, eff in ipairs(record.effects or {}) do
            addEffectId(eff and (eff.id or eff.effectId or eff.effect and eff.effect.id))
            found = true
        end
        return found
    end

    local function findSpellRecord(id)
        if not id then return nil end
        local rec = core.magic.spells.records[id]
        if rec then return rec end
        rec = core.magic.spells.records[id:lower()]
        if rec then return rec end
        local lower = id:lower()
        for _, r in pairs(core.magic.spells.records) do
            if r.id and tostring(r.id):lower() == lower then return r end
        end
        return nil
    end

    local function findEnchantRecord(id)
        if not id or not core.magic.enchantments then return nil end
        local rec = core.magic.enchantments.records[id]
        if rec then return rec end
        rec = core.magic.enchantments.records[id:lower()]
        if rec then return rec end
        local lower = id:lower()
        for _, r in pairs(core.magic.enchantments.records) do
            if r.id and tostring(r.id):lower() == lower then return r end
        end
        return nil
    end

    local record = findSpellRecord(rid) or findEnchantRecord(rid)
    if collectRecordEffects(record) then return (count > 0) and kindEffects or nil end

    -- An enchantment cast lives under the *item*'s record id; resolve the
    -- item's enchantment effect list for the scroll/weapon/armor cases.
    local itemRec = nil
    local itemStores = {
        types.Weapon and types.Weapon.records,
        types.Armor and types.Armor.records,
        types.Book and types.Book.records,
        types.Clothing and types.Clothing.records,
        types.MiscItem and types.MiscItem.records,
    }
    for _, store in ipairs(itemStores) do
        if type(store) == 'table' then
            local rec = store[rid] or store[rid:lower()]
            if rec then
                itemRec = rec
                break
            end
            local lower = rid:lower()
            for _, r in pairs(store) do
                if r.id and tostring(r.id):lower() == lower then
                    itemRec = r
                    break
                end
            end
            if itemRec then break end
        end
    end
    if itemRec then
        local enchantId = itemRec.enchant
        if type(enchantId) == 'string' and enchantId ~= ''
            and core.magic.enchantments then
            collectRecordEffects(findEnchantRecord(enchantId)
                or core.magic.enchantments.records[enchantId])
        end
    end

    if count > 0 then return kindEffects end
    return nil
end

--- The summon effect ids an active-spell entry carries (normalised keys).
local function collectActiveSummonEffects(inst)
    return collectActiveEffectIds(inst, isSummonEffectId)
end

--- True when the normalised effect id is a bound-equipment effect — an
--- entry in the engine's own bound list, a magic effect with an Item field,
--- or a modded effect whose id/name spells "bound".
local function isBoundEffectId(effKey)
    return boundEffectItemIds(effKey) ~= nil
end

--- The bound effect ids an active-spell entry carries (normalised keys).
local function collectActiveBoundEffects(inst)
    return collectActiveEffectIds(inst, isBoundEffectId)
end

--- True when two summon-effect sets share at least one effect id.
local function summonEffectsOverlap(a, b)
    if not (a and b) then return false end
    for effId in pairs(a) do
        if b[effId] then return true end
    end
    return false
end

-- ============================================================
-- [BOUND & SUMMON DISPLACEMENT] One summon per creature kind, one bound
-- effect per item kind — retroactive replacement, newest cast wins.
--
-- Vanilla forbids stacking a bound/summon effect: its magnitude is forced
-- to 1 and a new application REPLACES the older one — you cannot hold two
-- of the same creature or two of the same bound item.  The engine only
-- enforces this per spell record (a non-stackable recast replaces itself),
-- so two DIFFERENT spells carrying the same Summon or BoundX effect — a
-- vanilla spell and a quick-cast stand-in, two modded spells, a scroll and
-- a spell — stay active side by side and produce two scamps / two bound
-- daggers.
--
-- This closes the gap for every source at once.  A cast's summon/bound
-- effects are folded to *kind keys*: the creature record id the engine
-- spawns for a summon effect and the item record ids a bound effect equips,
-- so even two different effect ids that summon the same creature (a modded
-- copy of a vanilla effect) displace each other, exactly like two casts of
-- the same effect id do.  When a cast lands, older active spells on the
-- same actor sharing one of its kind keys are removed by their per-cast
-- active-spell id; the engine's own cleanup for the losing effect then
-- disbands its creature / takes back its bound item.  A polled sweep (every
-- DISPLACEMENT_SWEEP_INTERVAL of sim time, over world.players and
-- world.activeActors) enforces the same newest-wins rule for casts this
-- script never sees — a plain vanilla cast, an NPC's spell — by tracking,
-- per actor and kind, the cast that currently holds the slot: a cast key
-- that is new for the kind is the newer cast, and the previous holders
-- lose.  Removing a whole active spell (never just one effect) is what
-- keeps the engine's own summon/bound bookkeeping consistent, the same
-- contract the reduced-cast sweeps below rely on.
-- ============================================================

local boundSummonWatch = {}   -- [actorId] = { actor = handle, known = { [kindKey] = { castKey, seq } } }
local displacementSeq = 0     -- monotonically increasing: higher seq = newer cast
local DISPLACEMENT_SWEEP_INTERVAL = 0.2
local nextDisplacementSweep = 0

--- Fold one normalised effect id into the kind keys it occupies on the
--- target: the spawned creature record for a summon, the equipped item
--- record ids for a bound effect, the effect id itself when the concrete
--- record is unknown (modded effects without a resolvable item).
local function addDisplacementKindKeys(effKey, out)
    if type(effKey) ~= 'string' or effKey == '' then return end
    if isSummonEffectId(effKey) then
        -- The creature record the engine spawns is the kind: two different
        -- spell records that summon the same creature still summon the same
        -- creature.  Fall back to the effect id when the GMST cannot be
        -- resolved on this build.
        local gmst = SUMMON_EFFECT_GMST[effKey]
        local creatureId = nil
        if gmst and core.getGMST then creatureId = core.getGMST(gmst) end
        if type(creatureId) == 'string' and creatureId ~= '' then
            out[creatureId:lower()] = true
        else
            out[effKey] = true
        end
        return
    end
    local items = boundEffectItemIds(effKey)
    if items then
        for itemId in pairs(items) do
            if itemId == WILDCARD_BOUND_KEY then
                out[effKey] = true
            else
                out[tostring(itemId):lower()] = true
            end
        end
    end
end

--- Kind keys an active-spell entry currently occupies on its host.
local function activeEntryDisplacementKinds(inst)
    local out = {}
    local effIds = collectActiveEffectIds(inst, function(key)
        return isSummonEffectId(key) or isBoundEffectId(key)
    end)
    if effIds then
        for effKey in pairs(effIds) do
            addDisplacementKindKeys(effKey, out)
        end
    end
    return out
end

--- Kind keys a source spell record carries for the effect indexes a cast
--- applies (the record's effect tables are plain readable entries).
local function sourceSpellDisplacementKinds(spell, effectIndexes)
    local out = {}
    for _, idx in ipairs(effectIndexes or {}) do
        local rawEff = spell and spell.effects and spell.effects[idx + 1]
        if rawEff then
            local effKey = tostring(effectFieldValue(rawEff, "id") or ""):lower():gsub("[^%a%d]", "")
            addDisplacementKindKeys(effKey, out)
        end
    end
    return out
end

local function sharesAnyKind(a, b)
    if not (a and b) then return false end
    for kindKey in pairs(a) do
        if b[kindKey] then return true end
    end
    return false
end

--- Remember which cast currently holds each of `kinds` for `actor`, so the
--- polled sweep recognises it as the incumbent instead of a challenger.
local function noteDisplacementWinner(actor, activeSpellId, kinds)
    if not (actor and actor:isValid()) then return end
    local castKey = activeSpellId and activeSpellIdKey(activeSpellId) or nil
    if not castKey then return end
    local actorId = tostring(actor.id)
    local watch = boundSummonWatch[actorId]
    if not watch then
        watch = { actor = actor, known = {} }
        boundSummonWatch[actorId] = watch
    end
    watch.actor = actor
    for kindKey in pairs(kinds) do
        displacementSeq = displacementSeq + 1
        watch.known[kindKey] = { castKey = castKey, seq = displacementSeq }
    end
end

--- Retroactive replacement at apply time: `appliedActiveSpellId` is the cast
--- that just landed; every OTHER active spell on the target that shares one
--- of its summon/bound kind keys is an older application of the same kind
--- and is removed (newest wins).  Called right after activeSpells:add, when
--- the losing entries are still the only same-kind entries in the list.
local function displaceOlderBoundSummonSpells(active, target, appliedActiveSpellId, kinds)
    if not (active and type(active.remove) == 'function') then return end
    if type(kinds) ~= 'table' or next(kinds) == nil then return end
    if not (target and target:isValid()) then return end
    local appliedKey = appliedActiveSpellId and activeSpellIdKey(appliedActiveSpellId) or nil
    -- Without the per-cast id `activeSpells:add` returns there is no way to
    -- tell the cast that just landed from the older ones — removing the
    -- wrong side would kill the fresh cast.  The polled sweep covers those
    -- engines instead, from its seen-this-frame ordering.
    if not appliedKey then return end
    local losers = {}
    for _, inst in pairs(active) do
        local isApplied = false
        local instCastKey = inst and inst.activeSpellId
            and activeSpellIdKey(inst.activeSpellId) or nil
        if appliedKey and instCastKey and instCastKey == appliedKey then
            isApplied = true
        end
        -- Constant-effect enchantments are not applications of the kind: the
        -- engine re-adds them every mechanics tick while the item is worn,
        -- so removing one only guarantees a respawn loop.
        if inst and inst.fromEquipment then
            isApplied = true
        end
        if not isApplied and inst then
            local otherKinds = activeEntryDisplacementKinds(inst)
            if sharesAnyKind(kinds, otherKinds) and inst.activeSpellId then
                losers[#losers + 1] = {
                    activeSpellId = inst.activeSpellId,
                    label = tostring(inst.id or inst.activeSpellId),
                }
            end
        end
    end
    for _, loser in ipairs(losers) do
        active:remove(loser.activeSpellId)
        debugLog(string.format(
            'Bound/summon displacement: newer cast %s replaced older %s on %s',
            tostring(appliedKey or '?'), loser.label, tostring(target.recordId or target.id)))
    end
    if appliedKey then
        noteDisplacementWinner(target, appliedActiveSpellId, kinds)
    end
end

--- The polled half of the displacement rule: enforces one active spell per
--- summon/bound kind on every loaded actor, newest cast wins, for casts
--- that never pass through applySpellToActor (vanilla player casts, NPC
--- spells, scrolls).  See the block comment above for the bookkeeping.
local function sweepBoundSummonDisplacement(now)
    if now < nextDisplacementSweep then return end
    nextDisplacementSweep = now + DISPLACEMENT_SWEEP_INTERVAL

    local targets = {}
    local function addTarget(actor)
        if actor and actor.isValid and actor:isValid()
            and types.Actor and types.Actor.objectIsInstance(actor) then
            targets[tostring(actor.id)] = actor
        end
    end
    for _, player in ipairs(world.players or {}) do addTarget(player) end
    if world.activeActors then
        for _, actor in ipairs(world.activeActors) do addTarget(actor) end
    else
        -- Older engines without world.activeActors: at least keep watching
        -- the actors the other registries already know about.
        for _, entry in pairs(reducedCastRegistry) do addTarget(entry.target) end
        for _, entry in pairs(unpenalizedSummonRegistry) do addTarget(entry.target) end
        for _, entry in pairs(reducedBoundItems) do addTarget(entry.actor) end
    end

    for actorId, actor in pairs(targets) do
        local active = types.Actor.activeSpells(actor)
        if not active then
            boundSummonWatch[actorId] = nil
        else
            -- present[kindKey] = { { castKey = ..., activeSpellId = ... }, ... }
            local present = {}
            for _, inst in pairs(active) do
                -- Constant-effect enchantments are not applications of the
                -- kind: the engine re-adds them every mechanics tick while
                -- the item is worn, so they can neither be displaced nor
                -- displace (removing one only guarantees a respawn loop).
                if not (inst and inst.fromEquipment) then
                    local kinds = activeEntryDisplacementKinds(inst)
                    if next(kinds) then
                        local castKey = (inst.activeSpellId or inst.id)
                            and activeSpellIdKey(inst.activeSpellId or inst.id) or nil
                        for kindKey in pairs(kinds) do
                            local list = present[kindKey]
                            if not list then
                                list = {}
                                present[kindKey] = list
                            end
                            list[#list + 1] = { castKey = castKey, activeSpellId = inst.activeSpellId }
                        end
                    end
                end
            end
            if next(present) then
                local watch = boundSummonWatch[actorId] or { actor = actor, known = {} }
                watch.actor = actor
                local losers = {}
                for kindKey, holders in pairs(present) do
                    -- Sequence continuity: the cast already known to hold this
                    -- kind keeps its sequence number; anything else is a cast
                    -- that arrived since the last pass, i.e. the newest.
                    local known = watch.known[kindKey]
                    local winner, winnerSeq
                    for _, holder in ipairs(holders) do
                        local seq
                        if known and known.castKey == holder.castKey then
                            seq = known.seq
                        else
                            displacementSeq = displacementSeq + 1
                            seq = displacementSeq
                        end
                        if not winner or seq > winnerSeq then
                            winner, winnerSeq = holder, seq
                        end
                    end
                    for _, holder in ipairs(holders) do
                        if holder ~= winner and winner and winner.activeSpellId
                            and holder.activeSpellId then
                            losers[#losers + 1] = {
                                activeSpellId = holder.activeSpellId,
                                winnerLabel = tostring(winner.castKey),
                                kindKey = kindKey,
                            }
                        end
                    end
                    watch.known[kindKey] = { castKey = winner.castKey, seq = winnerSeq }
                end
                -- Kinds no longer present drop out of the watch (the spell
                -- expired or was dispelled; a later reappearance is a new
                -- cast and wins trivially).
                for kindKey in pairs(watch.known) do
                    if not present[kindKey] then watch.known[kindKey] = nil end
                end
                for _, loser in ipairs(losers) do
                    if type(active.remove) == 'function' then
                        active:remove(loser.activeSpellId)
                        debugLog(string.format(
                            'Bound/summon displacement: %s holds %s on %s; older cast removed',
                            loser.winnerLabel, loser.kindKey,
                            tostring(actor.recordId or actor.id)))
                    end
                end
                if next(watch.known) then
                    boundSummonWatch[actorId] = watch
                else
                    boundSummonWatch[actorId] = nil
                end
            else
                boundSummonWatch[actorId] = nil
            end
        end
    end

    -- Watches whose actor is no longer tracked (left the cell, died and was
    -- cleaned up) have nothing to police.
    for actorId in pairs(boundSummonWatch) do
        if not targets[actorId] then boundSummonWatch[actorId] = nil end
    end
end

--- Remember a quick-cast summon that was applied at FULL strength (no effect
--- penalty or exempt): it lives under the source spell's own record id, so it
--- can stack with a later vanilla summon exactly like the reported bug.  The
--- next vanilla active spell whose summon effect overlaps it wins and this
--- entry's summon is purged, matching quick-cast-over-vanilla in the reverse
--- order.  `activeSpellId` is the per-cast id `activeSpells:add` returned —
--- the engine's own unique id for this exact cast — so "ours" is found by id,
--- not by matching the source record.
local function registerUnpenalizedSummon(target, sourceId, activeSpellId, summonEffects)
    if not (target and target:isValid()) then return end
    if type(sourceId) ~= 'string' or sourceId == '' then return end
    local effectSet = {}
    if type(summonEffects) == 'table' then
        for effId in pairs(summonEffects) do
            effectSet[effId] = true
        end
    end
    if not next(effectSet) then return end
    local sourceKey = activeSpellIdKey(sourceId)
    unpenalizedSummonRegistry[tostring(target.id) .. '|' .. tostring(sourceKey)] = {
        target = target,
        sourceKey = sourceKey,
        activeSpellId = activeSpellId,
        summonEffects = effectSet,
        lastSweep = core.getSimulationTime(),
    }
end

--- Every UNPENALIZED_SUMMON_INTERVAL seconds, look for a vanilla active spell on
--- each registered target whose summon effect overlaps the quick-cast summon's;
--- the first one found wins and the quick-cast summon is purged by its own
--- active-spell id.  The engine removes the matching summoned creature when the
--- active spell carrying its summon effect is purged, so removing exactly the
--- quick-cast summon leaves the vanilla one standing — mirrors the shorthand
--- "quick-cast over a vanilla summon disbands it" in the order this registry
--- exists to police.  An entry's summon is no longer identifiable once its
--- active spell expired (or was dispelled); that also simply wins the exchange,
--- which is the vanilla rule, so nothing is done then.
local function sweepUnpenalizedSummons()
    local now = core.getSimulationTime()
    for key, entry in pairs(unpenalizedSummonRegistry) do
        local target = entry.target
        if not (target and target:isValid()) then
            unpenalizedSummonRegistry[key] = nil
        elseif now - (entry.lastSweep or now) < UNPENALIZED_SUMMON_INTERVAL then
            -- not this entry's turn yet
        elseif now - (entry.lastSweep or now) > UNPENALIZED_SUMMON_EXPIRY then
            -- long past any summon duration; stop polling this cast
            unpenalizedSummonRegistry[key] = nil
        else
            entry.lastSweep = now
            local active = types.Actor.activeSpells(target)
            if not active then
                unpenalizedSummonRegistry[key] = nil
            else
                local ours = nil
                local rival = nil
                local rivalReason = nil
                local ownedKey = entry.activeSpellId
                    and activeSpellIdKey(entry.activeSpellId)
                for _, inst in pairs(active) do
                    local isOurs = ownedKey and inst and inst.activeSpellId
                        and activeSpellIdKey(inst.activeSpellId) == ownedKey
                    -- Older engines may not return an id from activeSpells:add;
                    -- fall back to matching the source record id for our cast.
                    if not ownedKey and inst and inst.id
                        and activeSpellIdKey(inst.id) == entry.sourceKey then
                        isOurs = true
                    end
                    if isOurs then
                        ours = inst
                    else
                        -- A vanilla summon can replace ours in two ways, same
                        -- as sweepReducedCasts: same spell recast at full
                        -- strength, or a different spell with overlapping
                        -- summon effect. The effect list may be unavailable
                        -- on some engine versions, so sameSpell is a fallback
                        -- that must not be gated on collectActiveSummonEffects.
                        local idKey = activeSpellIdKey(inst and inst.id or '')
                        local sameSpell = idKey == entry.sourceKey
                        local fx = collectActiveSummonEffects(inst)
                        if sameSpell or (fx and summonEffectsOverlap(entry.summonEffects, fx)) then
                            -- Keep first rival, but continue scanning so ours
                            -- is still found even if pairs() visited rival first.
                            if not rival then
                                rival = inst
                                rivalReason = sameSpell and 'same spell' or 'overlapping effect'
                            end
                        end
                    end
                end
                if rival and ours and ours.activeSpellId
                    and type(active.remove) == 'function' then
                    active:remove(ours.activeSpellId)
                    debugLog(string.format(
                        'Effect penalty: quick-cast summon %s disbanded by a later vanilla summon %s (%s)',
                        tostring(entry.sourceKey),
                        tostring(rival.id or rival.activeSpellId or '?'),
                        tostring(rivalReason)))
                    unpenalizedSummonRegistry[key] = nil
                elseif not ours then
                    -- our summon already expired/dispelled; nothing to keep
                    unpenalizedSummonRegistry[key] = nil
                end
            end
        end
    end
end

--- Drop our reduced stand-in once the engine adds the spell it replaces, and
--- forget entries whose stand-in is no longer active anyway.
---
--- For a quick-cast *summon* this sweep additionally enforces the vanilla
--- single-summon rule in the order the reduced-cast registry cannot see by
--- record id: the engine's summon bookkeeping is keyed by the magic *effect*
--- id (CreatureStats::getSummonedCreatureMap), so a vanilla summon cast while
--- our quick-cast summon is up lands as a *different* active spell carrying
--- the same Summon effect.  Summons must not stack unless the spell is marked
--- stackable, so the vanilla cast disbands the quick-cast summon exactly as a
--- quick-cast disbands a vanilla summon (removeSourceForReducedSpell).  Both
--- creatures briefly exist on the engine side while the cast queue drains;
--- removing the reduced stand-in here runs the engine's own cleanup for its
--- summon - the VFX, the creature, and its ledger entry.
local function sweepReducedCasts()
    for key, entry in pairs(reducedCastRegistry) do
        local target = entry.target
        if not (target and target:isValid()) then
            reducedCastRegistry[key] = nil
        else
            local active = types.Actor.activeSpells(target)
            if not active then
                reducedCastRegistry[key] = nil
            else
                local ours = nil
                local sourceCast = false
                local seen = {}
                local foreignSummon = nil   -- later full-strength summon displacing ours
                local foreignReason = nil
                for activeKey, inst in pairs(active) do
                    local id = tostring((inst and inst.id) or activeKey or '')
                    seen[#seen + 1] = id
                    local idKey = activeSpellIdKey(id)
                    -- A stand-in another quick-cast generated is never a rival.
                    local foreign = not reducedGeneratedKeys[idKey]
                    if idKey == entry.generatedKey then
                        ours = inst
                    elseif entry.summonGuard and not foreignSummon and foreign then
                        -- Two ways a later full-strength summon takes the field
                        -- away from our stand-in, and both have to be caught:
                        --
                        --   * the SAME spell recast normally — the one thing the
                        --     engine CAN hand us is its record id, which is
                        --     exactly the source id this stand-in stands in for
                        --     (the generated stand-in can never equal it, so the
                        --     match is unambiguous).  This is the vanilla recast
                        --     the record-id check exists for: both casts summon
                        --     creatures of the same record id, and without this
                        --     the quick-cast summon simply stayed standing;
                        --
                        --   * a DIFFERENT spell carrying an overlapping summon
                        --     effect — the engine keys summons by effect id, not
                        --     by spell, so there is no record id connecting the
                        --     two casts; the effect set is the only truth.
                        --
                        -- Neither test is gated on inst.temporary: some engines
                        -- keep vanilla casts under the SpellStore flag rather
                        -- than Temporary, and a build that gates on it silently
                        -- never sees the cast it is supposed to disband.
                        local sameSpell = idKey == entry.sourceKey
                        local fx = collectActiveSummonEffects(inst)
                        if sameSpell or (fx and summonEffectsOverlap(entry.summonEffects, fx)) then
                            foreignSummon = inst
                            foreignReason = sameSpell and 'the same spell recast at full strength'
                                or 'another summon of the same effect'
                        end
                    elseif not entry.summonGuard and idKey == entry.sourceKey then
                        -- Non-summon reduced casts still rely on the record-id
                        -- match (there is no engine-side spawn to key by).
                        sourceCast = true
                    end
                end

                -- `ours` can be gone already (the engine replaced the
                -- stand-in, or the effect expired between passes): removing a
                -- spell that is not there is a no-op, not an error.
                local function removeOurs()
                    if ours and ours.activeSpellId
                        and type(active.remove) == 'function' then
                        active:remove(ours.activeSpellId)
                    end
                end

                if foreignSummon then
                    -- A later full-strength summon displaced ours (see the loop
                    -- above): summons do not stack, so the vanilla cast
                    -- disbands the quick-cast summon.  Removing the stand-in
                    -- runs the engine's own summon cleanup — the creature, its
                    -- VFX and its ledger entry — even when the vanilla cast
                    -- already claimed the effect-id slot in that ledger.
                    removeOurs()
                    debugLog(string.format(
                        'Effect penalty: quick-cast summon %s disbanded by %s (%s)',
                        tostring(entry.generatedId),
                        tostring(foreignSummon and (foreignSummon.id or foreignSummon.activeSpellId) or '?'),
                        tostring(foreignReason)))
                    reducedCastRegistry[key] = nil
                elseif sourceCast then
                    -- The exact same spell is active under its own record id (a
                    -- full-strength vanilla recast, or the same spell quick-cast
                    -- again unpenalized): the engine could never match that id
                    -- to the generated stand-in, so the stand-in is removed here.
                    -- For a summon this also runs the engine's summon cleanup;
                    -- the vanilla cast's summon then stands alone, exactly as
                    -- recasting a summon in vanilla replaces the old one.
                    removeOurs()
                    debugLog(string.format(
                        'Effect penalty: reduced %s replaced by a full-strength cast of %s',
                        tostring(entry.generatedId), tostring(entry.sourceId)))
                    reducedCastRegistry[key] = nil
                elseif not ours then
                    -- The stand-in is gone (expired or dispelled); a foreign
                    -- vanilla summon that shares its effect has simply won the
                    -- replacement, which is the vanilla rule we are enforcing.
                    debugLog(string.format(
                        'Effect penalty: reduced %s is no longer active on %s (active: %s)',
                        tostring(entry.generatedId), tostring(entry.targetId),
                        table.concat(seen, ', ')))
                    reducedCastRegistry[key] = nil
                end
            end
        end
    end

    -- ── Unpenalized quick-cast summons ─────────────────────────────────────
    -- No penalty means no generated stand-in — ours *is* the source spell under
    -- its own record id — so the sweep above never sees these casts.  They are
    -- handled back-to-front here on the same summon-effect rule.  The engine
    -- keeps the other summon alive whenever it is not the one whose active
    -- spell is being removed, so every other summon of a matching effect on the
    -- target is purged directly by its active spell id; this is the one case
    -- where a vanilla spell is removed on behalf of a newer quick-cast, in
    -- order to match how quick-cast-over-vanilla already behaves.
    sweepUnpenalizedSummons()
end

local heightCache = {}
local lastPlayerCell = nil

-- ============================================================
-- [CONFIG] Spell Effect Stacking
-- Modders can modify STACK_CONFIG via I.MagExp.STACK_CONFIG
-- ============================================================
local STACK_CONFIG = {
    -- "SPELL" mode: casting a spell replaces previous instances of the EXACT same spell ID.
    MODE = "SPELL",
    DEFAULT_LIMIT = 1,
    -- Exception definitions: specific spell IDs and how many times they can stack.
    -- Example: SPELL_LIMITS = { ["third barrier"] = 3 }
    SPELL_LIMITS = {},
    PERSISTENT_EFFECTS = {
        ["shield"] = true,
        ["fireshield"] = true,
        ["frostshield"] = true,
        ["lightningshield"] = true,
        ["soultrap"] = true,
    },
    LOCKABLE_EFFECTS = {
        ['open'] = true,
        ['lock'] = true,
        ['disarmtrap'] = true,
        ['absorbtrap'] = true,
        ['detecttrap'] = true,
        ['detecttrap_alt'] = true
    },
    UNIVERSAL_EFFECTS = {}
}

-- ============================================================
-- [HELPERS] Data Enrichment for Events
-- ============================================================

local function awardSpellSkillProgress(caster, school, spellCost, isEnchant, spellId)
    if not caster or not caster:isValid() then return end
    if caster.type ~= types.Player then return end
    if not school or school == "" then return end

    local cost = spellCost or 0
    caster:sendEvent('MagExp_AwardSkillProgress', {
        school    = school,
        cost      = cost,
        isEnchant = isEnchant or false,
        spellId   = spellId,
    })
end

local function getSpellDamageInfo(spellId, effectScale)
    local dt = { health = 0, magicka = 0, fatigue = 0 }
    local spell = core.magic.spells.records[spellId]
    if not (spell and spell.effects) then return dt end
    local scale = coerceEffectScale(effectScale)
    for _, eff in ipairs(spell.effects) do
        local mid = eff.id:lower()
        -- Reported damage follows the cast: with a penalty in play the spell
        -- dealt the reduced magnitude, not the record's.
        local params = scaledEffectParams(eff, scale)
        local magMin = params.magnitudeMin or 0
        local magMax = params.magnitudeMax or magMin
        local mag = (magMin + magMax) / 2
        if mid:find("health") or mid:find("fire") or mid:find("frost") or mid:find("shock") or mid:find("poison") then
            dt.health = dt.health + mag
        elseif mid:find("magicka") then
            dt.magicka = dt.magicka + mag
        elseif mid:find("fatigue") then
            dt.fatigue = dt.fatigue + mag
        end
    end
    return dt
end

--- True when the spell effect's recorded range is "on self".
local function spellEffectRangeIsSelf(r)
    local R = core.magic.RANGE
    if r == nil then return false end
    if R and r == R.Self then return true end
    if type(r) == "string" then
        local s = r:lower():gsub("^%s+", ""):gsub("%s+$", "")
        return s == "self" or s == "on self"
    end
    if type(r) == "number" and R and type(R.Self) == "number" then
        return r == R.Self
    end
    return false
end

--- Pick which spell.effects entry represents this hit (effects[1] fails when Self is listed first).
local function inferEffectIndexForMagicHit(spell, data)
    local R = core.magic.RANGE
    local st = data.spellType or R.Target
    if not spell or not spell.effects then return 0 end
    if st == R.Self then
        for i, eff in ipairs(spell.effects) do
            if spellEffectRangeIsSelf(eff.range) then return i - 1 end
        end
        return 0
    elseif st == R.Touch then
        for i, eff in ipairs(spell.effects) do
            if eff.range == R.Touch then return i - 1 end
        end
    elseif st == R.Target then
        for i, eff in ipairs(spell.effects) do
            if not spellEffectRangeIsSelf(eff.range) and eff.range ~= R.Touch then return i - 1 end
        end
        for i, eff in ipairs(spell.effects) do
            if eff.range == R.Touch then return i - 1 end
        end
    end
    return 0
end

local function fireMagicHitEvent(data)
    -- data expects: attacker, target, spellId, hitPos, hitNormal, spellType, isAoE, area, velocity, projectile, userData
    -- data.effectScale (optional): the quick-cast penalty this hit landed with.
    -- The event reports what actually happened, so every magnitude a listener
    -- reads here is the reduced one for a penalised cast — the same values the
    -- generated record applied.  Listeners that deal damage from these fields
    -- (Kinetic Forces and friends) would otherwise hit at full strength
    -- through a halved cast.
    local effectScale = coerceEffectScale(data.effectScale)
    local spellId = data.spellId
    local spell = core.magic.spells.records[spellId] or core.magic.enchantments.records[spellId]
    
    if not spell and spellId then
        -- Safe iterative fallback for numerical proxies or case-sensitivity edge cases
        for _, rec in pairs(core.magic.spells.records) do
            local recId = rec.id
            if recId and tostring(recId):lower() == tostring(spellId):lower() then
                spell = rec
                break
            end
        end
        if not spell then
            for _, rec in pairs(core.magic.enchantments.records) do
                local recId = rec.id
                if recId and tostring(recId):lower() == tostring(spellId):lower() then
                    spell = rec
                    break
                end
            end
        end
    end

    if not spell then return end

    local metaIdx = data.effectIndex
    if metaIdx == nil then
        metaIdx = inferEffectIndexForMagicHit(spell, data)
    end
    local firstEff = spell.effects and spell.effects[(metaIdx or 0) + 1]
    if not firstEff and spell.effects and spell.effects[1] then
        firstEff = spell.effects[1]
    end

    local info = {
        attacker     = data.attacker,
        target       = data.target,
        spellId      = data.spellId,
        hitPos       = data.hitPos,
        hitNormal    = data.hitNormal or util.vector3(0,0,1),
        successful   = true,
        sourceType   = (I.Combat and I.Combat.AttackSourceType) and I.Combat.AttackSourceType.Magic or (core.magic.ATTACK_SOURCE_TYPE and core.magic.ATTACK_SOURCE_TYPE.Magic or 2),
        spellType    = data.spellType or core.magic.RANGE.Target,
        isAoE        = data.isAoE or false,
        area         = data.area or 0,
        effectScale  = effectScale,
        damage       = getSpellDamageInfo(data.spellId, effectScale),
        projectile   = data.projectile,
        velocity     = data.velocity or util.vector3(0,0,0),
        impactSpeed  = data.impactSpeed or 0,
        maxSpeed     = data.maxSpeed or 0,
        unreflectable = data.unreflectable or false,
        casterLinked = data.casterLinked or false,
        userData     = data.userData
    }

    -- Metadata detection: effect driving this hit (not always spell.effects[1] when Self precedes Touch/Target).
    info.magMin = 0
    info.magMax = 0

    if firstEff then
        local mgef = core.magic.effects.records[firstEff.id]
        if mgef then
            info.school = mgef.school 
            local eid = tostring(firstEff.id):lower()
            local name = (mgef.name or ""):lower()
            local n = eid .. " " .. name
            if n:find("fire") then info.element = "fire"
            elseif n:find("frost") then info.element = "frost"
            elseif n:find("shock") then info.element = "shock"
            elseif n:find("poison") then info.element = "poison"
            elseif n:find("heal") or n:find("restore") then info.element = "heal"
            else info.element = "default" end
            
            -- 1. Check for primary effect damage
            if n:find("health") or n:find("fire") or n:find("frost") or n:find("shock") or n:find("poison") then
                info.magMin = roundScaledEffectValue(firstEff.magnitudeMin, effectScale, 0) or 0
                info.magMax = roundScaledEffectValue(firstEff.magnitudeMax or firstEff.magnitudeMin,
                    effectScale, 0) or info.magMin
            end
        end
    end
    
    -- 2. Final Fallback: If no explicit damage was found but we have effects, use the first one's magnitude.
    -- This supports mods using 'Script Effect' or custom templates for metadata events.
    if info.magMax == 0 and firstEff then
        info.magMin = roundScaledEffectValue(firstEff.magnitudeMin, effectScale, 0) or 0
        info.magMax = roundScaledEffectValue(firstEff.magnitudeMax or firstEff.magnitudeMin,
            effectScale, 0) or info.magMin
    end

    -- Stacking Info
    info.stackLimit = STACK_CONFIG.SPELL_LIMITS[data.spellId] or STACK_CONFIG.DEFAULT_LIMIT
    if info.target and info.target:isValid() and types.Actor.objectIsInstance(info.target) then
        local activeSpells = types.Actor.activeSpells(info.target)
        if activeSpells then
            local count = 0
            for sId, _ in pairs(activeSpells) do
                if sId == data.spellId then count = count + 1 end
            end
            info.stackCount = count
        end
    end

    -- Broadcast globally
    core.sendGlobalEvent('MagExp_OnMagicHit', info)
    if MagExpPublicInterface and MagExpPublicInterface.MagExp_OnMagicHit then
        MagExpPublicInterface.MagExp_OnMagicHit(info)
    end

    -- Send to target (local script) if actor
    if data.target and data.target:isValid() then
        data.target:sendEvent('MagExp_Local_MagicHit', info)

        -- Compatibility audio dispatch for actor hits. Actor hit visuals are
        -- owned exclusively by applySpellToActor so explicit hit models and
        -- suppressImpactVfx cannot be followed by a second stock hit static.
        if not data.muteAudio and types.Actor.objectIsInstance(data.target) and data.target.enabled and firstEff then
            local mgef = core.magic.effects.records[firstEff.id]
            if mgef then
                local userData = data.userData
                local hasImpactSoundOverride = type(userData) == "table"
                    and type(userData.impactSound) == "string"

                if not hasImpactSoundOverride then
                    local snd = mgef.school:lower() .. " hit"
                    data.target:sendEvent('PlaySound3d', { sound = snd })
                end
            end
        end
    end
end

--- Internal dispatcher for effect lifecycle events.
--- Fires both the public interface callback and a global event.
local function fireEffectEvent(eventName, actor, effect)
    if MagExpPublicInterface and MagExpPublicInterface[eventName] then
        MagExpPublicInterface[eventName](actor, effect)
    end
    core.sendGlobalEvent('MagExp_' .. eventName:sub(1,1):upper() .. eventName:sub(2), { actor = actor, effect = effect })
end

-- ============================================================
-- [CORE] Authoritative Spell Application
-- ============================================================

local function staticOrWeaponRecord(recordId)
    if type(recordId) ~= "string" or recordId == "" then
        return nil
    end
    local folded = string.lower(recordId)
    return (types.Static.records and (types.Static.records[recordId] or types.Static.records[folded]))
        or (types.Weapon.records and (types.Weapon.records[recordId] or types.Weapon.records[folded]))
end

local function staticOrWeaponModel(recordId)
    local record = staticOrWeaponRecord(recordId)
    if record and type(record.model) == "string" and record.model ~= "" then
        return record.model
    end
    return nil
end

local function visualModelFromModelOrRecord(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    local lower = string.lower(value)
    if lower:find(".nif", 1, true) or value:find("\\", 1, true) or value:find("/", 1, true) then
        return value
    end
    return staticOrWeaponModel(value)
end

local function spawnProjectileImpactVfx(data, hitPos)
    if not (data and hitPos and world.vfx and world.vfx.spawn) then
        return false
    end
    local userData = data.userData
    if type(userData) == "table" and userData.suppressImpactVfx == true then
        return false
    end
    local model = visualModelFromModelOrRecord(data.hitModel)
        or staticOrWeaponModel(data.areaVfxRecId)
        or staticOrWeaponModel(data.vfxRecId)
    if type(model) ~= "string" or model == "" then
        return false
    end
    world.vfx.spawn(model, hitPos, { mwMagicVfx = false })
    return true
end

--- Fallback hit static record id when mgef.hitVfx is absent (ported from legacy manual apply VFX resolver).
local function deriveMagicEffectImpactStaticId(mgef)
    if not mgef then return nil end
    if mgef.hitVfx and mgef.hitVfx ~= "" then return mgef.hitVfx end
    local schoolIdx = mgef.school
    local s = "destruction"
    if type(schoolIdx) == "string" then s = schoolIdx:lower()
    elseif type(schoolIdx) == "number" then
        local schools = { [0] = "alteration", [1] = "conjuration", [2] = "destruction", [3] = "illusion", [4] = "mysticism", [5] = "restoration" }
        s = schools[schoolIdx] or "destruction"
    end

    local n = (mgef.name or ""):lower()
    local eid = tostring(mgef.id):lower()
    local element = nil
    if n:find("fire") or eid:find("fire") then element = "Fire"
    elseif n:find("frost") or eid:find("frost") or n:find("cold") or eid:find("cold") then element = "Frost"
    elseif n:find("shock") or eid:find("shock") or n:find("lightn") then element = "Lightning"
    elseif n:find("poison") or eid:find("poison") then element = "Poison"
    end

    local hitVfxId
    if element then hitVfxId = "VFX_" .. element .. "Hit"
    elseif s == "destruction" then hitVfxId = "VFX_DestructHit"
    elseif s == "alteration" then hitVfxId = "VFX_AlterationHit"
    elseif s == "conjuration" then hitVfxId = "VFX_ConjureHit"
    elseif s == "illusion" then hitVfxId = "VFX_IllusionHit"
    elseif s == "mysticism" then hitVfxId = "VFX_MysticismHit"
    elseif s == "restoration" then hitVfxId = "VFX_RestorationHit"
    else hitVfxId = "VFX_DefaultHit" end

    local lId = tostring(hitVfxId):lower()
    if not (types.Static.records[lId] or types.Weapon.records[lId]) then
        if tostring(hitVfxId):find("Hit") then hitVfxId = "VFX_DefaultHit" end
    end
    return hitVfxId
end

--- Fallback area static record id when mgef.areaStatic is absent.
local function deriveMagicEffectImpactAreaId(mgef)
    if not mgef then return nil end
    
    local schoolIdx = mgef.school
    local s = "destruction"
    if type(schoolIdx) == "string" then 
        s = schoolIdx:lower()
    elseif type(schoolIdx) == "number" then
        local schools = { 
            [0] = "alteration", 
            [1] = "conjuration", 
            [2] = "destruction", 
            [3] = "illusion", 
            [4] = "mysticism", 
            [5] = "restoration" 
        }
        s = schools[schoolIdx] or "destruction"
    end

    local n = (mgef.name or ""):lower()
    local eid = tostring(mgef.id):lower()
    local element = nil
    if n:find("fire") or eid:find("fire") then 
        element = "Fire"
    elseif n:find("frost") or eid:find("frost") or n:find("cold") or eid:find("cold") then 
        element = "Frost"
    elseif n:find("shock") or eid:find("shock") or n:find("lightn") then 
        element = "Lightning"
    elseif n:find("poison") or eid:find("poison") then 
        element = "Poison"
    end

    local areaVfxId
    if element then 
        areaVfxId = "VFX_" .. element .. "Area"
    elseif s == "destruction" then 
        areaVfxId = "VFX_DestructArea"
    elseif s == "alteration" then 
        areaVfxId = "VFX_AlterationArea"
    elseif s == "conjuration" then 
        areaVfxId = "VFX_ConjureArea"
    elseif s == "illusion" then 
        areaVfxId = "VFX_IllusionArea"
    elseif s == "mysticism" then 
        areaVfxId = "VFX_MysticismArea"
    elseif s == "restoration" then 
        areaVfxId = "VFX_RestorationArea"
    else 
        areaVfxId = "VFX_DefaultArea" 
    end

    local lId = tostring(areaVfxId):lower()
    if not (types.Static.records[lId] or types.Weapon.records[lId]) then
        areaVfxId = "VFX_DefaultArea"
    end
    return areaVfxId
end

-- [FRIENDLIER FIRE COMPAT] Spells applied from Lua (activeSpells:add) bypass
-- the engine's CastSpell::inflict / ApplyMagicEffects path, so Friendlier
-- Fire's own sweep can never see them. Detect friendly fire here — using
-- Follower Detection Util's follower list and the same test Friendlier Fire
-- uses — and skip harmful casts aimed at followers/summons. Honours FF's
-- settings read-only; no-op without FDU/FF.
local function ffSetting(key, default)
    local sec = nil
    sec = storage.globalSection('SettingsFriendlierFire_settings')
    if not sec then return default end
    local val = nil
    val = sec:get(key)
    if val ~= nil then return val end
    return default
end

local function ffFollowerList()
    if I.FollowerDetectionUtil
        and type(I.FollowerDetectionUtil.getFollowerList) == 'function' then
        -- The call is not guarded: an exception raised inside that mod is its
        -- bug and should surface in the log rather than be flattened into
        -- "no followers". The shape check stays, so a mod that returns
        -- something which is not a list still degrades to {} instead of
        -- poisoning the caller.
        local list = I.FollowerDetectionUtil.getFollowerList()
        if type(list) == 'table' then return list end
    end
    return {}
end

local function ffIsFriendlyPair(caster, target, followers)
    if not (caster and target) then return false end
    if caster.id == target.id then return false end
    local castByPlayer = caster.type == types.Player
    local casterState = followers[caster.id]
    if not (castByPlayer or (casterState and casterState.followsPlayer)) then
        return false
    end
    local victimState = followers[target.id]
    return target.type == types.Player or (victimState and victimState.followsPlayer)
end

local function ffIsHarmful(effects)
    if not effects then return false end
    for _, effect in ipairs(effects) do
        if effect and effect.id then
            local mgef = core.magic.effects.records[effect.id]
            if mgef and mgef.harmful then return true end
        end
    end
    return false
end

local function ffProtectionActive(target)
    if not target then return false end
    if not ffSetting('disableSpells', true) then return false end

    if target.type ~= types.Player then
        if ffSetting('commandDisablesProtection', true) then
            local cc, ch = 0, 0
            local ae = types.Actor.activeEffects(target)
            cc = ae:getEffect('commandcreature').magnitude
            ch = ae:getEffect('commandhumanoid').magnitude
            if cc ~= 0 or ch ~= 0 then return false end
        end

        local recordId = target.recordId
        local isSummon = type(recordId) == 'string'
            and (recordId:find('_summon$') or recordId == 'bonewalker_greater_summ')
        if isSummon and not ffSetting('protectSummons', true) then return false end

        local records = target.type.records
        local rec = records and records[recordId]
        local mwscript = rec and rec.mwscript
        if mwscript then
            local blacklist = ffSetting('blacklistedScripts', {})
            for _, blacklisted in ipairs(blacklist or {}) do
                if mwscript == blacklisted then return false end
            end
        end
    end
    return true
end

local function isFriendlyFireSpell(caster, target, effects)
    if not (caster and target) then return false end
    if not ffProtectionActive(target) then return false end
    return ffIsFriendlyPair(caster, target, ffFollowerList())
        and ffIsHarmful(effects)
end

--- The normalised summon-effect ids from a spell's own model effect list
--- (letters only, lowercase).  Mirrors the SUMMON_EFFECT_GMST keys handed to
--- the penalised-spawn tracker below, so a quick-cast summon can be registered
--- with the same effect ids the reduced-cast sweep must match a foreign
--- vanilla summon against.
local function collectSourceSpellSummonEffects(spell, effectIndexes)
    local summonEffects = {}
    if not (spell and type(spell.effects) == 'table') then return summonEffects end
    local scan = effectIndexes
    if not (type(scan) == 'table' and #scan > 0) then
        scan = {}
        for i = 1, #spell.effects do scan[#scan + 1] = i - 1 end
    end
    for _, idx in ipairs(scan) do
        local rawEff = spell.effects[idx + 1]
        local effId = tostring(rawEff and rawEff.id or ''):lower():gsub('[^%a%d]', '')
        if SUMMON_EFFECT_GMST[effId] then
            summonEffects[effId] = true
        end
    end
    return summonEffects
end

-- The projectile ray already supports this caller-scoped exclusion list.
-- Apply the same contract to direct spells and area targets, before damage,
-- actor feedback, or AoE hit broadcasts. Unspecified lists preserve defaults.
local function userDataIgnoresActor(target, userData)
    local ignored = type(userData) == "table" and userData.ignoreActorRecordIds
    if type(ignored) ~= "table" or not types.Actor.objectIsInstance(target) then
        return false
    end
    local recordId = string.lower(target.recordId)
    for key, value in pairs(ignored) do
        if type(key) == "string" and value == true and string.lower(key) == recordId then
            return true
        end
        if type(value) == "string" and string.lower(value) == recordId then
            return true
        end
    end
    return false
end

local function applySpellToActor(spellId, caster, target, hitPos, isAoe, itemObject, forcedEffects, unreflectable, casterLinked, userData, muteAudio, muteLight, continuousVfx, effectScale, sourceData)
    if not target or not target:isValid() then return end
    if not (caster and caster:isValid()) then caster = target end
    if target.type ~= types.NPC and target.type ~= types.Creature and target.type ~= types.Player then
        debugLog("applySpellToActor: Aborting - target is not an actor type")
        return
    end

    -- [DEAD ACTOR GATE] Must be first — before any VFX/sounds fire on the target
    if not checkTarget(target) or userDataIgnoresActor(target, userData) then
        debugLog("[MagExp] Target Vetoed (dead or filtered): ", tostring(target.recordId or target.id))
        return
    end

    debugLog("Applying " .. spellId .. " to " .. (target.recordId or "unknown") .. " by " .. (caster.recordId or "unknown"))

    local spell = core.magic.spells.records[spellId]
    local isEnchantment = false
    if not spell then
        spell = core.magic.enchantments.records[spellId]
        isEnchantment = true
    end
    if not spell then
        isEnchantment = false
        for _, rec in pairs(core.magic.spells.records) do
            local recId = rec.id
            if recId and tostring(recId):lower() == tostring(spellId):lower() then
                spell = rec; break
            end
        end
    end
    if not spell then
        for _, rec in pairs(core.magic.enchantments.records) do
            local recId = rec.id
            if recId and tostring(recId):lower() == tostring(spellId):lower() then
                spell = rec; isEnchantment = true; break
            end
        end
    end
    if not spell then
        local effRec = core.magic.effects.records[spellId]
        if not effRec then
            for _, rec in pairs(core.magic.effects.records) do
                local recId = rec.id
                if recId and tostring(recId):lower() == tostring(spellId):lower() then
                    effRec = rec; break
                end
            end
        end
        if effRec then
            spell = {
                id = spellId, cost = 0,
                effects = { { id = spellId, range = core.magic.RANGE.Target, magnitudeMin = 30, magnitudeMax = 30, area = 0 } }
            }
        end
    end

    if not spell then
        debugLog("applySpellToActor: record not found:", tostring(spellId))
        return
    end

    local hasHarmful = false
    local hasCasterLinked = casterLinked or false
    if spell.effects then
        for _, eff in ipairs(spell.effects) do
            debugLog("Checking effect", eff.id)
            local mgef = core.magic.effects.records[eff.id]
            if mgef then
                if mgef.harmful then
                    debugLog("Detected harmful effect:", eff.id)
                    hasHarmful = true
                end
                if mgef.casterLinked then
                    debugLog("Detected casterLinked effect:", eff.id)
                    hasCasterLinked = true
                end
            else
                debugLog("No mgef for", eff.id)
            end
        end
    else
        debugLog("No effects in spell")
    end

    local effectIndexes = (forcedEffects and #forcedEffects > 0) and forcedEffects or nil
    if not effectIndexes and spell.effects then
        effectIndexes = {}
        for i, _ in ipairs(spell.effects) do
            table.insert(effectIndexes, i - 1)
        end
    end

    local sameCasterAsTarget = (caster and caster:isValid() and target and target:isValid() and caster.id == target.id)
    if effectIndexes and spell.effects and not sameCasterAsTarget then
        local filtered = {}
        for _, idx in ipairs(effectIndexes) do
            local eff = spell.effects[idx + 1]
            if eff and not spellEffectRangeIsSelf(eff.range) then
                table.insert(filtered, idx)
            end
        end
        effectIndexes = (#filtered > 0) and filtered or nil
    end

    if not effectIndexes or #effectIndexes == 0 then
        debugLog("applySpellToActor: no eligible effects on this actor (after range gate) —", tostring(spellId))
        return
    end

    -- ── Effect penalty: replace the source with a generated record ─────────
    local scale = coerceEffectScale(effectScale)
    if effectPenaltyExemptSpell(spell, isEnchantment) and scale < 1 then
        -- A power (always) or a spell/scroll (while the exclusion toggle is
        -- on) must land at full strength — a caller that miscomputed the scale
        -- still gets it annulled here.  Enchanted items stay penalised.
        scale = 1.0
    end
    local isPenalized = scale < 1 and scale > 0
    local itemForApplication = itemObject
    local itemRecordIdStr = nil

    -- ── Enchanted-item identity ─────────────────────────────────────────
    -- The engine resolves an enchanted activeSpells:add through the ITEM
    -- RECORD (getNameAndMagicEffects understands Spell/Potion/Ingredient/
    -- Armor/Book/Clothing/Weapon ids and follows the record's `enchant` to
    -- its effect list); the ENCHANTMENT id itself is NOT a valid add id — it
    -- falls into the engine's Spell-store lookup and raises "not found".  The
    -- item RECORD id is therefore kept as a plain string: a scroll's INSTANCE
    -- is consumed by the launch-time resource guard before this runs, and any
    -- property read on that dead handle raises (see itemRefRecordId above).
    -- Only a confirmed-live instance is kept for ActiveSpellAddOptions.item.
    if isEnchantment then
        if type(itemForApplication) == "string" then
            itemRecordIdStr = (itemForApplication ~= "") and itemForApplication or nil
            itemForApplication = nil
        end
        if itemRecordIdStr == nil and itemForApplication ~= nil then
            itemRecordIdStr = itemRefRecordId(itemForApplication)
        end
        if itemRecordIdStr == nil and type(sourceData) == "table" then
            local rid = sourceData.itemRecordId
            if type(rid) == "string" and rid ~= "" then itemRecordIdStr = rid end
        end
        -- Re-find the instance by record id too: another stack of the same
        -- item is as good as the consumed one for the cast's source identity
        -- (`inventory:find` answers a falsy value when the caster carries
        -- none — the same contract the launch guard relies on).
        local live = nil
        if itemRefIsLive(itemForApplication) then
            live = itemForApplication
        elseif itemRecordIdStr ~= nil and caster and caster:isValid() then
            local inv = types.Actor.inventory(caster)
            local found = inv and inv:find(itemRecordIdStr)
            if found then live = found end
        end
        itemForApplication = live
    end

    local sourceSpellId = spellId
    if isEnchantment then
        sourceSpellId = itemRecordIdStr or spellId
    end
    local sourceKey = reducedSpellSourceKey(spell, isEnchantment)
    local applicationRecord = isEnchantment and sourceSpellId or spellId
    -- ActiveSpellAddOptions.id is read by the engine as a *string* record id
    -- (`RefId::deserializeText(options.get<std::string_view>("id"))`).  A record
    -- object in that slot arrives as an empty string, i.e. an empty RefId, and
    -- the engine raises `Spell 'Empty{}' not found` — so the id handed to
    -- activeSpells:add is always the string, and the record is kept only to
    -- read the generated effect list back out of it.
    local applicationId = applicationRecord
    local applicationName = nil
    local appliedSpellId = sourceSpellId
    local penaltyDisplay = nil
    local summonExpected = nil
    local summonSnapshot = nil
    local summonCellId = nil
    local boundExpected = nil
    local boundSnapshot = nil
    local boundDuration = nil
    local isStackableSpell = (STACK_CONFIG.SPELL_LIMITS[spellId]
        or STACK_CONFIG.DEFAULT_LIMIT) > 1

    -- A reduced cast always runs through a generated Spell record.  An
    -- enchanted cast left with NO resolvable item record id (only the
    -- enchantment id in hand) must use one too — the engine cannot resolve an
    -- enchantment id at all — so it gets an unpenalised clone at `scale`
    -- (1.0 in that case) instead of dying at activeSpells:add.
    local usedGeneratedRecord = false
    if isPenalized or (isEnchantment and itemRecordIdStr == nil) then
        usedGeneratedRecord = true
        -- This is deliberately a Spell record even for an enchanted item: the
        -- engine resolves the added id in the Spell store, and `item` keeps the
        -- original enchanted item as the cast source.  The original record is
        -- never added for this cast.
        applicationRecord, sourceKey = createReducedSpellRecord(spell, isEnchantment, scale)
        if not applicationRecord then
            -- Never silently apply the unreduced source after a generation
            -- failure; that would be the exact bug this path is preventing.
            debugLog("Effect penalty: reduced record generation failed; cast skipped", tostring(spellId))
            return
        end
        applicationId = applicationRecord.id
        if type(applicationId) ~= "string" or applicationId == "" then
            debugLog("Effect penalty: generated record has no usable id; cast skipped", tostring(spellId))
            return
        end
        -- Belt and braces around the engine's `mList.at(index)` lookup: even a
        -- complete clone is only safe to add when every index we pass still
        -- lands inside the generated record's effect list.  Count the list
        -- only when its shape allows it (it may arrive as a userdata list,
        -- where `#` would raise) and fall back to the source effect count
        -- (the clone is 1:1 with the source list).
        local generatedEffects = applicationRecord.effects
        local generatedCount = nil
        if type(generatedEffects) == "table" then
            generatedCount = #generatedEffects
        end
        if generatedCount == nil then
            generatedCount = (spell.effects and #spell.effects) or 0
        end
        local highestIndex = -1
        for _, idx in ipairs(effectIndexes) do
            if type(idx) == "number" and idx > highestIndex then highestIndex = idx end
        end
        if highestIndex >= generatedCount then
            debugLog(string.format(
                "Effect penalty: effect index %d is outside generated %s (%d effect(s)); cast skipped",
                highestIndex, tostring(applicationId), generatedCount))
            return
        end
        applicationName = reducedSpellDisplayName(spell, isEnchantment, itemForApplication)
        appliedSpellId = applicationId
        penaltyDisplay = {}
        for _, idx in ipairs(effectIndexes) do
            local generatedEff = applicationRecord.effects
                and applicationRecord.effects[idx + 1]
            if generatedEff then
                local magnitude
                if type(generatedEff.magnitudeMin) == "number" then
                    local lo = math.floor(generatedEff.magnitudeMin + 0.5)
                    local hi = math.floor((generatedEff.magnitudeMax
                        or generatedEff.magnitudeMin) + 0.5)
                    if hi < lo then hi = lo end
                    magnitude = math.random(lo, hi)
                end
                penaltyDisplay[idx] = {
                    magnitude = magnitude,
                    duration = generatedEff.duration or 0,
                }
            end
        end

        -- Summons and bound items have values that are not part of the
        -- effect's magnitude fields: the creature's own stats and gear, and
        -- the item the bound effect equips.  The effect itself comes entirely
        -- from the reduced record; everything the engine spawns for it is
        -- collected here and reduced by the post-spawn sweep (see the
        -- penalised-spawn tracker above).
        summonExpected = {}
        boundExpected = {}
        for _, idx in ipairs(effectIndexes) do
            local rawEff = spell.effects[idx + 1]
            if rawEff then
                local effId = tostring(rawEff.id):lower():gsub("[^%a%d]", "")
                local gmst = SUMMON_EFFECT_GMST[effId]
                if gmst then
                    local creatureId = core.getGMST(gmst)
                    if creatureId and creatureId ~= "" then
                        summonExpected[tostring(creatureId):lower()] = true
                    end
                else
                    local boundItems = boundEffectItemIds(effId)
                    if boundItems then
                        for _, itemId in ipairs(boundItems) do
                            boundExpected[tostring(itemId):lower()] = true
                        end
                        -- Empty / sentinel-bearing list = effect looks like
                        -- bound but we don't know the exact item id(s); sweep
                        -- by name/id match instead.
                        if boundItems[WILDCARD_BOUND_KEY] then
                            boundExpected[WILDCARD_BOUND_KEY] = true
                        end
                    end
                end
            end
        end
        if next(summonExpected) ~= nil and caster and caster:isValid() then
            local cell = caster.cell
            if cell and cell.getAll then
                summonSnapshot = {}
                for _, obj in ipairs(cell:getAll()) do
                    summonSnapshot[obj.id] = true
                end
                summonCellId = cell.id
            end
        end
        if next(boundExpected) ~= nil and target and target:isValid() then
            -- Only items that were NOT in the target's inventory before the
            -- cast are replaced, so a bound item that an earlier (still
            -- active) effect owns is never touched.
            local inv = types.Actor.inventory and types.Actor.inventory(target)
            if inv and inv.getAll then
                boundSnapshot = {}
                for _, obj in ipairs(inv:getAll()) do
                    boundSnapshot[obj.id] = true
                end
            end
            -- How long the engine will keep the bound items: the scaled
            -- duration on the generated record (+ a small buffer so the
            -- engine's own take-back runs first).
            boundDuration = 0
            for _, idx in ipairs(effectIndexes) do
                local rawEff = spell.effects[idx + 1]
                local generatedEff = applicationRecord.effects
                    and applicationRecord.effects[idx + 1]
                if rawEff and generatedEff then
                    local effId = tostring(rawEff.id):lower():gsub("[^%a%d]", "")
                    -- Recognize both explicitly-listed bound effects and
                    -- wildcard "looks like bound" effects when calculating
                    -- how long our replacement must live.
                    if boundEffectItemIds(effId) then
                        local d = tonumber(generatedEff.duration) or 0
                        if d > boundDuration then boundDuration = d end
                    end
                end
            end
            if boundDuration > 0 then boundDuration = boundDuration + 1 end
        end
    end

    -- Friendlier Fire compatibility: spells applied from Lua (activeSpells:add)
    -- bypass the engine's CastSpell::inflict / ApplyMagicEffects path, so FF's
    -- sweep can never see them. Detect friendly fire ourselves (via Follower
    -- Detection Util, mirroring FF's own test) before applying.
    local appliedEffects = {}
    if spell.effects then
        for _, idx in ipairs(effectIndexes) do
            local eff = spell.effects[idx + 1]
            if eff then appliedEffects[#appliedEffects + 1] = eff end
        end
    end
    if isFriendlyFireSpell(caster, target, appliedEffects) then
        debugLog("[MagExp] Friendly fire vetoed:", tostring(spellId), "->", tostring(target.recordId or target.id))
        return
    end

    local primaryApplied = spell.effects and spell.effects[effectIndexes[1] + 1]

    -- [HIT VISUALS]
    local audioPlayedThisApply = false
    local hasExplicitHitModel = sourceData
        and sourceData.hitModelExplicit == true
        and type(sourceData.hitModel) == "string"
        and sourceData.hitModel ~= ""
    local suppressImpactVfx = (isAoe == true and hitPos ~= nil)
        or (type(userData) == "table" and userData.suppressImpactVfx == true)
        or hasExplicitHitModel
    local function resolveSpawnPos()
        local vfxPos = hitPos
        if not vfxPos then
            local tStr = tostring(target.type)
            if tStr:find("NPC") or tStr:find("Creature") or tStr:find("Player") then
                local zOffset = heightCache[target.id]
                if not zOffset then
                    zOffset = 45
                    local bbox = target:getBoundingBox()
                    if bbox then
                        zOffset = bbox.halfSize.z * 1.1
                        if zOffset > 105 then zOffset = 65 end
                    end
                    heightCache[target.id] = zOffset
                end
                vfxPos = target.position + util.vector3(0, 0, zOffset)
            else
                vfxPos = target.position
            end
        end
        return vfxPos
    end

    if hasExplicitHitModel
        and not isAoe
        and not (type(userData) == "table" and userData.suppressImpactVfx == true)
    then
        spawnProjectileImpactVfx(sourceData, resolveSpawnPos())
    end

    for _, idx in ipairs(effectIndexes) do
        local rawEff = spell.effects[idx + 1]
        local mgef = rawEff and core.magic.effects.records[rawEff.id]
        if rawEff and mgef then
            local eId = mgef.id:lower()
            local isPersistentEffect = STACK_CONFIG.PERSISTENT_EFFECTS[eId] == true
            local isPersistentLoop = isPersistentEffect and (rawEff.duration or 0) > 0
            local vfxTag = "MagExp_" .. tostring(spellId) .. "_" .. tostring(idx)

            local staticId = (sourceData and sourceData.areaVfxRecId) or mgef.hitStatic
            local hasAttachStatic = staticId and staticId ~= ""
            local static = hasAttachStatic and types.Static.records[staticId] or nil
            if static and static.model and target.enabled and not suppressImpactVfx then
if isPersistentLoop then
if not activeVfxRegistry[target.id] then activeVfxRegistry[target.id] = {} end
activeVfxRegistry[target.id][vfxTag] = { target = target, spellId = appliedSpellId }

-- [OPTION A FIX] Attach the VFX handler script to non-player actors
if target.type ~= types.Player then
    debugLog(string.format("[Script Attach] Attempting to attach magexp_actor_vfx.lua to %s", target.recordId or "unknown"))
    local ok, err = addScriptOnce(target, 'scripts/OMW_MagExp/magexp_actor_vfx.lua')
    if ok then
        debugLog("[Script Attach] Actor VFX script is attached")
    else
        debugLog("[Script Attach] Actor VFX script attach failed:", tostring(err))
    end
end
end

                local vfxOptions = { mwMagicVfx = true }
                if isPersistentLoop then
                    vfxOptions = {
                        loop       = true,
                        mwMagicVfx = false,
                        vfxId      = vfxTag,
                    }
                end

                target:sendEvent('AddVfx', {
                    model   = static.model,
                    options = vfxOptions
                })

                if isPersistentLoop then
                    -- The generated reduced spell carries the scaled duration, so the
                    -- loop VFX must end with that same duration too.
                    local duration = (penaltyDisplay and penaltyDisplay[idx]
                        and penaltyDisplay[idx].duration)
                        or (rawEff.duration or 30)
                    async:newUnsavableSimulationTimer(duration, function()
                        if target and target:isValid() then
                            -- All actors now have RemoveVfx handler:
                            -- player via its own local script,
                            -- NPCs/Creatures via magexp_actor_vfx.lua attached above.
                            debugLog(string.format("[Timed VFX Cleanup] Removing VFX '%s' from %s", vfxTag, target.recordId or "unknown"))
                            target:sendEvent('RemoveVfx', vfxTag)
                        end
                    end)
                end
            end

            if not suppressImpactVfx and not isAoe and not (hasAttachStatic and static and static.model) then
                local hitVfxId = deriveMagicEffectImpactStaticId(mgef)
                if hitVfxId then
                    local rid = tostring(hitVfxId):lower()
                    local rec = types.Static.records[rid] or types.Weapon.records[rid]
                    if rec and rec.model then
                        local opts = { mwMagicVfx = false }
                        if target:isValid() and target.enabled then
                            opts.attachToObject = target
                        end
                        world.vfx.spawn(rec.model, resolveSpawnPos(), opts)
                    end
                end
            end

            if not muteAudio and target.enabled and not audioPlayedThisApply then
                local impactSound = type(userData) == "table" and userData.impactSound or nil
                local hasImpactSoundOverride = type(impactSound) == "string"
                local hasImpactSound = type(impactSound) == "string" and impactSound ~= ""
                local sourceArea = sourceData and tonumber(sourceData.area) or 0
                if hasImpactSound and not isAoe and sourceArea <= 0 then
                    core.sound.playSound3d(impactSound, target, { volume = 1.0 })
                elseif not hasImpactSoundOverride then
                    local schoolIdx = mgef.school
                    local s = "destruction"
                    if type(schoolIdx) == "string" then s = schoolIdx:lower()
                    elseif type(schoolIdx) == "number" then
                        local schools = { [0] = "alteration", [1] = "conjuration", [2] = "destruction", [3] = "illusion", [4] = "mysticism", [5] = "restoration" }
                        s = schools[schoolIdx] or "destruction"
                    end
                    if mgef.hitSound and mgef.hitSound ~= "" then
                        core.sound.playSound3d(mgef.hitSound, target, { volume = 1.0 })
                    elseif mgef.school then
                        target:sendEvent('PlaySound3d', { sound = mgef.school:lower() .. " hit" })
                    else
                        core.sound.playSound3d(tostring(s):lower() .. " hit", target, { volume = 1.0 })
                    end
                elseif hasImpactSound then
                    debugLog("[AUDIO] Suppressed per-target sound for custom area impact:", impactSound)
                else
                    debugLog("[AUDIO] Explicitly silenced per-target impact sound")
                end
                audioPlayedThisApply = true
            end
        end
    end

    debugLog(string.format("Applying %s to %s", spellId, target.recordId or target.id))

    -- The hit event carries what the cast actually did.  Under a penalty both
    -- the area and the magnitudes above were cloned into the generated record
    -- at `scale`, so the event must not quote the source record's values back
    -- to listeners (event damage is what some mods hit for).
    local primaryArea = 0
    if primaryApplied then
        primaryArea = scaledEffectParams(primaryApplied, scale).area or 0
    end

    local Rrng = core.magic.RANGE
    if not isAoe and primaryApplied then
        local r = primaryApplied.range
        if r == Rrng.Touch then
            fireMagicHitEvent({
                attacker      = caster,
                target        = target,
                spellId       = spellId,
                hitPos        = hitPos or target.position,
                spellType     = Rrng.Touch,
                isAoE         = false,
                area          = primaryArea,
                effectScale   = effectScale,
                effectIndex   = effectIndexes[1],
                unreflectable = unreflectable or false,
                userData      = userData,
                muteAudio     = muteAudio,
                muteLight     = muteLight
            })
        elseif r == Rrng.Self and sameCasterAsTarget then
            fireMagicHitEvent({
                attacker      = caster,
                target        = target,
                spellId       = spellId,
                hitPos        = hitPos or target.position,
                spellType     = Rrng.Self,
                isAoE         = false,
                area          = primaryArea,
                effectScale   = effectScale,
                effectIndex   = effectIndexes[1],
                unreflectable = unreflectable or false,
                userData      = userData,
                muteAudio     = muteAudio,
                muteLight     = muteLight
            })
        end
    end

    local activeSpells = types.Actor.activeSpells(target)
    if activeSpells then
        if isEnchantment and sourceSpellId ~= spellId then
            debugLog(string.format("Using item ID %s for enchanted spell effects instead of enchantment ID %s", sourceSpellId, spellId))
        end

        -- Replace the source active spell before adding the generated one.
        -- This removes both an unreduced source cast and an older reduced
        -- variant, while preserving stackable spell exceptions.
        --
        -- The clean-up runs for an *unpenalised* cast too, with no source id:
        -- the engine replaces an active spell by record id, and a reduced cast
        -- lives under a generated id it knows nothing about.  Without this, a
        -- quick-cast summon stayed alive when the same spell was recast at full
        -- strength (the reverse order already worked, because the penalised
        -- branch removes the source).
        if not isStackableSpell then
            removeSourceForReducedSpell(activeSpells,
                (isPenalized or usedGeneratedRecord) and sourceSpellId or nil,
                sourceKey, itemForApplication)
        end

        local addIndexes = effectIndexes
        if addIndexes and #addIndexes > 0 then
            local params = {
                id      = applicationId,
                effects = addIndexes,
            }
            if applicationName then params.name = applicationName end
            if caster and caster:isValid() then
                if types.NPC.objectIsInstance(caster) or types.Creature.objectIsInstance(caster) or types.Player.objectIsInstance(caster) then
                    params.caster = caster
                end
            end

            if isEnchantment then
                if itemRefIsLive(itemForApplication) then
                    params.item = itemForApplication
                end
            elseif isStackableSpell then
                params.stackable = true
            end
            local appliedActiveSpellId = activeSpells:add(params)

            -- ── Retroactive bound/summon replacement ────────────────────────
            -- The cast that just landed carries a Summon or BoundX effect:
            -- vanilla only allows one application of each kind per actor, so
            -- every older active spell that summons the same creature (or
            -- equips the same bound item) — a vanilla spell, another mod's
            -- spell, a scroll — is displaced now, while this cast is the
            -- newest.  Removing the older active spell runs the engine's own
            -- cleanup for its creature / bound item.  (Same-record recasts
            -- were already handled above by removeSourceForReducedSpell.)
            do
                local displacementKinds = sourceSpellDisplacementKinds(spell, effectIndexes)
                if next(displacementKinds) ~= nil then
                    displaceOlderBoundSummonSpells(activeSpells, target,
                        appliedActiveSpellId, displacementKinds)
                end
            end

            -- Remember which source spell this reduced cast stands in for, so
            -- a later full-strength cast of the same spell replaces it (the
            -- engine can only match its own record ids).  A quick-cast summon
            -- is additionally registered with the summon effect ids it carries
            -- so the reduced-cast sweep can also disband it when a *different*
            -- vanilla summon (same effect, different spell) lands on top of it
            -- — the engine's summon bookkeeping is keyed by effect id, not
            -- spell id, which is why that order otherwise slips through.
            if isPenalized and not isStackableSpell then
                registerReducedCast(target, tostring(applicationId), tostring(sourceSpellId),
                    collectSourceSpellSummonEffects(spell, effectIndexes))
            elseif not isPenalized and not isStackableSpell then
                -- A full-strength quick-cast summon has no generated stand-in,
                -- so the reduced-cast sweep above cannot see it; register it
                -- with the summon effect ids it carries instead and disband it
                -- (by the active-spell id the add just returned) the moment a
                -- later vanilla summon of the same effect lands on the target —
                -- the reverse order of quick-cast-over-vanilla.
                local summonEffects = collectSourceSpellSummonEffects(spell, effectIndexes)
                if next(summonEffects) ~= nil then
                    registerUnpenalizedSummon(target, tostring(sourceSpellId),
                        appliedActiveSpellId, summonEffects)
                end
            end

            local effCount = spell.effects and #spell.effects or 0
            debugLog(string.format("Successfully added %s (%d effect(s) total, %d via engine%s)",
                tostring(appliedSpellId), effCount, #addIndexes,
                isPenalized and ", reduced replacement" or ""))
        end

        -- ── Summon / bound-item penalty ─────────────────────────────────────
        -- The engine spawns the summoned creature and the bound items on a
        -- mechanics update after this add, at full record strength; the
        -- sweep scales their stats and replaces their items the moment they
        -- appear (see the penalised-spawn tracker above).
        if isPenalized and (summonSnapshot or boundSnapshot)
            and target and target:isValid() then
            trackPenalisedSpawn(caster, target, scale, applicationId,
                summonExpected, summonSnapshot, summonCellId,
                boundExpected, boundSnapshot, boundDuration)
        end

        if not trackedEffectRegistry[target] then trackedEffectRegistry[target] = {} end
        local trackingData = {
            caster    = caster,
            startTime = core.getSimulationTime(),
            effects   = {}
        }
        if spell.effects then
            for _, idx in ipairs(effectIndexes) do
                local rawEff = spell.effects[idx + 1]
                if rawEff then
                    -- With a penalty in play, report what was ACTUALLY applied
                    -- (the on-the-fly scaled magnitude / duration) so
                    -- onEffectApplied listeners see the real values.
                    local display = penaltyDisplay and penaltyDisplay[idx]
                    local effInfo = {
                        id        = rawEff.id,
                        spellId   = spellId,
                        index     = idx,
                        magnitude = (display and display.magnitude)
                            or math.random(rawEff.magnitudeMin or 0, rawEff.magnitudeMax or rawEff.magnitudeMin or 0),
                        duration  = (display and display.duration) or (rawEff.duration or 0),
                        caster    = caster,
                        unreflectable = unreflectable or false,
                        casterLinked  = hasCasterLinked
                    }
                    table.insert(trackingData.effects, effInfo)
                    fireEffectEvent('onEffectApplied', target, effInfo)
                end
            end
        end
        trackedEffectRegistry[target][spellId] = trackingData

        if continuousVfx then
            if not activeVfxRegistry[target.id] then activeVfxRegistry[target.id] = {} end
            local vfxTag = "MagExp_" .. spellId
            activeVfxRegistry[target.id][vfxTag] = {
                target = target,
                spellId = appliedSpellId,
            }
            continuousVfxActors[target.id] = {
                actor            = target,
                spellId          = appliedSpellId,
                vfxTag           = vfxTag,
                registrationTime = core.getGameTime()
            }
            debugLog(string.format("[continuousVfx] Registered actor %s with VFX %s", target.recordId or "unknown", vfxTag))

            local pfx = primaryApplied and primaryApplied.id
            local pmgef = pfx and core.magic.effects.records[pfx]
            local castVfxId = (pmgef and pmgef.castVfx and pmgef.castVfx ~= "") and pmgef.castVfx or nil
            if castVfxId then
                local rid = tostring(castVfxId):lower()
                local rec = types.Static.records[rid] or types.Weapon.records[rid]
                if rec and rec.model then
                    world.vfx.spawn(rec.model, target.position, {
                        attachToObject = target,
                        mwMagicVfx    = false,
                        tag           = vfxTag,
                    })
                end
            end
            debugLog(string.format("[continuousVfx] Registered persistent VFX for %s on %s", spellId, target.recordId))
        end

        if hasCasterLinked then
            debugLog("Tracking casterLinked spell", spellId, "on", target.recordId)
            table.insert(casterLinkedSpells, { caster = caster, target = target, spellId = spellId })
        end
    end
end

local function getObjectCenter(obj)
    if not obj or not obj:isValid() then return nil, 0 end
    local pos = obj.position
    local bbox = obj:getBoundingBox()
    if bbox then
        local r = (bbox.halfSize.x + bbox.halfSize.y) / 2
        return bbox.center, r
    end
    return pos, 0
end

-- ============================================================
-- [INTERNAL] Max area statistic among a subset of spell effects (records use area fields).
-- ============================================================
local function maxAreaAmongIndexes(spell, idxList)
    local m = 0
    if not spell or not spell.effects or not idxList then return 0 end
    for _, idx in ipairs(idxList) do
        local eff = spell.effects[idx + 1]
        if eff and type(eff.area) == "number" then m = math.max(m, eff.area) end
    end
    return m
end

--- Prefer the forced index whose effect has largest area (for AoE visuals / blast metadata).
local function dominantAreaEffectIndex(spell, idxList)
    if not spell or not spell.effects or not idxList or #idxList == 0 then return 0 end
    local bestA, pick = -1, idxList[1]
    for _, ix in ipairs(idxList) do
        local e = spell.effects[ix + 1]
        local a = (e and type(e.area) == "number") and e.area or 0
        if a > bestA then bestA = a; pick = ix end
    end
    return pick
end

--- Groups a list of 0-based effect indexes by their magic school.
--- Returns an ordered list of { school = "...", mgef = <record or nil>, indexes = {0based...} }.
--- Effects with no MagicEffect record fall into school="default".
local function groupEffectIndexesBySchool(spell, idxList)
    if not spell or not spell.effects or not idxList then return {} end

    local groups = {}      -- ordered list
    local groupMap = {}    -- schoolKey -> group entry

    for _, idx in ipairs(idxList) do
        local eff = spell.effects[idx + 1]
        if eff then
            local mgef = core.magic.effects.records[eff.id]
            local schoolKey = (mgef and mgef.school) and tostring(mgef.school):lower() or "default"

            local g = groupMap[schoolKey]
            if not g then
                g = { school = schoolKey, mgef = mgef, indexes = {} }
                groupMap[schoolKey] = g
                table.insert(groups, g)
            end

            table.insert(g.indexes, idx)
        end
    end

    return groups
end

-- ============================================================
-- [UTILITY] Door lock/unlock handling
-- ============================================================
local function handleDoorLockUnlock(spellId, caster, target, effectScale)
    debugLog(string.format("[DOOR] handleDoorLockUnlock called: spellId=%s caster=%s target=%s",
        tostring(spellId),
        tostring(caster and caster.recordId or "nil"),
        tostring(target and target.recordId or "nil")))

    local isLockable = (target and (target.type == types.Door or target.type == types.Container))
    if not isLockable then
        debugLog("[DOOR] Target is not lockable, returning false")
        return false
    end

    local spell = core.magic.spells.records[spellId] or core.magic.enchantments.records[spellId]
    if not spell or not spell.effects then
        debugLog("[DOOR] Spell record not found or has no effects")
        return false
    end

    -- Only prevents multiple crimes within a single spell's effect loop
    -- Resets to false on every new call (every new cast)
    local crimeCommitted = false

    for _, eff in ipairs(spell.effects) do
        local eid = tostring(eff.id):lower()

        if eid == "open" or eid == "lock" then
            -- The lock/unlock magnitude *is* the effect's magnitude (the lock
            -- level it defeats or sets), so it takes the same penalty as every
            -- other magnitude.  Reading it off the source record would let a
            -- penalised quick-cast open a lock the reduced record could not.
            local params = scaledEffectParams(eff, coerceEffectScale(effectScale))
            local magnitude = math.random(params.magnitudeMin or 0,
                params.magnitudeMax or params.magnitudeMin or 0)
            debugLog(string.format("[DOOR] Effect: %s magnitude: %d", eid, magnitude))

            if types.Lockable then
                local isLocked = types.Lockable.isLocked(target)
                local lockLvl = 0
                if types.Lockable.getLockLevel then
                    lockLvl = types.Lockable.getLockLevel(target)
                elseif types.Lockable.lockLevel then
                    lockLvl = types.Lockable.lockLevel(target)
                end
                debugLog(string.format("[DOOR] isLocked=%s lockLevel=%d", tostring(isLocked), lockLvl))

                if target.enabled then
                    if eid == "open" then
                        if isLocked and magnitude >= lockLvl then
                            debugLog("[DOOR] Unlocking target")
                            types.Lockable.unlock(target)
                            core.sound.playSound3d("Open Lock", target)
                        elseif isLocked then
                            debugLog("[DOOR] Failed to unlock (magnitude too low)")
                            core.sound.playSound3d("Open Lock Fail", target)
                        else
                            debugLog("[DOOR] Target already unlocked — still applying crime + VFX per vanilla")
                        end
                    elseif eid == "lock" then
                        if not isLocked or magnitude > lockLvl then
                            debugLog("[DOOR] Locking target")
                            types.Lockable.lock(target, magnitude)
                            core.sound.playSound3d("Open Lock", target)
                        else
                            debugLog("[DOOR] Already locked with equal or higher level")
                        end
                    end
                end

                -- [VFX] Always fire alteration hit on every cast, regardless of lock state
                local vfxPos, _ = getObjectCenter(target)
                vfxPos = vfxPos or target.position
                local rid = "VFX_AlterationHit"
                local staticRecord = types.Static.records[rid] or types.Weapon.records[rid]
                if staticRecord and staticRecord.model then
                    core.sound.playSound3d("alteration hit", target)
                    world.vfx.spawn(staticRecord.model, vfxPos, { mwMagicVfx = false })
                    debugLog("[DOOR] Spawned Alteration Hit VFX")
                else
                    debugLog("[DOOR] WARNING: vfx_alteration_hit record or model not found")
                end

                -- [CRIME] Always fire on owned objects, every cast, only once per spell cast
                if caster and caster.type == types.Player and not crimeCommitted then
                    local Crimes = I.Crimes
                    if not Crimes then
                        debugLog("[DOOR] ERROR: Crimes interface not available")
                    else
                        local victim, factionId = nil, nil
                        local owner = target.owner

                        if owner then
                            factionId = owner.factionId
                            local ownerRecordId = owner.recordId

                            debugLog(string.format("[DOOR] owner.recordId=%s owner.factionId=%s",
                                tostring(ownerRecordId), tostring(factionId)))

                            if ownerRecordId and ownerRecordId ~= "" and target.cell then
                                for _, obj in ipairs(target.cell:getAll()) do
                                    if obj:isValid() and obj.type == types.NPC and obj.recordId == ownerRecordId then
                                        victim = obj
                                        debugLog("[DOOR] Found victim NPC:", tostring(victim.recordId))
                                        break
                                    end
                                end
                            end

                            if victim and (not factionId or factionId == "") then
                                local npcRecord = types.NPC.records[victim.recordId]
                                if npcRecord and npcRecord.faction and npcRecord.faction ~= "" then
                                    factionId = npcRecord.faction
                                    debugLog("[DOOR] Using NPC record faction:", factionId)
                                end
                            end
                        else
                            debugLog("[DOOR] Target has no owner — no crime")
                        end

                        if victim or (factionId and factionId ~= "") then
                            debugLog(string.format("[DOOR] Committing crime: victim=%s faction=%s",
                                tostring(victim and victim.recordId or "nil"),
                                tostring(factionId or "nil")))

                            local result = Crimes.commitCrime(caster, {
                                type        = OFFENSE_TYPE_IDS.Trespassing,
                                victim      = victim,
                                faction     = factionId,
                                victimAware = false,
                            })

                            debugLog(string.format("[DOOR] Crime result: wasCrimeSeen=%s",
                                tostring(result and result.wasCrimeSeen or "nil")))

                            -- Prevent multiple crimes within this single spell's effect loop only
                            if result and result.wasCrimeSeen then
                                crimeCommitted = true
                                debugLog("[DOOR] Crime seen — blocking further crime calls within this cast")
                            end
                        else
                            debugLog("[DOOR] No owner found — skipping crime")
                        end
                    end
                end
            end
        end
    end

    return true
end
-- ============================================================
-- [AOE] Detonate spell at world position
-- ============================================================
local function detonateSpellAtPos(spellId, caster, pos, cell, itemObject, forcedEffects, unreflectable, casterLinked, vfxOverride, impactSpeed, maxSpeed, areaVfxScale, excludeTarget, userData, muteAudio, muteLight, continuousVfx, effectScale, areaOverride)
    local spell = core.magic.spells.records[spellId] or core.magic.enchantments.records[spellId]
    if not spell and spellId then
        -- Safe iterative fallback for numerical proxies or case-sensitivity edge cases
        for _, rec in pairs(core.magic.spells.records) do
            local recId = rec.id
            if recId and tostring(recId):lower() == tostring(spellId):lower() then
                spell = rec; break
            end
        end
        if not spell then
            for _, rec in pairs(core.magic.enchantments.records) do
                local recId = rec.id
                if recId and tostring(recId):lower() == tostring(spellId):lower() then
                    spell = rec; break
                end
            end
        end
    end
    if not (spell and spell.effects) then return end

    -- The blast must use the same *effective* area the cast was resolved
    -- with.  A quick-cast penalty scales the area of every effect in the
    -- generated record, so the blast of a 50% cast is half as wide — a blast
    -- that re-reads the source record's area would still catch everyone
    -- inside the unreduced radius while every hit landed at the reduced
    -- magnitude.  Callers that already resolved the area (launchSpell's
    -- self/touch paths and the projectile collision) hand it over as
    -- areaOverride; anything else — including the public interface, which
    -- does not know about the penalty — gets the record's area scaled here by
    -- the same scale the effects were cloned with.
    local maxArea = 0
    local AREA_MULT = (core.getGMST("fAreaRadiusMult") or 1.0) * 22.1
    local hasAreaOverride = type(areaOverride) == "number"

    if hasAreaOverride then
        maxArea = math.max(0, areaOverride)
    elseif forcedEffects and #forcedEffects > 0 then
        maxArea = maxAreaAmongIndexes(spell, forcedEffects)
    elseif spell.effects and spell.effects[1] then
        maxArea = (spell.effects[1] and spell.effects[1].area) or 0
    end
    local areaScale = coerceEffectScale(effectScale)
    if not hasAreaOverride and areaScale < 1 and maxArea > 0 then
        maxArea = math.max(0, math.floor(maxArea * areaScale + 0.5))
    end
    if maxArea <= 0 then return end

    local finalRadius = maxArea * AREA_MULT

    local areaVfxIx = dominantAreaEffectIndex(spell, forcedEffects)
    local areaVfxEff = spell.effects and spell.effects[areaVfxIx + 1]
    if areaVfxEff then
        local mgef = core.magic.effects.records[areaVfxEff.id]
        if mgef then
            local areaStaticId = vfxOverride
            
            -- [SFP LOGIC] If no specific area VFX was provided, try to detect from record
            if not areaStaticId or areaStaticId == "" or areaStaticId == "VFX_DefaultArea" then
                if mgef and mgef.areaStatic and mgef.areaStatic ~= "" then
                    areaStaticId = mgef.areaStatic
                else
                    areaStaticId = "VFX_AREA_FALLBACK"
                end
            end
            
            -- [ELEMENTAL LOGIC] Select specialized area VFX based on effect name/id
            local lowerId = tostring(areaStaticId):lower()
            if lowerId:find("bolt") or lowerId == "vfx_area_fallback" or lowerId == "vfx_defaultarea" then
                local schoolIdx = mgef and mgef.school or 2
                local n = mgef and (mgef.name or ""):lower() or ""
                local eid = mgef and tostring(mgef.id):lower() or ""
                
                -- 1. Determine school name 's'
                local s = "destruction"
                if type(schoolIdx) == "string" then s = schoolIdx:lower()
                elseif type(schoolIdx) == "number" then
                    local schools = { [0]="alteration", [1]="conjuration", [2]="destruction", [3]="illusion", [4]="mysticism", [5]="restoration" }
                    s = schools[schoolIdx] or "destruction"
                end
                
                -- 2. Detect Elemental Identity (regardless of school)
                local n = (mgef.name or ""):lower()
                local eid = tostring(mgef.id):lower()
                local element = nil
                if     n:find("fire")   or eid:find("fire")   then element = "Fire"
                elseif n:find("frost")  or eid:find("frost")  or n:find("cold") or eid:find("cold") then element = "Frost"
                elseif n:find("shock")  or eid:find("shock")  or n:find("lightn") then element = "Lightning"
                elseif n:find("poison") or eid:find("poison") then element = "Poison"
                end

                -- 3. Resolve Area VFX based on Priority: Element > School > Default
                if element then
                    areaStaticId = "VFX_" .. element .. "Area"
                else
                    if s == "alteration" then areaStaticId = "VFX_AlterationArea"
                    elseif s == "conjuration" then areaStaticId = "VFX_ConjureArea"
                    elseif s == "illusion" then areaStaticId = "VFX_IllusionArea"
                    elseif s == "mysticism" then areaStaticId = "VFX_MysticismArea"
                    elseif s == "restoration" then areaStaticId = "VFX_RestorationArea"
                    else areaStaticId = "VFX_DestructArea" end
                end

                -- [SFP FALLBACK] Progressive refinement to stay on-element
                local lId = tostring(areaStaticId):lower()
                if not (types.Static.records[lId] or types.Weapon.records[lId]) then
                    debugLog("[DETONATE] Missing Area VFX:", tostring(areaStaticId), " -- checking Hit fallback")
                    local hitId = areaStaticId:gsub("Area", "Hit")
                    if types.Static.records[hitId:lower()] or types.Weapon.records[hitId:lower()] then
                        areaStaticId = hitId
                    else
                        if not (types.Static.records[areaStaticId:lower()] or types.Weapon.records[areaStaticId:lower()]) then
                            debugLog("[DETONATE] Missing Hit VFX:", tostring(areaStaticId), " -- falling back to generic Default")
                            areaStaticId = "VFX_DefaultArea"
                        end
                    end
                end
                debugLog("[DETONATE] Final VFX candidate:", tostring(areaStaticId))

                -- Final check: Ensure we don't spawn nothing
                local finalId = areaStaticId:lower()
                if not (types.Static.records[finalId] or types.Weapon.records[finalId]) then
                    areaStaticId = "VFX_DefaultHit"
                end
            end

            local impactSound = type(userData) == "table" and userData.impactSound or nil
            local hasImpactSoundOverride = type(impactSound) == "string"
            local explosionSound
            if hasImpactSoundOverride then
                explosionSound = impactSound ~= "" and impactSound or nil
            else
                explosionSound = mgef.areaSound ~= "" and mgef.areaSound
                    or (mgef.school and (mgef.school .. " area"))
            end
            local suppressImpactVfx = type(userData) == "table"
                and userData.suppressImpactVfx == true
            if not suppressImpactVfx and world.vfx and world.vfx.spawn then
                local rid = tostring(areaStaticId):lower()
                local rec = types.Static.records[rid] or types.Weapon.records[rid]
                if rec and rec.model then
                    local scale = areaVfxScale or (finalRadius / 14.0 + 2.0)
                    debugLog(string.format("[DETONATE] Spawning VFX: %s at %s (Scale: %.2f)", tostring(rec.model), tostring(pos), scale))
                    world.vfx.spawn(rec.model, pos, { scale = scale, mwMagicVfx = false })
                else
                    debugLog("[DETONATE] ERROR: Missing or invalid model for static ID:", tostring(areaStaticId))
                end
            end
-- ✅ FIXED — replaces the broken playSound3d call at line 1163
if explosionSound and not muteAudio then
    local soundAnchor = nil

    -- Search cell for the closest valid object to the blast position
    if cell then
        local bestDist = math.huge
        for _, obj in ipairs(cell:getAll()) do
            if obj:isValid() and obj.enabled then
                local d = (obj.position - pos):length()
                if d < bestDist then
                    bestDist = d
                    soundAnchor = obj
                end
            end
        end
    end

    -- Last resort: caster (only if valid — avoids the nil crash)
    if not soundAnchor and caster and caster:isValid() then
        soundAnchor = caster
    end

    if soundAnchor then
        core.sound.playSound3d(explosionSound, soundAnchor, { volume = 1.0 })
    else
        debugLog("[DETONATE] No valid sound anchor found for:", explosionSound)
    end
end
        
    end
end
    local isLockUnlock = false
    if spell.effects then
        for _, eff in ipairs(spell.effects) do
            local eid = tostring(eff.id):lower()
            if eid == "open" or eid == "lock" or eid == "disarmtrap" or eid == "absorbtrap" then 
                isLockUnlock = true; break 
            end
        end
    end

    if cell then
        local affectedCount = 0
        -- OpenMW 0.51 keeps the player outside the ordinary cell reference list.
        -- Query Player explicitly, then deduplicate before applying any effects.
        -- Both lists belong to this cell; range and caller exclusions still apply.
        local targets, seen = {}, {}
        for _, objects in ipairs({cell:getAll(), cell:getAll(types.Player)}) do
            for _, object in ipairs(objects) do
                if object:isValid() and not seen[object.id] then
                    seen[object.id] = true
                    targets[#targets + 1] = object
                end
            end
        end
        for _, object in ipairs(targets) do
            if object:isValid() then
                local objPos, objRad = getObjectCenter(object)
                objPos = objPos or object.position
                local dist = nil
                dist = (objPos - pos):length()
                if dist and dist <= (finalRadius + objRad) and (not excludeTarget or object.id ~= excludeTarget.id) then
                    local isLockable = (object.type == types.Door or object.type == types.Container)
                    local isActor    = (object.type == types.NPC or object.type == types.Creature or object.type == types.Player)

                    if isLockUnlock and isLockable then
                        handleDoorLockUnlock(spellId, caster, object, effectScale)
                        affectedCount = affectedCount + 1
                    elseif isActor and not isLockUnlock and not (types.Actor.objectIsInstance(object) and types.Actor.isDead(object))
                        and not userDataIgnoresActor(object, userData) then
                        applySpellToActor(spellId, caster, object, pos, true, itemObject, forcedEffects, unreflectable, casterLinked, userData, muteAudio, muteLight, continuousVfx, effectScale)
                        -- Broadcast AoE hit
                        fireMagicHitEvent({
                            attacker  = caster,
                            target    = object,
                            spellId   = spellId,
                            hitPos    = pos,
                            spellType = core.magic.RANGE.Target,
                            isAoE     = true,
                            area      = finalRadius,
                            effectScale = effectScale,
                            effectIndex = dominantAreaEffectIndex(spell, forcedEffects),
                            impactSpeed = impactSpeed, -- Forward projectile speed to the blast event
                            maxSpeed  = maxSpeed,
                            unreflectable = unreflectable,
                            casterLinked = casterLinked,
                            userData  = userData,
                            muteAudio = muteAudio,
                            muteLight = muteLight
                        })
                        affectedCount = affectedCount + 1
                    end
                end
            end
        end
        debugLog(string.format('[DETONATE] %s blast hit %d targets.', tostring(spellId), tonumber(affectedCount) or 0))
    end
end

-- ============================================================
-- [INTERNAL] Auto-detect bolt VFX/sound/spin from a spell record
-- Returns a table of defaults that launchSpell can override.
-- primaryEffectIndex: optional 0-based index into spell.effects for mixed-range spells (default first effect).
-- ============================================================
local function autoDetectProjectileParams(spell, primaryEffectIndex)
    local out = {
        mgef        = nil,
        school      = "destruction",
        n           = "",
        vfxRecId    = "VFX_DefaultBolt",
        boltModel   = "",
        castModel   = "",
        hitModel    = "",
        areaVfxRecId = "",
        particleTex = "",
        boltSound   = nil,
        hitSound    = nil,
        castSound   = nil,
        boltLightId = nil,
        spinSpeed   = 0,
    }

    local pi = primaryEffectIndex or 0
    local primEff = spell and spell.effects and spell.effects[pi + 1]
    if not primEff then return out end

    local mgef = core.magic.effects.records[primEff.id]
    local school = (mgef and mgef.school) or "destruction"
    local n      = mgef and (mgef.name or ""):lower() or ""
    out.mgef   = mgef
    out.school = school
    out.n      = n

    -- ---- Bolt VFX record ----
    if mgef and mgef.bolt and mgef.bolt ~= "" then
        out.vfxRecId = mgef.bolt
    else
        local SCHOOL = core.magic.SCHOOL or { Alteration=0, Conjuration=1, Destruction=2, Illusion=3, Mysticism=4, Restoration=5 }
        if school == "destruction" or school == SCHOOL.Destruction then
            if n:find("fire") then out.vfxRecId = "VFX_DestructBolt"
            elseif n:find("frost") then out.vfxRecId = "VFX_FrostBolt"
            elseif n:find("shock") then out.vfxRecId = "VFX_DefaultBolt"
            elseif n:find("poison") then out.vfxRecId = "VFX_PoisonBolt"
            else out.vfxRecId = "VFX_DestructBolt" end
        elseif school == "restoration" or school == SCHOOL.Restoration then out.vfxRecId = "VFX_RestoreBolt"
        elseif school == "alteration"  or school == SCHOOL.Alteration  then out.vfxRecId = "VFX_AlterationBolt"
        elseif school == "conjuration" or school == SCHOOL.Conjuration then out.vfxRecId = "VFX_ConjureBolt"
        elseif school == "illusion"    or school == SCHOOL.Illusion    then out.vfxRecId = "VFX_IllusionBolt"
        else out.vfxRecId = "VFX_MysticismBolt" end
    end

    local rid = out.vfxRecId:lower()
    local rec = types.Weapon.records[rid] or types.Static.records[rid] or (types.MiscItem and types.MiscItem.records[rid])
    if rec and rec.model then out.boltModel = rec.model end

    -- ---- mgef static VFX fields ----
    if mgef then
        local cvid = (mgef.castVfx and mgef.castVfx ~= "") and mgef.castVfx or nil
        if not cvid then
            local schoolIdx = mgef.school or 2
            local sStr = "destruction"
            if type(schoolIdx) == "string" then sStr = schoolIdx:lower()
            elseif schoolIdx == 0 then sStr = "alteration"
            elseif schoolIdx == 1 then sStr = "conjuration"
            elseif schoolIdx == 2 then sStr = "destruction"
            elseif schoolIdx == 3 then sStr = "illusion"
            elseif schoolIdx == 4 then sStr = "mysticism"
            elseif schoolIdx == 5 then sStr = "restoration"
            end

            if sStr == "destruction" then
                if n:find("fire") then cvid = "VFX_DefaultCast" -- Missing specialized fire cast in list
                elseif n:find("frost") or n:find("cold") then cvid = "VFX_FrostCast"
                elseif n:find("shock") or n:find("lightning") then cvid = "VFX_LightningCast"
                elseif n:find("poison") then cvid = "VFX_PoisonCast"
                else cvid = "VFX_DestructCast" end
            elseif sStr == "alteration" then cvid = "VFX_AlterationCast"
            elseif sStr == "conjuration" then cvid = "VFX_ConjureCast"
            elseif sStr == "illusion" then cvid = "VFX_IllusionCast"
            elseif sStr == "mysticism" then cvid = "VFX_MysticismCast"
            elseif sStr == "restoration" then cvid = "VFX_RestorationCast"
            else cvid = "VFX_DefaultCast" end
        end

        local rid = tostring(cvid):lower()
        local rec = types.Static.records[rid] or types.Weapon.records[rid]
        if rec and rec.model then out.castModel = rec.model end

        if mgef.hitVfx   and mgef.hitVfx   ~= "" then out.hitModel    = mgef.hitVfx   end
        if mgef.areaStatic and mgef.areaStatic ~= "" then out.areaVfxRecId = mgef.areaStatic end
        if mgef.particle and mgef.particle  ~= "" then out.particleTex = mgef.particle end
    end

    -- ---- Bolt flight sound ----
    if mgef and mgef.boltSound and mgef.boltSound ~= "" then
        out.boltSound = mgef.boltSound
    else
        local s = (type(school) == "string") and school:lower() or "destruction"
        if     s == "destruction" then
            if n:find("frost") then out.boltSound = "frost_bolt"
            elseif n:find("shock") or n:find("lightning") then out.boltSound = "shock bolt"
            else out.boltSound = "destruction bolt" end
        elseif s == "restoration" then out.boltSound = "restoration bolt"
        elseif s == "alteration"  then out.boltSound = "alteration bolt"
        elseif s == "conjuration" then out.boltSound = "conjuration bolt"
        elseif s == "illusion"    then out.boltSound = "illusion bolt"
        else out.boltSound = "mysticism bolt" end
    end

    -- ---- Hit sound ----
    if mgef and mgef.hitSound and mgef.hitSound ~= "" then
        out.hitSound = mgef.hitSound
    else
        local s = (type(school) == "string") and school:lower() or "destruction"
        if     s == "destruction" then
            if n:find("frost") then out.hitSound = "frost hit"
            elseif n:find("shock") or n:find("lightning") then out.hitSound = "shock hit"
            else out.hitSound = "destruction hit" end
        elseif s == "restoration" then out.hitSound = "restoration hit"
        elseif s == "alteration"  then out.hitSound = "alteration hit"
        elseif s == "conjuration" then out.hitSound = "conjuration hit"
        elseif s == "illusion"    then out.hitSound = "illusion hit"
        else out.hitSound = "mysticism hit" end
    end

    -- ---- Cast sound ----
    if mgef and mgef.castSound and mgef.castSound ~= "" then
        out.castSound = mgef.castSound
    else
        local s = (type(school) == "string") and school:lower() or "destruction"
        if     s == "destruction" then
            if n:find("frost") then out.castSound = "frost cast"
            elseif n:find("shock") or n:find("lightning") then out.castSound = "shock cast"
            else out.castSound = "destruction cast" end
        elseif s == "restoration" then out.castSound = "restoration cast"
        elseif s == "alteration"  then out.castSound = "alteration cast"
        elseif s == "conjuration" then out.castSound = "conjuration cast"
        elseif s == "illusion"    then out.castSound = "illusion cast"
        else out.castSound = "mysticism cast" end
    end

    -- ---- Bolt light ----
    out.boltLightId = nil -- No default light; schools/mods must explicitly assign one.

    -- ---- Spin speed ----
    if n:find("frost") then out.spinSpeed = math.rad(400) 
    elseif n:find("fire") then out.spinSpeed = math.rad(233)
    elseif school == "conjuration" or school == "alteration" or school == "restoration" then out.spinSpeed = math.rad(333)
    elseif school == "illusion" then out.spinSpeed = math.rad(400)
    end

    -- ---- Auto speed from MagicEffect record (vanilla parity) ----
    -- Vanilla OpenMW derives magic projectile speed from the spell's MagicEffect
    -- records (see ProjectileManager::getMagicBoltData / updateMagicBolt in
    -- OpenMW's projectilemanager.cpp):
    --   speed = fTargetSpellMaxSpeed * average(mgef.speed over ALL effects)
    -- (then multiplied by the caster's race weight for NPC casters — launchSpell).
    -- Morrowind.esm ships fTargetSpellMaxSpeed = 1000 and mgef.speed ~1.0, so
    -- vanilla bolts fly at ~1000 units/sec. We mirror that instead of the old
    -- hardcoded "Oblivion-style" speeds (2500-4500) which made OSSC-cast
    -- projectiles several times faster than vanilla casting.
    local baseSpeed = 1000
    baseSpeed = core.getGMST("fTargetSpellMaxSpeed") or 1000
    local speedSum, speedCount = 0, 0
    if spell and spell.effects then
        for _, eff in ipairs(spell.effects) do
            local effRec = core.magic.effects.records[eff.id]
            local spd = effRec and effRec.speed
            if type(spd) == "number" then
                speedSum = speedSum + spd
                speedCount = speedCount + 1
            end
        end
    end
    if speedCount > 0 then
        out.speed = baseSpeed * (speedSum / speedCount)
    else
        local effectSpeedMult = (mgef and mgef.speed) and mgef.speed or 1.0
        out.speed = effectSpeedMult * baseSpeed
    end
    
    debugLog(string.format("MagicEffect auto-detect: %s | Final Speed: %s", tostring(n), tostring(out.speed)))

    -- ---- Auto light draft from MagicEffect color ----
    -- [FEATURE 2] Mirror C++ addSpellCastGlow: derive bolt light color from mgef.color.
    -- mgef.color is a util.vector4 with components in 0-255 range.
    if mgef and mgef.color then
        local c = mgef.color
        local r = (c.x or c.r or 255) / 255
        local g = (c.y or c.g or 255) / 255
        local b = (c.z or c.b or 255) / 255
        out.boltLightDraft = {
            color   = util.vector3(r, g, b),
            radius  = 200,
            flicker = false,
        }
    end

    return out
end

-- ============================================================
-- [CORE] launchSpell — main public API entry point
--
-- Full parameter table (all optional fields have sensible defaults):
-- {
--   -- REQUIRED:
--   attacker    = <Actor>,         -- the casting actor
--   spellId     = "spark",         -- spell record ID to apply on impact
--   startPos    = util.vector3(..), -- world position to launch from
--   direction   = util.vector3(..), -- launch direction (need not be normalised)
--
--   -- ROUTING override (auto-detected from spell record if omitted):
--   spellType   = core.magic.RANGE.Target, -- Self/Touch/Target
--   area        = 0,               -- AoE radius (in game units)
--
--   -- COMMON overrides:
--   isFree      = false,           -- true = skip the magicka check
--   speed       = auto,            -- projectile speed (units/sec, vanilla auto)
--   maxLifetime = 10,              -- seconds before projectile expires
--
--   -- PROJECTILE VFX overrides (auto-detected from spell/mgef if omitted):
--   vfxRecId    = "VFX_DefaultBolt", -- bolt VFX record ID
--   boltModel   = "meshes/...",    -- bolt mesh path (resolved from vfxRecId if omitted)
--   projectileScale = 1.0,          -- visual scale for the projectile carrier and attached bolt VFX
--   castModel   = "",              -- cast VFX model shown at attacker on launch
--   hitModel    = "",              -- hit VFX model shown at impact point
--   particleTex = "",              -- particle texture override for the bolt VFX
--
--   -- SOUND overrides:
--   boltSound   = "destruction bolt", -- looping flight sound ID
--
--   -- LIGHT overrides:
--   boltLightId = nil,              -- record ID (string) OR recordDraft (table) to attach to projectile
--
--   -- PROJECTILE PHYSICS overrides:
--   spinSpeed   = 0,               -- rotation speed in rad/sec (0 = no spin)
--   rotationFollowRate = 0,        -- exponential velocity-facing rate (1/sec; 0 = fixed orientation)
--   rotationDirectionUndirected = false, -- treat forward/backward as the same visual axis
--   forceCanReverse = false,       -- continuous force may cross zero speed without expiring
--   initialRotation = nil,         -- util.transform override for initial projectile rotation
--                                  -- (auto-calculated from direction if omitted)
--   spawnOffset = 80,              -- how far ahead of startPos the projectile spawns
--
--   -- NEW FEATURES:
--   userData         = {},              -- per-launch cookie persistence
--   effectScale      = 1.0,             -- quick-cast penalty to apply the launch with;
--                                       -- magnitudes and the resolved AoE area are scaled by it
--   muteAudio        = false,           -- if true, skip in-flight sounds
--   muteLight        = false,           -- if true, skip environmental lighting (glow)
--   itemRequirements = {                -- required items to cast
--      all = {"id1", "id2"},
--      any = {"id3", "id4"}
--   }
--
--   -- PROJECTILE BASE OBJECT override:
--   projectileRecordId = "Colony_Assassin_act",  -- world object record used as the projectile carrier
-- }
-- ============================================================
--- Returns a list of unique school IDs present across ALL effects of a spell.
--- Each entry is { school = "alteration", mgef = <record> }
--- Preserves insertion order (first occurrence of each school wins).
local function collectSpellSchools(spell)
    if not spell or not spell.effects then return {} end
    local seen = {}
    local out = {}
    for _, eff in ipairs(spell.effects) do
        local mgef = core.magic.effects.records[eff.id]
        if mgef and mgef.school then
            local s = tostring(mgef.school):lower()
            if not seen[s] then
                seen[s] = true
                table.insert(out, { school = s, mgef = mgef })
            end
        end
    end
    return out
end

--- Resolve cast VFX model path with priority:
--- 1. Explicit mgef.castVfx field
--- 2. Elemental keywords (poison, shock, frost)
--- 3. Generic school (alteration, destruction, etc.)
--- 4. Final fallback (VFX_DefaultCast)
--- Resolve cast VFX model path with strict priority.
local function resolveCastVfxModel(mgef, school)
    if not mgef then return nil end

    -- Helper to find the first valid model from a list of record IDs.
    local function findFirstValidVfxModel(candidates)
        for _, rid in ipairs(candidates) do
            local rec = types.Static.records[rid] or types.Static.records[rid:lower()]
            if not rec then
                rec = types.Weapon.records[rid] or types.Weapon.records[rid:lower()]
            end
            if rec and rec.model then
                debugLog("[VFX RESOLVER] Found valid model for candidate:", rid)
                return rec.model
            end
        end
        return nil
    end

    -- Priority 1: Explicit mgef.castVfx field
    if mgef.castVfx and mgef.castVfx ~= "" then
        local model = findFirstValidVfxModel({mgef.castVfx})
        if model then return model end
    end

    -- Priority 2: Elemental keywords
    local n = mgef.name:lower()
    local id = mgef.id:lower()
    local elementalCandidates = {}
    if n:find("poison") or id:find("poison") then
        elementalCandidates = {"VFX_PoisonCast"}
    elseif n:find("shock") or id:find("lightn") then
        elementalCandidates = {"VFX_LightningCast", "VFX_LightningHit"}
    elseif n:find("frost") or id:find("frost") then
        elementalCandidates = {"VFX_FrostCast", "VFX_FrostHit"}
    end
    if #elementalCandidates > 0 then
        local model = findFirstValidVfxModel(elementalCandidates)
        if model then return model end -- IMPORTANT: Stops here if found
    end

    -- Priority 3: Generic school
    local schoolCandidates = {
        alteration  = {"VFX_AlterationCast", "VFX_AlterationHit"},
        conjuration = {"VFX_ConjureCast"},
        destruction = {"VFX_DestructCast"},
        illusion    = {"VFX_IllusionCast"},
        mysticism   = {"VFX_MysticismCast"},
        restoration = {"VFX_RestorationCast"},
    }
    if schoolCandidates[school] then
        local model = findFirstValidVfxModel(schoolCandidates[school])
        if model then return model end
    end

    -- Priority 4: Final fallback
    return findFirstValidVfxModel({"VFX_DefaultCast"})
end


-- ============================================================
-- [CAST VFX] Spawn cast-start VFX for *every* effect in the spell.
-- This MUST live in launchSpell() path so mods like OSSC that call
-- MagExp_CastRequest directly still get caster VFX.
--
-- Uses MagicEffect.castStatic (OpenMW field) to resolve the cast VFX. <!--citation:1-->
-- Uses actor AddVfx -> animation.addVfx with boneName/vfxId. <!--citation:2-->
-- ============================================================

local function _magExpEffectElementKey(mgef, effIdFallback)
    local name = (mgef and mgef.name or ""):lower()
    local id   = (mgef and mgef.id   or effIdFallback or ""):lower()

    if name:find("fire") or id:find("fire") then return "fire" end
    if name:find("frost") or id:find("frost") or name:find("cold") or id:find("cold") then return "frost" end
    if name:find("shock") or id:find("shock") or name:find("lightning") or id:find("lightning") then return "shock" end
    if name:find("poison") or id:find("poison") then return "poison" end
    return nil
end

local function _magExpResolveCastStaticId(mgef)
    -- Primary: OpenMW MagicEffect.castStatic <!--citation:1-->
    if mgef and mgef.castStatic and mgef.castStatic ~= "" then
        return mgef.castStatic
    end
    return nil
end

local function _magExpFallbackCastStaticId(mgef, effIdFallback)
    -- If an effect has no castStatic (or a modded effect is missing it),
    -- fall back to element/school.
    local element = _magExpEffectElementKey(mgef, effIdFallback)
    local school  = tostring(mgef and mgef.school or "default"):lower()

    local map = {
        fire        = "VFX_DefaultCast",
        frost       = "VFX_FrostCast",
        shock       = "VFX_LightningCast",
        poison      = "VFX_PoisonCast",

        alteration  = "VFX_AlterationCast",
        conjuration = "VFX_ConjureCast",
        destruction = "VFX_DestructCast",
        illusion    = "VFX_IllusionCast",
        mysticism   = "VFX_MysticismCast",
        restoration = "VFX_RestorationCast",
    }

    return map[element or ""] or map[school] or "VFX_DefaultCast"
end

local function _magExpModelFromStaticId(staticId)
    if not staticId or staticId == "" then return nil end
    local rid = tostring(staticId):lower()
    local rec = types.Static.records[rid] or types.Weapon.records[rid]
    return (rec and rec.model) or nil
end

local function _magExpEnsureActorVfxScript(actor)
    -- Player already has AddVfx/RemoveVfx in magexp_player.lua
    if not actor or not actor:isValid() then return end
    if actor.type == types.Player then return end

    -- Non-player actors need a local handler to interpret AddVfx/RemoveVfx events.
    -- You already do this elsewhere for persistent effects; do it here too.
    addScriptOnce(actor, 'scripts/OMW_MagExp/magexp_actor_vfx.lua')
end

local function spawnCastVfxForAllEffects(attacker, spell, spellId, opts)
    if not attacker or not attacker:isValid() then return end
    if not spell or not spell.effects then return end
    opts = opts or {}

    if opts.muteCastVfx then return end

    if not attacker.enabled then
        debugLog("[CASTVFX] attacker not enabled, skipping cast VFX for", tostring(spellId))
        return
    end

    _magExpEnsureActorVfxScript(attacker)

        -- Attach all cast VFX to ACTOR ROOT only (no hands/head/etc).
    -- In OpenMW, boneName default is "" (root). We set it explicitly. <!--citation:1-->
    
end
-- Swimming gate helper: reproduce the engine's World::isSwimming test.
-- The real engine check (mwworld/worldimp.cpp) is
--     isUnderwater(object, fSwimHeightScale)
-- i.e. the water level is above fSwimHeightScale (0.9) of the actor's height
-- measured from the feet — the WHOLE body is in the water. Wading with only
-- the feet wet does NOT trip it (that would be World::isWading at 0.25).
-- types.Actor.isSwimming cannot be used here: it is LObject-only and this is
-- a global script, so the same test is rebuilt from the actor position, its
-- bounding-box height and the cell water level.
local SWIM_HEIGHT_SCALE = 0.9 -- fSwimHeightScale GMST value
local function isAttackerSwimming(actor)
    local swimming = false
    if not actor or not actor.isValid or not actor:isValid() then return end
    local cell = actor.cell
    if not cell or not cell.hasWater or not cell.waterLevel then return end
    local halfHeight = 64 -- fallback: default humanoid half-height
    local bbox = actor:getBoundingBox()
    if bbox and bbox.halfSize and bbox.halfSize.z then
        halfHeight = bbox.halfSize.z
    end
    -- actor.position is the feet origin, same as the engine test
    swimming = (actor.position.z + SWIM_HEIGHT_SCALE * 2 * halfHeight) < cell.waterLevel
    return swimming
end

-- Every provisional object has an owner before initialization can throw.
-- Successful projectiles transfer to activeSpellRegistry; anchors stay here
-- until their projectile ends, including the delayed local handoff interval.
local creationOwnership = { objects = {}, frame = 0 }
function creationOwnership.begin(object, kind, owner)
    creationOwnership.objects[object.id] = { object = object, kind = kind, owner = owner }
end
function creationOwnership.retire(object, kind)
    if not object or not object:isValid() then return end
    local entry = creationOwnership.objects[object.id]
    if not entry then
        creationOwnership.begin(object, kind)
        entry = creationOwnership.objects[object.id]
    end
    entry.ready = false
end
function creationOwnership.update()
    if core.isWorldPaused() then return end
    creationOwnership.frame = creationOwnership.frame + 1
    for id, entry in pairs(creationOwnership.objects) do
        local object = entry.object
        local owner = entry.owner and activeSpellRegistry[entry.owner.id]
        if not object:isValid() then
            creationOwnership.objects[id] = nil
            projectileItemRegistry[id] = nil
        elseif not entry.ready or not owner or owner.projectile ~= entry.owner
            or owner.lifecycleCancelRequestedAt ~= nil then
            -- A zero count also means a teleport is still queued. Only our own
            -- accepted removal, followed by another unpaused update, can use
            -- zero count as confirmation. Never remove during a pending move.
            if entry.removalFrame and creationOwnership.frame > entry.removalFrame and object.count == 0 then
                creationOwnership.objects[id] = nil
                projectileItemRegistry[id] = nil
            elseif not entry.removalFrame and not entry.removalError and object.count > 0 then
                object:remove()
                entry.removalFrame = creationOwnership.frame
            end
            if entry.removalFrame and creationOwnership.frame > entry.removalFrame
                and object.count > 0 and not entry.removalError then
                entry.removalError = 'object still present after accepted removal'
                print('[MagExp] Cleanup unconfirmed for ' .. entry.kind .. ' ' .. id .. ': ' .. entry.removalError)
            end
        end
    end
end
function creationOwnership.save()
    local pending = {}
    for _, entry in pairs(creationOwnership.objects) do
        if entry.object:isValid() then
            pending[#pending + 1] = { object = entry.object, kind = entry.kind }
        end
    end
    return { pendingCreationCleanup = pending }
end
function creationOwnership.load(data)
    -- These are transient objects, never resumed projectiles or queued casts.
    for _, entry in ipairs(data and data.pendingCreationCleanup or {}) do
        creationOwnership.retire(entry.object, entry.kind)
    end
end
local function attachRequiredProjectileScript(object)
    local path = 'scripts/OMW_MagExp/magexp_projectile_local.lua'
    -- This script is mandatory and registered CUSTOM. Configuration/programming
    -- errors must propagate to the request boundary; no nested silent fallback.
    if not object:hasScript(path) then object:addScript(path) end
end

local function launchSpell(data)
    -- A synchronous caller needs its projectile now. Nil also means a successful
    -- non-projectile cast, so it cannot signal this rejection. Fail before any
    -- resources/effects; MagExp_CastRequest is the deferred alternative.
    if core.isWorldPaused() then
        error('SFP launchSpell: world_paused; resume before calling or use MagExp_CastRequest', 2)
    end

    debugLog("launchSpell called with spellId:", data.spellId)
    local attacker  = data.attacker
    local spellId   = data.spellId
    local itemObject = data.item or data.itemObject
    local startPos  = data.startPos
    local direction = data.direction

    -- ── Swimming gate ─────────────────────────────────────────────────────
    -- Target-range spells must not launch while the caster is SWIMMING —
    -- the whole body in the water, not merely feet wading through shallows.
    -- OSSC gates its own quick-casts the same way; enforcing it here covers
    -- every other launch path that goes through SFP. types.Actor.isSwimming
    -- is local-script-only (LObject), so the engine's World::isSwimming test
    -- is reproduced manually below in isAttackerSwimming().

    debugLog("Parameter validation:")
    debugLog("  attacker:", attacker and (attacker:isValid() and "VALID" or "INVALID") or "NIL")
    debugLog("  spellId:", spellId and tostring(spellId) or "NIL")
    debugLog("  startPos:", startPos and tostring(startPos) or "NIL")
    debugLog("  direction:", direction and tostring(direction) or "NIL")
    
    if not attacker or not spellId or not startPos or not direction then
        debugLog("launchSpell: missing required data (attacker, spellId, startPos, direction)")
        debugLog("EARLY RETURN - missing required parameters!")
        --playerNotifyCastIssue(attacker, "Cast failed (invalid spell data).")
        return
    end
    debugLog("Parameter validation passed!")

    local spell = core.magic.spells.records[spellId] or core.magic.enchantments.records[spellId]
    debugLog("Direct spell lookup result:", spell and "FOUND" or "NOT FOUND")
    
    -- Fallback: Iterative search if the proxy is numerically indexed
    if not spell then
        debugLog("Trying fallback iterative search...")
        for _, rec in pairs(core.magic.spells.records) do
            local recId = rec.id
            if recId and tostring(recId):lower() == tostring(spellId):lower() then
                spell = rec
                debugLog("Found spell in fallback search!")
                break
            end
        end
    end
    if not spell then
        for _, rec in pairs(core.magic.enchantments.records) do
            local recId = rec.id
            if recId and tostring(recId):lower() == tostring(spellId):lower() then
                spell = rec
                debugLog("Found spell in fallback search!")
                break
            end
        end
    end

    -- Last resort: check if spellId is a magic effect and synthesize a minimal spell wrapper
    if not spell then
        local effRec = core.magic.effects.records[spellId]
        if not effRec then
            -- try iterative search on effects too (proxy may be numeric)
            for _, rec in pairs(core.magic.effects.records) do
                local recId = rec.id
                if recId and tostring(recId):lower() == tostring(spellId):lower() then
                    effRec = rec
                    break
                end
            end
        end
        if effRec then
            debugLog("Found '" .. spellId .. "' as a magic effect — synthesizing spell wrapper")
            spell = {
                id      = spellId,
                cost    = 0,
                effects = {
                    { id = spellId, range = core.magic.RANGE.Target, magnitudeMin = 30, magnitudeMax = 30, area = 0 }
                }
            }
        end
    end

    if not spell then
        debugLog("launchSpell ERROR: spell/enchantment record not found: " .. tostring(spellId))
        --playerNotifyCastIssue(attacker, "You cannot cast that spell.")
        return
    end
    debugLog("Spell record found successfully!")

    -- Swimming gate (cont.): reject target-range launches from a swimming
    -- caster. Self-range casts have no Target-range effects (and Touch ones
    -- neither), so only spells that can ship a Target-range effect are
    -- checked.  (attacker is never nil here: the parameter validation above
    -- returns early when it is, and every protocol sender — including for
    -- Self-range casts — passes the casting object itself.)
    if magExpSettings.blockTargetSpellsWhileSwimming and attacker then
        local hasTargetEffect = false
        for _, eff in ipairs(spell.effects or {}) do
            if eff.range == core.magic.RANGE.Target then
                hasTargetEffect = true
                break
            end
        end
        if hasTargetEffect and isAttackerSwimming(attacker) then
            debugLog("launchSpell: blocked — target spell while swimming:", tostring(spellId))
            return
        end
    end

-- ===================================================================
-- [CAST VFX + SOUND] Spawn for ALL unique schools, right at cast start
-- ===================================================================

    -- [FEATURE 4] nonRecastable: silently abort if spell is already active on the caster.
    debugLog("Checking nonRecastable...")
    if data.nonRecastable then
        debugLog("nonRecastable is TRUE, checking active spells...")
        local isActive = false
        local as = types.Actor.activeSpells(attacker)
        if as then
            for sid, _ in pairs(as) do
                if tostring(sid):lower() == tostring(spellId):lower() then
                    isActive = true
                    break
                end
            end
        end
        if isActive then
            debugLog("nonRecastable:", spellId, "already active on caster — aborting.")
            return
        else
            debugLog("nonRecastable: spell is not active on caster")
        end
    else
        debugLog("nonRecastable is FALSE or not set")
    end
    debugLog("nonRecastable check passed!")

    -- [RESOURCE GUARD] (skipped when isFree = true)
    debugLog("Checking resource guard, isFree:", data.isFree, "isGodMode:", data.isGodMode)
    if not data.isFree and not data.isGodMode then
        debugLog("Resource guard: checking costs and resources...")
        local isEnchantment = core.magic.enchantments.records[spellId] ~= nil
        local cost = data.overrideCost or Helpers.getModifiedSpellCost(attacker, spellId, isEnchantment)
        local resolvedItem = itemObject
        if isEnchantment then
            local inv = types.Actor.inventory(attacker)
            if type(resolvedItem) == "string" and inv then
                resolvedItem = inv:find(resolvedItem)
            end
            if (not resolvedItem or type(resolvedItem) == "string" or not resolvedItem:isValid()) and data.itemRecordId and inv then
                resolvedItem = inv:find(data.itemRecordId)
            end
        end

        if isEnchantment then
            debugLog("Spell is enchantment, checking item...")
            if not (resolvedItem and type(resolvedItem) ~= "string" and resolvedItem:isValid()) then
                debugLog("Enchantment failure: no valid enchanted item")
                if attacker.type == types.Player then
                    attacker:sendEvent('Ui_ShowMessage', C.MSG.INSUFFICIENT_CHARGE)
                end
                debugLog("Enchantment failure: no valid enchanted item for", tostring(spellId))
                return
            end
            debugLog("Enchantment item validation passed!")
            -- Fold the enchanted-item identity down to the item's RECORD id
            -- while the instance is still alive: a scroll is consumed just
            -- below, and a consumed handle can no longer report anything
            -- (property access on it raises).  The record id is all spell
            -- application needs — the engine resolves an enchanted
            -- activeSpells:add through the item record (Book/Weapon/…), and
            -- applySpellToActor re-finds a live instance when one remains for
            -- ActiveSpellAddOptions.item.
            itemObject = resolvedItem.recordId or data.itemRecordId or resolvedItem
            if spell.type == core.magic.ENCHANTMENT_TYPE.CastOnce then
                -- Scroll / Cast Once Check: Consume 1 item
                if resolvedItem.count > 0 then
                    magExpApplyInventoryResourceConsumption(attacker, {
                        item = resolvedItem,
                        itemCountCost = 1,
                        itemRecordId = resolvedItem.recordId,
                    })
                else
                    if attacker.type == types.Player then
                        attacker:sendEvent('Ui_ShowMessage', C.MSG.INSUFFICIENT_ITEMS)
                    end
                    return
                end
            else
                local currentCharge, haveCharge = magExpReadItemEnchantmentCharge(resolvedItem)
                if not haveCharge then
                    currentCharge = spell.charge or 0
                end
                if currentCharge < cost then
                    if attacker.type == types.Player then
                        attacker:sendEvent('Ui_ShowMessage', C.MSG.INSUFFICIENT_CHARGE)
                    end
                    debugLog("Enchantment failure:", spellId, "requires", cost, "charges, has", currentCharge)
                    return
                end
                -- [DEDUCTION] (global script — required for item charge writes)
                magExpApplyInventoryResourceConsumption(attacker, {
                    item = resolvedItem,
                    itemChargeCost = cost,
                    itemRecordId = resolvedItem.recordId,
                })
            end
            -- itemObject already carries the item's record-id string (captured
            -- above while the instance was alive).
        else
            -- Magicka Check
            debugLog("Checking magicka cost...")
            local magicka = (attacker.type == types.Player)
                and types.Player.stats.dynamic.magicka(attacker)
                or  types.Actor.stats.dynamic.magicka(attacker)
            debugLog("Current magicka:", magicka and magicka.current or "NIL", "Cost:", cost)
            debugLog("Comparison: magicka.current < cost =", magicka and magicka.current or "NIL", "<", cost)
            if magicka.current < cost then
                debugLog("Not enough magicka, returning early!")
                if attacker.type == types.Player then
                    attacker:sendEvent('Ui_ShowMessage', C.MSG.INSUFFICIENT_MAGICKA)
                end
                debugLog("Magicka failure:", spellId, "requires", cost, "magicka, has", magicka.current)
                return
            end
            -- [DEDUCTION]
            if attacker.type == types.Player then
                attacker:sendEvent('MagExp_ConsumeResource', { magickaCost = cost })
            end
        end
    end
    
    -- [ITEM REQUIREMENTS]
    debugLog("Checking item requirements...")
    if data.itemRequirements and types.Actor.objectIsInstance(attacker) then
        debugLog("Item requirements found, checking...")
        local inv = types.Actor.inventory(attacker)
        local spellName = (spell and spell.name) or spellId
        
        local function getItemName(id)
            local rec = types.Item.records[id] or core.magic.spells.records[id]
            if rec then return rec.name end
            -- Fallback search across common item types
            local typesList = { types.MiscItem, types.Weapon, types.Armor, types.Potion, types.Apparatus, types.Book, types.Ingredient, types.Lockpick, types.RepairPick, types.Probe, types.Clothing }
            for _, t in ipairs(typesList) do
                local r = t.records[id]
                if r then return r.name end
            end
            return id
        end

        local function showFail(itemId)
            if attacker.type == types.Player then
                local itemName = getItemName(itemId)
                local msg = string.format(C.MSG.ITEM_REQUIRED, itemName, spellName)
                attacker:sendEvent('Ui_ShowMessage', msg)
            end
        end

        if data.itemRequirements.all then
            for _, id in ipairs(data.itemRequirements.all) do
                if inv:count(id) <= 0 then
                    showFail(id)
                    return
                end
            end
        end

        if data.itemRequirements.any and #data.itemRequirements.any > 0 then
            local foundAny = false
            for _, id in ipairs(data.itemRequirements.any) do
                if inv:count(id) > 0 then
                    foundAny = true
                    break
                end
            end
            if not foundAny then
                showFail(data.itemRequirements.any[1])
                return
            end
        end
    end
    debugLog("Item requirements check passed!")
    -- Enchanted-item identity: fold the item down to its RECORD id string
    -- (see the note in applySpellToActor).  The resource guard above already
    -- does this when it consumed the item; this covers the isFree/god-mode
    -- paths that skip the guard, and any caller that passed a live handle.
    -- A dead handle that cannot even report its record id falls back to the
    -- request's own itemRecordId; applySpellToActor has a final fallback.
    if itemObject ~= nil and type(itemObject) ~= "string" then
        local rid = itemRefRecordId(itemObject)
        if rid ~= nil then
            itemObject = rid
        elseif type(data.itemRecordId) == "string" and data.itemRecordId ~= "" then
            itemObject = data.itemRecordId
        elseif not itemRefIsLive(itemObject) then
            -- A consumed handle can never answer anything again; drop it so
            -- applySpellToActor's generated-record fallback takes over.
            itemObject = nil
        end
    end
    -- Spawn cast-start VFX for ALL effects (works even when OSSC calls MagExp_CastRequest directly)
    spawnCastVfxForAllEffects(attacker, spell, spellId, {
        muteCastVfx = data.muteCastVfx or false,
    })
    local effectScale = coerceEffectScale(data.effectScale)
    debugLog("Effect scale:", effectScale)

    -- Partition by per-effect range: Self only on caster; Touch only on hitObject; Target only via projectile indices.
    debugLog("Partitioning spell effects...")
    local selfIndexes, touchIndexes, targetIndexes = {}, {}, {}
    if spell.effects then
        debugLog("Spell has", #spell.effects, "effects")
        for i, eff in ipairs(spell.effects) do
            local ix = i - 1
            debugLog("Effect", i, "range:", eff.range)
            if spellEffectRangeIsSelf(eff.range) then
                table.insert(selfIndexes, ix)
            elseif eff.range == core.magic.RANGE.Touch then
                table.insert(touchIndexes, ix)
            else
                table.insert(targetIndexes, ix)
            end
        end
    else
        debugLog("Spell has no effects!")
    end
    debugLog("Effects partitioned - Self:", #selfIndexes, "Touch:", #touchIndexes, "Target:", #targetIndexes)

    local function casterTorsoPosition()
        local zOffset = 95
        local bbox = attacker:getBoundingBox()
        if bbox then
            zOffset = bbox.halfSize.z
            if zOffset > 105 then zOffset = 100 end
        end
        return attacker.position + util.vector3(0, 0, zOffset)
    end

    if #selfIndexes > 0 then
        debugLog(string.format("Applying %d Self effect(s) on caster only for %s", #selfIndexes, spellId))
        local torsoPos = casterTorsoPosition()
        local selfArea = maxAreaAmongIndexes(spell, selfIndexes)
        if effectScale < 1 then
            selfArea = math.max(0, math.floor(selfArea * effectScale + 0.5))
        end
        if selfArea > 0 then
            detonateSpellAtPos(spellId, attacker, torsoPos, attacker.cell, itemObject, selfIndexes, data.unreflectable, data.casterLinked, nil, 0, 0, nil, nil, data.userData, data.muteAudio, data.muteLight, data.continuousVfx, effectScale, selfArea)
        end
        applySpellToActor(spellId, attacker, attacker, torsoPos, false, itemObject, selfIndexes, data.unreflectable, data.casterLinked, data.userData, data.muteAudio, data.muteLight, data.continuousVfx, effectScale, data)
    end

    if #touchIndexes == 0 and #targetIndexes == 0 then
        return
    end

    local function spellFlagsFromEffectIndexes(idxList)
        local spellIsLockUnlock, spellIsUniversal = false, false
        if spell.effects and idxList then
            for _, ix in ipairs(idxList) do
                local eff = spell.effects[ix + 1]
                if eff then
                    local eid = tostring(eff.id):lower()
                    if STACK_CONFIG.LOCKABLE_EFFECTS[eid] then spellIsLockUnlock = true end
                    if STACK_CONFIG.UNIVERSAL_EFFECTS[eid] then spellIsUniversal = true end
                end
            end
        end
        return spellIsLockUnlock, spellIsUniversal
    end

    -- ---- TOUCH ---- (only indexes in touchIndexes; Target effects are handled by projectile below)
 if #touchIndexes > 0 then
    debugLog(string.format("[TOUCH] Touch spell detected with %d effects", #touchIndexes))
    local obj = data.hitObject
    debugLog(string.format("[TOUCH] data.hitObject = %s", tostring(obj)))
    
    if obj and obj:isValid() then
        debugLog(string.format("[TOUCH] Hit object is VALID: type=%s recordId=%s", tostring(obj.type), tostring(obj.recordId)))
        
        local spellIsLockUnlock, spellIsUniversal = spellFlagsFromEffectIndexes(touchIndexes)
        debugLog(string.format("[TOUCH] spellIsLockUnlock=%s spellIsUniversal=%s", tostring(spellIsLockUnlock), tostring(spellIsUniversal)))

        local isLockable = (obj.type == types.Door or obj.type == types.Container)
        local isActor    = (obj.type == types.NPC or obj.type == types.Creature or obj.type == types.Player)
        debugLog(string.format("[TOUCH] isLockable=%s isActor=%s", tostring(isLockable), tostring(isActor)))

        local validTarget = (isLockable or isActor or spellIsUniversal)
        debugLog(string.format("[TOUCH] validTarget=%s", tostring(validTarget)))

        if validTarget then
            debugLog("[TOUCH] Valid target confirmed, proceeding with interaction")
            local hitPos = getObjectCenter(obj) or obj.position
            if isActor then
                local zOffset = 95
                local bbox = obj:getBoundingBox()
                if bbox then
                    zOffset = bbox.halfSize.z
                    if zOffset > 105 then zOffset = 100 end
                end
                hitPos = obj.position + util.vector3(0, 0, zOffset)
            end

            local touchArea = maxAreaAmongIndexes(spell, touchIndexes)
            if effectScale < 1 then
                touchArea = math.max(0, math.floor(touchArea * effectScale + 0.5))
            end

            if touchArea > 0 then
                detonateSpellAtPos(spellId, attacker, hitPos, obj.cell, itemObject, touchIndexes, data.unreflectable, data.casterLinked, nil, 0, 0, nil, obj, data.userData, data.muteAudio, data.muteLight, data.continuousVfx, effectScale, touchArea)
            end

            if spellIsLockUnlock then
                debugLog("[TOUCH] Calling handleDoorLockUnlock for:", tostring(obj.recordId))
                handleDoorLockUnlock(spellId, attacker, obj, effectScale)
            elseif isActor and not (types.Actor.objectIsInstance(obj) and types.Actor.isDead(obj)) then
                debugLog("[TOUCH] Applying spell to actor:", tostring(obj.recordId))
                applySpellToActor(spellId, attacker, obj, hitPos, false, itemObject, touchIndexes, data.unreflectable, data.casterLinked, data.userData, data.muteAudio, data.muteLight, data.continuousVfx, effectScale, data)
            else
                debugLog("[TOUCH] WARNING: validTarget=true but no action taken (not lockable, not actor)")
            end

            local isProperTarget = spellIsUniversal or (spellIsLockUnlock and isLockable)
                or (not spellIsLockUnlock and isActor and not (types.Actor.objectIsInstance(obj) and types.Actor.isDead(obj)))

            if isProperTarget then
                debugLog("[TOUCH] Firing MagicHit event")
                fireMagicHitEvent({
                    attacker   = attacker,
                    target     = obj,
                    spellId    = spellId,
                    itemObject = itemObject,
                    hitPos     = hitPos,
                    isAoE      = false,
                    area       = touchArea,
                    effectScale = effectScale,
                    spellType  = core.magic.RANGE.Touch,
                    effectIndex = touchIndexes[1],
                    unreflectable = data.unreflectable,
                    casterLinked = data.casterLinked,
                    userData   = data.userData
                })
            end
        else
            debugLog("[TOUCH] WARNING: Hit object is not a validTarget")
        end
    else
        debugLog("[TOUCH] WARNING: data.hitObject is nil or invalid — Touch spell has no target!")
    end

    -- Pure Touch spell with no projectile leg: behavior matches vanilla (need valid touch when no Target effects).
    if #targetIndexes == 0 then
        debugLog("[TOUCH] Pure Touch spell (no Target effects), returning")
        return
    end
end

if #targetIndexes == 0 then
    debugLog("[TOUCH] No Target effects remaining, returning")
    return
end

    -- ---- TARGET (projectile): one bolt per unique school in Target effects ----

local area = data.area
if area == nil then
    area = maxAreaAmongIndexes(spell, targetIndexes)
end
area = area or 0
if effectScale < 1 then
    area = math.max(0, math.floor(area * effectScale + 0.5))
end

local effectIndexes = targetIndexes

-- Group ONLY the Target-range effects by school.
local schoolGroups = groupEffectIndexesBySchool(spell, effectIndexes)
debugLog(string.format("[LAUNCH] Target effects grouped into %d school bolt(s).", #schoolGroups))

if #schoolGroups == 0 then
    return nil
end

-- Estimate distance once (for point-blank spawnOffset reduction)
local estimatedTargetDistance = 0
if data.hitObject and data.hitObject:isValid() then
    local targetPos = getObjectCenter(data.hitObject) or data.hitObject.position
    estimatedTargetDistance = (targetPos - startPos):length()
elseif data.hitPos then
    estimatedTargetDistance = (data.hitPos - startPos):length()
end

local spawnOffset = data.spawnOffset or 80
if estimatedTargetDistance > 0 and estimatedTargetDistance < 100 then
    spawnOffset = 10
    debugLog(string.format(
        "Point-blank range detected (%.1f units), using reduced spawnOffset: %d for %s",
        estimatedTargetDistance, spawnOffset, spellId
    ))
end

-- Base direction safety
local baseDir = direction
if not baseDir or (baseDir.length and baseDir:length() < 0.001) then
    baseDir = util.vector3(0, 1, 0)
else
    baseDir = baseDir:normalize()
end

local recordId = data.projectileRecordId or "Colony_Assassin_act"
local projectileScale = tonumber(data.projectileScale)
if projectileScale ~= nil then
    if projectileScale <= 0 then
        projectileScale = nil
    else
        projectileScale = math.max(0.05, math.min(10.0, projectileScale))
    end
end

-- Maintain the live enchanted item reference per projectile (your existing registry fix)
local itemRecordId = nil
if itemObject then
    if type(itemObject) == "string" then
        itemRecordId = itemObject
    else
        itemRecordId = itemObject.recordId
        -- NOTE: the per-projectile registry entry is set per projectile below
    end
end

local lastProj = nil
local castSoundPlayed = false

for gi, group in ipairs(schoolGroups) do
    debugLog(string.format(
        "[LAUNCH] Bolt %d/%d school=%s effects=%d",
        gi, #schoolGroups, tostring(group.school), #group.indexes
    ))

    -- Per-bolt AoE radius: max area among that bolt’s indexes
    local boltArea = data.area
    if boltArea == nil then
        boltArea = maxAreaAmongIndexes(spell, group.indexes)
    end
    boltArea = boltArea or 0
    if effectScale < 1 then
        boltArea = math.max(0, math.floor(boltArea * effectScale + 0.5))
    end

    -- ✅ NEW: Collect ALL unique VFX models for this school group's effects
    local boltModels = {}      -- list of model paths
    local particleTextures = {} -- list of particle override textures
    local seenModels = {}
    
    for _, idx in ipairs(group.indexes) do
        local auto = autoDetectProjectileParams(spell, idx)
        
        if auto.boltModel and auto.boltModel ~= "" and not seenModels[auto.boltModel] then
            table.insert(boltModels, auto.boltModel)
            seenModels[auto.boltModel] = true
        end
        
        if auto.particleTex and auto.particleTex ~= "" then
            table.insert(particleTextures, auto.particleTex)
        end
    end

    -- Auto-detect bolt params from the FIRST effect of THIS school group
    local auto = autoDetectProjectileParams(spell, group.indexes[1])

    local vfxRecId     = data.vfxRecId     or auto.vfxRecId
    local areaVfxRecId = data.areaVfxRecId or (auto.areaVfxRecId ~= "" and auto.areaVfxRecId or nil)
    local boltModel    = data.boltModel    or auto.boltModel
    local hitModel     = data.hitModel     or auto.hitModel
    local particleTex  = data.particleTex  or auto.particleTex
    local boltSound    = (data.muteAudio) and nil or (data.boltSound or auto.boltSound)
    local hitSound     = (data.muteAudio) and nil or (data.hitSound  or auto.hitSound)
    local castSound    = (data.muteAudio) and nil or (data.castSound or auto.castSound)
    local boltLightId  = (data.muteLight) and nil or (data.boltLightId or auto.boltLightDraft)
    local spinSpeed    = (data.spinSpeed ~= nil) and data.spinSpeed or auto.spinSpeed
    -- Vanilla fallback, not the old hardcoded "Oblivion-style" 1500.  If a
    -- spell/enchantment has no readable effect-speed data we still fly at the
    -- GMST's base target-spell speed, so a quick-cast can never silently jump
    -- to a non-vanilla value.
    local speed        = data.speed or auto.speed or (core.getGMST("fTargetSpellMaxSpeed") or 1000)

    -- Vanilla parity: OpenMW scales magic projectile speed by the caster's race
    -- weight for NPC casters (player included) when "normalise race speed" is
    -- off (the default; see updateMagicBolt in OpenMW's projectilemanager.cpp).
    -- Lua cannot read "normalise race speed", so use the SFP NormaliseRaceSpeed
    -- setting (SettingsMagExp_General), which has the exact same meaning as the
    -- launcher setting.  Default false matches the vanilla Morrowind/OpenMW
    -- default; set it to true if your launcher has "normalise race speed" on.
    -- Only auto-detected speeds get the weight — an explicit data.speed wins.
    if not magExpSettings.normaliseRaceSpeed and data.speed == nil and attacker
        and (attacker.type == types.NPC or attacker.type == types.Player) then
        local mult, raceId = Helpers.getProjectileRaceWeight(attacker)
        if mult then
            speed = speed * mult
            debugLog(string.format(
                "Race weight %.2f applied to projectile speed (normalise race speed = false) -> %s",
                mult, tostring(speed)))
        else
            debugLog(string.format(
                "Race weight lookup returned no multiplier for caster %s (raceId=%s) — projectile speed stays %s",
                tostring(attacker.recordId or attacker.id or "unknown"),
                tostring(raceId), tostring(speed)))
        end
    else
        if data.speed ~= nil then
            debugLog("Vanilla race weight skipped: caller provided explicit speed (" .. tostring(data.speed) .. ")")
        else
            debugLog("Vanilla race weight skipped for projectile speed (normalise race speed = true)")
        end
    end
    local maxLifetime  = data.maxLifetime or 10

    -- Explicit caller visuals must win over auto-detected magic-effect visuals.
    -- The local projectile script prefers boltModels/particleTextures when present,
    -- so build those arrays from caller overrides before falling back to auto VFX.
    if type(data.boltModels) == "table" and #data.boltModels > 0 then
        boltModels = {}
        particleTextures = {}
        for i, model in ipairs(data.boltModels) do
            if type(model) == "string" and model ~= "" then
                table.insert(boltModels, model)
                local particle = type(data.particleTextures) == "table" and data.particleTextures[i] or nil
                if type(particle) == "string" and particle ~= "" then
                    particleTextures[#boltModels] = particle
                end
            end
        end
    elseif data.boltModel and data.boltModel ~= "" then
        boltModels = { data.boltModel }
        particleTextures = {}
        if data.particleTex and data.particleTex ~= "" then
            particleTextures[1] = data.particleTex
        end
    end
    if #boltModels == 0 and boltModel and boltModel ~= "" then
        boltModels[1] = boltModel
    end
    if #particleTextures == 0 and particleTex and particleTex ~= "" then
        particleTextures[1] = particleTex
    end

    -- Validate an optional local path provider before allocating any carriers.
    if data.motionPath ~= nil then
        assert(type(data.motionPath) == 'table' and type(data.motionPath.module) == 'string',
            'motionPath requires a module and config')
        local provider = require(data.motionPath.module)
        assert(type(provider.create) == 'function' and type(provider.validate) == 'function',
            'motionPath provider requires create and validate')
        provider.validate(data.motionPath.config)
    end

    local dir = baseDir
    local spawnPos = startPos + dir * spawnOffset

    local rotation = data.initialRotation
    if not rotation then
        local yaw   = math.atan2(dir.x, dir.y)
        local pitch = math.asin(math.max(-1, math.min(1, dir.z)))
        rotation = util.transform.rotateZ(yaw) * util.transform.rotateX(-pitch)
    end

    debugLog("Attempting to create projectile with recordId:", tostring(recordId))
    local proj = world.createObject(recordId, 1)
    creationOwnership.begin(proj, 'projectile')
    debugLog("Created projectile object:", tostring(proj and proj.id or "NIL"))
    if not proj or not proj:isValid() then
        debugLog("ERROR: Failed to create valid projectile object for bolt", tostring(gi))
    else
        if projectileScale ~= nil then
            proj:setScale(projectileScale)
        end
        proj:teleport(attacker.cell, spawnPos, rotation)

        -- Per-projectile registry for live item object (enchantments)
        if itemObject and type(itemObject) ~= "string" then
            projectileItemRegistry[proj.id] = itemObject
        end

        attachRequiredProjectileScript(proj)

        local initPayload = {
            velocity        = dir * speed,
            maxLifetime     = maxLifetime,
            spinSpeed       = spinSpeed,
            rotationFollowRate = data.rotationFollowRate,
            rotationDirectionUndirected = data.rotationDirectionUndirected,
            forceCanReverse = data.forceCanReverse,
            accelerationExp = data.accelerationExp,
            maxSpeed        = data.maxSpeed,

            attacker        = attacker,
            spellId         = spellId,
            motionPath      = data.motionPath,
            itemRecordId    = itemRecordId,
            effectIndexes   = group.indexes,
            effectScale     = effectScale,
            area            = boltArea,

            boltSound       = boltSound,
            hitSound        = hitSound,
            castSound       = castSound,

            boltLightId     = boltLightId,

            -- ✅ CHANGED: Send ALL models + particles for layered VFX
            boltModels      = boltModels,           -- NEW: table of all model paths
            boltModel       = boltModels[1],        -- Fallback for old logic
            particleTextures = particleTextures,     -- NEW: table of all particles
            particle        = particleTextures[1],   -- Fallback for old logic
            
            hitModel        = hitModel,
            hitModelExplicit = data.hitModel ~= nil,
            vfxRecId        = vfxRecId,
            areaVfxRecId    = areaVfxRecId,

            unreflectable   = data.unreflectable,
            casterLinked    = data.casterLinked,
            isPaused        = data.isPaused,
            direction       = dir,
            areaVfxScale    = data.areaVfxScale,
            userData        = data.userData,
            muteAudio       = data.muteAudio,
            muteLight       = data.muteLight,
            continuousVfx   = data.continuousVfx,

            bounceEnabled       = data.bounceEnabled,
            bounceMax           = data.bounceMax,
            bouncePower         = data.bouncePower,
            detonateOnActorHit  = data.detonateOnActorHit,

            piercing       = data.piercing,
            pierceLimit    = data.pierceLimit,
            pierceRepeatHits = data.pierceRepeatHits,
            pierceRateLimit = data.pierceRateLimit,
            canHitCasterAfter = data.canHitCasterAfter,
            collisionMode   = data.collisionMode,
            impactImpulse  = data.impactImpulse,
            anchorRecordId = data.anchorRecordId,
        }

        proj:sendEvent('MagExp_InitProjectile', initPayload)

        -- Direct/programmatic launches do not pass through the player-side
        -- MagExp_CastStart presentation path. Play their resolved cast sound
        -- once per launchSpell call, never once per school-group projectile.
        if not castSoundPlayed
            and data.isFree == true
            and type(castSound) == "string"
            and castSound ~= ""
            and attacker.enabled
        then
            core.sound.playSound3d(castSound, attacker, { volume = 1.0 })
            castSoundPlayed = true
        end

        -- Register in live spell registry
        local launchTime = core.getSimulationTime()
        activeSpellRegistry[proj.id] = {
            projectile    = proj,
            spellId       = spellId,
            attacker      = attacker,
            launchTime    = launchTime,
            maxLifetime   = maxLifetime,
            isPaused      = data.isPaused == true,
            maxSpeed      = data.maxSpeed or 0,
            userData      = data.userData,
            muteAudio     = data.muteAudio,
            muteLight     = data.muteLight,
            continuousVfx = data.continuousVfx
        }
        creationOwnership.objects[proj.id] = nil -- live registry now owns cleanup

        debugLog(string.format(
            "[LAUNCH] Launched bolt %d/%d for '%s' school=%s spd=%d",
            gi, #schoolGroups, tostring(spellId), tostring(group.school), speed
        ))

        lastProj = proj
    end
end
-- [SKILL] Award progression for all schools after spell fires successfully
if not data.isFree and not (data.userData and data.userData.OSSC) then
    local isEnchant = (itemObject ~= nil)
    local schools = collectSpellSchools(spell)
    for _, entry in ipairs(schools) do
        awardSpellSkillProgress(attacker, entry.school, spell.cost, isEnchant, spell.id)
    end
end

return lastProj

end

-- ============================================================
-- [INTERNAL] Projectile lifecycle event handlers
-- ============================================================
local function teleportProjectileMove(proj, newPos, newRot)
    if proj.count == 0 then return false, 'object removed or teleport still pending' end
    if newRot then
        proj:teleport(proj.cell, newPos, newRot)
    else
        proj:teleport(proj.cell, newPos)
    end
    return true
end

local function clearProjectileRegistries(projectileId)
    if projectileId == nil then return end
    projectileItemRegistry[projectileId] = nil
    activeSpellRegistry[projectileId] = nil
    pendingProjectileMoves[projectileId] = nil
    pauseWork.moves[projectileId] = nil
    pauseWork.sounds[projectileId] = nil
    pauseWork.lights[projectileId] = nil
    for id in pairs(pauseWork.anchorIds[projectileId] or {}) do pauseWork.anchors[id] = nil end
    pauseWork.anchorIds[projectileId] = nil
end

local function cancelSpell(projectile, reason)
    if not projectile or not projectile:isValid() then return end
    local projectileId = projectile.id
    local registryEntry = activeSpellRegistry[projectileId]
    if registryEntry and registryEntry.projectile == projectile then
        if registryEntry.lifecycleCancelRequestedAt == nil then
            registryEntry.lifecycleCancelRequestedAt = core.getSimulationTime()
            projectile:sendEvent('MagExp_ForceCancel')
        elseif core.getSimulationTime() >= registryEntry.lifecycleCancelRequestedAt + PROJECTILE_LIFECYCLE_CANCEL_GRACE then
            clearProjectileRegistries(projectileId)
            if projectile:isValid() then
                creationOwnership.retire(projectile, 'cancelled projectile')
            end
        end
    else
        clearProjectileRegistries(projectileId)
        if projectile:isValid() then
            projectile:sendEvent('MagExp_ForceCancel')
        end
    end
end

local function retryPendingProjectileMoves()
    if core.isWorldPaused() then return end
    local currentTime = core.getSimulationTime()
    for projId, move in pairs(pendingProjectileMoves) do
        local registryEntry = activeSpellRegistry[projId]
        local proj = move.projectile
        if not proj or not proj:isValid() or not registryEntry or registryEntry.projectile ~= proj then
            pendingProjectileMoves[projId] = nil
        elseif registryEntry.lifecycleCancelRequestedAt ~= nil then
            -- Keep the lifecycle entry until terminal cleanup or its backstop.
            pendingProjectileMoves[projId] = nil
        elseif currentTime >= move.nextAttemptAt then
            local moved, err = teleportProjectileMove(proj, move.newPos, move.newRot)
            if moved then
                pendingProjectileMoves[projId] = nil
            else
                move.lastError = tostring(err)
                move.attempts = move.attempts + 1
                move.nextAttemptAt = currentTime + PROJECTILE_MOVE_RETRY_INTERVAL
            end
        end
    end
end

local function sweepProjectileLifecycles()
    if core.isWorldPaused() then return end
    local currentTime = core.getSimulationTime()
    if currentTime < nextProjectileLifecycleSweepAt then return end
    nextProjectileLifecycleSweepAt = currentTime + PROJECTILE_LIFECYCLE_SWEEP_INTERVAL

    for projId, move in pairs(pendingProjectileMoves) do
        local registryEntry = activeSpellRegistry[projId]
        local proj = move.projectile
        if not proj or not proj:isValid() or not registryEntry or registryEntry.projectile ~= proj then
            pendingProjectileMoves[projId] = nil
        elseif (currentTime - move.firstFailedAt) > PROJECTILE_MOVE_RETRY_MAX_AGE
            or move.attempts >= PROJECTILE_MOVE_RETRY_MAX_ATTEMPTS
        then
            pendingProjectileMoves[projId] = nil
            pauseWork.moves[projId] = nil
            pauseWork.sounds[projId] = nil
            pauseWork.lights[projId] = nil
            print('[MagExp] Movement abandoned for ' .. projId .. ': ' .. tostring(move and move.lastError))
            cancelSpell(proj, 'movement retry limit reached')
        end
    end
end

local function onProjectileMove(data)
    local proj = data.projectile
    local entry = proj and proj:isValid() and activeSpellRegistry[proj.id]
    if entry and entry.projectile == proj and entry.lifecycleCancelRequestedAt == nil and data.newPos then
        -- One placement per projectile per update, including the last sample
        -- delivered as the world entered pause. Newer samples supersede it.
        pauseWork.moves[proj.id] = data
    end
end

local function applyProjectileMove(data)
    local proj, newPos = data.projectile, data.newPos
    local entry = proj and proj:isValid() and activeSpellRegistry[proj.id]
    if not entry or entry.projectile ~= proj or entry.lifecycleCancelRequestedAt ~= nil then return end
    local projId, currentTime = proj.id, core.getSimulationTime()
    local pending = pendingProjectileMoves[projId]
    if pending and currentTime < pending.nextAttemptAt then
        pending.newPos, pending.newRot = newPos, data.newRot
    else
        local moved, err = teleportProjectileMove(proj, newPos, data.newRot)
        if moved then
            pendingProjectileMoves[projId] = nil
        else
            pendingProjectileMoves[projId] = {
                projectile = proj, newPos = newPos, newRot = data.newRot,
                firstFailedAt = pending and pending.firstFailedAt or currentTime,
                nextAttemptAt = currentTime + PROJECTILE_MOVE_RETRY_INTERVAL,
                attempts = (pending and pending.attempts or 0) + 1,
                lastError = tostring(err),
            }
        end
    end
    queueAnchorMove(data.soundAnchor, proj.cell, newPos, proj)
    queueAnchorMove(data.lightAnchor, proj.cell, newPos, proj)
end

local function onProjectileExpired(data)
    local proj = data.projectile
    local projectileId = data.projectileId
    if projectileId == nil and proj and proj:isValid() then
        projectileId = proj.id
    end
    if proj and proj:isValid() then
        proj:sendEvent('MagExp_StopSound')
        creationOwnership.retire(proj, 'finished projectile')
    end
    -- Clean up registries
    clearProjectileRegistries(projectileId)
    creationOwnership.retire(data.soundAnchor, 'sound anchor')
    creationOwnership.retire(data.lightAnchor, 'light anchor')
end

local function onProjectileCollision(data)
    local proj     = data.projectile
    local attacker = data.attacker
    local spellId  = data.spellId
    local target   = data.hitObject
    local hitPos   = data.hitPos
    local area     = data.area or 0
    local velocity = data.velocity or util.vector3(0,0,0)
    local impactSpeed = velocity:length()

    -- Registry lookups (Cleanup moved to end of function to allow event listeners access)
    local itemRecordId = (proj and proj.id and projectileItemRegistry[proj.id]) or data.itemRecordId
    local registryEntry = proj and proj.id and activeSpellRegistry[proj.id]
    local refMaxSpeed   = (registryEntry and registryEntry.maxSpeed) or (impactSpeed > 1000 and impactSpeed or 1500)
    local userData      = (registryEntry and registryEntry.userData) or data.userData
    local muteAudio     = data.muteAudio or false
    local muteLight     = data.muteLight or false


    if not attacker or not spellId or not hitPos then
        debugLog("ProjectileCollision: missing data")
        return
    end

    local spell = core.magic.spells.records[spellId] or core.magic.enchantments.records[spellId]
    local cell  = (proj and proj.cell) or (attacker and attacker.cell)

    local spellIsLockUnlock = false
    if spell and spell.effects then
        for _, eff in ipairs(spell.effects) do
            local eid = tostring(eff.id):lower()
            if STACK_CONFIG.LOCKABLE_EFFECTS[eid] then 
                spellIsLockUnlock = true 
                break
            end
        end
    end

    local effectIndexes = data.effectIndexes
    -- [ORDER: Detonation First]
    if area > 0 then
        detonateSpellAtPos(spellId, attacker, hitPos, cell, itemRecordId, effectIndexes, data.unreflectable, data.casterLinked, data.areaVfxRecId or data.vfxRecId, impactSpeed, refMaxSpeed, data.areaVfxScale, target, userData, muteAudio, muteLight, data.continuousVfx, data.effectScale, area)
    elseif not (target and target:isValid() and (target.type == types.NPC or target.type == types.Creature or target.type == types.Player)) then
        spawnProjectileImpactVfx(data, hitPos)
    end

    -- [ORDER: Interaction / Direct Hit Second]
    local isActor = target and target:isValid() and (target.type == types.NPC or target.type == types.Creature or target.type == types.Player)
    local isLockable = target and target:isValid() and (target.type == types.Door or target.type == types.Container)

if spellIsLockUnlock and isLockable then
    handleDoorLockUnlock(spellId, attacker, target, data.effectScale)
elseif isActor and not (types.Actor.objectIsInstance(target) and types.Actor.isDead(target)) then
    applySpellToActor(spellId, attacker, target, hitPos, false, itemRecordId, effectIndexes, data.unreflectable, data.casterLinked, userData, muteAudio, muteLight, data.continuousVfx, data.effectScale, data)
elseif not isActor and not isLockable and area == 0 then
    debugLog("[COLLISION] Non-actor hit detected for non-AOE spell")

    local impactSound = type(userData) == "table" and userData.impactSound or nil
    if not muteAudio and type(impactSound) == "string" and impactSound ~= "" then
        local soundAnchor = target and target:isValid() and target.enabled and target
            or (proj and proj:isValid() and proj.enabled and proj)
            or (attacker and attacker:isValid() and attacker.enabled and attacker)
        if soundAnchor then
            core.sound.playSound3d(impactSound, soundAnchor, { volume = 1.0 })
        end
    end
end
    -- [MAXYARI] Physics impulse on detonation
    if data.impactImpulse and data.impactImpulse > 0
       and target and target:isValid()
       and types.Actor.objectIsInstance(target) then
        local impDir = (data.velocity and data.velocity:length() > 0.01)
                       and data.velocity:normalize() or util.vector3(0, 1, 0)
        target:sendEvent('LuaPhysics_ApplyImpulse', {
            impulse = impDir * data.impactImpulse,
            culprit = attacker
        })
    end

    -- BROADCAST HIT EVENT (For primary projectile impact)
    -- impactSpeed and maxSpeed are forwarded so listeners
    -- can compute speed-scaled damage.
    fireMagicHitEvent({
        attacker      = attacker,
        target        = target,
        spellId       = spellId,
        hitPos        = hitPos,
        hitNormal     = data.hitNormal,
        velocity      = velocity,
        impactSpeed   = impactSpeed,
        maxSpeed      = refMaxSpeed,
        projectile    = proj,
        spellType     = core.magic.RANGE.Target,
        isAoE         = false,
        area          = area,
        -- The bolt carries the penalty it was launched with; a penalised hit
        -- must report the reduced magnitudes to listeners that hit from them.
        effectScale   = data.effectScale,
        effectIndex   = effectIndexes and effectIndexes[1],
        unreflectable = data.unreflectable,
        casterLinked  = data.casterLinked,
        userData      = userData,
        muteAudio     = muteAudio,
        muteLight     = muteLight
    })

    -- Final cleanup
    clearProjectileRegistries(data.projectileId or (proj and proj.id))

    if proj and proj:isValid() then
        proj:sendEvent('MagExp_StopSound')
        creationOwnership.retire(proj, 'finished projectile')
    end
    creationOwnership.retire(data.soundAnchor, 'sound anchor')
    creationOwnership.retire(data.lightAnchor, 'light anchor')
end

local function canCreateAnchor(data)
    local projectile = data and data.projectile
    local entry = projectile and projectile:isValid() and activeSpellRegistry[projectile.id]
    return entry and entry.projectile == projectile and entry.lifecycleCancelRequestedAt == nil
end

local function createSoundAnchor(data)
    if not canCreateAnchor(data) then return end
    local anchor = world.createObject(data.recordId, 1)
    creationOwnership.begin(anchor, 'sound anchor', data.projectile)
    anchor:teleport(data.projectile.cell, data.projectile.position)
    attachRequiredProjectileScript(anchor)
    anchor:sendEvent('MagExp_InitSound', { sound = data.sound, isSoundAnchor = true })
    data.projectile:sendEvent('MagExp_SetSoundAnchor', { anchor = anchor })
    creationOwnership.objects[anchor.id].ready = true
end

local function createLightAnchor(data)
    if not canCreateAnchor(data) then return end
    local recId = data.recordId
    if type(recId) == "table" then
        -- It's a light draft. Generate or retrieve instantiated dynamic record.
        local c = recId.color or util.vector3(1, 1, 1)
        local rad = recId.radius or 200
        local key = string.format("light_%d_%d_%d_%d", math.floor(c.x * 255), math.floor(c.y * 255), math.floor(c.z * 255), rad)
        if not cachedDynamicRecords[key] then
            local colorObj = (util.color and util.color.rgb) and util.color.rgb(c.x, c.y, c.z) or c
            local draft = types.Light.createRecordDraft({
                name = "MagExp Light",
                color = colorObj,
                radius = rad,
                isDynamic = true,
                isCarriable = false,
                isFire = false,
                flicker = false,
            })
            local newRec = world.createRecord(draft)
            cachedDynamicRecords[key] = newRec.id
        end
        recId = cachedDynamicRecords[key]
    end

    local anchor = world.createObject(recId, 1)
    creationOwnership.begin(anchor, 'light anchor', data.projectile)
    anchor:teleport(data.projectile.cell, data.projectile.position)
    attachRequiredProjectileScript(anchor)
    data.projectile:sendEvent('MagExp_SetLightAnchor', { anchor = anchor })
    creationOwnership.objects[anchor.id].ready = true
end

local function flushPauseWork()
    if core.isWorldPaused() then return end
    -- Take requests before invoking callbacks. Failed creation/casting may have
    -- partially succeeded: report it once and never blindly replay the request.
    for id, anchor in pairs(pauseWork.anchorFailures or {}) do
        if not anchor:isValid() then pauseWork.anchorFailures[id] = nil end
    end
    local casts = pauseWork.casts
    pauseWork.casts = {}
    pauseWork.castOverflowReported = false
    for _, data in ipairs(casts) do
        if data.attacker:isValid() then launchSpell(data) end
    end
    local moves = pauseWork.moves
    pauseWork.moves = {}
    for _, data in pairs(moves) do applyProjectileMove(data) end
    retryPendingProjectileMoves()
    for _, kind in ipairs({ 'sounds', 'lights' }) do
        local requests = pauseWork[kind]
        pauseWork[kind] = {}
        for _, data in pairs(requests) do
            if kind == 'sounds' then createSoundAnchor(data) else createLightAnchor(data) end
        end
    end
    local anchors = pauseWork.anchors
    pauseWork.anchors = {}
    pauseWork.anchorIds = {}
    for _, move in pairs(anchors) do
        if move.anchor:isValid() and (not move.projectile or canCreateAnchor(move)) then
            move.anchor:teleport(move.cell, move.position)
        end
    end
end

local function onCastRequest(data)
    -- Reject malformed messages before they enter the detached batch. Sources
    -- may be non-actors (traps/emitters), so do not impose an Actor-only contract.
    if type(data) ~= 'table' or type(data.attacker) ~= 'userdata'
        or type(data.spellId) ~= 'string' or data.spellId == ''
        or data.startPos == nil or data.direction == nil then
        print('[MagExp] Cast request rejected: expected object source, spellId, startPos and direction')
        return
    end
    if not core.isWorldPaused() then return launchSpell(data) end
    if #pauseWork.casts < MAX_PAUSED_CAST_REQUESTS then
        pauseWork.casts[#pauseWork.casts + 1] = data
    elseif not pauseWork.castOverflowReported then
        pauseWork.castOverflowReported = true
        print('[MagExp] Paused cast queue full; further requests rejected until resume.')
    end
end

local function onUpdate(dt)
    creationOwnership.update()
    sweepProjectileLifecycles()
    flushPauseWork()
    -- Displacement first, so the other sweeps see a clean active-spell
    -- list the frame after a new summon/bound effect lands (a cast this
    -- script applied already displaced its rivals at apply time; this
    -- catches the engine-native casts).
    sweepBoundSummonDisplacement(core.getSimulationTime())
    sweepReducedBoundItems()
    sweepReducedCasts()

    local player = world.players[1]
    if player and player:isValid() then
        local currentCell = player.cell.name
        if lastPlayerCell ~= currentCell then
            if lastPlayerCell ~= nil then
                heightCache = {}
                debugLog("[CACHE] Cell changed. Wiping height cache.")
            end
            lastPlayerCell = currentCell
        end
    end

 -- [NEW] continuousVFX Actor Registry Cleanup
 for actorId, regData in pairs(continuousVfxActors) do
    local actor = regData.actor
    local spellId = regData.spellId
    local vfxTag = regData.vfxTag
    
    if not actor or not actor:isValid() then
        debugLog("[continuousVFX Registry] Removing invalid actor:", actorId)
        continuousVfxActors[actorId] = nil
     else
        local isActive = false
        local activeSpells = types.Actor.activeSpells(actor)
        if activeSpells then
            for _, inst in pairs(activeSpells) do
                if inst.id == spellId then isActive = true; break end
            end
        end
        
        if not isActive then
            debugLog(string.format("[continuousVFX Registry] Removing VFX %s from %s (spell expired)", vfxTag, actor.recordId or "unknown"))
            
            -- Send RemoveVfx event to actor's local script
            actor:sendEvent('RemoveVfx', vfxTag)
            
            -- Also clean world.vfx registry (for cast glow spawned via world.vfx.spawn)
            world.vfx.remove(vfxTag)
            
            continuousVfxActors[actorId] = nil
            debugLog("[continuousVFX Registry] Unregistered actor:", actorId)
        end
    end
end

 -- [PERSISTENT VFX CLEANUP] Pulsed every 0.1s (legacy system)
 local gameTime = core.getSimulationTime()
 if not MagExp_NextCleanup or gameTime > MagExp_NextCleanup then
    MagExp_NextCleanup = gameTime + 0.1
    for targetId, spells in pairs(activeVfxRegistry) do
        local anyRemaining = false
        for regKey, val in pairs(spells) do
            local tgt, spellKey, removeVfxId
            if type(val) == "table" and val.target ~= nil and val.spellId ~= nil then
                tgt = val.target
                spellKey = val.spellId
                removeVfxId = regKey
            else
                tgt = val
                spellKey = regKey
                removeVfxId = "MagExp_" .. tostring(regKey)
            end

            if not tgt or not tgt:isValid() then
                spells[regKey] = nil
            else
                local isActive = false
                local as = types.Actor.activeSpells(tgt)
                if as then
                    for _, inst in pairs(as) do
                        if inst.id == spellKey then
                            isActive = true
                            break
                        end
                    end
                end

                if not isActive then
                    debugLog(string.format("[VFX Cleanup] Removing VFX '%s' from %s (spell: %s)", removeVfxId, tgt.recordId or "unknown", spellKey))
                    
                    -- Send RemoveVfx event to actor's local script (handles anim-based VFX)
                    tgt:sendEvent('RemoveVfx', removeVfxId)
                    
                    -- Also clean world.vfx registry (for world-spawned VFX)
                    world.vfx.remove(removeVfxId)
                    
                    spells[regKey] = nil
                else
                    anyRemaining = true
                end
            end
        end
        if not anyRemaining then activeVfxRegistry[targetId] = nil end
    end
end
end

-- ============================================================
-- PUBLIC INTERFACE + ENGINE HANDLERS
-- ============================================================
--- Public interface implementation
local MagExpPublicInterface = {
    --- Version of the OMW_MagExp framework.
    version = 1.0,
    motionPathVersion = 1,
    Helpers = Helpers,

    --- Launch a spell projectile (or apply Self/Touch immediately).
    -- @param data table: { attacker, spellId, startPos, direction, isFree?, speed? }
    launchSpell = launchSpell,

    --- Apply spell effects directly to an actor.
    -- @param spellId string, caster Actor, target Actor, hitPos vector3, isAoe boolean, itemObject Object, forcedEffects table, unreflectable boolean, casterLinked boolean, userData table, muteAudio boolean, muteLight boolean, continuousVfx boolean
    applySpellToActor = applySpellToActor,

    --- Helper: Emit a spell projectile directly from a non-actor object (like a door, trap, activator, or script).
    -- @param data table: { source=Object, spellId=string, startPos=Vector3 (optional, defaults to source center), direction=Vector3, speed=number (optional) }
    emitProjectileFromObject = function(data)
        if not data.source or not data.spellId or not data.direction then return end
        
        local pos = data.startPos
        if not pos then
            pos = data.source:getBoundingBox().center
            if not pos then pos = data.source.position end
        end

        return launchSpell({
            attacker  = data.source, -- Sent as custom source (sanitized safely by engine logic)
            spellId   = data.spellId,
            startPos  = pos,
            direction = data.direction,
            -- Leave nil so launchSpell auto-detects the vanilla effect speed.
            speed     = data.speed,
            isFree    = true,  -- Objects don't use magicka
            spellType = core.magic.RANGE.Target, -- Forces projectile behavior
            bounceEnabled    = data.bounceEnabled,
            bounceMax        = data.bounceMax,
            bouncePower      = data.bouncePower,
            maxSpeed         = data.maxSpeed,
            accelerationExp  = data.accelerationExp,
            vfxRecId         = data.vfxRecId,
            boltModel        = data.boltModel,
            projectileScale  = data.projectileScale,
            boltSound        = data.boltSound,
            boltLightId      = data.boltLightId,
            impactImpulse    = data.impactImpulse,
            maxLifetime      = data.maxLifetime,
            spawnOffset      = data.spawnOffset,
            collisionMode    = data.collisionMode
        })
    end,

    --- Register an effect ID to use persistent looping visuals (e.g. Shield).
    -- @param effectId string
    registerPersistentEffect = function(id)
        if id then STACK_CONFIG.PERSISTENT_EFFECTS[id:lower()] = true end
    end,

    --- Register a magic effect ID to allow spells containing it to interact with Doors and Containers (Lockables).
    -- @param effectId string
    registerLockableEffect = function(id)
        if id then STACK_CONFIG.LOCKABLE_EFFECTS[id:lower()] = true end
    end,

    --- Register a magic effect ID to allow spells containing it to interact with ANY object (Statics, Activators, etc.).
    -- This ensures Touch spells can hit anything and emit a MagExp_OnMagicHit event for custom scripts.
    -- @param effectId string
    registerUniversalEffect = function(id)
        if id then STACK_CONFIG.UNIVERSAL_EFFECTS[id:lower()] = true end
    end,

    --- Trigger an AoE blast at a world position.
    -- @param spellId string, caster Actor, pos vector3, cell Cell, itemObject Object, forcedEffects table, unreflectable boolean, casterLinked boolean, vfxOverride string, impactSpeed number, maxSpeed number, areaVfxScale number, excludeTarget Object, userData table, muteAudio boolean, muteLight boolean, continuousVfx boolean, effectScale number, areaOverride number
    -- effectScale is the quick-cast penalty the cast was reduced with: callers
    -- that know it (OSSC passes it with its cast request) must forward it, so the
    -- blast's radius and every published magnitude match the reduced effects.
    -- areaOverride is an already-resolved area in feet; when given it wins over
    -- the record lookup, so a caller that scaled the area itself is never
    -- scaled twice.
    detonateSpellAtPos = detonateSpellAtPos,

    --- Apply scroll consumption or enchantment charge deduction. Must run from global script context;
    --- player scripts should call this via I.MagExp.applyResourceConsumption(actor, data).
    -- @param data table: { itemCountCost?, itemRecordId?, itemChargeCost? }
    applyResourceConsumption = magExpApplyInventoryResourceConsumption,

    --- Register a custom target filter. Returns true/false to allow/block hits.
    addTargetFilter = function(f) table.insert(customFilters, f) end,
    -- Deprecated but kept for backward compatibility:
    setTargetFilter = function(f) table.insert(customFilters, f) end,
    STACK_CONFIG = STACK_CONFIG,

    --- Lifecycle hooks (to be overridden by other mods)
    onEffectApplied    = function(actor, effect) end,
    onEffectTick       = function(actor, effect) end,
    onEffectOver       = function(actor, effect) end,
    --- Bounce hook (to be overridden by other mods)
    onProjectileBounce = function(data) end,
    --- Pierce hook (to be overridden by other mods)
    onProjectilePierce = function(data) end,

    -- ----------------------------------------------------------------
    -- In-flight Spell Control API
    -- ----------------------------------------------------------------

    --- Get full state snapshot of a live spell projectile.
    --- Reply arrives as global event 'MagExp_SpellState' with matching tag.
    getSpellState = function(projId, tag)
        local e = activeSpellRegistry[projId]
        if e and e.projectile:isValid() then
            e.projectile:sendEvent('MagExp_GetState', { tag = tag })
        end
    end,

    --- Mutate any physics property of a spell currently in flight.
    --- All fields optional; only provided keys are applied.
    setSpellPhysics = function(projId, data)
        local e = activeSpellRegistry[projId]
        if e and e.projectile:isValid() then
            e.projectile:sendEvent('MagExp_SetPhysics', data)
            -- Keep the global lifecycle backstop aligned with local mutations.
            if data.maxSpeed then e.maxSpeed = data.maxSpeed end
            if data.maxLifetime ~= nil then e.maxLifetime = data.maxLifetime end
            if data.isPaused ~= nil then e.isPaused = data.isPaused == true end
        end
    end,

    --- Redirect a spell projectile toward a new direction vector (speed is preserved).
    redirectSpell = function(projId, newDirection)
        local e = activeSpellRegistry[projId]
        if e and e.projectile:isValid() then
            e.projectile:sendEvent('MagExp_SetPhysics', { direction = newDirection })
        end
    end,

    --- Reposition a live projectile within its current cell without tracing
    --- the skipped path. Optional velocity/direction/speed changes are applied
    --- atomically by the projectile's local simulation.
    warpSpell = function(projId, data)
        local e = activeSpellRegistry[projId]
        if not (e and e.projectile:isValid() and type(data) == "table" and (data.position or data.pos)) then
            return false
        end
        e.projectile:sendEvent('MagExp_WarpProjectile', data)
        return true
    end,

    --- Override the current speed of a spell projectile without changing its direction.
    setSpellSpeed = function(projId, newSpeed)
        local e = activeSpellRegistry[projId]
        if e and e.projectile:isValid() then
            e.projectile:sendEvent('MagExp_SetPhysics', { speed = newSpeed })
        end
    end,

    --- Pause or resume a spell projectile.
    setSpellPaused = function(projId, paused)
        local e = activeSpellRegistry[projId]
        if e and e.projectile:isValid() then
            e.projectile:sendEvent('MagExp_SetPhysics', { isPaused = paused })
            e.isPaused = paused == true
        end
    end,

    --- Force-cancel and remove a live spell projectile.
    cancelSpell = function(projId)
        local e = activeSpellRegistry[projId]
        if e and e.projectile and e.projectile:isValid() then
            if e.lifecycleCancelRequestedAt ~= nil then return end
            -- Reject already-delivered movement and anchor creation immediately;
            -- the local cancellation event still owns terminal notification.
            e.lifecycleCancelRequestedAt = core.getSimulationTime()
            pauseWork.moves[projId] = nil
            pauseWork.sounds[projId] = nil
            pauseWork.lights[projId] = nil
            pendingProjectileMoves[projId] = nil
            e.projectile:sendEvent('MagExp_ForceCancel')
        end
    end,

    --- Configure bounce behaviour on a live spell projectile.
    setSpellBounce = function(projId, enabled, bounceMax, bouncePower)
        local e = activeSpellRegistry[projId]
        if e and e.projectile:isValid() then
            e.projectile:sendEvent('MagExp_SetPhysics', {
                bounceEnabled = enabled,
                bounceMax     = bounceMax  or 0,
                bouncePower   = bouncePower or 0.7,
            })
        end
    end,

    --- Toggle whether a bouncing spell detonates on actor contact.
    setSpellDetonateOnActor = function(projId, value)
        local e = activeSpellRegistry[projId]
        if e and e.projectile:isValid() then
            e.projectile:sendEvent('MagExp_SetPhysics', { detonateOnActorHit = value })
        end
    end,

    --- Toggle piercing and/or change pierce cap on a live spell projectile.
    setSpellPiercing = function(projId, enabled, newLimit)
        local e = activeSpellRegistry[projId]
        if e and e.projectile:isValid() then
            e.projectile:sendEvent('MagExp_SetPhysics', {
                piercing = enabled,
                pierceLimit = newLimit
            })
        end
    end,

    --- Get all IDs of currently active MagExp spell projectiles.
    getActiveSpellIds = function()
        local ids = {}
        for id, _ in pairs(activeSpellRegistry) do table.insert(ids, id) end
        return ids
    end,

    -- ----------------------------------------------------------------
    -- Projectile speed parity settings
    -- ----------------------------------------------------------------

    --- Mirrors OpenMW's "normalise race speed" launcher setting for magic
    --- projectiles, with the exact same meaning: true === the race weight IS
    --- normalised (every race casts bolts at the same speed); false === the
    --- race weight is NOT normalised (bolt speed differs by race, the vanilla
    --- Morrowind default).
    getNormaliseRaceSpeed = function()
        return magExpSettings.normaliseRaceSpeed
    end,

    --- Set the SFP "normalise race speed" behaviour at runtime.
    --- Persisted to SettingsMagExp_General.NormaliseRaceSpeed.
    setNormaliseRaceSpeed = function(enabled)
        magExpSettings.normaliseRaceSpeed = (enabled == true)
        storage.globalSection('SettingsMagExp_General'):set('NormaliseRaceSpeed', magExpSettings.normaliseRaceSpeed)
        debugLog(string.format("NormaliseRaceSpeed set to %s", tostring(magExpSettings.normaliseRaceSpeed)))
    end,

    -- ----------------------------------------------------------------
    -- [FEATURE 5] Custom Cast Animation API
    -- ----------------------------------------------------------------

    --- Blend mask constants for launchSpellAnim.
    BLEND_MASK = {
        LowerBody  = 1,   -- Bip01 pelvis and below
        Torso      = 2,   -- Bip01 Spine1 and up, excluding arms
        LeftArm    = 4,   -- Bip01 L Clavicle and out
        RightArm   = 8,   -- Bip01 R Clavicle and out
        UpperBody  = 14,  -- Bip01 Spine1 and up, including arms
        All        = 15,  -- All bones
    },

    --- Animation scheduling priority constants for launchSpellAnim.
    PRIORITY = {
        Default             = 0,
        WeaponLowerBody     = 1,
        SneakIdleLowerBody  = 2,
        SwimIdle            = 3,
        Jump                = 4,
        Movement            = 5,
        Hit                 = 6,
        Weapon              = 7,   -- Default for spell casts
        Block               = 8,
        Knockdown           = 9,
        Torch               = 10,
        Storm               = 11,
        Death               = 12,
        Scripted            = 13,
    },

    --- Play a custom animation on an actor as part of the spell cast lifecycle.
    -- Both isCharged=true and isCharged=false spells fire at the 'release' text key.
    -- @param data table: { actor, animGroup, blendMask?, priority?, isCharged?, chargeKey?, onRelease? }
    launchSpellAnim = function(data)
        if not data or not data.actor or not data.animGroup then return end
        if not data.actor:isValid() then return end
        data.actor:sendEvent('MagExp_PlaySpellAnim', {
            animGroup  = data.animGroup,
            blendMask  = data.blendMask  or 15,
            priority   = data.priority   or 7,
            startLoop  = data.startLoop  or false,
            isCharged  = data.isCharged  or false,
            chargeKey  = data.chargeKey,
            onRelease  = data.onRelease,
        })
    end,

    --- Gracefully release a looping or charged spell animation.
    -- Does NOT cancel abruptly. Progresses the animation to the 'release' text key,
    -- which fires the spell naturally, then proceeds to 'stop'.
    -- @param actor Actor
    -- @param animGroup string
    stopSpellAnim = function(actor, animGroup)
        if actor and actor:isValid() then
            actor:sendEvent('MagExp_ReleaseSpellAnim', { animGroup = animGroup })
        end
    end,


    
    -- ----------------------------------------------------------------
    -- [FEATURE 6] Cross-Mod Charge Key Binding
    -- ----------------------------------------------------------------

    --- Register a key-held predicate for a charged spell.
    -- Call from a player script. The function must return true while the key is held.
    -- @param keyId string  Unique ID (e.g. "MyMod_ChargeKey")
    -- @param isPressFn function  Returns true while key is held (uses input.isKeyPressed etc.)
    registerChargeKey = function(keyId, isPressFn)
        if keyId and type(isPressFn) == "function" then
            chargeKeyRegistry[keyId] = isPressFn
        end
    end,

    --- Query whether a registered charge key is currently held.
    -- NOTE: Must only be called from player scripts — uses player-side input API internally.
    -- @param keyId string
    -- @return boolean
    isChargeKeyHeld = function(keyId)
        local fn = chargeKeyRegistry[keyId]
        if fn then
            -- registerChargeKey already type-checks the registration, so `fn`
            -- is a function. If calling it raises, that is the registering
            -- mod's bug, and swallowing it here would only make the key look
            -- permanently unheld with nothing in the log to explain why.
            local result = fn()
            return result or false
        end
        return false
    end,

    --- Internal: expose registry for player script polling in onUpdate.
    _chargeKeyRegistry = chargeKeyRegistry,
}

-- ============================================================
-- PUBLIC INTERFACE + ENGINE HANDLERS
-- ============================================================
return {
    interfaceName = "MagExp",
    interface = MagExpPublicInterface,
    engineHandlers = {
        onUpdate = onUpdate,
        onSave = creationOwnership.save,
        onLoad = creationOwnership.load,
    },
    eventHandlers = {
        --- Inventory scroll/charge consumption from player scripts (must run globally).
        -- data: { attacker, item?, itemCountCost?, itemRecordId?, itemChargeCost? }
        MagExp_ApplyInventoryConsume = function(data)
            local actor = data and (data.attacker or data.actor)
            if actor then magExpApplyInventoryResourceConsumption(actor, data) end
        end,

        --- Main spell launch event. Usable from player scripts via core.sendGlobalEvent.
        MagExp_CastRequest         = onCastRequest,
        MagExp_ProjectileMove      = onProjectileMove,
        MagExp_ProjectileExpired   = function(data) debugLog("Projectile EXPIRED: " .. tostring(data.spellId or "nil")); onProjectileExpired(data) end,
        MagExp_ProjectileCollision = function(data) debugLog("Projectile COLLISION: " .. tostring(data.spellId or "nil") .. " with " .. tostring(data.hitObject or "world")); onProjectileCollision(data) end,

        --- Bounce event: forwarded from local script on each wall reflection.
        MagExp_OnProjectileBounce  = function(data)
            if MagExpPublicInterface and MagExpPublicInterface.onProjectileBounce then
                MagExpPublicInterface.onProjectileBounce(data)
            end
        end,

        --- Pierce event: forwarded from local script when piercing through actors.
        MagExp_OnProjectilePierce = function(data)
            -- Apply spell effects to pierced actor
            if data.hitObject and data.hitObject:isValid() then
                applySpellToActor(
                    data.spellId,
                    data.attacker,
                    data.hitObject,
                    data.hitPos,
                    false, -- not AoE
                    nil, -- no item object
                    data.effectIndexes,
                    data.unreflectable,
                    data.casterLinked,
                    data.userData,
                    data.muteAudio,
                    data.muteLight,
                    data.continuousVfx,
                    data.effectScale,
                    data
                )
            end

            -- Call user hook
            if MagExpPublicInterface and MagExpPublicInterface.onProjectilePierce then
                MagExpPublicInterface.onProjectilePierce(data)
            end
        end,

        --- State snapshot reply: passthrough for other global scripts to listen to.
        MagExp_SpellState = function(data) end,

        --- A summoned actor's own local script (magexp_actor_stats.lua) has
        --- applied the quick-cast penalty to its stats and is telling us the
        --- token is done, so the post-spawn sweep can stop re-asking.  Writing
        --- those stats from here is refused by the engine (self-only binding),
        --- which is why the confirmation - not the request - is the truth.
        MagExp_StatScaleApplied = function(data)
            markStatScaleConfirmed(data and data.token)
            if data then
                debugLog(string.format(
                    'Effect penalty: %s reports stats scaled to %d%% (%s stat(s), token %s)',
                    tostring(data.recordId or data.objectId),
                    math.floor((tonumber(data.scale) or 1) * 100 + 0.5),
                    tostring(data.stats or '?'), tostring(data.token)))
            end
        end,

        --- The actor's own local script (magexp_local_equip.lua, wired by
        --- magexp_actor_stats.lua on a summon and magexp_player.lua on the
        --- player) has applied - or refused - a reduced-item slot swap.  Only
        --- an actor's own script may write its equipment, so this report is
        --- what lets the sweep remove the full-strength original and stop
        --- re-asking.
        MagExp_EquipReducedItemApplied = function(data)
            if not data then return end
            if data.ok == false then
                reportItemSwapRefused(data)
                return
            end
            markItemSwapConfirmed(data.token)
        end,

        MagExp_AnchorTeleport      = function(data)
            if data.lightAnchor and data.lightAnchor:isValid() then
                queueAnchorMove(data.lightAnchor, data.cellName or data.lightAnchor.cell, data.pos, data.projectile)
            end
            if data.soundAnchor and data.soundAnchor:isValid() then
                queueAnchorMove(data.soundAnchor, data.cellName or data.soundAnchor.cell, data.pos, data.projectile)
            end
        end,

        MagExp_CreateSoundAnchor = function(data)
            if data.lightAnchor and data.lightAnchor:isValid() then queueAnchorMove(data.lightAnchor, data.lightAnchor.cell, data.pos, data.projectile) end
            if data.soundAnchor and data.soundAnchor:isValid() then queueAnchorMove(data.soundAnchor, data.soundAnchor.cell, data.pos, data.projectile) end
            if canCreateAnchor(data) then pauseWork.sounds[data.projectile.id] = data end
        end,

        MagExp_CreateLightAnchor = function(data)
            if data.lightAnchor and data.lightAnchor:isValid() then queueAnchorMove(data.lightAnchor, data.lightAnchor.cell, data.pos, data.projectile) end
            if data.soundAnchor and data.soundAnchor:isValid() then queueAnchorMove(data.soundAnchor, data.soundAnchor.cell, data.pos, data.projectile) end
            if canCreateAnchor(data) then pauseWork.lights[data.projectile.id] = data end
        end,
MagExp_CastStart = function(data)
    local attacker = data and data.attacker
    local spellId  = data and data.spellId
    if not attacker or not attacker:isValid() or not spellId then return end

    -- Throttle: avoid duplicates (play handler + key handler + your own calls)
    MagExp_CastStartThrottle = MagExp_CastStartThrottle or {}
    local now = core.getSimulationTime()
    local tkey = tostring(attacker.id) .. "::" .. tostring(spellId)
    if MagExp_CastStartThrottle[tkey] and (now - MagExp_CastStartThrottle[tkey]) < 0.20 then
        return
    end
    MagExp_CastStartThrottle[tkey] = now

    -- Resolve spell record (supports Generated:0x...)
    local spell = core.magic.spells.records[spellId] or core.magic.enchantments.records[spellId]
    if not spell then
        for _, rec in pairs(core.magic.spells.records) do
            local recId = rec.id
            if recId and tostring(recId):lower() == tostring(spellId):lower() then
                spell = rec
                break
            end
        end
    end
    if not spell or not spell.effects then
        debugLog("[CASTSTART] No spell/effects for", spellId)
        return
    end

    -- Ensure NPCs can respond to AddVfx/RemoveVfx (player already can)
    if attacker.type ~= types.Player then
        addScriptOnce(attacker, 'scripts/OMW_MagExp/magexp_actor_vfx.lua')
    end

    local function modelFromStaticId(staticId)
        if not staticId or staticId == "" then return nil end
        local rid = tostring(staticId):lower()
        local rec = types.Static.records[rid] or types.Weapon.records[rid]
        return rec and rec.model or nil
    end

    local function elementKeyOf(mgef, effIdFallback)
        local name = (mgef and mgef.name or ""):lower()
        local id   = (mgef and mgef.id   or effIdFallback or ""):lower()
        if name:find("fire") or id:find("fire") then return "fire" end
        if name:find("frost") or id:find("frost") or name:find("cold") or id:find("cold") then return "frost" end
        if name:find("shock") or id:find("shock") or name:find("lightning") or id:find("lightning") then return "shock" end
        if name:find("poison") or id:find("poison") then return "poison" end
        return nil
    end

    local function schoolKeyOf(mgef)
        local s = mgef and mgef.school
        if type(s) == "string" then return s:lower() end
        if type(s) == "number" then
            local map = { [0]="alteration",[1]="conjuration",[2]="destruction",[3]="illusion",[4]="mysticism",[5]="restoration" }
            return map[s] or "default"
        end
        return "default"
    end

    local function fallbackCastStaticId(mgef, effIdFallback)
        local element = elementKeyOf(mgef, effIdFallback)
        local school  = schoolKeyOf(mgef)
        local map = {
            fire        = "VFX_DefaultCast",
            frost       = "VFX_FrostCast",
            shock       = "VFX_LightningCast",
            poison      = "VFX_PoisonCast",
            alteration  = "VFX_AlterationCast",
            conjuration = "VFX_ConjureCast",
            destruction = "VFX_DestructCast",
            illusion    = "VFX_IllusionCast",
            mysticism   = "VFX_MysticismCast",
            restoration = "VFX_RestorationCast",
        }
        return map[element or ""] or map[school] or "VFX_DefaultCast"
    end

    debugLog(string.format("[CASTSTART] Spawning ROOT cast VFX for %s (%d effects)",
        tostring(spellId), #spell.effects))

    -- ROOT ONLY: boneName = "" (no hands)
    local rootBone = ""

    for i, eff in ipairs(spell.effects) do
        local mgef = core.magic.effects.records[eff.id]
        if mgef then
            -- Prefer correct OpenMW field (castStatic); fall back if missing
            local castStaticId = (mgef.castStatic and mgef.castStatic ~= "") and mgef.castStatic or fallbackCastStaticId(mgef, eff.id)
            local model = modelFromStaticId(castStaticId)

            local vfxId = string.format("MagExpCastStart_%s_%d_%s",
                tostring(spellId), i, tostring(eff.id):lower())

            debugLog(string.format("[CASTSTART] eff#%d id=%s castStatic=%s model=%s vfxId=%s",
                i, tostring(eff.id), tostring(castStaticId), tostring(model), tostring(vfxId)))

            if model then
                local delay = (i - 1) * 0.02
                async:newUnsavableSimulationTimer(delay, function()
                    if not attacker or not attacker:isValid() then return end

                    attacker:sendEvent('AddVfx', {
                        model = model,
                        options = {
                            loop = false,
                            boneName = rootBone, -- ROOT
                            particleTextureOverride = mgef.particle or "",
                            vfxId = vfxId,
                            useAmbientLight = true,
                        }
                    })

                    async:newUnsavableSimulationTimer(1.2, function()
                        if attacker and attacker:isValid() then
                            attacker:sendEvent('RemoveVfx', vfxId)
                        end
                    end)
                end)
            end
        end
    end
end,
MagExp_ProcessCast = function(data)
    local actor = data and data.actor
    if not actor or not actor:isValid() then return end

    local spellId = data.spellId
    local isEnchant = false
    local spell = core.magic.spells.records[spellId]
    if not spell then
        isEnchant = true
        spell = core.magic.enchantments.records[spellId]
    end
    if not spell then return end
    --TODO: add option to override the spell cost and affect cast chance?
    local chance = isEnchant and 100 or Helpers.getSpellCastChance(spellId, actor, {isGodMode = data.isGodMode})
    local success = chance > 0 and ((chance >= 100) or (math.random(0, 99) < chance))

    if not success then
        actor:sendEvent('MagExp_CastResult', { spellId = spellId, success = false })
        if actor.enabled then
            core.sound.playSound3d("spell failure destruction", actor)
        end
        return
    end

    local function schoolKeyOf(mgef)
        local s = mgef and mgef.school
        if type(s) == "string" then return s:lower() end
        if type(s) == "number" then
            local map = {
                [0] = "alteration",
                [1] = "conjuration",
                [2] = "destruction",
                [3] = "illusion",
                [4] = "mysticism",
                [5] = "restoration",
            }
            return map[s] or "default"
        end
        return "default"
    end

    local function elementKeyOf(mgef, effIdFallback)
        local name = (mgef and mgef.name or ""):lower()
        local id   = (mgef and mgef.id   or effIdFallback or ""):lower()
        if name:find("fire") or id:find("fire") then return "fire" end
        if name:find("frost") or id:find("frost") or name:find("cold") or id:find("cold") then return "frost" end
        if name:find("shock") or id:find("shock") or name:find("lightning") or id:find("lightning") then return "shock" end
        if name:find("poison") or id:find("poison") then return "poison" end
        return nil
    end

    local function modelFromStaticId(staticId)
        if not staticId or staticId == "" then return nil end
        local rid = tostring(staticId):lower()
        local rec = types.Static.records[rid] or types.Weapon.records[rid]
        return (rec and rec.model) or nil
    end

    local function resolveCastStaticId(mgef, elementKey, schoolKey)
        -- Correct OpenMW field:
        local sid = mgef.castStatic
        if sid and sid ~= "" then return sid end

        -- Fallback map (only if castStatic missing):
        local map = {
            fire        = "VFX_DefaultCast",
            frost       = "VFX_FrostCast",
            shock       = "VFX_LightningCast",
            poison      = "VFX_PoisonCast",

            alteration  = "VFX_AlterationCast",
            conjuration = "VFX_ConjureCast",
            destruction = "VFX_DestructCast",
            illusion    = "VFX_IllusionCast",
            mysticism   = "VFX_MysticismCast",
            restoration = "VFX_RestorationCast",
        }
        return map[elementKey or ""] or map[schoolKey or ""] or "VFX_DefaultCast"
    end

    local function resolveCastSound(mgef, elementKey, schoolKey)
        if mgef.castSound and mgef.castSound ~= "" then
            return mgef.castSound
        end
        local map = {
            fire        = "destruction cast",
            frost       = "frost cast",
            shock       = "shock cast",
            poison      = "destruction cast",
            alteration  = "alteration cast",
            conjuration = "conjuration cast",
            destruction = "destruction cast",
            illusion    = "illusion cast",
            mysticism   = "mysticism cast",
            restoration = "restoration cast",
        }
        return map[elementKey or ""] or map[schoolKey or ""] or "destruction cast"
    end

    -- Build castVfx list: dedupe by castStaticId first (best), otherwise by element/school
    local castVfx = {}
    local seen = {}

    if spell.effects then
        for _, eff in ipairs(spell.effects) do
            local mgef = core.magic.effects.records[eff.id]
            if mgef then
                local schoolKey  = schoolKeyOf(mgef)
                local elementKey = elementKeyOf(mgef, eff.id)

                local castStaticId = resolveCastStaticId(mgef, elementKey, schoolKey)
                local model = modelFromStaticId(castStaticId)

                local key = (castStaticId and castStaticId ~= "" and tostring(castStaticId):lower())
                            or elementKey or schoolKey or "default"

                if not seen[key] then
                    seen[key] = true
                    table.insert(castVfx, {
                        key      = key,
                        model    = model,                -- may be nil if record missing
                        sound    = resolveCastSound(mgef, elementKey, schoolKey),
                        particle = mgef.particle or "",  -- texture id/path for override (optional)
                        element  = elementKey,
                        school   = schoolKey,
                    })
                end
            end
        end
    end

    actor:sendEvent('MagExp_CastResult', {
        spellId = spellId,
        success = true,
        item    = data.item,
        isFree  = data.isFree,
        castVfx = castVfx,   -- NEW: structured list the player will spawn
    })
end,

        --- Internal: Sync physics updates from local to global registry
        MagExp_UpdateRegistry = function(data)
            if not data or not data.projId then return end
            local e = activeSpellRegistry[data.projId]
            if e then
                if data.maxSpeed then e.maxSpeed = data.maxSpeed end
                if data.spellId  then e.spellId  = data.spellId  end
                if data.area     then e.area     = data.area     end
            end
        end,

MagExp_RemoveObject = function(obj)
    if not obj or not obj:isValid() then return end
    local projectileId = obj.id
    pauseWork.moves[projectileId] = nil
    pauseWork.sounds[projectileId] = nil
    pauseWork.lights[projectileId] = nil
    pauseWork.anchors[projectileId] = nil
    if pauseWork.anchorFailures then pauseWork.anchorFailures[projectileId] = nil end
    creationOwnership.retire(obj, 'requested removal')
end,

        MagExp_BreakInvisibility = function(data)
            local actor = data.actor
            if not actor or not actor:isValid() then return end
            local activeSpells = types.Actor.activeSpells(actor)
            if activeSpells then
                for spellId, spellInst in pairs(activeSpells) do
                    local hasInvis = false
                    local effsToCheck = spellInst.effects
                    if not effsToCheck then
                        local rId = spellInst.id or spellId
                        local rSpell = core.magic.spells.records[rId]
                        if rSpell then effsToCheck = rSpell.effects end
                    end
                    if effsToCheck then
                        for _, eff in pairs(effsToCheck) do
                            local eId = eff.id or eff.effectId
                            if type(eId) == "string" and eId:lower() == "invisibility" then
                                hasInvis = true; break
                            end
                        end
                    end
                    if hasInvis then
                        local removeId = spellInst.activeSpellId or spellInst.id or spellId
                        activeSpells:remove(removeId)
                    end
                end
            end
        end,
    }
}
