-- ============================================================
-- OMW_MagExp: Magic Expansion Framework for OpenMW
-- magexp_projectile_local.lua (CUSTOM script - attached to projectile objects)
--
-- Handles per-frame physics, ray-cast collision detection, and
-- lifecycle events. All global events use the MagExp_ prefix.
-- ============================================================

local self   = require('openmw.self')
local nearby = require('openmw.nearby')
local core   = require('openmw.core')
local util   = require('openmw.util')
local anim   = require('openmw.animation')
local types  = require('openmw.types')

local velocity     = nil
local attacker     = nil
local spellId      = nil
local area         = 0
local lifetime     = 0
local maxLifetime  = 10
local hasCollided  = false
local boltSound    = nil
local soundAnchor  = nil
local lightAnchor  = nil
local isRotating   = false
local currentRotation = nil
local rotSpinLog   = 0
local spinSpeed    = 0
local boltVfxHandle = nil
local effectIndexes = nil
local isProjectile = false

local function stopSound()
    if boltSound then
        pcall(function() core.sound.stopSound3d(boltSound, self) end)
    end
    if soundAnchor and soundAnchor:isValid() then
        soundAnchor:sendEvent('MagExp_StopSound')
        core.sendGlobalEvent('MagExp_RemoveObject', soundAnchor)
        soundAnchor = nil
    end
    if lightAnchor and lightAnchor:isValid() then
        core.sendGlobalEvent('MagExp_RemoveObject', lightAnchor)
        lightAnchor = nil
    end
    if boltVfxHandle then
        pcall(function() boltVfxHandle:remove() end)
        boltVfxHandle = nil
    end
end

local function onInit(data)
    if data and data.velocity then
        -- Main projectile initialization
        isProjectile    = true
        velocity        = data.velocity
        attacker        = data.attacker
        spellId         = data.spellId
        area            = data.area or 0
        boltSound       = data.boltSound or nil
        lifetime        = 0
        hasCollided     = false
        isRotating      = false
        currentRotation = self.rotation
        spinSpeed       = data.spinSpeed or 0
        maxLifetime     = data.maxLifetime or 10
        effectIndexes   = data.effectIndexes or nil
        if spinSpeed > 0 then isRotating = true end

        if data.boltModel and data.boltModel ~= "" then
            local opts = {
                useAmbientLight = true,
                loop = true,
                vfxId = data.vfxRecId or "MagExp_SpellVFX"
            }
            if data.particle and data.particle ~= "" then
                opts.particleTextureOverride = data.particle
            end
            boltVfxHandle = anim.addVfx(self, data.boltModel, opts)
        end

        -- Request Sound Anchor creation on global side
        if boltSound and boltSound ~= "" then
            core.sendGlobalEvent('MagExp_CreateSoundAnchor', {
                recordId  = "Colony_Assassin_act",
                sound     = boltSound,
                projectile = self
            })
            boltSound = nil
        end

        -- Request Light Anchor creation on global side
        if data.boltLightId then
            core.sendGlobalEvent('MagExp_CreateLightAnchor', {
                recordId  = data.boltLightId,
                projectile = self
            })
        end

    elseif data and data.isSoundAnchor then
        -- Sound anchor initialization
        isProjectile = false
        boltSound    = data.sound
        if boltSound then
            core.sound.playSound3d(boltSound, self, { loop = true })
        end
    end
end

local function onUpdate(dt)
    if not isProjectile or hasCollided or not velocity then return end

    lifetime = lifetime + dt
    if lifetime > maxLifetime then
        hasCollided = true
        stopSound()
        core.sendGlobalEvent('MagExp_ProjectileExpired', {
            projectile  = self,
            soundAnchor = soundAnchor,
            lightAnchor = lightAnchor
        })
        return
    end

    if isRotating then
        rotSpinLog = rotSpinLog + spinSpeed * dt
        local dir   = velocity:normalize()
        local yaw   = math.atan2(dir.x, dir.y)
        local pitch = math.asin(dir.z)
        currentRotation = util.transform.rotateZ(yaw) * util.transform.rotateX(-pitch) * util.transform.rotateY(rotSpinLog)
    end

    local from = self.position
    local moveDist = velocity:length() * dt
    local to   = from + velocity:normalize() * moveDist

    -- [PHYSICAL VOLUME SIMULATION]
    -- Since native collision events are unsupported, we use a 4-point cross pattern 
    -- of raycasts to simulate a projectile with a radius of ~12 units.
    local dir   = velocity:normalize()
    local right = util.vector3(dir.y, -dir.x, 0):normalize()
    if right:length() < 0.01 then right = util.vector3(1, 0, 0) end
    local up    = dir:cross(right):normalize()
    
    local radius = 12
    local offsets = {
        util.vector3(0,0,0), -- Center
        right * radius,
        -right * radius,
        up * radius,
        -up * radius
    }

    local lookAheadDist = moveDist * 2.0
    local ray = nil

    for _, offset in ipairs(offsets) do
        local startPos = from + offset
        local endPos   = startPos + dir * lookAheadDist
        local hit = nearby.castRay(startPos, endPos, { ignore = { self, attacker } })
        if hit.hit then
            -- [DEAD ACTOR PASS-THROUGH] Skip corpses
            local hitObj = hit.hitObject
            if hitObj and hitObj:isValid() and types.Actor.objectIsInstance(hitObj) and types.Actor.isDead(hitObj) then
                -- Skip this hit and try others or just pass through
            else
                ray = hit; break
            end
        end
    end

    if ray then
        hasCollided = true
        stopSound()
        core.sendGlobalEvent('MagExp_ProjectileCollision', {
            projectile  = self,
            hitObject   = ray.hitObject,
            hitPos      = ray.hitPos,
            hitNormal   = ray.hitNormal,
            velocity    = velocity,
            attacker    = attacker,
            spellId     = spellId,
            area        = area,
            effectIndexes = effectIndexes,
            soundAnchor = soundAnchor,
            lightAnchor = lightAnchor
        })
        return
    end

    core.sendGlobalEvent('MagExp_ProjectileMove', {
        projectile  = self,
        newPos      = to,
        newRot      = currentRotation,
        soundAnchor = soundAnchor,
        lightAnchor = lightAnchor
    })
end

return {
    engineHandlers = {
        onUpdate = onUpdate,
    },
    eventHandlers = {
        MagExp_InitProjectile  = onInit,
        MagExp_InitSound       = onInit,
        MagExp_StopSound       = stopSound,
        MagExp_SetSoundAnchor  = function(data) soundAnchor = data.anchor end,
        MagExp_SetLightAnchor  = function(data) lightAnchor = data.anchor end,
    },
}
