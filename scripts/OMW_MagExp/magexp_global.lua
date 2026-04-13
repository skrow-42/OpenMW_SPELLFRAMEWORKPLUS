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

local targetFilter = nil
local activeVfxRegistry = {} 
local casterLinkedSpells = {} -- list of {caster, target, spellId} for casterLinked effects

local function debugLog(msg)
    local debugOn = storage.globalSection('SettingsMagExp_General'):get('DebugMode')
    if debugOn then
        print("[MagExp] " .. tostring(msg))
    end
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
    }
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
    -- data expects: attacker, target, spellId, hitPos, hitNormal, spellType, isAoE, area, velocity, projectile
    local spell = core.magic.spells.records[data.spellId] or core.magic.enchantments.records[data.spellId]
    if not spell then return end

    local info = {
        attacker     = data.attacker,
        target       = data.target,
        spellId      = data.spellId,
        hitPos       = data.hitPos,
        hitNormal    = data.hitNormal or util.vector3(0,0,1),
        successful   = true,
        sourceType   = core.magic.ATTACK_SOURCE_TYPE and core.magic.ATTACK_SOURCE_TYPE.Magic or 2, -- AttackSourceType.Magic = 2
        spellType    = data.spellType or core.magic.RANGE.Target,
        isAoE        = data.isAoE or false,
        area         = data.area or 0,
        damage       = getSpellDamageInfo(data.spellId),
        projectile   = data.projectile,
        velocity     = data.velocity or util.vector3(0,0,0)
    }

    -- Element & School detection
    if spell.effects and spell.effects[1] then
        local mgef = core.magic.effects.records[spell.effects[1].id]
        if mgef then
            info.school = mgef.school
            local n = (mgef.name or ""):lower()
            if n:find("fire") then info.element = "fire"
            elseif n:find("frost") then info.element = "frost"
            elseif n:find("shock") then info.element = "shock"
            elseif n:find("poison") then info.element = "poison"
            elseif n:find("heal") or n:find("restore") then info.element = "heal"
            else info.element = "default" end
        end
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
    -- Send to target script if actor
    if data.target and data.target:isValid() then
        data.target:sendEvent('MagExp_Local_MagicHit', info)

        -- Manual dispatch for specific school hit effects
        if spell.effects and spell.effects[1] then
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

-- ============================================================
-- [CORE] Authoritative Spell Application
-- ============================================================
local function applySpellToActor(spellId, caster, target, hitPos, isAoe, itemObject)
    if not target or not target:isValid() then return end
    if not (caster and caster:isValid()) then caster = target end
    if target.type ~= types.NPC and target.type ~= types.Creature and target.type ~= types.Player then
        debugLog("applySpellToActor: Aborting - target is not an actor type")
        return
    end

    print("MagExp: Applying " .. spellId .. " to " .. (target.recordId or "unknown") .. " by " .. (caster.recordId or "unknown"))

    local spell = core.magic.spells.records[spellId]
    local isEnchantment = false
    if not spell then
        spell = core.magic.enchantments.records[spellId]
        isEnchantment = true
    end

    if not spell then
        debugLog("applySpellToActor: record not found: " .. tostring(spellId))
        return
    end

    -- Check for harmful and casterLinked flags
    local hasHarmful = false
    local hasCasterLinked = false
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

                        target:sendEvent('AddVfx', {
                            model = static.model,
                            options = vfxOptions
                        })

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
                local snd = mgef.school:lower() .. " hit"
                target:sendEvent('PlaySound3d', { sound = snd })
            end
        end)
    end

    debugLog(string.format("Applying %s to %s", spellId, target.recordId or target.id))

    -- [MOD-SIDE VETO] Allow other mods (like OSSC) to block hits (made to not affect corpses)
    if targetFilter and not targetFilter(target) then
        print("[MagExp] Target Blocked by Veto Filter: " .. tostring(target.recordId or target.id))
        debugLog("applySpellToActor: Blocked by targetFilter")
        return
    end

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
                area      = spell.effects[1].area or 0
            })
        end
    end

    local effectIndexes = {}
    if spell.effects then
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
            if caster and caster:isValid() then params.caster = caster end

            -- Apply effects
            if isEnchantment then
                -- Provide the item source for mods that need it (like OSSC)
                if itemObject and itemObject:isValid() then params.item = itemObject end
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

            -- Handle harmful effects: elicit hostile reaction
            if hasHarmful and types.NPC.objectIsInstance(target) then
                print("MagExp: Triggering hostile reaction on " .. target.recordId .. " from " .. (caster.recordId or "unknown"))
                local attackInfo = {
                    attacker = caster,
                    damage = {health = 0},
                    successful = true,
                    sourceType = 'Magic',
                    strength = 1.0,
                    type = 'Thrust'
                }
                local ok, err = pcall(function() target:sendEvent('Hit', attackInfo) end)
                if not ok then print("MagExp: sendEvent Hit failed: " .. tostring(err)) end
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
        if not vfxPos then
            local tStr = tostring(target.type)
            if tStr:find("NPC") or tStr:find("Creature") or tStr:find("Player") then
                local zOffset = heightCache[target.id]
                if not zOffset then
                    zOffset = 45 -- Lowered fallback significantly (waist level)
                    pcall(function()
                        local bbox = target:getBoundingBox()
                        if bbox and bbox.min and bbox.max then
                            zOffset = (bbox.max.z - bbox.min.z) * 0.55
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
                local hitVfxId = (mgef.hitVfx and mgef.hitVfx ~= "") and mgef.hitVfx or nil
                local school = mgef.school
                if not hitVfxId then
                    local SCHOOL = core.magic.SCHOOL or { Alteration=0, Conjuration=1, Destruction=2, Illusion=3, Mysticism=4, Restoration=5 }
                    if school == "destruction" or school == SCHOOL.Destruction then hitVfxId = "vfx_dest_hit"
                    elseif school == "restoration" or school == SCHOOL.Restoration then hitVfxId = "vfx_rest_hit"
                    elseif school == "alteration"  or school == SCHOOL.Alteration  then hitVfxId = "vfx_alt_hit"
                    elseif school == "conjuration" or school == SCHOOL.Conjuration then hitVfxId = "vfx_conj_hit"
                    elseif school == "illusion"    or school == SCHOOL.Illusion    then hitVfxId = "vfx_illus_hit"
                    else hitVfxId = "vfx_myst_hit" end
                end

                if hitVfxId then
                    local rec = types.Static.records[hitVfxId:lower()] or types.Weapon.records[hitVfxId:lower()]
                    if rec and rec.model then
                        world.vfx.spawn(rec.model, vfxPos, { attachToObject = target, mwMagicVfx = true })
                    end
                end

                local sndId = (mgef.hitSound and mgef.hitSound ~= "") and mgef.hitSound or (tostring(school):lower() .. " hit")
                pcall(function() core.sound.playSound3d(sndId, target, { volume = 1.0 }) end)
            end
        end
    end)
    if not ok2 then debugLog("VFX Logic Error: " .. tostring(err2)) end
end

-- ============================================================
-- [UTILITY] Door lock/unlock handling
-- ============================================================
local function handleDoorLockUnlock(spellId, caster, target)
    if not target or target.type ~= types.Door then return false end
    local spell = core.magic.spells.records[spellId] or core.magic.enchantments.records[spellId]
    if not spell or not spell.effects then return false end

    for _, eff in ipairs(spell.effects) do
        if eff.id == "open" or eff.id == "lock" then
            local magnitude = math.random(eff.magnitudeMin or 0, eff.magnitudeMax or eff.magnitudeMin or 0)
            if types.Lockable and types.Lockable.objectIsInstance(target) then
                local isLocked = types.Lockable.isLocked(target)
                local lockLvl = 0
                if types.Lockable.getLockLevel then lockLvl = types.Lockable.getLockLevel(target)
                elseif types.Lockable.lockLevel then lockLvl = types.Lockable.lockLevel(target) end

                if eff.id == "open" then
                    if isLocked and magnitude >= lockLvl then
                        types.Lockable.unlock(target)
                        pcall(function() core.sound.playSound3d("Open Lock", target) end)
                        pcall(function() core.sound.playSound3d("alteration hit", target) end)
                    elseif isLocked then
                        pcall(function() core.sound.playSound3d("Open Lock Fail", target) end)
                        pcall(function() core.sound.playSound3d("alteration hit", target) end)
                    end
                elseif eff.id == "lock" then
                    if not isLocked or magnitude > lockLvl then
                        types.Lockable.lock(target, magnitude)
                        pcall(function() core.sound.playSound3d("Open Lock", target) end)
                        pcall(function() core.sound.playSound3d("alteration hit", target) end)
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
local function detonateSpellAtPos(spellId, caster, pos, cell, itemObject)
    local spell = core.magic.spells.records[spellId] or core.magic.enchantments.records[spellId]
    if not spell or not spell.effects then return end

    local maxArea = 0
    local AREA_MULT = 24

    for _, effect in ipairs(spell.effects) do
        local a = (effect and effect.area) or 0
        if a > maxArea then maxArea = a end
    end
    if maxArea <= 0 then return end

    local finalRadius = maxArea * AREA_MULT

    if spell.effects[1] then
        local mgef = core.magic.effects.records[spell.effects[1].id]
        if mgef then
            local areaStaticId = mgef.areaStatic ~= "" and mgef.areaStatic or "VFX_DefaultArea"
            local explosionSound = mgef.areaSound ~= "" and mgef.areaSound or (mgef.school and (mgef.school .. " area"))
            if world.vfx and world.vfx.spawn then
                local staticRec = types.Static.records[areaStaticId]
                if staticRec and staticRec.model then
                    world.vfx.spawn(staticRec.model, pos, { scale = (maxArea * 2), mwMagicVfx = true })
                end
            end
            if explosionSound then
                pcall(function() core.sound.playSound3d(explosionSound, caster, { position = pos, volume = 1.0 }) end)
            end
        end
    end

    local isLockUnlock = false
    for _, eff in ipairs(spell.effects) do
        if eff.id == "open" or eff.id == "lock" then isLockUnlock = true; break end
    end

    if cell then
        local affectedCount = 0
        for _, object in ipairs(cell:getAll()) do
            if object:isValid() then
                local dist = 0
                pcall(function() dist = (object.position - pos):length() end)
                if dist and dist <= finalRadius then
                    if isLockUnlock then
                        if object.type == types.Door then
                            handleDoorLockUnlock(spellId, caster, object)
                            affectedCount = affectedCount + 1
                        end
                    else
                        if object.type == types.NPC or object.type == types.Creature or object.type == types.Player then
                            applySpellToActor(spellId, caster, object, pos, true, itemObject)
                            -- Broadcast AoE hit
                            fireMagicHitEvent({
                                attacker  = caster,
                                target    = object,
                                spellId   = spellId,
                                hitPos    = pos,
                                spellType = core.magic.RANGE.Target,
                                isAoE     = true,
                                area      = finalRadius
                            })
                            affectedCount = affectedCount + 1
                        end
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
        if mgef.castVfx  and mgef.castVfx  ~= "" then out.castModel   = mgef.castVfx  end
        if mgef.hitVfx   and mgef.hitVfx   ~= "" then out.hitModel    = mgef.hitVfx   end
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
    out.boltLightId = "Flame Light_64" -- All schools get a light by default

    -- ---- Spin speed ----
    if n:find("frost") then out.spinSpeed = math.rad(400) 
    elseif n:find("fire") then out.spinSpeed = math.rad(233)
    elseif school == "conjuration" or school == "alteration" or school == "restoration" then out.spinSpeed = math.rad(333)
    elseif school == "illusion" then out.spinSpeed = math.rad(400)
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
--   boltLightId = "Flame Light_64",   -- record ID of the light to attach to projectile
--
--   -- PROJECTILE PHYSICS overrides:
--   spinSpeed   = 0,               -- rotation speed in rad/sec (0 = no spin)
--   initialRotation = nil,         -- util.transform override for initial projectile rotation
--                                  -- (auto-calculated from direction if omitted)
--   spawnOffset = 80,              -- how far ahead of startPos the projectile spawns
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
    if not spell then
        debugLog("launchSpell: spell/enchantment record not found: " .. tostring(spellId))
        return
    end

    -- Optional magicka guard (skipped when isFree = true)
    if not data.isFree then
        local magicka = (attacker.type == types.Player)
            and types.Player.stats.dynamic.magicka(attacker)
            or  types.Actor.stats.dynamic.magicka(attacker)
        if magicka.current < (spell.cost or 0) then return end
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

    -- ---- SELF ----
    if routingType == core.magic.RANGE.Self then
        local zOffset = 95
        pcall(function()
            local bbox = attacker:getBoundingBox()
            if bbox and bbox.min and bbox.max then
                zOffset = (bbox.max.z - bbox.min.z) * 0.5
                if zOffset > 105 then zOffset = 100 end
            end
        end)
        local torsoPos = attacker.position + util.vector3(0, 0, zOffset)
        if area > 0 then detonateSpellAtPos(spellId, attacker, torsoPos, attacker.cell, itemObject) end
        applySpellToActor(spellId, attacker, attacker, torsoPos, false, itemObject)
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
            if spell.effects then
                for _, eff in ipairs(spell.effects) do
                    if eff.id == "open" or eff.id == "lock" then spellIsLockUnlock = true end
                end
            end

            local validTarget = false
            if spellIsLockUnlock then
                if obj.type == types.Door then validTarget = true end
            else
                if obj.type == types.NPC or obj.type == types.Creature or obj.type == types.Player then validTarget = true end
            end

            if validTarget then
                if spellIsLockUnlock then
                    handleDoorLockUnlock(spellId, attacker, obj)
                else
                    local zOffset = 95
                    pcall(function()
                        local bbox = obj:getBoundingBox()
                        if bbox and bbox.min and bbox.max then
                            zOffset = (bbox.max.z - bbox.min.z) * 0.5
                            if zOffset > 105 then zOffset = 100 end
                        end
                    end)
                    local torsoPos = obj.position + util.vector3(0, 0, zOffset)
                    if area > 0 then detonateSpellAtPos(spellId, attacker, torsoPos, obj.cell, itemObject) end
                    applySpellToActor(spellId, attacker, obj, torsoPos, false, itemObject)

                    -- [VFX FOR TOUCH] Manually trigger hit visuals since there is no projectile collision
                    fireMagicHitEvent({
                        attacker   = attacker,
                        target     = obj,
                        spellId    = spellId,
                        itemObject = itemObject,
                        hitPos     = torsoPos,
                        isAoE      = false,
                        area       = area,
                        spellType  = core.magic.RANGE.Touch
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
    local boltModel   = data.boltModel   or auto.boltModel
    local castModel   = data.castModel   or auto.castModel
    local hitModel    = data.hitModel    or auto.hitModel
    local particleTex = data.particleTex or auto.particleTex
    local boltSound   = data.boltSound   or auto.boltSound
    local boltLightId = data.boltLightId or auto.boltLightId
    local spinSpeed   = (data.spinSpeed ~= nil) and data.spinSpeed or auto.spinSpeed
    local speed       = data.speed       or 1500
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

    -- Spawn cast VFX at attacker position on launch
    if castModel ~= "" then
        pcall(function()
            world.vfx.spawn(castModel, attacker.position, { attachToObject = attacker, mwMagicVfx = true })
        end)
    end

    local proj = world.createObject(recordId, 1)
    proj:teleport(attacker.cell, spawnPos, rotation)

    local function safeAddScript(obj, path)
        local ok = pcall(function() obj:addScript(path) end)
        if not ok then
            local altPath = path:gsub("/omw_magexp/", "/OMW_MagExp/")
            if altPath == path then altPath = path:gsub("/OMW_MagExp/", "/omw_magexp/") end
            pcall(function() obj:addScript(altPath) end)
        end
    end

    safeAddScript(proj, 'scripts/OMW_MagExp/magexp_projectile_local.lua')
    proj:sendEvent('MagExp_InitProjectile', {
        -- Physics
        velocity    = dir * speed,
        maxLifetime = maxLifetime,
        spinSpeed   = spinSpeed,
        -- Identity
        attacker    = attacker,
        spellId     = spellId,
        itemRecordId = itemObject and itemObject.recordId or nil,
        area        = area,
        -- Audio
        boltSound   = boltSound,
        -- Lighting
        boltLightId = boltLightId,
        -- VFX
        boltModel   = boltModel,
        hitModel    = hitModel,
        vfxRecId    = vfxRecId,
        particle    = particleTex,
    })

    debugLog(string.format("Launched '%s' [%s] spd=%d spin=%.2f", tostring(spellId), tostring(recordId), speed, spinSpeed))
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
        pcall(function() data.soundAnchor:teleport(proj.cell, newPos) end)
    end
    if data.lightAnchor and data.lightAnchor:isValid() and newPos then
        pcall(function() data.lightAnchor:teleport(proj.cell, newPos) end)
    end
end

local function onProjectileExpired(data)
    local proj = data.projectile
    if proj and proj:isValid() then
        proj:sendEvent('MagExp_StopSound')
        pcall(function() proj:remove() end)
    end
    if data.soundAnchor and data.soundAnchor:isValid() then pcall(function() data.soundAnchor:remove() end) end
    if data.lightAnchor and data.lightAnchor:isValid() then pcall(function() data.lightAnchor:remove() end) end
end

local function onProjectileCollision(data)
    local proj     = data.projectile
    local attacker = data.attacker
    local spellId  = data.spellId
    local itemRecordId = data.itemRecordId
    local target   = data.hitObject
    local hitPos   = data.hitPos
    local area     = data.area or 0

    if not attacker or not spellId or not hitPos then
        debugLog("ProjectileCollision: missing data")
        return
    end

    local spell = core.magic.spells.records[spellId]
    local cell  = (proj and proj.cell) or (attacker and attacker.cell)

    local spellIsLockUnlock = false
    if spell and spell.effects then
        for _, eff in ipairs(spell.effects) do
            if eff.id == "open" or eff.id == "lock" then spellIsLockUnlock = true end
        end
    end

    if spellIsLockUnlock then
        if target and target.type == types.Door then handleDoorLockUnlock(spellId, attacker, target)
        elseif area > 0 then detonateSpellAtPos(spellId, attacker, hitPos, cell, itemRecordId) end
    else
        if area > 0 then
            detonateSpellAtPos(spellId, attacker, hitPos, cell, itemRecordId)
        elseif target and (tostring(target.type):find("NPC") or tostring(target.type):find("Creature") or tostring(target.type):find("Player")) then
            applySpellToActor(spellId, attacker, target, hitPos, false, itemRecordId)
        end
    end

    -- BROADCAST HIT EVENT (For primary projectile impact)
    fireMagicHitEvent({
        attacker   = attacker,
        target     = target,
        spellId    = spellId,
        hitPos     = hitPos,
        hitNormal  = data.hitNormal,
        velocity   = data.velocity,
        projectile = proj,
        spellType  = core.magic.RANGE.Target,
        isAoE      = false,
        area       = area
    })

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

        -- [CASTER LINKED CLEANUP] Remove casterLinked spells if caster dies
        for i = #casterLinkedSpells, 1, -1 do
            local link = casterLinkedSpells[i]
            local caster = link.caster
            local isCasterDead = false
            if not caster or not caster:isValid() then
                isCasterDead = true
            elseif types.Actor.objectIsInstance(caster) then
                local health = types.Actor.stats.dynamic.health(caster)
                if health and health.current <= 0 then
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
return {
    interfaceName = "MagExp",
    interface = {
        --- Version of the OMW_MagExp framework.
        version = 1.0,

        --- Launch a spell projectile (or apply Self/Touch immediately).
        -- @param data table: { attacker, spellId, startPos, direction, isFree?, speed? }
        launchSpell = launchSpell,

        --- Apply spell effects directly to an actor.
        -- @param spellId string, caster Actor, target Actor, hitPos vector3
        applySpellToActor = applySpellToActor,

        --- Register an effect ID to use persistent looping visuals (e.g. Shield).
        -- @param effectId string
        registerPersistentEffect = function(id)
            if id then STACK_CONFIG.PERSISTENT_EFFECTS[id:lower()] = true end
        end,

        --- Trigger an AoE blast at a world position.
        -- @param spellId string, caster Actor, pos vector3, cell Cell
        detonateSpellAtPos = detonateSpellAtPos,

        --- Stacking configuration table. Modders can modify this at runtime.
        applySpell   = applySpellToActor,
        setTargetFilter = function(f) targetFilter = f end,
        STACK_CONFIG = STACK_CONFIG,
    },
    engineHandlers = {
        onUpdate = onUpdate,
    },
    eventHandlers = {
        --- Main spell launch event. Usable from player scripts via core.sendGlobalEvent.
        MagExp_CastRequest         = function(data) launchSpell(data) end,
        MagExp_ProjectileMove      = onProjectileMove,
        MagExp_ProjectileExpired   = onProjectileExpired,
        MagExp_ProjectileCollision = onProjectileCollision,

        MagExp_CreateSoundAnchor = function(data)
            local anchor = world.createObject(data.recordId, 1)
            anchor:teleport(data.projectile.cell, data.projectile.position)
            local ok = pcall(function() anchor:addScript('scripts/OMW_MagExp/magexp_projectile_local.lua') end)
            if not ok then pcall(function() anchor:addScript('scripts/omw_magexp/magexp_projectile_local.lua') end) end
            anchor:sendEvent('MagExp_InitSound', { sound = data.sound, isSoundAnchor = true })
            data.projectile:sendEvent('MagExp_SetSoundAnchor', { anchor = anchor })
        end,

        MagExp_CreateLightAnchor = function(data)
            local anchor = world.createObject(data.recordId, 1)
            anchor:teleport(data.projectile.cell, data.projectile.position)
            local ok = pcall(function() anchor:addScript('scripts/OMW_MagExp/magexp_projectile_local.lua') end)
            if not ok then pcall(function() anchor:addScript('scripts/omw_magexp/magexp_projectile_local.lua') end) end
            data.projectile:sendEvent('MagExp_SetLightAnchor', { anchor = anchor })
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
