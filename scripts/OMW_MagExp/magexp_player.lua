-- ============================================================
-- OMW_MagExp: Magic Expansion Framework for OpenMW
-- magexp_player.lua (PLAYER script)
-- ============================================================

local self    = require('openmw.self')
local core    = require('openmw.core')
local types   = require('openmw.types')
local anim    = require('openmw.animation')
local input   = require('openmw.input')
local storage = require('openmw.storage')
local ui      = require('openmw.ui')
local camera  = require('openmw.camera')
local util    = require('openmw.util')
local debug   = require('openmw.debug')
local I       = require('openmw.interfaces')

-- ---- State Management ----
local busyUntil        = 0
local hasQueuedLaunch  = false
local pendingLaunches  = {}

-- ---- [FEATURE 5] Charged Spell State ----
local currentChargeData = nil  -- { animGroup, chargeKey, priority, blendMask, isCharging }

-- ============================================================
-- [OSSC DETECTION] Optional OSSC integration
-- OSSC-specific code (debug logging, per-school speed overrides) is only
-- activated when OSSC's storage sections are detected as present.
-- Detection is done once at startup via pcall so it never throws.
-- ============================================================
local IS_OSSC_LOADED = false
pcall(function()
    local s = storage.playerSection('SettingsOSSC_General')
    -- OSSC registers 'DebugMode' key during its init; if it's present, the mod is loaded.
    IS_OSSC_LOADED = (s ~= nil and s:get('DebugMode') ~= nil)
end)

local function debugLog(msg)
    if not IS_OSSC_LOADED then return end
    local section = storage.playerSection('SettingsOSSC_General')
    if section and section:get('DebugMode') then
        print("[MagExp-Player] " .. tostring(msg))
    end
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
        -- Nudge from hand in 1st person
        startPos = startPos + camera.getUp() * -10 + camera.getLeft() * 15
    else
        startPos  = self.position + util.vector3(0, 0, 120) -- Chest level
        direction = camera.getViewDirection()
        -- Nudge from left hand toward crosshair
        startPos = startPos + camera.getLeft() * 25
    end

    return {
        attacker   = self,
        spellId    = spell.id,
        itemObject = item,
        startPos   = startPos,
        direction  = direction,
        isGodMode  = debug.isGodMode()
    }
end

-- ============================================================
-- [CORE] Animation Sync & Lifecycle
-- ============================================================
local function onTextKey(groupname, key)
    if not hasQueuedLaunch then return end

    local k = tostring(key):lower()
    if k == "release" or k == "spellcast" then
        debugLog("Animation Release Key Detected: " .. k)
        for spellId, item in pairs(pendingLaunches) do
            local spell = core.magic.spells.records[spellId] or core.magic.enchantments.records[spellId]
            if spell then
                local payload = calculateLaunchPayload(spell, item)
                core.sendGlobalEvent('MagExp_CastRequest', payload)
            end
        end
        pendingLaunches  = {}
        hasQueuedLaunch  = false
        -- Clear charge state once the spell has fired at 'release'
        if currentChargeData then
            currentChargeData.isCharging = false
        end
    elseif k == "stop" then
        hasQueuedLaunch = false
        pendingLaunches = {}
        currentChargeData = nil
    end
end

-- ============================================================
-- [UPDATE] Charge Key Polling
-- [FEATURE 6] Poll registered charge key each frame.
-- When the key is released, let the animation proceed to 'release' naturally.
-- ============================================================
local function onUpdate(dt)
    if currentChargeData and currentChargeData.isCharging then
        local chargeKey = currentChargeData.chargeKey
        local isHeld    = false

        if chargeKey then
            pcall(function()
                local fn = I.MagExp and I.MagExp._chargeKeyRegistry and I.MagExp._chargeKeyRegistry[chargeKey]
                if fn then isHeld = fn() end
            end)
        end

        if not isHeld then
            -- Key released: resume animation at normal speed so it reaches 'release' naturally.
            -- The onTextKey 'release' handler above will then fire the spell.
            debugLog("Charge key released — proceeding to release key")
            currentChargeData.isCharging = false
            pcall(function()
                anim.play(self, currentChargeData.animGroup,
                    currentChargeData.priority or 7,
                    currentChargeData.blendMask or 15,
                    false, 1.0)
            end)
        end
    end
end

-- ============================================================
-- [EVENT] MagExp_StartQuickCast
-- ============================================================
local function startQuickCast(data)
    local spellId = data.spellId
    local spell = core.magic.spells.records[spellId] or core.magic.enchantments.records[spellId]
    if not spell then return end

    debugLog("Initiating Quick Cast sequence for: " .. spellId)

    -- Request Authority validation from Global
    core.sendGlobalEvent('MagExp_ProcessCast', {
        actor     = self,
        spellId   = spellId,
        item      = data.item,
        isFree    = data.isFree,
        isGodMode = debug.isGodMode()
    })
end

local function handleCastResult(data)
    if data.success then
        debugLog("Cast Authorization: SUCCESS")
        hasQueuedLaunch = true
        pendingLaunches[data.spellId] = data.item

        -- Trigger casting animation (0.94s duration match)
        anim.playBlended(self, "spellcast", { priority = 1, blend = 0.2 })
    else
        debugLog("Cast Authorization: FAILED (Roll/Magicka)")
    end
end

if I.AnimationController then
    -- Catch all animation text keys across any played group (empty string catches all)
    I.AnimationController.addTextKeyHandler('', onTextKey)
end

return {
    engineHandlers = {
        onUpdate  = onUpdate,
    },
    eventHandlers = {
        MagExp_StartQuickCast = startQuickCast,
        MagExp_CastResult     = handleCastResult,

        -- [FEATURE 5] Custom animation override from launchSpellAnim()
        MagExp_PlaySpellAnim = function(data)
            if not data or not data.animGroup then return end
            local group    = data.animGroup
            local mask     = data.blendMask or 15
            local priority = data.priority  or 7

            debugLog("MagExp_PlaySpellAnim: " .. group .. " (priority=" .. priority .. " mask=" .. mask .. ")")
            pcall(function()
                anim.play(self, group, priority, mask, false, 1.0)
            end)

            if data.isCharged then
                -- Register charge hold state; onUpdate will poll the key each frame
                currentChargeData = {
                    animGroup  = group,
                    chargeKey  = data.chargeKey,
                    priority   = priority,
                    blendMask  = mask,
                    isCharging = true,
                }
                debugLog("Charged spell started: " .. group .. " key=" .. tostring(data.chargeKey))
            end
        end,

        -- [FEATURE 5] Graceful release: does NOT cancel. Resumes normal playback so
        -- the 'release' text key fires naturally → spell launches → 'stop' clears state.
        MagExp_ReleaseSpellAnim = function(data)
            if not data or not data.animGroup then return end
            debugLog("MagExp_ReleaseSpellAnim: " .. data.animGroup)
            pcall(function()
                anim.play(self, data.animGroup,
                    currentChargeData and currentChargeData.priority or 7,
                    currentChargeData and currentChargeData.blendMask or 15,
                    false, 1.0)  -- no loop → plays through to 'release' then 'stop'
            end)
            if currentChargeData then
                currentChargeData.isCharging = false
            end
        end,

        -- VFX Utilities
        AddVfx = function(data)
            pcall(function() anim.addVfx(self, data.model, data.options) end)
        end,
        RemoveVfx = function(vfxId)
            pcall(function() anim.removeVfx(self, vfxId) end)
        end,
    }
}
