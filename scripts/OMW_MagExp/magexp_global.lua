-- ============================================================
-- Magicka Expanded Framework for OpenMW v1.0 - skrow42
-- magexp_global.lua (GLOBAL script)
--
-- Public Interface: I.MagExp
-- Usage from another global script:
--   local I = require('openmw.interfaces')
--   I.MagExp.launchSpell({ attacker=..., spellId=..., startPos=..., direction=... })
--
-- Usage from a player script:
--   core.sendGlobalEvent('MagExp_CastRequest', { attacker=self, spellId=..., startPos=..., direction=... })
-- ============================================================

local world   = require('openmw.world')
local core    = require('openmw.core')
local types   = require('openmw.types')
local util    = require('openmw.util')
local storage = require('openmw.storage')
local I       = require('openmw.interfaces')
local async   = require('openmw.async')

local activeVfxRegistry      = {}
local projectileItemRegistry = {} -- [proj.id] = live item object, kept until projectile dies
local casterLinkedSpells     = {} -- list of {caster, target, spellId} for casterLinked effects
local customFilters          = {}
local trackedEffectRegistry  = {}
local cachedDynamicRecords   = {} -- [hash_key] = record_string_id

-- [FEATURE 6] Cross-mod charge key registry: [keyId] = isPressed function
-- Populated by player scripts via I.MagExp.registerChargeKey()
local chargeKeyRegistry = {}

--- Live projectile registry.
--- [proj.id] = { projectile, spellId, attacker, launchTime, maxSpeed }
--- Populated by launchSpell, removed on collision or expiry.
local activeSpellRegistry = {}

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

local function debugLog(msg)
    print("[MagExp] " .. tostring(msg))
end

-- ============================================================
-- [PORT] Morrowind Engine Success Formula (Binary Parity)
-- ============================================================
local function calcSpellBaseSuccessChance(spell, actor)
    local school = 0
    if spell.effects and spell.effects[1] then school = spell.effects[1].school end
    local skillValue = 0
    if types.NPC.stats.skills[school] then
        skillValue = types.Actor.stats.skills[school](actor).modified
    end
    local stats = types.Actor.stats
    local willpower = stats.attributes.willpower(actor).modified
    local luck = stats.attributes.luck(actor).modified
    return (skillValue * 2) + (willpower / 5) + (luck / 10) - spell.cost
end

local function getSpellSuccessChance(spell, actor, isGodMode)
    if isGodMode then return 100 end
    if types.Actor.getEffect(actor, "silence") > 0 then return 0 end
    local soundLevel = types.Actor.getEffect(actor, "sound")
    local baseChance = calcSpellBaseSuccessChance(spell, actor)
    local fatigue = types.Actor.stats.dynamic.fatigue(actor)
    local fatigueTerm = 1.0
    if fatigue.base > 0 then
        fatigueTerm = 0.75 + 0.5 * (fatigue.current / fatigue.base)
    end
    local chance = (baseChance - soundLevel) * fatigueTerm
    return math.max(0, math.min(100, math.floor(chance + 0.5)))
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
local function getSpellDamageInfo(spellId)
    local dt = { health = 0, magicka = 0, fatigue = 0 }
    local spell = core.magic.spells.records[spellId]
    if not (spell and spell.effects) then return dt end
    for _, eff in ipairs(spell.effects) do
        local mid = eff.id:lower()
        local mag = ((eff.magnitudeMin or 0) + (eff.magnitudeMax or eff.magnitudeMin or 0)) / 2
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

local function fireMagicHitEvent(data)
    -- data expects: attacker, target, spellId, hitPos, hitNormal, spellType, isAoE, area, velocity, projectile, userData
    local spellId = data.spellId
    local spell = core.magic.spells.records[spellId] or core.magic.enchantments.records[spellId]
    
    if not spell and spellId then
        -- Safe iterative fallback for numerical proxies or case-sensitivity edge cases
        for _, rec in pairs(core.magic.spells.records) do
            local ok, recId = pcall(function() return rec.id end)
            if ok and recId and tostring(recId):lower() == tostring(spellId):lower() then
                spell = rec
                break
            end
        end
        if not spell then
            for _, rec in pairs(core.magic.enchantments.records) do
                local ok, recId = pcall(function() return rec.id end)
                if ok and recId and tostring(recId):lower() == tostring(spellId):lower() then
                    spell = rec
                    break
                end
            end
        end
    end

    if not spell then return end

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
        damage       = getSpellDamageInfo(data.spellId),
        projectile   = data.projectile,
        velocity     = data.velocity or util.vector3(0,0,0),
        impactSpeed  = data.impactSpeed or 0,
        maxSpeed     = data.maxSpeed or 0,
        unreflectable = data.unreflectable or false,
        casterLinked = data.casterLinked or false,
        userData     = data.userData
    }

    -- Metadata detection (Strict Primary-Only to match vanilla engine)
    local firstEff = spell.effects and spell.effects[1]
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
                info.magMin = firstEff.magnitudeMin or 0
                info.magMax = firstEff.magnitudeMax or info.magMin
            end
        end
    end
    
    -- 2. Final Fallback: If no explicit damage was found but we have effects, use the first one's magnitude.
    -- This supports mods using 'Script Effect' or custom templates for metadata events.
    if info.magMax == 0 and firstEff then
        info.magMin = firstEff.magnitudeMin or 0
        info.magMax = firstEff.magnitudeMax or info.magMin
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
        pcall(function() MagExpPublicInterface.MagExp_OnMagicHit(info) end)
    end

    -- Send to target (local script) if actor
    if data.target and data.target:isValid() then
        data.target:sendEvent('MagExp_Local_MagicHit', info)

        -- Manual dispatch for specific school hit effects (Actors only)
        if types.Actor.objectIsInstance(data.target) and data.target.enabled and spell.effects and spell.effects[1] then
            pcall(function()
                local mgef = core.magic.effects.records[spell.effects[1].id]
                if mgef then
                    -- Hit Sound
                    local snd = mgef.school:lower() .. " hit"
                    data.target:sendEvent('PlaySound3d', { sound = snd })

                    -- Primary Hit Static (The flash/hit visual)
                    local vfxId = mgef.hitStatic
                    if vfxId and vfxId ~= "" then
                        local static = types.Static.records[vfxId]
                        if static and static.model then
                            data.target:sendEvent('AddVfx', {
                                model = static.model,
                                options = { mwMagicVfx = true }
                            })
                        end
                    end
                end
            end)
        end
    end
end

--- Internal dispatcher for effect lifecycle events.
--- Fires both the public interface callback and a global event.
local function fireEffectEvent(eventName, actor, effect)
    if MagExpPublicInterface and MagExpPublicInterface[eventName] then
        pcall(function() MagExpPublicInterface[eventName](actor, effect) end)
    end
    core.sendGlobalEvent('MagExp_' .. eventName:sub(1,1):upper() .. eventName:sub(2), { actor = actor, effect = effect })
end

-- ============================================================
-- [CORE] Authoritative Spell Application
-- ============================================================
local function applySpellToActor(spellId, caster, target, hitPos, isAoe, itemObject, forcedEffects, unreflectable, casterLinked, userData, muteAudio, muteLight)
    if not target or not target:isValid() then return end
    if not (caster and caster:isValid()) then caster = target end
    if target.type ~= types.NPC and target.type ~= types.Creature and target.type ~= types.Player then
        debugLog("applySpellToActor: Aborting - target is not an actor type")
        return
    end

    -- [DEAD ACTOR GATE] Must be first — before any VFX/sounds fire on the target
    if not checkTarget(target) then
        debugLog("[MagExp] Target Vetoed (dead or filtered): " .. tostring(target.recordId or target.id))
        return
    end

    print("MagExp: Applying " .. spellId .. " to " .. (target.recordId or "unknown") .. " by " .. (caster.recordId or "unknown"))

    local spell = core.magic.spells.records[spellId]
    local isEnchantment = false
    if not spell then
        spell = core.magic.enchantments.records[spellId]
        isEnchantment = true
    end
    -- Deep search fallback (proxy may be numerically indexed)
    if not spell then
        isEnchantment = false
        for _, rec in pairs(core.magic.spells.records) do
            local ok, recId = pcall(function() return rec.id end)
            if ok and recId and tostring(recId):lower() == tostring(spellId):lower() then
                spell = rec; break
            end
        end
    end
    if not spell then
        for _, rec in pairs(core.magic.enchantments.records) do
            local ok, recId = pcall(function() return rec.id end)
            if ok and recId and tostring(recId):lower() == tostring(spellId):lower() then
                spell = rec; isEnchantment = true; break
            end
        end
    end
    -- Effect-level fallback: synthesize minimal spell wrapper
    if not spell then
        local effRec = core.magic.effects.records[spellId]
        if not effRec then
            for _, rec in pairs(core.magic.effects.records) do
                local ok, recId = pcall(function() return rec.id end)
                if ok and recId and tostring(recId):lower() == tostring(spellId):lower() then
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
        debugLog("applySpellToActor: record not found: " .. tostring(spellId))
        return
    end

    -- Check for harmful and casterLinked flags
    local hasHarmful = false
    local hasCasterLinked = casterLinked or false
    if spell.effects then
        for _, eff in ipairs(spell.effects) do
            print("MagExp: Checking effect " .. eff.id)
            local mgef = core.magic.effects.records[eff.id]
            if mgef then
                if mgef.harmful then 
                    print("MagExp: Detected harmful effect: " .. eff.id)
                    hasHarmful = true
                end
                if mgef.casterLinked then 
                    print("MagExp: Detected casterLinked effect: " .. eff.id)
                    hasCasterLinked = true
                end
            else
                print("MagExp: No mgef for " .. eff.id)
            end
        end
    else
        print("MagExp: No effects in spell")
    end

    -- [SCHOOL VISUALS] Manual dispatch for schools that struggle with global application
    if spell.effects and spell.effects[1] then
        pcall(function()
            local mgef = core.magic.effects.records[spell.effects[1].id]
            if mgef then
                local eId = mgef.id:lower()
                local isPersistentEffect = STACK_CONFIG.PERSISTENT_EFFECTS[eId] == true
                local isPersistentLoop = isPersistentEffect and (spell.effects[1].duration or 0) > 0
                local vfxId = mgef.hitStatic
                
                if vfxId and vfxId ~= "" then
                    local static = types.Static.records[vfxId]
                    if static and static.model then
                        -- [CLEANUP REGISTRATION]
                        if isPersistentLoop then
                            if not activeVfxRegistry[target.id] then activeVfxRegistry[target.id] = {} end
                            activeVfxRegistry[target.id][spellId] = target
                        end

                        local vfxOptions = { mwMagicVfx = true } -- Engine-managed one-shot
                        if isPersistentLoop then
                            vfxOptions = { 
                                loop      = true, 
                                mwMagicVfx = false, 
                                vfxId     = "MagExp_" .. spellId 
                            }
                        end

                        if target.enabled then
                            target:sendEvent('AddVfx', {
                                model = static.model,
                                options = vfxOptions
                            })
                        end

                        -- [TIMER CLEANUP] AUTHORITATIVE REMOVAL
                        if isPersistentLoop then
                            local duration = spell.effects[1].duration or 30
                            async:newUnsavableSimulationTimer(duration, function()
                                if target and target:isValid() then
                                    target:sendEvent('RemoveVfx', "MagExp_" .. spellId)
                                end
                            end)
                        end
                    end
                end
                
                -- Play school sound
                if not muteAudio and target.enabled then
                    local snd = mgef.school:lower() .. " hit"
                    target:sendEvent('PlaySound3d', { sound = snd })
                end
            end
        end)
    end

    debugLog(string.format("Applying %s to %s", spellId, target.recordId or target.id))

    -- BROADCAST HIT EVENT (For Self/Touch spells that don't go through projectile logic)
    -- If isAoe is true, it means it's being applied via detonateSpellAtPos
    if not isAoe and spell and spell.effects and spell.effects[1] then
        local r = spell.effects[1].range
        if r == core.magic.RANGE.Self or r == core.magic.RANGE.Touch then
            fireMagicHitEvent({
                attacker  = caster,
                target    = target,
                spellId   = spellId,
                hitPos    = hitPos or target.position,
                spellType = r,
                isAoE     = false,
                area      = spell.effects[1].area or 0,
                unreflectable = unreflectable or false,
                userData  = userData,
                muteAudio = muteAudio,
                muteLight = muteLight
            })
        end
    end

    -- [FIX] Treat an empty table the same as nil so activeSpells:add always
    -- receives a populated list (or none at all, letting the engine use defaults).
    local effectIndexes = (forcedEffects and #forcedEffects > 0) and forcedEffects or nil
    if not effectIndexes and spell.effects then
        effectIndexes = {}
        for i, _ in ipairs(spell.effects) do
            table.insert(effectIndexes, i - 1)
        end
    end

    local ok, err = pcall(function()
        local activeSpells = types.Actor.activeSpells(target)
        if activeSpells then
            local params = {
                id      = spellId, -- Use the Enchantment/Spell ID so the engine plays persistent visuals (Shield, etc.)
                effects = effectIndexes,
            }
            if caster and caster:isValid() then 
                if types.NPC.objectIsInstance(caster) or types.Creature.objectIsInstance(caster) or types.Player.objectIsInstance(caster) then
                    params.caster = caster 
                end
            end

            -- Apply effects
            if isEnchantment then
                -- Provide the item source for mods that need it (like OSSC)
                if type(itemObject) == "string" and caster and caster:isValid() then
                    -- Resolve recordId string to a real item proxy if possible
                    pcall(function()
                        local inv = types.Actor.inventory(caster)
                        local found = inv:find(itemObject)
                        if found then itemObject = found end
                    end)
                end

                if itemObject and type(itemObject) ~= "string" and itemObject:isValid() then
                    params.item = itemObject
                end
                pcall(function() activeSpells:add(params) end)
            else
                local isStackable = false
                if (STACK_CONFIG.SPELL_LIMITS[spellId] or STACK_CONFIG.DEFAULT_LIMIT) > 1 then
                    isStackable = true
                end
                if isStackable then params.stackable = true end
                pcall(function() activeSpells:add(params) end)
            end
            local effCount = spell.effects and #spell.effects or 0
            debugLog(string.format("Successfully added %s (%d effect(s))", spellId, effCount))

            -- [TRACKING] Register spell for lifecycle events
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
                        local effInfo = {
                            id        = rawEff.id,
                            spellId   = spellId,
                            index     = idx,
                            magnitude = math.random(rawEff.magnitudeMin or 0, rawEff.magnitudeMax or rawEff.magnitudeMin or 0),
                            duration  = rawEff.duration or 0,
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

            -- [FEATURE 3] continuousVfx: register persistent cast VFX on the target.
            -- The VFX is tracked in activeVfxRegistry and cleaned up when the spell expires.
            if data and data.continuousVfx then
                if not activeVfxRegistry[target.id] then activeVfxRegistry[target.id] = {} end
                activeVfxRegistry[target.id][spellId] = target
                -- Spawn the cast glow VFX model attached to the target
                local pfx = spell and spell.effects and spell.effects[1] and spell.effects[1].id
                local pmgef = pfx and core.magic.effects.records[pfx]
                local castVfxId = (pmgef and pmgef.castVfx and pmgef.castVfx ~= "") and pmgef.castVfx or nil
                if castVfxId then
                    local rid = tostring(castVfxId):lower()
                    local rec = types.Static.records[rid] or types.Weapon.records[rid]
                    if rec and rec.model then
                        pcall(function()
                            world.vfx.spawn(rec.model, target.position, {
                                attachToObject = target,
                                mwMagicVfx = false,
                                tag = "MagExp_" .. spellId,
                            })
                        end)
                    end
                end
                debugLog(string.format("[continuousVfx] Registered persistent VFX for %s on %s", spellId, target.recordId))
            end

            -- Handle casterLinked effects: track for removal on caster death
            if hasCasterLinked then
                print("MagExp: Tracking casterLinked spell " .. spellId .. " on " .. target.recordId)
                table.insert(casterLinkedSpells, {caster = caster, target = target, spellId = spellId})
            end
        end
    end)
    if not ok then debugLog("Spell Application Error: " .. tostring(err)) end

    -- Visual Effects (Manual fallback)
    local ok2, err2 = pcall(function()
        local vfxPos = hitPos
        if not vfxPos or isAoe then
            local tStr = tostring(target.type)
            if tStr:find("NPC") or tStr:find("Creature") or tStr:find("Player") then
                local zOffset = heightCache[target.id]
                if not zOffset then
                    zOffset = 45 -- Lowered fallback significantly (waist level)
                    pcall(function()
                        local bbox = target:getBoundingBox()
                        if bbox then
                            zOffset = bbox.halfSize.z * 1.1 -- Roughly 0.55 of full height
                            if zOffset > 105 then zOffset = 65 end
                        end
                    end)
                    heightCache[target.id] = zOffset
                end
                vfxPos = target.position + util.vector3(0, 0, zOffset)
            else
                vfxPos = target.position
            end
        end

        if spell.effects and spell.effects[1] then
            local mgef = core.magic.effects.records[spell.effects[1].id]
            if mgef then
                -- 1. Determine school name 's' for VFX and sound fallbacks
                local schoolIdx = mgef.school
                local s = "destruction"
                if type(schoolIdx) == "string" then s = schoolIdx:lower()
                elseif type(schoolIdx) == "number" then
                    local schools = { [0]="alteration", [1]="conjuration", [2]="destruction", [3]="illusion", [4]="mysticism", [5]="restoration" }
                    s = schools[schoolIdx] or "destruction"
                end

                if not isAoe then
                    local hitVfxId = (mgef.hitVfx and mgef.hitVfx ~= "") and mgef.hitVfx or nil
                    if not hitVfxId then

                        -- 2. Detect Elemental Identity (regardless of school)
                        local n = (mgef.name or ""):lower()
                        local eid = tostring(mgef.id):lower()
                        local element = nil
                        if     n:find("fire")   or eid:find("fire")   then element = "Fire"
                        elseif n:find("frost")  or eid:find("frost")  or n:find("cold") or eid:find("cold") then element = "Frost"
                        elseif n:find("shock")  or eid:find("shock")  or n:find("lightn") then element = "Lightning"
                        elseif n:find("poison") or eid:find("poison") then element = "Poison"
                        end

                        -- 3. Resolve Hit VFX based on Priority: Element > School > Default
                        if element then
                            hitVfxId = "VFX_" .. element .. "Hit"
                        else
                            if s == "destruction" then hitVfxId = "VFX_DestructHit"
                            elseif s == "alteration"  then hitVfxId = "VFX_AlterationHit"
                            elseif s == "conjuration" then hitVfxId = "VFX_ConjureHit"
                            elseif s == "illusion"    then hitVfxId = "VFX_IllusionHit"
                            elseif s == "mysticism"   then hitVfxId = "VFX_MysticismHit"
                            elseif s == "restoration" then hitVfxId = "VFX_RestorationHit"
                            else hitVfxId = "VFX_DefaultHit" end
                        end

                        -- 4. Record Existence Sanity Check (Case-insensitive)
                        local lId = tostring(hitVfxId):lower()
                        if not (types.Static.records[lId] or types.Weapon.records[lId]) then
                            if hitVfxId:find("Hit") then 
                                hitVfxId = "VFX_DefaultHit" 
                            end
                        end
                    end

                    if hitVfxId then
                        local rid = tostring(hitVfxId):lower()
                        local rec = types.Static.records[rid] or types.Weapon.records[rid]
                        if rec and rec.model then
                            local opts = { mwMagicVfx = false }
                            -- Only attach if the target is still valid and enabled to avoid "disabled object" errors
                            if target:isValid() and target.enabled then
                                opts.attachToObject = target
                            end
                            world.vfx.spawn(rec.model, vfxPos, opts)
                        end
                    end
                end
                
                if not muteAudio and target.enabled then
                    local sndId = (mgef.hitSound and mgef.hitSound ~= "") and mgef.hitSound or (tostring(s):lower() .. " hit")
                    pcall(function() core.sound.playSound3d(sndId, target, { volume = 1.0 }) end)
                end
            end
        end
    end)
    if not ok2 then debugLog("VFX Logic Error: " .. tostring(err2)) end
end

local function getObjectCenter(obj)
    if not obj or not obj:isValid() then return nil, 0 end
    local pos = obj.position
    local ok, bbox = pcall(function() return obj:getBoundingBox() end)
    if ok and bbox then
        local r = (bbox.halfSize.x + bbox.halfSize.y) / 2
        return bbox.center, r
    end
    return pos, 0
end

-- ============================================================
-- [UTILITY] Door lock/unlock handling
-- ============================================================
local function handleDoorLockUnlock(spellId, caster, target)
    local isLockable = (target and (target.type == types.Door or target.type == types.Container))
    if not isLockable then return false end
    
    local spell = core.magic.spells.records[spellId] or core.magic.enchantments.records[spellId]
    if not spell or not spell.effects then return false end

    for _, eff in ipairs(spell.effects) do
        local eid = tostring(eff.id):lower()
        if eid == "open" or eid == "lock" then
            local magnitude = math.random(eff.magnitudeMin or 0, eff.magnitudeMax or eff.magnitudeMin or 0)
            -- print(string.format("[MagExp] Interaction: EID=%s, Mag=%d", eid, magnitude))
            if types.Lockable then
                local isLocked = types.Lockable.isLocked(target)
                local lockLvl = 0
                if types.Lockable.getLockLevel then lockLvl = types.Lockable.getLockLevel(target)
                elseif types.Lockable.lockLevel then lockLvl = types.Lockable.lockLevel(target) end
                -- print(string.format("[MagExp] Target: %s, Locked: %s, LockLvl: %d", target.recordId, tostring(isLocked), lockLvl))

                if target.enabled then
                    if eid == "open" then
                        if isLocked and magnitude >= lockLvl then
                            types.Lockable.unlock(target)
                            pcall(function() core.sound.playSound3d("Open Lock", target) end)
                            pcall(function() core.sound.playSound3d("alteration hit", target) end)
                        elseif isLocked then
                            pcall(function() core.sound.playSound3d("Open Lock Fail", target) end)
                            pcall(function() core.sound.playSound3d("alteration hit", target) end)
                        end
                    elseif eid == "lock" then
                        if not isLocked or magnitude > lockLvl then
                            types.Lockable.lock(target, magnitude)
                            pcall(function() core.sound.playSound3d("Open Lock", target) end)
                            pcall(function() core.sound.playSound3d("alteration hit", target) end)
                        end
                    end
                end

                local rid = "vfx_alteration_hit"
                local staticRecord = types.Static.records[rid] or types.Weapon.records[rid]
                if staticRecord and staticRecord.model then
                    world.vfx.spawn(staticRecord.model, target.position, { mwMagicVfx = false })
                end
            end
        end
    end
    return true
end

-- ============================================================
-- [AOE] Detonate spell at world position
-- ============================================================
local function detonateSpellAtPos(spellId, caster, pos, cell, itemObject, forcedEffects, unreflectable, casterLinked, vfxOverride, impactSpeed, maxSpeed, areaVfxScale, excludeTarget, userData, muteAudio, muteLight)
    local spell = core.magic.spells.records[spellId] or core.magic.enchantments.records[spellId]
    if not spell and spellId then
        -- Safe iterative fallback for numerical proxies or case-sensitivity edge cases
        for _, rec in pairs(core.magic.spells.records) do
            local ok, recId = pcall(function() return rec.id end)
            if ok and recId and tostring(recId):lower() == tostring(spellId):lower() then
                spell = rec; break
            end
        end
        if not spell then
            for _, rec in pairs(core.magic.enchantments.records) do
                local ok, recId = pcall(function() return rec.id end)
                if ok and recId and tostring(recId):lower() == tostring(spellId):lower() then
                    spell = rec; break
                end
            end
        end
    end
    if not (spell and spell.effects) then return end

    local maxArea = 0
    local AREA_MULT = (core.getGMST("fAreaRadiusMult") or 1.0) * 22.1

    if spell.effects and spell.effects[1] then
        maxArea = (spell.effects[1] and spell.effects[1].area) or 0
    end
    if maxArea <= 0 then return end

    local finalRadius = maxArea * AREA_MULT

    if spell.effects[1] then
        local mgef = core.magic.effects.records[spell.effects[1].id]
        if mgef then
            local areaStaticId = vfxOverride
            
            -- [SFP LOGIC] If no specific area VFX was provided, try to detect from record
            if not areaStaticId or areaStaticId == "" or areaStaticId == "VFX_DefaultArea" then
                if mgef and mgef.areaStatic ~= "" then
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
                    debugLog("[DETONATE] Missing Area VFX: " .. tostring(areaStaticId) .. " -- checking Hit fallback")
                    local hitId = areaStaticId:gsub("Area", "Hit")
                    if types.Static.records[hitId:lower()] or types.Weapon.records[hitId:lower()] then
                        areaStaticId = hitId
                    else
                        if not (types.Static.records[areaStaticId:lower()] or types.Weapon.records[areaStaticId:lower()]) then
                            debugLog("[DETONATE] Missing Hit VFX: " .. tostring(areaStaticId) .. " -- falling back to generic Default")
                            areaStaticId = "VFX_DefaultArea"
                        end
                    end
                end
                debugLog("[DETONATE] Final VFX candidate: " .. tostring(areaStaticId))

                -- Final check: Ensure we don't spawn nothing
                local finalId = areaStaticId:lower()
                if not (types.Static.records[finalId] or types.Weapon.records[finalId]) then
                    areaStaticId = "VFX_DefaultHit"
                end
            end

            local explosionSound = mgef.areaSound ~= "" and mgef.areaSound or (mgef.school and (mgef.school .. " area"))
            if world.vfx and world.vfx.spawn then
                local rid = tostring(areaStaticId):lower()
                local rec = types.Static.records[rid] or types.Weapon.records[rid]
                if rec and rec.model then
                    local scale = areaVfxScale or (finalRadius / 14.0 + 2.0)
                    debugLog(string.format("[DETONATE] Spawning VFX: %s at %s (Scale: %.2f)", tostring(rec.model), tostring(pos), scale))
                    world.vfx.spawn(rec.model, pos, { scale = scale, mwMagicVfx = false })
                else
                    debugLog("[DETONATE] ERROR: Missing or invalid model for static ID: " .. tostring(areaStaticId))
                end
            end
            if explosionSound and not muteAudio then
                pcall(function() core.sound.playSound3d(explosionSound, caster, { position = pos, volume = 1.0 }) end)
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
        for _, object in ipairs(cell:getAll()) do
            if object:isValid() then
                local objPos, objRad = getObjectCenter(object)
                objPos = objPos or object.position
                pcall(function() dist = (objPos - pos):length() end)
                if dist and dist <= (finalRadius + objRad) and (not excludeTarget or object.id ~= excludeTarget.id) then
                    local isLockable = (object.type == types.Door or object.type == types.Container)
                    local isActor    = (object.type == types.NPC or object.type == types.Creature or object.type == types.Player)

                    if isLockUnlock and isLockable then
                        handleDoorLockUnlock(spellId, caster, object)
                        affectedCount = affectedCount + 1
                    elseif isActor and not isLockUnlock and not (types.Actor.objectIsInstance(object) and types.Actor.isDead(object)) then
                        applySpellToActor(spellId, caster, object, pos, true, itemObject, forcedEffects, unreflectable, casterLinked, userData, muteAudio, muteLight)
                        -- Broadcast AoE hit
                        fireMagicHitEvent({
                            attacker  = caster,
                            target    = object,
                            spellId   = spellId,
                            hitPos    = pos,
                            spellType = core.magic.RANGE.Target,
                            isAoE     = true,
                            area      = finalRadius,
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
-- ============================================================
local function autoDetectProjectileParams(spell)
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
        boltLightId = nil,
        spinSpeed   = 0,
    }

    if not (spell and spell.effects and spell.effects[1]) then return out end

    local mgef = core.magic.effects.records[spell.effects[1].id]
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

    -- ---- Bolt light ----
    out.boltLightId = nil -- No default light; schools/mods must explicitly assign one.

    -- ---- Spin speed ----
    if n:find("frost") then out.spinSpeed = math.rad(400) 
    elseif n:find("fire") then out.spinSpeed = math.rad(233)
    elseif school == "conjuration" or school == "alteration" or school == "restoration" then out.spinSpeed = math.rad(333)
    elseif school == "illusion" then out.spinSpeed = math.rad(400)
    end

    -- ---- Auto speed from MagicEffect record ----
    -- [FEATURE 1] Use dynamically detected bolt speeds based on element/school.
    -- (Vanilla ESM records universally mandate 1.0 multiplier/1000 speed, so we inject fast Oblivion speeds here).
    if n:find("fire") then out.speed = 4500
    elseif n:find("frost") or n:find("cold") then out.speed = 2500
    elseif n:find("shock") or n:find("lightning") then out.speed = 3200
    elseif n:find("poison") then out.speed = 2900
    elseif n:find("restor") or n:find("heal") then out.speed = 2800
    elseif school == "illusion" then out.speed = 3000
    elseif school == "alteration" then out.speed = 2900
    elseif school == "conjuration" then out.speed = 3000
    elseif school == "mysticism" then out.speed = 2900
    elseif school == "destruction" then out.speed = 4500
    elseif school == "restoration" then out.speed = 2800 
    else 
        local baseSpeed = 1000
        pcall(function() baseSpeed = core.getGMST("fTargetSpellSpeed") or 1000 end)
        local effectSpeedMult = (mgef and mgef.speed) and mgef.speed or 1.0
        out.speed = effectSpeedMult * baseSpeed
    end
    
    print(string.format("[MagExp] MagicEffect auto-detect: %s | Final Speed: %s", tostring(n), tostring(out.speed)))

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
--   speed       = 1500,            -- projectile speed (units/sec)
--   maxLifetime = 10,              -- seconds before projectile expires
--
--   -- PROJECTILE VFX overrides (auto-detected from spell/mgef if omitted):
--   vfxRecId    = "VFX_DefaultBolt", -- bolt VFX record ID
--   boltModel   = "meshes/...",    -- bolt mesh path (resolved from vfxRecId if omitted)
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
--   initialRotation = nil,         -- util.transform override for initial projectile rotation
--                                  -- (auto-calculated from direction if omitted)
--   spawnOffset = 80,              -- how far ahead of startPos the projectile spawns
--
--   -- NEW FEATURES:
--   userData         = {},              -- per-launch cookie persistence
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
local function launchSpell(data)
    local attacker  = data.attacker
    local spellId   = data.spellId
    local itemObject = data.item or data.itemObject
    local startPos  = data.startPos
    local direction = data.direction

    if not attacker or not spellId or not startPos or not direction then
        debugLog("launchSpell: missing required data (attacker, spellId, startPos, direction)")
        return
    end

    local spell = core.magic.spells.records[spellId] or core.magic.enchantments.records[spellId]
    
    -- Fallback: Iterative search if the proxy is numerically indexed
    if not spell then
        for _, rec in pairs(core.magic.spells.records) do
            local ok, recId = pcall(function() return rec.id end)
            if ok and recId and tostring(recId):lower() == tostring(spellId):lower() then
                spell = rec
                break
            end
        end
    end
    if not spell then
        for _, rec in pairs(core.magic.enchantments.records) do
            local ok, recId = pcall(function() return rec.id end)
            if ok and recId and tostring(recId):lower() == tostring(spellId):lower() then
                spell = rec
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
                local ok, recId = pcall(function() return rec.id end)
                if ok and recId and tostring(recId):lower() == tostring(spellId):lower() then
                    effRec = rec
                    break
                end
            end
        end
        if effRec then
            print("[MagExp] Found '" .. spellId .. "' as a magic effect — synthesizing spell wrapper")
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
        print("[MagExp] launchSpell ERROR: spell/enchantment record not found: " .. tostring(spellId))
        return
    end

    -- [FEATURE 4] nonRecastable: silently abort if spell is already active on the caster.
    if data.nonRecastable then
        local isActive = false
        pcall(function()
            local as = types.Actor.activeSpells(attacker)
            if as then
                for sid, _ in pairs(as) do
                    if tostring(sid):lower() == tostring(spellId):lower() then
                        isActive = true
                        break
                    end
                end
            end
        end)
        if isActive then
            debugLog("nonRecastable: " .. spellId .. " already active on caster — aborting.")
            return
        end
    end

    -- Optional magicka guard (skipped when isFree = true)
    if not data.isFree then
        local magicka = (attacker.type == types.Player)
            and types.Player.stats.dynamic.magicka(attacker)
            or  types.Actor.stats.dynamic.magicka(attacker)
        if magicka.current < (spell.cost or 0) then return end
    end
    
    -- [ITEM REQUIREMENTS]
    if data.itemRequirements and types.Actor.objectIsInstance(attacker) then
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
            local itemName = getItemName(itemId)
            local msg = string.format("You need %s to cast %s", itemName, spellName)
            if attacker.type == types.Player then
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


    -- Routing type and area: accept caller override, otherwise read from spell
    local routingType = data.spellType
    local area        = data.area
    if routingType == nil and spell.effects and #spell.effects > 0 then
        routingType = spell.effects[1].range
    end
    if area == nil and spell.effects and #spell.effects > 0 then
        area = spell.effects[1].area or 0
    end
    routingType = routingType or core.magic.RANGE.Target
    area  = area  or 0

    -- Split effects by range: Self effects apply immediately to caster
    local selfIndexes = {}
    local otherIndexes = {}
    if spell.effects then
        for i, eff in ipairs(spell.effects) do
            if eff.range == core.magic.RANGE.Self then
                table.insert(selfIndexes, i - 1)
            else
                table.insert(otherIndexes, i - 1)
            end
        end
    end

    -- [SPLIT-RANGE APPLICATION]
    -- If there are Self effects and we are doing a non-Self routing, apply Self parts to attacker now.
    if #selfIndexes > 0 and routingType ~= core.magic.RANGE.Self then
        debugLog(string.format("Splitting %d Self effects from %s", #selfIndexes, spellId))
        applySpellToActor(spellId, attacker, attacker, nil, false, itemObject, selfIndexes, data.unreflectable, data.casterLinked, data.userData)
        
        -- If no non-Self effects remain, we're done.
        if #otherIndexes == 0 then return end
    end

    -- If we have other effects, use them for the subsequent routing
    local effectIndexes = #otherIndexes > 0 and otherIndexes or nil

    -- ---- SELF ----
    if routingType == core.magic.RANGE.Self then
        local zOffset = 95
        pcall(function()
            local bbox = attacker:getBoundingBox()
            if bbox then
                zOffset = bbox.halfSize.z
                if zOffset > 105 then zOffset = 100 end
            end
        end)
        local torsoPos = attacker.position + util.vector3(0, 0, zOffset)
        if area > 0 then detonateSpellAtPos(spellId, attacker, torsoPos, attacker.cell, itemObject, effectIndexes, data.unreflectable, data.casterLinked, nil, 0, 0, 1, nil, data.userData) end
        applySpellToActor(spellId, attacker, attacker, torsoPos, false, itemObject, effectIndexes, data.unreflectable, data.casterLinked, data.userData)
        return
    end

    -- ---- TOUCH ----
    if routingType == core.magic.RANGE.Touch then
        -- [SHARED-RAY AUTHORITATIVITY] 
        -- Rely on the player script to provide a precision hitObject from the 
        -- camera-accurate SharedRay service.
        local obj = data.hitObject
        
        if obj and obj:isValid() then
            local spellIsLockUnlock = false
            local spellIsUniversal  = false
            if spell.effects then
                for _, eff in ipairs(spell.effects) do
                    local eid = tostring(eff.id):lower()
                    if STACK_CONFIG.LOCKABLE_EFFECTS[eid] then 
                        spellIsLockUnlock = true 
                    end
                    if STACK_CONFIG.UNIVERSAL_EFFECTS[eid] then
                        spellIsUniversal = true
                    end
                end
            end

            local isLockable = (obj.type == types.Door or obj.type == types.Container)
            local isActor    = (obj.type == types.NPC or obj.type == types.Creature or obj.type == types.Player)

            local validTarget = (isLockable or isActor or spellIsUniversal)

            if validTarget then
                local hitPos = getObjectCenter(obj) or obj.position
                if isActor then
                    local zOffset = 95
                    pcall(function()
                    local bbox = obj:getBoundingBox()
                    if bbox then
                        zOffset = bbox.halfSize.z
                        if zOffset > 105 then zOffset = 100 end
                    end
                    end)
                    hitPos = obj.position + util.vector3(0, 0, zOffset)
                end

                if spellIsLockUnlock then
                    -- Use authoritative interaction handler for Lock/Unlock/Disarm
                    handleDoorLockUnlock(spellId, attacker, obj)
                elseif isActor and not (types.Actor.objectIsInstance(obj) and types.Actor.isDead(obj)) then
                    if area > 0 then detonateSpellAtPos(spellId, attacker, hitPos, obj.cell, itemObject, effectIndexes, data.unreflectable, data.casterLinked, nil, 0, 0, 1, obj, data.userData) end
                    applySpellToActor(spellId, attacker, obj, hitPos, false, itemObject, effectIndexes, data.unreflectable, data.casterLinked, data.userData)
                end

                -- [VFX FOR TOUCH] Only for valid targets
                -- Universal spells trigger on anything. Lock spells on Lockables. Normal spells on Actors.
                local isProperTarget = spellIsUniversal or (spellIsLockUnlock and isLockable) or (not spellIsLockUnlock and isActor and not (types.Actor.objectIsInstance(obj) and types.Actor.isDead(obj)))
                
                if isProperTarget then
                    fireMagicHitEvent({
                        attacker   = attacker,
                        target     = obj,
                        spellId    = spellId,
                        itemObject = itemObject,
                        hitPos     = hitPos,
                        isAoE      = false,
                        area       = area,
                        spellType  = core.magic.RANGE.Touch,
                        unreflectable = data.unreflectable,
                        casterLinked = data.casterLinked,
                        userData   = data.userData
                    })
                end
                return
            end
        end
        return
    end

    -- ---- TARGET (projectile) ----
    -- Auto-detect all VFX/sound/physics params from the spell, then apply caller overrides
    local auto = autoDetectProjectileParams(spell)

    local vfxRecId    = data.vfxRecId    or auto.vfxRecId
    local areaVfxRecId= data.areaVfxRecId or (auto.areaVfxRecId ~= "" and auto.areaVfxRecId or nil)
    local boltModel   = data.boltModel   or auto.boltModel
    local castModel   = data.castModel   or auto.castModel
    local hitModel    = data.hitModel    or auto.hitModel
    local particleTex = data.particleTex or auto.particleTex
    local boltSound   = (data.muteAudio) and nil or (data.boltSound   or auto.boltSound)
    -- [FEATURE 2] Light: prefer explicit override, then auto color draft, then nil
    local boltLightId = (data.muteLight) and nil or (data.boltLightId or auto.boltLightDraft)
    local spinSpeed   = (data.spinSpeed ~= nil) and data.spinSpeed or auto.spinSpeed
    -- [FEATURE 1] Speed: prefer explicit caller override, then engine mgef.speed, then 1500 fallback
    local speed       = data.speed or auto.speed or 1500
    local maxLifetime = data.maxLifetime or 10
    local spawnOffset = data.spawnOffset or 80
    local recordId    = data.projectileRecordId or "Colony_Assassin_act"

    local dir      = direction:normalize()
    local spawnPos = startPos + dir * spawnOffset

    -- Initial rotation: caller can provide a full transform, otherwise auto-calculate from direction
    local rotation = data.initialRotation
    if not rotation then
        local yaw   = math.atan2(dir.x, dir.y)
        local pitch = math.asin(math.max(-1, math.min(1, dir.z)))
        rotation = util.transform.rotateZ(yaw) * util.transform.rotateX(-pitch)
    end

    -- [FEATURE 2] Cast glow: spawn school-specific cast VFX on caster, mirroring C++ addSpellCastGlow.
    -- Duration is ~1.5s (the VFX animation's natural length), matching the engine constant.
    if castModel ~= "" and not data.muteCastGlow then
        pcall(function()
            world.vfx.spawn(castModel, attacker.position, { attachToObject = attacker, mwMagicVfx = false })
        end)
    end

    local proj = world.createObject(recordId, 1)
    print("[MagExp] Created projectile object: " .. tostring(proj.id))
    pcall(function() proj:teleport(attacker.cell, spawnPos, rotation) end)
    -- [FIX] Store the live item object in a registry keyed by projectile ID.
    -- Passing itemObject.recordId (a string) loses the live object reference, which
    -- prevents activeSpells:add from receiving the correct params.item field for
    -- enchantment projectiles.  The registry is cleared on collision or expiry.
    local itemRecordId = nil
    if itemObject then
        if type(itemObject) == "string" then
            itemRecordId = itemObject
        else
            itemRecordId = itemObject.recordId
            projectileItemRegistry[proj.id] = itemObject
        end
    end

    local function safeAddScript(obj, path)
        local ok = pcall(function() obj:addScript(path) end)
        if not ok then
            local altPath = path:gsub("/omw_magexp/", "/OMW_MagExp/")
            if altPath == path then altPath = path:gsub("/OMW_MagExp/", "/omw_magexp/") end
            pcall(function() obj:addScript(altPath) end)
        end
    end

    safeAddScript(proj, 'scripts/OMW_MagExp/magexp_projectile_local.lua')

    -- [FIX] Defer MagExp_InitProjectile by one simulation tick.
    -- addScript() schedules the script for attachment on the NEXT engine update; if
    -- sendEvent is called immediately in the same frame the event arrives before
    -- onInit runs, producing an inert projectile with no velocity or spellId.
    local initPayload = {
        -- Physics
        velocity    = dir * speed,
        maxLifetime = maxLifetime,
        spinSpeed   = spinSpeed,
        accelerationExp = data.accelerationExp,
        maxSpeed    = data.maxSpeed,
        -- Identity
        attacker    = attacker,
        spellId     = spellId,
        itemRecordId = itemRecordId,
        effectIndexes = effectIndexes,
        area        = area,
        -- Audio
        boltSound   = boltSound,
        -- Lighting
        boltLightId = boltLightId,
        -- VFX
        boltModel   = boltModel,
        hitModel    = hitModel,
        vfxRecId    = vfxRecId,
        areaVfxRecId = areaVfxRecId,
        particle    = particleTex,
        unreflectable = data.unreflectable,
        casterLinked  = data.casterLinked,
        isPaused      = data.isPaused,
        direction     = dir,   -- [FIX] Always pass direction even if velocity is 0
        areaVfxScale  = data.areaVfxScale,
        userData      = data.userData,
    }
    if proj and proj:isValid() then
        proj:sendEvent('MagExp_InitProjectile', initPayload)
    end

    -- Register in live spell registry for in-flight API access
    if proj and proj:isValid() then
        activeSpellRegistry[proj.id] = {
            projectile = proj,
            spellId    = spellId,
            attacker   = attacker,
            launchTime = core.getSimulationTime(),
            maxSpeed   = data.maxSpeed or 0,
            userData   = data.userData,
            muteAudio  = data.muteAudio,
            muteLight  = data.muteLight
        }
    end

    debugLog(string.format("Launched '%s' [%s] spd=%d spin=%.2f", tostring(spellId), tostring(recordId), speed, spinSpeed))
    return proj
end

-- ============================================================
-- [INTERNAL] Projectile lifecycle event handlers
-- ============================================================
local function onProjectileMove(data)
    local proj   = data.projectile
    local newPos = data.newPos
    if proj and proj:isValid() and newPos then
        pcall(function()
            if data.newRot then proj:teleport(proj.cell, newPos, data.newRot)
            else proj:teleport(proj.cell, newPos) end
        end)
    end
    if data.soundAnchor and data.soundAnchor:isValid() and newPos then
        data.soundAnchor:teleport(proj.cell, newPos)
    end
    if data.lightAnchor and data.lightAnchor:isValid() and newPos then
        data.lightAnchor:teleport(proj.cell, newPos)
    end
end

local function onProjectileExpired(data)
    local proj = data.projectile
    if proj and proj:isValid() then
        proj:sendEvent('MagExp_StopSound')
        pcall(function() proj:remove() end)
    end
    -- Clean up registries
    if proj and proj.id then
        projectileItemRegistry[proj.id] = nil
        activeSpellRegistry[proj.id]    = nil
    end
    if data.soundAnchor and data.soundAnchor:isValid() then pcall(function() data.soundAnchor:remove() end) end
    if data.lightAnchor and data.lightAnchor:isValid() then pcall(function() data.lightAnchor:remove() end) end
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
        detonateSpellAtPos(spellId, attacker, hitPos, cell, itemRecordId, effectIndexes, data.unreflectable, data.casterLinked, data.areaVfxRecId or data.vfxRecId, impactSpeed, refMaxSpeed, data.areaVfxScale, target, userData, muteAudio, muteLight)
    end

    -- [ORDER: Interaction / Direct Hit Second]
    local isActor = target and target:isValid() and (target.type == types.NPC or target.type == types.Creature or target.type == types.Player)
    local isLockable = target and target:isValid() and (target.type == types.Door or target.type == types.Container)

    if spellIsLockUnlock and isLockable then
        handleDoorLockUnlock(spellId, attacker, target)
    elseif isActor and not (types.Actor.objectIsInstance(target) and types.Actor.isDead(target)) then
        applySpellToActor(spellId, attacker, target, hitPos, false, itemRecordId, effectIndexes, data.unreflectable, data.casterLinked, userData, muteAudio, muteLight)
    end

    -- [MAXYARI] Physics impulse on detonation
    if data.impactImpulse and data.impactImpulse > 0
       and target and target:isValid()
       and types.Actor.objectIsInstance(target) then
        local impDir = (data.velocity and data.velocity:length() > 0.01)
                       and data.velocity:normalize() or util.vector3(0, 1, 0)
        pcall(function()
            target:sendEvent('LuaPhysics_ApplyImpulse', {
                impulse = impDir * data.impactImpulse,
                culprit = attacker
            })
        end)
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
        unreflectable = data.unreflectable,
        casterLinked  = data.casterLinked,
        userData      = userData,
        muteAudio     = muteAudio,
        muteLight     = muteLight
    })

    -- Final cleanup
    if proj and proj.id then
        projectileItemRegistry[proj.id] = nil
        activeSpellRegistry[proj.id]    = nil
    end

    if proj and proj:isValid() then
        proj:sendEvent('MagExp_StopSound')
        pcall(function() proj:remove() end)
    end
    if data.soundAnchor and data.soundAnchor:isValid() then pcall(function() data.soundAnchor:remove() end) end
    if data.lightAnchor and data.lightAnchor:isValid() then pcall(function() data.lightAnchor:remove() end) end
end

local function onUpdate(dt)
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

    -- [PERSISTENT VFX CLEANUP] Pulsed every 0.1s
    local gameTime = core.getSimulationTime()
    if not MagExp_NextCleanup or gameTime > MagExp_NextCleanup then
        MagExp_NextCleanup = gameTime + 0.1
        for targetId, spells in pairs(activeVfxRegistry) do
            local anyRemaining = false
            for spellId, target in pairs(spells) do
                if not target:isValid() then
                    spells[spellId] = nil
                else
                    local isActive = false
                    pcall(function()
                        local as = types.Actor.activeSpells(target)
                        if as then
                            for _, inst in pairs(as) do
                                if inst.id == spellId then
                                    isActive = true
                                    break
                                end
                            end
                        end
                    end)
                    
                    if not isActive then
                        target:sendEvent('RemoveVfx', "MagExp_" .. spellId)
                        spells[spellId] = nil
                    else
                        anyRemaining = true
                    end
                end
            end
            if not anyRemaining then activeVfxRegistry[targetId] = nil end
        end

        -- [LIFECYCLE TRACKING] onEffectTick & onEffectOver
        for target, spells in pairs(trackedEffectRegistry) do
            if not target or not target:isValid() or (types.Actor.objectIsInstance(target) and types.Actor.isDead(target)) then
                -- Actor is gone or dead: Fire onEffectOver for all tracked spells
                for spellId, data in pairs(spells) do
                    for _, eff in ipairs(data.effects) do
                        fireEffectEvent('onEffectOver', target, eff)
                    end
                end
                trackedEffectRegistry[target] = nil
            else
                local activeSpells = types.Actor.activeSpells(target)
                for spellId, data in pairs(spells) do
                    local isActive = false
                    if activeSpells then
                        for sId, _ in pairs(activeSpells) do
                            if sId == spellId then isActive = true; break end
                        end
                    end

                    if not isActive then
                        -- Spell has expired or been removed
                        for _, eff in ipairs(data.effects) do
                            fireEffectEvent('onEffectOver', target, eff)
                        end
                        spells[spellId] = nil
                    else
                        -- Still active: Fire onEffectTick
                        for _, eff in ipairs(data.effects) do
                            fireEffectEvent('onEffectTick', target, eff)
                        end
                    end
                end
                -- Clean up empty target entries
                if next(spells) == nil then trackedEffectRegistry[target] = nil end
            end
        end

        -- [CASTER LINKED CLEANUP] Remove casterLinked spells if caster dies
        for i = #casterLinkedSpells, 1, -1 do
            local link = casterLinkedSpells[i]
            local caster = link.caster
            local isCasterDead = false
            if not caster or not caster:isValid() then
                isCasterDead = true
            elseif types.Actor.objectIsInstance(caster) then
                if types.Actor.isDead(caster) then
                    isCasterDead = true
                end
            end
            if isCasterDead then
                local target = link.target
                if target and target:isValid() then
                    pcall(function()
                        local activeSpells = types.Actor.activeSpells(target)
                        if activeSpells then activeSpells:remove(link.spellId) end
                    end)
                end
                table.remove(casterLinkedSpells, i)
            end
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

    --- Launch a spell projectile (or apply Self/Touch immediately).
    -- @param data table: { attacker, spellId, startPos, direction, isFree?, speed? }
    launchSpell = launchSpell,

    --- Apply spell effects directly to an actor.
    -- @param spellId string, caster Actor, target Actor, hitPos vector3, isAoe boolean, itemObject Object, forcedEffects table, unreflectable boolean, casterLinked boolean
    applySpellToActor = applySpellToActor,

    --- Helper: Emit a spell projectile directly from a non-actor object (like a door, trap, activator, or script).
    -- @param data table: { source=Object, spellId=string, startPos=Vector3 (optional, defaults to source center), direction=Vector3, speed=number (optional) }
    emitProjectileFromObject = function(data)
        if not data.source or not data.spellId or not data.direction then return end
        
        local pos = data.startPos
        if not pos then
            pcall(function() pos = data.source:getBoundingBox().center end)
            if not pos then pos = data.source.position end
        end

        launchSpell({
            attacker  = data.source, -- Sent as custom source (sanitized safely by engine logic)
            spellId   = data.spellId,
            startPos  = pos,
            direction = data.direction,
            speed     = data.speed or 1500,
            isFree    = true,  -- Objects don't use magicka
            spellType = core.magic.RANGE.Target, -- Forces projectile behavior
            bounceEnabled    = data.bounceEnabled,
            bounceMax        = data.bounceMax,
            bouncePower      = data.bouncePower,
            maxSpeed         = data.maxSpeed,
            accelerationExp  = data.accelerationExp,
            vfxRecId         = data.vfxRecId,
            boltModel        = data.boltModel,
            boltSound        = data.boltSound,
            boltLightId      = data.boltLightId,
            impactImpulse    = data.impactImpulse,
            maxLifetime      = data.maxLifetime,
            spawnOffset      = data.spawnOffset
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
    -- @param spellId string, caster Actor, pos vector3, cell Cell, itemObject Object, forcedEffects table, unreflectable boolean, casterLinked boolean
    detonateSpellAtPos = detonateSpellAtPos,

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
            -- Update registry maxSpeed if provided
            if data.maxSpeed then e.maxSpeed = data.maxSpeed end
        end
    end,

    --- Redirect a spell projectile toward a new direction vector (speed is preserved).
    redirectSpell = function(projId, newDirection)
        local e = activeSpellRegistry[projId]
        if e and e.projectile:isValid() then
            e.projectile:sendEvent('MagExp_SetPhysics', { direction = newDirection })
        end
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
        end
    end,

    --- Force-cancel and remove a live spell projectile.
    cancelSpell = function(projId)
        local e = activeSpellRegistry[projId]
        if e and e.projectile:isValid() then
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

    --- Get all IDs of currently active MagExp spell projectiles.
    getActiveSpellIds = function()
        local ids = {}
        for id, _ in pairs(activeSpellRegistry) do table.insert(ids, id) end
        return ids
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
            local ok, result = pcall(fn)
            return ok and result or false
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
    },
    eventHandlers = {
        --- Main spell launch event. Usable from player scripts via core.sendGlobalEvent.
        MagExp_CastRequest         = function(data) launchSpell(data) end,
        MagExp_ProjectileMove      = onProjectileMove,
        MagExp_ProjectileExpired   = function(data) print("[MagExp] Projectile EXPIRED: " .. tostring(data.spellId or "nil")); onProjectileExpired(data) end,
        MagExp_ProjectileCollision = function(data) print("[MagExp] Projectile COLLISION: " .. tostring(data.spellId or "nil") .. " with " .. tostring(data.hitObject or "world")); onProjectileCollision(data) end,

        --- Bounce event: forwarded from local script on each wall reflection.
        MagExp_OnProjectileBounce  = function(data)
            if MagExpPublicInterface and MagExpPublicInterface.onProjectileBounce then
                pcall(function() MagExpPublicInterface.onProjectileBounce(data) end)
            end
        end,

        --- State snapshot reply: passthrough for other global scripts to listen to.
        MagExp_SpellState = function(data) end,
        MagExp_AnchorTeleport      = function(data)
            if data.lightAnchor and data.lightAnchor:isValid() then pcall(function() data.lightAnchor:teleport(data.lightAnchor.cell, data.pos) end) end
            if data.soundAnchor and data.soundAnchor:isValid() then pcall(function() data.soundAnchor:teleport(data.soundAnchor.cell, data.pos) end) end
        end,

        MagExp_CreateSoundAnchor = function(data)
            local anchor = world.createObject(data.recordId, 1)
            anchor:teleport(data.projectile.cell, data.projectile.position)
            local ok = pcall(function() anchor:addScript('scripts/OMW_MagExp/magexp_projectile_local.lua') end)
            if not ok then pcall(function() anchor:addScript('scripts/omw_magexp/magexp_projectile_local.lua') end) end
            anchor:sendEvent('MagExp_InitSound', { sound = data.sound, isSoundAnchor = true })
            data.projectile:sendEvent('MagExp_SetSoundAnchor', { anchor = anchor })
        end,

        MagExp_CreateLightAnchor = function(data)
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
            anchor:teleport(data.projectile.cell, data.projectile.position)
            local ok = pcall(function() anchor:addScript('scripts/OMW_MagExp/magexp_projectile_local.lua') end)
            if not ok then pcall(function() anchor:addScript('scripts/omw_magexp/magexp_projectile_local.lua') end) end
            data.projectile:sendEvent('MagExp_SetLightAnchor', { anchor = anchor })
        end,

        MagExp_ProcessCast = function(data)
            local actor = data.actor
            if not actor or not actor:isValid() then return end
            local spell = core.magic.spells.records[data.spellId] or core.magic.enchantments.records[data.spellId]
            if not spell then return end
            
            local chance = getSpellSuccessChance(spell, actor, data.isGodMode)
            local roll = math.random(0, 99)
            if roll < chance then
                actor:sendEvent('MagExp_CastResult', {
                    spellId = data.spellId,
                    success = true,
                    item    = data.item,
                    isFree  = data.isFree
                })
            else
                actor:sendEvent('MagExp_CastResult', {
                    spellId = data.spellId,
                    success = false
                })
                if actor.enabled then
                    pcall(function() core.sound.playSound3d("spell failure destruction", actor) end)
                end
            end
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
            if obj and obj:isValid() then obj:remove() end
        end,

        MagExp_BreakInvisibility = function(data)
            local actor = data.actor
            if not actor or not actor:isValid() then return end
            pcall(function()
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
                            pcall(function() activeSpells:remove(removeId) end)
                        end
                    end
                end
            end)
        end,
    }
}
