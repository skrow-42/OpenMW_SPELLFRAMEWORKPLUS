local core = require('openmw.core')
local util = require('openmw.util')
local types = require('openmw.types')
local I    = require('openmw.interfaces')

local Helpers = {}

Helpers.getBaseSpellCost = function(spellId, isEnchant)
    local cost = 0

    local spellRecord
    if isEnchant then
        spellRecord = core.magic.enchantments.records[spellId]
    else
        spellRecord = core.magic.spells.records[spellId]
    end
    if not spellRecord then return cost end

    if not spellRecord.autocalcFlag then
        return spellRecord.cost
    end

    for _, effect in ipairs(spellRecord.effects) do
        local minMagnitude, maxMagnitude = 1, 1
        local baseEffect = effect.effect

        if baseEffect.hasMagnitude then
            minMagnitude = effect.magnitudeMin
            maxMagnitude = effect.magnitudeMax
        end
        if not isEnchant then
            minMagnitude = math.max(1, minMagnitude)
            maxMagnitude = math.max(1, maxMagnitude)
        end

        local x = baseEffect.hasDuration and effect.duration or 1
        if not baseEffect.isAppliedOnce then
            x = math.max(x, 1)
        end
        x = x * 0.1 * baseEffect.baseCost
        x = x * 0.5 * (effect.magnitudeMin + effect.magnitudeMax)
        x = x + 0.05 * baseEffect.baseCost * effect.area
        if effect.range == core.magic.RANGE.Target then
            x = x * 1.5
        end
        x = x * core.getGMST('fEffectCostMult')
        x = math.max(0, x)

        cost = cost + x
    end

    return math.max(1, math.floor(cost + 0.5))
end

Helpers.getModifiedSpellCost = function(actor, spellId, isEnchant)
    local baseCost = Helpers.getBaseSpellCost(spellId, isEnchant)

    local cost = baseCost

    if isEnchant then
        local x = 0.01 * (110 - actor.type.stats.skills.enchant(actor).modified)
        cost = math.floor(x * cost)
        cost = math.max(cost, 1)
    end

    return cost
end

--- 
---@param spellId string
---@param actor table
---@param opts? {isGodMode?: boolean, cost?: number, ignoreFatigue? : boolean, costAlreadyPaid?: boolean}
Helpers.getSpellCastChance = function(spellId, actor, opts)
    local isGodMode = opts and opts.isGodMode
    local spellRecord = core.magic.spells.records[spellId]
    if not spellRecord then return 0 end
    
    local activeEffects = actor.type.activeEffects(actor)
    local isSilenced = activeEffects:getEffect(core.magic.EFFECT_TYPE.Silence).magnitude > 0

    if not (spellRecord.type == core.magic.SPELL_TYPE.Spell or spellRecord.type == core.magic.SPELL_TYPE.Power) then
        return (isSilenced and not isGodMode) and 0 or 100
    end

    if spellRecord.type == core.magic.SPELL_TYPE.Power then
        return (isSilenced and not isGodMode or not actor.type.spells(actor):canUsePower(spellId)) and 0 or 100 -- Powers can always be used if not on cooldown
    end

    if spellRecord.type == core.magic.SPELL_TYPE.Spell then
        local cost = 0

        local y = math.huge
        local lowestSkill = 0
        local effectiveSchool
        for _, effect in ipairs(spellRecord.effects) do
            local baseEffect = effect.effect
            local x = baseEffect.hasDuration and effect.duration or 1
            if not baseEffect.isAppliedOnce then
                x = math.max(x, 1)
            end
            x = x * 0.1 * baseEffect.baseCost
            x = x * 0.5 * (effect.magnitudeMin + effect.magnitudeMax)
            x = x + 0.05 * baseEffect.baseCost * effect.area
            if effect.range == core.magic.RANGE.Target then
                x = x * 1.5
            end
            x = x * core.getGMST('fEffectCostMult')

            cost = cost + x

            local s = 2 * actor.type.stats.skills[baseEffect.school](actor).modified
            if (s - x) < y then
                y = s - x
                effectiveSchool = baseEffect.school
                lowestSkill = s
            end
        end

        if not spellRecord.autocalcFlag then
            cost = spellRecord.cost
        else
            cost = math.max(1, math.floor(cost + 0.5))
        end

        if isGodMode then
            return 100, effectiveSchool
        end

        if isSilenced then
            return 0, effectiveSchool
        end

        if spellRecord.alwaysSucceedFlag then
            return 100, effectiveSchool
        end

        --try get overridden cost from opts
        cost = opts and opts.cost or cost
        
        local willpower = actor.type.stats.attributes.willpower(actor)
        local luck = actor.type.stats.attributes.luck(actor)

        -- Affordability gate: an actor without the magicka cannot cast at all.
        --
        -- It reads the CURRENT pool, which is the right question for every
        -- caller whose cast has not been paid for yet - the engine's own cast,
        -- SFP's cast pipeline, NPC casts: all of them roll the chance before
        -- anything is deducted, so a short pool means the attempt never
        -- happens.
        --
        -- It is the WRONG question for a caller that already paid for THIS
        -- cast: OSSC deducts the spell cost when the cast gesture starts
        -- (vanilla drains the pool at the start of the gesture, not at the
        -- release) and rolls the chance at the launch, so by then the pool no
        -- longer holds the cost. Re-checking here demanded the cost TWICE -
        -- a 5-cost spell with exactly 5 magicka paid its 5, "failed" the roll
        -- against a pool of 0 and never landed, and the next attempt was
        -- refused outright with "not enough magicka". Such a caller says so
        -- with opts.costAlreadyPaid; the cost still feeds the formula below
        -- exactly as before - only the pool check is skipped.
        if not (opts and opts.costAlreadyPaid) then
            local magicka = actor.type.stats.dynamic.magicka(actor)
            if magicka.current < cost then
                return 0, effectiveSchool
            end
        end

        local castBonus = -activeEffects:getEffect(core.magic.EFFECT_TYPE.Sound).magnitude
        local fatigueTerm = opts and opts.ignoreFatigue and 1 or Helpers.getFatigueTerm(actor)
        local castChance = (lowestSkill - util.round(cost) + castBonus + 0.2 * willpower.modified + 0.1 * luck.modified) * fatigueTerm

        return math.floor(util.clamp(castChance, 0.0, 100.0)), effectiveSchool
    end
end

local FATIGUE_BASE = core.getGMST('fFatigueBase')
local FATIGUE_MULT = core.getGMST('fFatigueMult')

---@param actor table
Helpers.getFatigueTerm = function(actor)
    local fatigue = actor.type.stats.dynamic.fatigue(actor)
    local normalizedFatigue
    if fatigue.base == 0 then
        normalizedFatigue = 1
    else
        normalizedFatigue = math.max(0, fatigue.current / fatigue.base)
    end

    return FATIGUE_BASE - FATIGUE_MULT * (1 - normalizedFatigue)
end

--- Resolves the vanilla race-weight multiplier OpenMW applies to magic bolt
--- speed for NPC-ish casters (player included): speed *= race weight.
---
--- OpenMW applies the caster's race weight to magic projectile speed only when
--- the "normalise race speed" launcher setting is off (the Morrowind default;
--- see ProjectileManager::updateMagicBolt).  SFP's own NormaliseRaceSpeed
--- setting mirrors that for quick-casts, so callers should only apply the
--- returned multiplier when NormaliseRaceSpeed is false.
---
--- The record lookups use the documented functions (types.NPC.record(object)
--- and types.NPC.races.record(raceId)); indexing the Races table directly
--- (types.NPC.races[raceId]) is NOT supported and silently returns nil.
---
---@param attacker table|nil Actor (NPC or Player)
---@return number|nil mult  gender-specific race weight (> 0), or nil
---@return string|nil raceId the resolved race record ID (for logging)
---@return table|nil npcRec the resolved NPC record (for diagnostics)
Helpers.getProjectileRaceWeight = function(attacker)
    if not attacker then return nil end
    if not (attacker.type == types.NPC or attacker.type == types.Player) then
        return nil
    end

    local npcRec
    if type(types.NPC.record) == "function" then
        npcRec = types.NPC.record(attacker)
    elseif types.NPC.records and attacker.recordId then
        npcRec = types.NPC.records[attacker.recordId]
    end
    if not npcRec then return nil end

    local raceId = npcRec.race
    if not raceId then return nil end

    local raceRec
    local races = types.NPC.races
    if races then
        if races.records then
            raceRec = races.records[raceId]
        end
        if not raceRec and type(races.record) == "function" then
            raceRec = races.record(raceId)
        end
    end
    if not raceRec or not raceRec.weight then return nil end

    local mult = npcRec.isMale and raceRec.weight.male or raceRec.weight.female
    if type(mult) == "number" and mult > 0 then
        return mult, raceId, npcRec
    end
    return nil
end

-- ────────────────────────────────────────────────────────────────────────────
-- Content-file presence
-- ────────────────────────────────────────────────────────────────────────────
-- True when the named content file is in the load order.
--
-- `core.contentFiles.has` is the engine's own lookup and is the correct way to
-- ask "is this mod installed". It is checked first; the scan over
-- `core.contentFiles.list` is a fallback that makes the answer independent of
-- how the engine happens to compare file name casing.
function Helpers.hasContentFile(fileName)
    local wanted = fileName:lower()
    if core.contentFiles.has(fileName) then return true end
    for _, name in ipairs(core.contentFiles.list or {}) do
        if type(name) == 'string' and name:lower() == wanted then return true end
    end
    return false
end

-- True when a loaded content file's name contains every fragment given.
--
-- `hasContentFile` needs the exact file name, which only works for mods whose
-- release file name is known up front. Where it is not, this looks for the
-- distinctive part of the name instead: names are folded to lowercase letters
-- and digits first, so case, spaces, underscores and the extension do not have
-- to be guessed ("Skill Uses Scaled.omwscripts", "skill_uses_scaled.omwaddon"
-- and "SkillUsesScaled.omwscripts" all match 'skillusesscaled').
--
-- Like hasContentFile, this answers from the load order alone — it never probes
-- a module that may not be installed, which is what makes a guarded `require`
-- safe to call without catching anything.
function Helpers.hasContentFileMatching(fragment, ...)
    local fragments = { fragment, ... }
    for i, part in ipairs(fragments) do
        if type(part) ~= 'string' or part == '' then return false end
        fragments[i] = part:lower():gsub('[^%a%d]', '')
    end
    for _, name in ipairs(core.contentFiles.list or {}) do
        if type(name) == 'string' then
            local folded = name:lower():gsub('[^%a%d]', '')
            local matched = true
            for _, part in ipairs(fragments) do
                if not folded:find(part, 1, true) then matched = false; break end
            end
            if matched then return true end
        end
    end
    return false
end

-- True when Oblivion Style Spell Casting is installed.
--
-- This deliberately does NOT probe `storage.playerSection('SettingsOSSC_General')`:
-- asking for a settings section CREATES it, so the probe reported OSSC as
-- installed on every machine that had ever loaded SFP - and SFP then skipped
-- its own player cast VFX, waiting for an OSSC that was not there to provide
-- it. Presence of the content file is the only signal that does not have that
-- side effect.
local OSSC_CONTENT_FILE = 'Oblivion Style Spell Casting OSSC.omwscripts'
local osscInstalledCache = nil

function Helpers.isOsscInstalled()
    if osscInstalledCache ~= nil then return osscInstalledCache end
    -- An interface would be an equally good signal and is checked first for
    -- forward compatibility, but no OSSC release registers one, so the content
    -- file check is what actually decides.
    if I.OSSC ~= nil then
        osscInstalledCache = true
    else
        osscInstalledCache = Helpers.hasContentFile(OSSC_CONTENT_FILE)
    end
    return osscInstalledCache
end

-- True when yksui SpeedyMagick is installed.
--
-- Same rule as isOsscInstalled: decided by the load order. The previous version
-- probed storage.playerSection('SettingsyksuiSpeedyMagick') and friends, which
-- created those sections on read and so reported SpeedyMagick as installed on
-- every machine. It also tried six candidate module paths one by one, catching
-- each failure — which is the one thing a content-file check makes unnecessary.
local SPEEDY_MAGICK_CONTENT_FILE = 'yksuiSpeedyMagick.omwscripts'
local speedyMagickCache = nil

function Helpers.isSpeedyMagickInstalled()
    if speedyMagickCache ~= nil then return speedyMagickCache end
    if I.SpeedyMagick ~= nil or I.yksuiSpeedyMagick ~= nil or I.yksui_speedy_magick ~= nil then
        speedyMagickCache = true
    else
        speedyMagickCache = Helpers.hasContentFile(SPEEDY_MAGICK_CONTENT_FILE)
    end
    return speedyMagickCache
end

return Helpers