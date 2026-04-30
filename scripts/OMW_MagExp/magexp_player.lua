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
    if k == "release" then
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

local handlers = {
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
 
                anim.play(self, group, priority, mask, false, 1.0)
            

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
            anim.addVfx(self, data.model, data.options) end
        end,
        RemoveVfx = function(vfxId)
            anim.removeVfx(self, vfxId) end
        end,
        
        -- UI Utilities
        Ui_ShowMessage = function(msg)
            if type(msg) == "string" then ui.showMessage(msg) end
        end,

        -- Resource Consumption (Requires Local Script Context)
        MagExp_ConsumeResource = function(data)
            pcall(function()
                if data.magickaCost then
                    local magicka = types.Actor.stats.dynamic.magicka(self)
                    magicka.current = math.max(0, magicka.current - data.magickaCost)
                end
                if data.itemCountCost and data.itemRecordId then
                    local inv = types.Actor.inventory(self)
                    local item = inv:find(data.itemRecordId)
                    if item then item:remove(data.itemCountCost) end
                end
                if data.itemChargeCost and data.itemRecordId then
                    local inv = types.Actor.inventory(self)
                    local item = inv:find(data.itemRecordId)
                    if item then
                        local itemData = types.Item.itemData(item)
                        if itemData then
                            local oldCharge = itemData.enchantmentCharge or 0
                            itemData.enchantmentCharge = math.max(0, oldCharge - data.itemChargeCost)
                        end
                    end
                end
            end)
        end,
    }
}

-- ============================================================
-- [PUBLIC LOCAL API] For other player scripts (like OSSC, Kinetic Forces)
-- Exported as I.MagExp_Player via `interfaceName = "MagExp_Player"` in the return block.
-- ============================================================
local MagExp_PlayerInterface = {
    consumeSpellCost = function(spellId, itemObject)
        if debug.isGodMode() then return true end
        local spell = core.magic.spells.records[spellId]
        local isEnchantment = false
        if not spell then
            spell = core.magic.enchantments.records[spellId]
            isEnchantment = spell ~= nil
        end
        if not spell then return true end -- Unknown spell — treat as free
        local cost = spell.cost or 0
        if cost <= 0 then return true end -- Zero-cost spells always succeed

        if isEnchantment and itemObject and type(itemObject) ~= "string" and itemObject:isValid() then
            if spell.type == core.magic.ENCHANTMENT_TYPE.CastOnce then
                if itemObject.count > 0 then
                    local inv = types.Actor.inventory(self)
                    if inv then
                        local foundItem = inv:find(itemObject.recordId)
                        if foundItem then foundItem:remove(1) end
                    end
                    return true
                else
                    ui.showMessage("You do not have enough of that item.")
                    return false
                end
            else
                local skill = 0
                pcall(function() skill = types.Player.stats.skills.enchant(self).modified end)
                cost = math.max(1, math.floor(0.01 * (110 - skill) * cost))
                local itemData = types.Item.itemData(itemObject)
                local currentCharge = itemData and itemData.enchantmentCharge or spell.charge or 0
                if currentCharge >= cost then
                    if itemData then itemData.enchantmentCharge = currentCharge - cost end
                    return true
                else
                    ui.showMessage("You don't have enough charges in this item.")
                    return false
                end
            end
        else
            local magicka = types.Actor.stats.dynamic.magicka(self)
            if magicka.current >= cost then
                magicka.current = magicka.current - cost
                return true
            else
                ui.showMessage("You do not have enough Magicka to cast the spell.")
                return false
            end
        end
    end
}

return {
    interfaceName = "MagExp_Player",
    interface     = MagExp_PlayerInterface,
    engineHandlers = handlers.engineHandlers,
    eventHandlers  = handlers.eventHandlers,
}
