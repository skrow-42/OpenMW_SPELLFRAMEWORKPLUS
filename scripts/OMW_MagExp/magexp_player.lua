-- ============================================================
-- Spell Framework Plus for OpenMW
-- magexp_player.lua (PLAYER script)
-- ============================================================

local self    = require('openmw.self')
local core    = require('openmw.core')
local types   = require('openmw.types')
local anim    = require('openmw.animation')
local storage = require('openmw.storage')
local ui      = require('openmw.ui')
local camera  = require('openmw.camera')
local util    = require('openmw.util')
local debug   = require('openmw.debug')
local vfs     = require('openmw.vfs')
local I       = require('openmw.interfaces')
local async   = require('openmw.async')
local nearby  = require('openmw.nearby')

local C = require('scripts/OMW_MagExp/magexp_constants')
local Helpers = require('scripts/OMW_MagExp/magexp_helpers')
local SkillModes = require('scripts/OMW_MagExp/magexp_skillmodes')
local LocalEquip = require('scripts/OMW_MagExp/magexp_local_equip')
local debugLog = require('scripts/OMW_MagExp/magexp_logger').new('[MagExp-Player]')


-- ---- State Management ----
local busyUntil        = 0
local hasQueuedLaunch  = false
local pendingLaunches  = {}

-- ---- [FEATURE 5] Charged Spell State ----
local currentChargeData = nil

-- ---- [CHARGE-AS-CAST] ----
local pendingChargeKey = nil

-- ============================================================
-- [OSSC DETECTION] Optional OSSC integration
-- ============================================================
-- True when Oblivion-Style Spell Casting is installed. When it is, OSSC's own
-- player script plays the OSSC cast animation groups and, on their 'start'
-- text key, already spawns the on-caster cast VFX + cast sound it wants (its
-- EnablePlayerSwirls / EnableHandSwirls / EnableCastGlow visuals). This MagExp
-- player whitelists those same groups (and the native 'spellcast' group) and
-- would otherwise ALSO fire MagExp_CastStart on the identical 'start' key,
-- making the global script draw a second school-coloured "cast VFX around the
-- player" on every quick-cast (and on every SFP-latched spell-stance cast).
-- When OSSC is present it owns player cast VFX, so this layer must not
-- double-spawn.
--
-- Presence is decided by the LOAD ORDER (Helpers.isOsscInstalled), never by
-- probing storage.playerSection('SettingsOSSC_General'). Asking the engine for
-- a settings section CREATES that section, so the old probe installed the very
-- evidence it was looking for: every machine that had ever loaded SFP reported
-- OSSC as present, this layer then suppressed its own cast VFX, and with no
-- OSSC there to draw them the player saw no cast effects at all.
local function osccOwnsPlayerCastVfx()
    return Helpers.isOsscInstalled()
end

-- OSSC's own debug flag. Read through the settings section only once OSSC is
-- known to be installed - when it is, the section genuinely exists and reading
-- it is harmless; before that, touching it would create it.
local function isOsscDebugEnabled()
    if not Helpers.isOsscInstalled() then return false end
    local s = storage.playerSection('SettingsOSSC_General')
    return s ~= nil and s:get('DebugMode') == true
end

-- ============================================================
-- [SPEEDYMAGICK DETECTION]
-- Decided by the load order; see Helpers.isSpeedyMagickInstalled.
-- ============================================================
local function isSpeedyMagickInstalled()
    return Helpers.isSpeedyMagickInstalled()
end

local function getSpeedyMagickSpeedMult()
    if not isSpeedyMagickInstalled() then return 1.0 end
    local spd = types.Actor.stats.attributes.speed(self).modified
    if not spd or spd <= 0 then spd = 50.0 end
    return 2.0 / (1.0 + 2.0 ^ -(spd / 100.0))
end

-- ============================================================
-- [SUS DETECTION] Skill Uses Scaled
-- ============================================================
-- SUS ships its Lua module under two spellings, so the module name alone cannot
-- be required blindly: for whichever spelling is NOT installed, `require` raises
-- "module not found". The VFS is asked which file is really present first, and
-- only that one is required — so no call here has to catch its own error, and a
-- load error raised by SUS itself still surfaces instead of being swallowed.
--
-- Whether SUS is loaded at all is decided by the load order, the same rule the
-- OSSC and SpeedyMagick checks use (a settings-section probe would create the
-- section it looks for). The file name is folded to letters and digits before
-- the match, so no release name spelling has to be guessed.
local SUS_CONTENT_FILE_HINT = 'skillusesscaled'
local SUS_MODULE_PATHS = {
    'scripts.Skill_Uses_Scaled.data',
    'scripts.skill_uses_scaled.data',
}

--- Module-name -> file mapping, the engine's own (packageNameToPath in
--- components/lua/luastate.cpp: dots become slashes, then ".lua" or
--- "/init.lua"). `openmw.vfs` answers without raising, so this is a question
--- about the data files rather than an attempt at loading them.
local function susModuleFileExists(modulePath)
    local vfsPath = modulePath:gsub('%.', '/')
    return vfs.fileExists(vfsPath .. '.lua') or vfs.fileExists(vfsPath .. '/init.lua')
end

local susInstalledCache = nil
local function isSusInstalled()
    if susInstalledCache == nil then
        -- The load order is the primary signal; the module files cover a
        -- renamed or merged download, where the content-file name cannot be
        -- recognised. Both are cheap and neither touches a settings section.
        susInstalledCache = Helpers.hasContentFileMatching(SUS_CONTENT_FILE_HINT)
        if not susInstalledCache then
            for _, modulePath in ipairs(SUS_MODULE_PATHS) do
                if susModuleFileExists(modulePath) then
                    susInstalledCache = true
                    break
                end
            end
        end
    end
    return susInstalledCache
end

--- The installed SUS module, or nil. Only paths whose file is in the VFS are
--- required, so a `require` can never land on a missing module; a load error
--- coming from SUS itself is left to surface.
local function loadSusModule()
    for _, modulePath in ipairs(SUS_MODULE_PATHS) do
        if susModuleFileExists(modulePath) then
            local module = require(modulePath)
            if module and module.pc then return module end
        end
    end
    return nil
end

-- ============================================================
-- [CAST START GROUP WHITELIST]
-- Only these groups trigger casting VFX on their 'start' key.
-- We deliberately exclude "spellcast" and release-phase groups.
-- ============================================================
local VFX_CAST_GROUPS = {
    quickcast = true,
    quickbuff = true,
    qcconj    = true,
    qctouch   = true,
    qcalt     = true,
    qcalts    = true,
    qcill     = true,
    qcsnap    = true,
    qcdrain   = true,
    qcskrow   = true,
}

local castStartLatched = {}
local vfxTriggeredThisCast = false
local lastCastStartSentTime = -999
local lastCastStartSpellId  = nil
local pendingCastSpellId = nil
local hasPendingCastSpellId = false

local function shouldTriggerVfxOnStart(groupname)
    local g = tostring(groupname or ""):lower()
    return VFX_CAST_GROUPS[g] == true
end

local function isWhitelistedCastGroup(groupname)
    local g = tostring(groupname or ""):lower()
    return VFX_CAST_GROUPS[g] == true
end

local function sendCastStartNow(reason, groupname)
    -- OSSC already draws its own on-caster cast VFX on its cast groups' 'start'
    -- key. Suppress the duplicate MagExp_CastStart whenever OSSC is driving the
    -- player's cast presentation (see osccOwnsPlayerCastVfx above). The pending
    -- spell id is cleared too so it can never be mistaken for a still-pending
    -- cast if OSSC is ever unloaded mid-session.
    if osccOwnsPlayerCastVfx() then
        pendingCastSpellId = nil
        hasPendingCastSpellId = false
        return
    end

    if isOsscDebugEnabled() then
        debugLog("OSSC active - sending CastStart from MagExp for group: " .. tostring(groupname))
    end

    local t = core.getSimulationTime()
    local spellId
    if hasPendingCastSpellId then
        spellId = pendingCastSpellId
        hasPendingCastSpellId = false
    else
        local spell = types.Actor.getSelectedSpell(self)
        spellId = spell and spell.id
    end
    pendingCastSpellId = nil
    if not spellId then return end

    if lastCastStartSpellId == spellId and (t - lastCastStartSentTime) < 0.25 then
        return
    end

    lastCastStartSentTime = t
    lastCastStartSpellId  = spellId

    debugLog(string.format("CastStart (%s): group=%s spellId=%s", tostring(reason), tostring(groupname), tostring(spellId)))

    core.sendGlobalEvent('MagExp_CastStart', {
        attacker = self,
        spellId  = spellId,
    })
end

-- ============================================================
-- [HELPERS] Launch Parameter Calculation
-- ============================================================

local function calculateLaunchPayload(spell, item)
    local cameraMode = camera.getMode()
    local startPos, direction

    if cameraMode == camera.MODE.FirstPerson then
        startPos  = camera.getPosition()
        direction = camera.getViewDirection()
        startPos  = startPos + camera.getUp() * -10 + camera.getLeft() * 15
    else
        startPos  = self.position + util.vector3(0, 0, 120)
        direction = camera.getViewDirection()
        startPos  = startPos + camera.getLeft() * 25
    end

    debugLog("Starting raycast from:", startPos)
    debugLog("Direction:", direction)

    local hitObject = nil
    local hitPos    = nil

    -- nearby.castRay is an engine call. rayOk/rayErr only ever fed a debug
    -- line, so the wrapper bought nothing but a place for errors to hide.
    local endPos = startPos + direction * 300
    debugLog("Ray end position:", endPos)

    local rayResult = nearby.castRay(startPos, endPos, { ignore = self })
    debugLog("Raycast result:", rayResult)

    if rayResult then
        debugLog("Ray hit something!")
        debugLog("hitObject:", rayResult.hitObject)
        debugLog("hitPos:", rayResult.hitPos)
        if rayResult.hitObject then
            hitObject = rayResult.hitObject
            hitPos    = rayResult.hitPos
            debugLog("Hit object type:", hitObject.type)
            debugLog("Hit object recordId:", hitObject.recordId)
        end
    else
        debugLog("Raycast returned nil")
    end

     debugLog("Final hitObject for payload:", hitObject)

    return {
        attacker   = self,
        spellId    = spell.id,
        itemObject = item,
        startPos   = startPos,
        direction  = direction,
        isGodMode  = debug.isGodMode(),
        hitObject  = hitObject,
        hitPos     = hitPos,
    }
end

-- ============================================================
-- [INTERNAL] Charge key held check helper.
-- ============================================================
local function isChargeKeyCurrentlyHeld(keyId)
    if not keyId then return false end
    local result = false
    local fn = I.MagExp
               and I.MagExp._chargeKeyRegistry
               and I.MagExp._chargeKeyRegistry[keyId]
    if fn then result = fn() end
    return result
end

-- ============================================================
-- [CORE] Animation Sync & Lifecycle
-- ============================================================
-- ============================================================
-- CORE TEXT KEY HANDLER
-- ============================================================
local function onTextKey(groupname, key)
    local g = tostring(groupname or ""):lower()
    local k = tostring(key):lower()

    -- Parse compound text keys like "self start", "target release", "touch stop"
    local fst, snd = string.match(k, "([^ ]+) ([^ ]+)")
    local action = snd or k      -- "start", "release", "stop", etc.
    local targetType = snd and fst or nil -- "self", "target", "touch"

    -- VFX ONLY on the initial cast group's 'start' key
    if action == "start" then
        if (shouldTriggerVfxOnStart(g) or g == "spellcast") and not vfxTriggeredThisCast then
            vfxTriggeredThisCast = true
            castStartLatched[g] = true
            sendCastStartNow("textKey:start", g)
        end

        -- Accelerate OSSC cast animation speed if SpeedyMagick is active
        if isSpeedyMagickInstalled() and isWhitelistedCastGroup(g) then
            local speedMult = getSpeedyMagickSpeedMult()
            anim.setSpeed(self, g, speedMult)
        end
    end

    -- Reset on stop or release
    if action == "stop" or action == "release" then
        if isWhitelistedCastGroup(g) or g == "spellcast" then
            castStartLatched[g] = true
            vfxTriggeredThisCast = false
        end

        if speedymagickLatched then
            local spell = types.Actor.getSelectedSpell(self)
            if spell then
                debugLog(string.format("[SpeedyMagick] Text key '%s' reached — processing cast: %s", k, tostring(spell.id)))
                core.sendGlobalEvent('MagExp_ProcessCast', {
                    actor     = self,
                    spellId   = spell.id,
                    isFree    = true,   -- magicka handled by engine cast
                    isGodMode = debug.isGodMode()
                })
            end
            speedymagickLatched = false
        end
    end

    -- Only MagExp's own queued casts (OSSC path)
    if not hasQueuedLaunch then return end

    if action == "stop" or action == "release" then
        hasQueuedLaunch   = false
        pendingLaunches   = {}
        currentChargeData = nil
        pendingChargeKey  = nil
        vfxTriggeredThisCast = false
        return
    end
end
-- ============================================================
-- [SPEEDYMAGICK COMPATIBILITY HANDLER]
-- Detects casts initiated by omwSpeedyMagick (controls.use==1 in magic
-- stance) and ensures MagExp cast VFX + skill progression fires, while
-- letting the engine handle the actual spell effect via controls.use=1.
-- NO changes to SpeedyMagick required.
-- ============================================================
local speedymagickLatched = false
local speedymagickCastTime = 0

local function updateSpeedyMagickCompat(dt)
    local currentStance = types.Actor.getStance(self)

    -- 1. Detect when SpeedyMagick (or any non-OSSC path) initiates a cast:
    --    controls.use==1 in magic stance, while MagExp has NOT already started
    --    its own queued-launch pipeline (hasQueuedLaunch covers the OSSC path).
    if self.controls.use == 1 and currentStance == 2
            and not speedymagickLatched and not hasQueuedLaunch then
        local spell = types.Actor.getSelectedSpell(self)
        if spell then
            speedymagickLatched  = true
            speedymagickCastTime = core.getSimulationTime()
            debugLog("[SpeedyMagick] Cast latched for stance holding: " .. tostring(spell.id))
            -- NOTE: MagExp_CastStart VFX is triggered by the 'start' text-key in onTextKey.
            -- MagExp_ProcessCast is deferred to the 'release'/'stop' text-key phase in onTextKey.
            -- This avoids double-firing at cast initiation and aligns release perfectly.
        end
    end

    -- 2. While latched, hold the player in magic stance so the engine does
    --    not cancel the spellcast gesture before the animation completes.
    if speedymagickLatched then
        local now = core.getSimulationTime()
        local isPlaying = anim.isPlaying(self, 'spellcast')

        local speedMult = getSpeedyMagickSpeedMult()
        local maxHoldDuration = math.max(0.15, 0.40 / speedMult)

        if isPlaying or (now - speedymagickCastTime < maxHoldDuration) then
            if currentStance ~= 2 then
                types.Actor.setStance(self, 2)
            end
        else
            -- Animation finished or timed-out — release latch.
            speedymagickLatched = false
        end
    end
end

-- ============================================================
-- [UPDATE] Charge Key Polling + Cast latch safety cleanup
-- ============================================================
local function onUpdate(dt)
    updateSpeedyMagickCompat(dt)

    -- Charge loop polling
    if currentChargeData and currentChargeData.isCharging then
        local chargeKey = currentChargeData.chargeKey
        local isHeld    = isChargeKeyCurrentlyHeld(chargeKey)

        if not isHeld then
            debugLog("Charge key released — proceeding to release key")
            currentChargeData.isCharging = false
            pendingChargeKey = nil
            anim.play(self, currentChargeData.animGroup,
                currentChargeData.priority or 7,
                currentChargeData.blendMask or 15,
                false, 1.0)
        end
    end

    -- Safety: clear stale latches
    for g, _ in pairs(VFX_CAST_GROUPS) do
        local playing = anim.isPlaying(self, g)
        if not playing then
            castStartLatched[g] = nil
        end
    end
end

-- ============================================================
-- [EVENT] MagExp_StartQuickCast
-- ============================================================
local function startQuickCast(data)
    local spellId = data.spellId
    local spell   = core.magic.spells.records[spellId] or core.magic.enchantments.records[spellId]
    if not spell then return end

    debugLog("Initiating Quick Cast sequence for: " .. spellId)

    pendingChargeKey = data.chargeKey or nil

    -- Cast VFX is handled by the animation hooks (addPlayBlendedAnimationHandler / textKey:start).
    -- Do NOT send MagExp_CastStart here — it will be sent when the anim starts.
    core.sendGlobalEvent('MagExp_ProcessCast', {
        actor     = self,
        spellId   = spellId,
        item      = data.item,
        isFree    = data.isFree,
        isGodMode = debug.isGodMode()
    })
end

-- ============================================================
-- [EVENT] MagExp_CastResult
-- ============================================================
local function handleCastResult(data)
    if data.success then
        debugLog("Cast Authorization: SUCCESS")

        if speedymagickLatched then
            -- SpeedyMagick path: the engine + SpeedyMagick already started the 'spellcast'
            -- animation via controls.use=1, and SpeedyMagick's animHandler has already called
            -- setAnimSpeed(self, 'spellcast', speedMult) at 'touch/self/target start'.
            -- DO NOT call anim.playBlended here — it would restart the animation from the
            -- beginning at the default speed of 1.0, overriding SpeedyMagick's acceleration.
            -- MagExp_CastStart VFX was already fired in updateSpeedyMagickCompat; skill
            -- progression is handled by the isFree=true MagExp_ProcessCast we already sent.
            -- Just release the latch so stance guard cleans up naturally.
            debugLog(string.format("[SpeedyMagick] Cast confirmed (speedMult=%.3f) — animation already running, not replaying",
                getSpeedyMagickSpeedMult()))
        else
            -- Normal OSSC / MagExp_StartQuickCast path: play animation ourselves
            hasQueuedLaunch = true
            pendingLaunches[data.spellId] = data.item
            anim.playBlended(self, "spellcast", { priority = 1, blend = 0.2 })
        end
    else
        debugLog("Cast Authorization: FAILED (Roll/Magicka)")
        ui.showMessage(C.MSG.SPELL_FAILED)
        pendingChargeKey = nil
        speedymagickLatched = false
    end
end

-- ============================================================
-- ANIMATION HOOKS
-- ============================================================
if I.AnimationController then
    I.AnimationController.addTextKeyHandler('', onTextKey)

    if I.AnimationController.addPlayBlendedAnimationHandler then
        I.AnimationController.addPlayBlendedAnimationHandler(function(groupname, options)
            local g = tostring(groupname or ""):lower()
            if isWhitelistedCastGroup(g) then
                castStartLatched[g] = false   -- reset latch so 'start' key can fire VFX
            end
        end)
    end
end

-- ============================================================
-- EVENT + ENGINE HANDLER TABLE
-- ============================================================
--- Exactly one visible notice per block event.
---
--- `ui.showMessage` is suppressed while the world is paused (Barter,
--- Container and Inventory menus), and both block notices are delivered
--- while such a menu is still open.  The pause state is the same signal
--- the engine uses for the suppression, so it decides the delivery: an
--- unpaused frame shows the notice immediately, a paused frame defers a
--- single unsavable simulation timer — simulation time only advances
--- once the world is unpaused, so the deferred call always lands on a
--- visible frame after the menu closes.  Never both, so the notice can
--- neither vanish (the invisible sell-block message this exists to fix)
--- nor stack up three lines per drop (the blind-retry pattern it
--- replaces).
local function showBoundNoticeOnce(msg)
    if core.isWorldPaused and core.isWorldPaused() then
        async:newUnsavableSimulationTimer(0.05, function() ui.showMessage(msg) end)
    else
        ui.showMessage(msg)
    end
end

local handlers = {
    engineHandlers = {
        onUpdate = onUpdate,
    },
    eventHandlers = {
        MagExp_StartQuickCast = startQuickCast,
        MagExp_CastResult     = handleCastResult,
        --- The global effect-penalty sweep hands the reduced twin of a bound
        --- item to the player's own script, because `types.Actor.setEquipment`
        --- is a self-only binding: a global script that equiped it for the
        --- player would raise "Allowed only in local scripts for
        --- 'openmw.self'".  The swap is reported back so the sweep can remove
        --- the full-strength original (see magexp_local_equip.lua).
        MagExp_EquipReducedItem = function(data)
            return LocalEquip.onRequest(self, data)
        end,
        --- The global drop-protection sweep puts a conjured reduced bound
        --- item back into the caster's inventory the frame after it is
        --- dragged to the ground (a bound item may not be given away while
        --- its spell lasts).  ui.showMessage is player-scope-only, which is
        --- why the sweep sends this event instead of speaking itself.
        ---
        --- Barter and container menus pause the world (isWorldPaused) and
        --- suppress ui.showMessage while open — the sell-block notice is
        --- delivered during Barter mode, so an immediate showMessage would
        --- be invisible.  showBoundNoticeOnce gates on that same pause
        --- state: when the world is running the notice is shown once right
        --- away, and when it is paused exactly one unsavable simulation
        --- timer defers it until the menu closes (simulation time only
        --- advances once the world is unpaused, so the deferred call always
        --- lands on a visible frame).  Either way the player sees the
        --- notice exactly once per block — the retired implementation
        --- printed an unconditional message plus two blind retries, which
        --- stacked up to three identical lines on every drop.
        MagExp_BoundItemDropBlocked = function(data)
            showBoundNoticeOnce('You cannot drop summoned items!')
        end,
        MagExp_BoundItemSellBlocked = function(data)
            showBoundNoticeOnce('You cannot sell summoned items!')
        end,
        --- This event sets spell id that is used later to display VFX around the player.
        --- Without it VFX is based on currently equipped spell, which is OK for most cases. 
        MagExp_SetPendingCastSpellId = function(evt)
            pendingCastSpellId = evt and evt.spellId
            hasPendingCastSpellId = true
            debugLog("Set pendingCastSpellId:", pendingCastSpellId)
        end,

        -- [SKILL] Progression from global script
        MagExp_AwardSkillProgress = function(data)
            if not data or not data.school then return end

            local skillMap = {
                alteration  = "alteration",
                conjuration = "conjuration",
                destruction = "destruction",
                illusion    = "illusion",
                mysticism   = "mysticism",
                restoration = "restoration",
            }

            local skillId = skillMap[data.school:lower()]
            if not skillId then
                debugLog("Unknown school for skill progression:", tostring(data.school))
                return
            end
            
            -- Settings are registered in a GLOBAL script (magexp_settings.lua),
            -- so they live in GLOBAL storage. Prefer that; fall back to player
            -- storage for saves that used the older player-section layout.
            local section = storage.globalSection('SettingsMagExp_General') or storage.playerSection('SettingsMagExp_General')
            -- Reading through SkillModes normalises the dropped 'ncg+se (auto)'
            -- choice to 'skillevo' even in a save the settings script has not
            -- rewritten yet.
            local spMode  = SkillModes.normalize(section and section:get('SkillProgressionMode'))
            
            debugLog("[MagExp] SkillProgressionMode = " .. spMode)

            local function awardSkillXP_MagExp(sId)
                local skillStat = types.Player.stats.skills[sId]
                if not skillStat then return end
                local stat = skillStat(self)
                if not stat or stat.progress == nil then return end

                local cost = data.cost or 0
                local mult = section and section:get('MagickaXPMult') or 0.1

                local baseGain = 1.0
                local skillRec = core.stats.Skill.records[sId]
                if skillRec and skillRec.useValue0 then
                    baseGain = skillRec.useValue0
                end

                -- Internal scaling if 'magexp' mode is chosen
                local progress = cost * mult
                if progress <= 0 then progress = baseGain end -- fallback to vanilla baseGain

                stat.progress = stat.progress + progress
                debugLog(string.format("Awarded %.2f progress (baseGain=%.2f) to %s", progress, baseGain, sId))
            end

            local function awardSkillXP_External(sId)
                if not (I.SkillProgression and I.SkillProgression.skillUsed) then
                    debugLog("[MagExp] skillUsed unavailable, falling back to internal.")
                    awardSkillXP_MagExp(sId)
                    return
                end
                local useType = data.isEnchant
                    and I.SkillProgression.SKILL_USE_TYPES.Enchant_UseEnchantedItem
                    or  I.SkillProgression.SKILL_USE_TYPES.Spellcast_Success
                
                async.newUnsavableSimulationTimer(0.2, function()
                    -- A cross-mod interface call, and left unguarded on
                    -- purpose. The nil-check above already proved skillUsed
                    -- exists; if the other mod's own code errors, that is its
                    -- bug to surface, not something to route around silently.
                    I.SkillProgression.skillUsed(sId, { useType = useType })
                end)
            end

            local function awardSkillXP_SUS(sId)
                if not (I.SkillProgression and I.SkillProgression.skillUsed) then
                    debugLog("[MagExp] SUS: skillUsed unavailable, falling back to internal.")
                    awardSkillXP_MagExp(sId)
                    return
                end
                local useType = data.isEnchant
                    and I.SkillProgression.SKILL_USE_TYPES.Enchant_UseEnchantedItem
                    or  I.SkillProgression.SKILL_USE_TYPES.Spellcast_Success

                local spellForSus = nil
                if data.spellId then
                    spellForSus = core.magic.spells.records[data.spellId]
                    if not spellForSus then -- wrap custom spells
                        spellForSus = { id = data.spellId, cost = data.cost }
                    end
                end

                -- Only reach into SUS's module when the load order (or its own
                -- files) says SUS is there. When it is, exactly one of the two
                -- shipped spellings exists, so both the probe and the require
                -- stay name-based decisions instead of attempts.
                local dtSus, prevSpell = nil, nil
                if isSusInstalled() then
                    dtSus = loadSusModule()
                end
                if dtSus and spellForSus then
                    prevSpell = dtSus.pc.spell
                    dtSus.pc.spell = spellForSus
                    debugLog("[MagExp] SUS: patched spell pointer")
                end

                local capturedDtSus = dtSus
                local capturedPrevSpell = prevSpell
                async.newUnsavableSimulationTimer(0.2, function()
                    I.SkillProgression.skillUsed(sId, { useType = useType })
                    if capturedDtSus then capturedDtSus.pc.spell = capturedPrevSpell end
                end)
            end

            -- Dispatcher. 'none' awards nothing at all, so the whole path is
            -- skipped rather than routed to a formula.  The mod that turned it
            -- off still needs to hear that a cast happened, or it has nothing
            -- to call I.MagExp_Player.awardSkillProgress for.
            if SkillModes.isDisabled(spMode) then
                debugLog("[MagExp] skill progression disabled by setting")
                core.sendGlobalEvent('MagExp_SkillProgressSkipped', {
                    actor     = self,
                    skillId   = skillId,
                    school    = data.school,
                    spellId   = data.spellId,
                    cost      = data.cost or 0,
                    isEnchant = data.isEnchant == true,
                })
            elseif spMode == 'magexp' then
                awardSkillXP_MagExp(skillId)
            elseif SkillModes.isExternal(spMode) then
                awardSkillXP_External(skillId)
            elseif spMode == 'sus' then
                awardSkillXP_SUS(skillId)
            else
                awardSkillXP_MagExp(skillId)
            end
        end,

        -- [FEATURE 5] Custom animation override from launchSpellAnim()
        MagExp_PlaySpellAnim = function(data)
            if not data or not data.animGroup then return end
            local group    = data.animGroup
            local mask     = data.blendMask or 15
            local priority = data.priority  or 7
            local speed    = getSpeedyMagickSpeedMult()

            debugLog("PlaySpellAnim: " .. group .. " (priority=" .. priority .. " mask=" .. mask .. " speed=" .. speed .. ")")
            anim.play(self, group, priority, mask, false, speed)

            if data.isCharged then
                currentChargeData = {
                    animGroup  = group,
                    chargeKey  = data.chargeKey,
                    priority   = priority,
                    blendMask  = mask,
                    isCharging = true,
                }
                debugLog("Charged spell started:", group, "key=", tostring(data.chargeKey))
            end
        end,

        -- [FEATURE 5] Graceful release of charged spell animation
        MagExp_ReleaseSpellAnim = function(data)
            if not data or not data.animGroup then return end
            local speed = getSpeedyMagickSpeedMult()
            debugLog("MagExp_ReleaseSpellAnim: " .. data.animGroup .. " (speed=" .. speed .. ")")
            anim.play(self, data.animGroup,
                currentChargeData and currentChargeData.priority or 7,
                currentChargeData and currentChargeData.blendMask or 15,
                false, speed)
            if currentChargeData then
                currentChargeData.isCharging = false
            end
        end,

        -- VFX Utilities
        AddVfx = function(data)
            if not data or not data.model then return end
            debugLog(string.format("AddVfx model=%s vfxId=%s bone=%s",
                tostring(data.model),
                tostring(data.options and data.options.vfxId),
                tostring(data.options and data.options.boneName)
            ))
            anim.addVfx(self, data.model, data.options)
        end,

        RemoveVfx = function(vfxId)
            anim.removeVfx(self, vfxId)
        end,

        RemoveVfxDirect = function(vfxId)
            anim.removeVfx(self, vfxId)
        end,

        -- UI Utilities
        Ui_ShowMessage = function(msg)
            if type(msg) == "string" then ui.showMessage(msg) end
        end,

        -- Resource consumption
        MagExp_ConsumeResource = function(data)
            debugLog('ConsumeResource: magicka:', data.magickaCost, ', items:', data.itemCountCost)
            if data.magickaCost then
                local magicka = types.Actor.stats.dynamic.magicka(self)
                -- [MAGICKA TRACE] One of three deduction sites; see the
                -- matching trace in consumeSpellCost and in OSSC's
                -- handleCastCosts. A cast that is charged twice shows up as
                -- two of these lines with the same cost.
                local before = magicka.current
                magicka.current = math.max(0, magicka.current - data.magickaCost)
                debugLog(string.format(
                    '[MAGICKA TRACE] deduct %.2f via MagExp_ConsumeResource (launch-time resource guard): %.2f -> %.2f',
                    data.magickaCost, before, magicka.current))
            end
            if (data.itemCountCost and data.itemRecordId) or (data.itemChargeCost and data.itemRecordId) then
                core.sendGlobalEvent('MagExp_ApplyInventoryConsume', {
                    attacker       = self,
                    item           = data.item,
                    itemCountCost  = data.itemCountCost,
                    itemRecordId   = data.itemRecordId,
                    itemChargeCost = data.itemChargeCost,
                })
            end
        end,
    }
}

-- ============================================================
-- [SKILL] Public skill-progression entry point
--
-- 'none' in the Skill Progression Mode setting means SFP awards no experience
-- at all, because another mod owns spellcasting progression.  That other mod
-- needs a supported way to apply its own gain - without one, 'none' leaves it
-- writing skill.progress by hand and re-implementing Morrowind's level-up
-- bookkeeping.  So the award function lives here, on the public interface, and
-- is deliberately NOT gated by the setting.
-- ============================================================

--- Level the player's skill the way Morrowind does when a use crosses the
--- requirement: base + 1, the "skill up" message and sound, and the level
--- counters that feed the attribute / specialization bonuses at level up.
--- Setting skill.progress alone does none of this - the engine only stores it
--- (SkillStat::setValue → NpcStats::setSkill), it never levels from a write.
local function raisePlayerSkill(skillId, newBase)
    local accessor = types.Player.stats.skills[skillId]
    local skill = accessor and accessor(self)
    if not skill then return end
    skill.base = newBase

    local rec = core.stats.Skill.records[skillId]
    local displayName = (rec and rec.name) or skillId
    local skillName = core.getGMST('sSkill' .. displayName) or displayName
    local skillUpMsg = core.getGMST('sSkillUp') or 'Your %s skill has increased to %d.'
    ui.showMessage(string.format(skillUpMsg, skillName, newBase))
    core.sound.playSound3d('skillraise', self)

    local levelStats = types.Player.stats.level(self)
    if levelStats then
        levelStats.progress = (levelStats.progress or 0) + 1
        if rec and rec.attribute then
            levelStats.skillIncreasesForAttribute[rec.attribute] =
                (levelStats.skillIncreasesForAttribute[rec.attribute] or 0) + 1
        end
        if rec and rec.specialization then
            levelStats.skillIncreasesForSpecialization[rec.specialization] =
                (levelStats.skillIncreasesForSpecialization[rec.specialization] or 0) + 1
        end
    end
end

--- The gain SFP's own formula would award, used when the caller does not say
--- how much: cost * MagickaXPMult, falling back to the skill record's vanilla
--- base gain - exactly what the internal 'magexp' mode computes.
local function defaultSkillGain(skillId, cost)
    local section = storage.globalSection('SettingsMagExp_General')
        or storage.playerSection('SettingsMagExp_General')
    local mult = (section and section:get('MagickaXPMult')) or 0.1
    local progress = (tonumber(cost) or 0) * mult
    if progress > 0 then return progress end
    local skillRec = core.stats.Skill.records[skillId]
    return (skillRec and tonumber(skillRec.useValue0)) or 1.0
end

--- Award spellcasting skill experience to the player.
---
---     I.MagExp_Player.awardSkillProgress('destruction', { skillGain = 0.35 })
---
--- Works whatever the Skill Progression Mode setting says, 'none' included.
---
--- @param skillId string  skill record id: 'destruction', 'enchant', ... or a
---                        custom skill added by another framework
--- @param options table?
---   skillGain number   progress to add, in the unit skill.progress is exposed
---                      in: 1.0 == one skill level.  Major / minor /
---                      specialization bonuses are NOT applied - the caller
---                      owns the formula.
---   cost      number   spell cost, used for the default gain when skillGain
---                      is absent (SFP's own cost * MagickaXPMult formula)
---   useType   number   SkillProgression use type, forwarded on backend = 'external'
---   backend   string   'stat' (default): apply it to the player's skill here.
---                      'external': hand the use to I.SkillProgression.skillUsed
---                      (NCG / Skill Evolution / MBSP / SUS), which then owns
---                      the formula.
--- @return boolean true when the gain was applied or handed on
--- @return string? why it was not, when it was not
local function awardSkillProgress(skillId, options)
    options = (type(options) == 'table') and options or {}
    if type(skillId) ~= 'string' or skillId == '' then
        return false, 'skillId must be a non-empty string'
    end

    local accessor = types.Player.stats.skills[skillId]
    if not accessor then return false, 'unknown skill: ' .. skillId end
    local stat = accessor(self)
    if not stat or stat.progress == nil then
        return false, 'skill stat is not available: ' .. skillId
    end
    if (stat.base or 0) >= 100 then return false, 'skill is already at 100' end

    if options.backend == 'external' then
        if not (I.SkillProgression and I.SkillProgression.skillUsed) then
            return false, 'no external skill-progression interface is installed'
        end
        I.SkillProgression.skillUsed(skillId, {
            useType   = options.useType
                or I.SkillProgression.SKILL_USE_TYPES.Spellcast_Success,
            skillGain = tonumber(options.skillGain),
        })
        debugLog(string.format('[SKILL] handed %s to I.SkillProgression.skillUsed', skillId))
        return true
    end

    local gain = tonumber(options.skillGain) or defaultSkillGain(skillId, options.cost)
    if gain <= 0 then return false, 'nothing to award' end

    -- skill.progress is 0..1 of the requirement, so crossing 1.0 is a level.
    local progress = stat.progress + gain
    local base = stat.base
    while progress >= 1.0 and base < 100 do
        base = base + 1
        progress = progress - 1.0
        raisePlayerSkill(skillId, base)
    end
    stat.progress = math.max(0, progress)
    debugLog(string.format('[SKILL] awarded %.2f progress to %s (base now %d)',
        gain, skillId, base))
    return true
end

-- ============================================================
-- [PUBLIC LOCAL API] For other player scripts
-- ============================================================
local MagExp_PlayerInterface = {
    Helpers = Helpers,

    --- Award skill experience to the player, whatever the Skill Progression
    --- Mode setting says.  See awardSkillProgress above; this is the hook a
    --- mod uses after setting the mode to 'none'.
    awardSkillProgress = awardSkillProgress,
    consumeSpellCost = function(spellId, itemObject)
        if debug.isGodMode() then return true end
        local spell = core.magic.spells.records[spellId]
        local isEnchantment = false
        if not spell then
            spell = core.magic.enchantments.records[spellId]
            isEnchantment = spell ~= nil
        end
        if not spell then return true end
        local cost = Helpers.getModifiedSpellCost(self, spellId, isEnchantment) --TODO: add option to override the spell cost?
        if cost <= 0 and spell.type ~= core.magic.ENCHANTMENT_TYPE.CastOnce then return true end

        if isEnchantment and itemObject and type(itemObject) ~= "string" and itemObject:isValid() then
            if spell.type == core.magic.ENCHANTMENT_TYPE.CastOnce then
                if itemObject.count > 0 then
                    core.sendGlobalEvent('MagExp_ApplyInventoryConsume', {
                        attacker = self,
                        item = itemObject,
                        itemCountCost = 1,
                        itemRecordId = itemObject.recordId,
                    })
                    return true
                else
                    ui.showMessage(C.MSG.INSUFFICIENT_ITEMS)
                    return false
                end
            else
                local currentCharge, haveCharge = 0, false
                local itemData = types.Item.itemData(itemObject)
                if itemData and itemData.enchantmentCharge ~= nil then
                    currentCharge = itemData.enchantmentCharge
                    haveCharge = true
                end
                if not haveCharge then
                    currentCharge = spell.charge or 0
                end
                if currentCharge >= cost then
                    core.sendGlobalEvent('MagExp_ApplyInventoryConsume', {
                        attacker = self,
                        item = itemObject,
                        itemChargeCost = cost,
                        itemRecordId = itemObject.recordId,
                    })
                    return true
                else
                    ui.showMessage(C.MSG.INSUFFICIENT_CHARGE)
                    return false
                end
            end
        else
            local magicka = types.Actor.stats.dynamic.magicka(self)
            if magicka.current >= cost then
                -- [MAGICKA TRACE] One of three deduction sites; see the
                -- matching trace in MagExp_ConsumeResource and in OSSC's
                -- handleCastCosts. This one runs at ANIMATION START, when OSSC
                -- calls consumeSpellCost, and is the site that should pay for a
                -- quick-cast - the launch then goes out with isFree = true so
                -- the resource guard above is skipped.
                local before = magicka.current
                magicka.current = magicka.current - cost
                debugLog(string.format(
                    '[MAGICKA TRACE] deduct %.2f via consumeSpellCost (animation start): %.2f -> %.2f',
                    cost, before, magicka.current))
                return true
            else
                -- Log the refusal too: the reported "silent failure" is a cast
                -- that was refused without the player being told why.
                debugLog(string.format(
                    '[MAGICKA TRACE] REFUSED via consumeSpellCost: need %.2f, have %.2f (spell %s)',
                    cost, magicka.current, tostring(spellId)))
                ui.showMessage(C.MSG.INSUFFICIENT_MAGICKA)
                return false
            end
        end
    end
}

return {
    interfaceName  = "MagExp_Player",
    interface      = MagExp_PlayerInterface,
    engineHandlers = handlers.engineHandlers,
    eventHandlers  = handlers.eventHandlers,
}