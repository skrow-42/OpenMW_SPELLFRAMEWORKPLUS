-- ============================================================
-- Spell Framework Plus - skrow42
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

local debugLog = require('scripts/OMW_MagExp/magexp_logger').new('[MagExp Proj]')

-- ---- Core state ----
local velocity        = nil
local simulatedPosition = nil
local attacker        = nil
local canHitCasterAfter = nil
local spellId         = nil
local area            = 0
local lifetime        = 0
local maxLifetime     = 10
local hasCollided     = false
local boltSound       = nil
local soundAnchor     = nil
local lightAnchor     = nil
local isRotating      = false
local currentRotation = nil
local rotSpinLog      = 0
local spinSpeed       = 0
-- Bundled to keep onUpdate at Lua 5.1's 60-upvalue ceiling.
local orientationState = {
    followRate = 0,
    undirected = false,
    allowForceReversal = false,
    direction = nil,
    warpIgnoreObject = nil,
    warpIgnoreUntil = 0,
    pendingWarp = false,
    pendingWarpTag = nil,
    hitModelExplicit = false,
}
local boltVfxHandle   = nil
local effectIndexes   = nil
local isProjectile    = false
local maxSpeed        = 0
local isPaused        = false
local unreflectable   = false
local casterLinked    = false
local userData        = nil
local muteAudio       = false
local muteLight       = false
local continuousVfx   = false
local effectScale     = nil
local anchorRecordId = "Colony_Assassin_act" -- default fallback
local collisionMode   = "default"
-- ---- Physics extensions ----
-- accelerationExp: exponential signed speed multiplier per frame.
-- When signedSpeed crosses zero the spell reverses direction.
-- forceVec: true directional force added to velocity each frame (Vector3, units/sec²).
local accelerationExp = 0
local forceVec        = nil

-- signedSpeed tracks the current speed WITH sign along baseDir.
-- Negative = traveling in reverse of the original launch direction.
local signedSpeed  = 0
-- baseDir is the 'positive forward' axis used by accelerationExp.
-- Updated whenever velocity or direction is explicitly overridden.
local baseDir      = util.vector3(0, 1, 0)

-- ---- VFX identity ----
local vfxRecId        = nil   -- BUG FIX: was referenced in collision payload without declaration
local areaVfxRecId    = nil
local hitModel        = nil
local boltVfxId = nil
local pendingVfxInitData = nil
local boltVfxAttached = false
-- ---- Bounce system ----
local bounceEnabled      = false
local bounceMax          = 0       -- 0 = unlimited bounces until lifetime expires
local bounceCount        = 0
local bouncePower        = 0.7     -- restitution coeff: 1.0 = perfect elastic, 0 = dead stop
local BOUNCE_EXTRA_CLEARANCE = 20
local BOUNCE_MAX_CLEARANCE = 72
local BOUNCE_MIN_NORMAL_DOT = 0.22
local BOUNCE_NORMAL_BIAS = 0.35

local function normalizedOrNil(vector)
    if vector and vector.length and vector:length() > 0.01 then
        return vector:normalize()
    end
    return nil
end

local function reflectedBounceVelocity(incoming, normal, restitution)
    local n = normalizedOrNil(normal)
    local speed = incoming and incoming:length() or 0
    if n == nil or speed <= 0.01 then
        return nil
    end

    local reflected = incoming - n * (2 * incoming:dot(n))
    local reflectedDir = normalizedOrNil(reflected) or n
    if reflectedDir:dot(n) < BOUNCE_MIN_NORMAL_DOT then
        reflectedDir = normalizedOrNil(reflectedDir + n * BOUNCE_NORMAL_BIAS) or reflectedDir
    end
    return reflectedDir * (speed * (tonumber(restitution) or 1))
end

-- ---- Actor detonation rule ----
-- When true (default): actor contact always detonates regardless of remaining bounces.
-- When false: actors are treated as static surface for bounce purposes.
local detonateOnActorHit = true

-- ---- Piercing system ----
local piercing       = false  -- If true, projectile passes through actors
local pierceLimit    = nil    -- Max actor pass-throughs before the next actor collision (nil = unlimited)
local pierceCount    = 0      -- How many actors have been pierced so far
local piercePulseCount = 0    -- How many pierce damage pulses have been emitted
local pierceRepeatHits = false -- If true, actors can be hit again after the rate gate
local pierceRateLimit = 60    -- Max pierce pulses/sec per actor when repeat hits are enabled
local piercedActors  = {}     -- Per-actor pierce state for this projectile
local piercedActorObjects = {} -- Actor objects ignored by future raycasts for this projectile

-- ---- Impact data ----
local impactSpeed     = 0     -- speed captured the frame collision is confirmed (units/sec)
local impactImpulse   = 0     -- MaxYari LuaPhysics impulse magnitude applied on detonation

-- ============================================================
-- [INTERNAL] Clean up sounds and lights
-- ============================================================
local function stopSound()
    if boltSound then
        core.sound.stopSound3d(boltSound, self)
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
    if boltVfxId and boltVfxId ~= "" then
        -- anim.removeVfx raises "Object has no animation" on an actor that has
        -- none. Ask first; the condition is queryable and there is nothing to
        -- undo when it is false.
        if anim.hasAnimation(self) then
            anim.removeVfx(self, boltVfxId)
        end
        boltVfxId = nil
    end
end

local function expireProjectile(reason)
    if not isProjectile or hasCollided then
        return false
    end
    hasCollided = true
    stopSound()
    core.sendGlobalEvent('MagExp_ProjectileExpired', {
        projectile   = self,
        projectileId = self.id,
        position     = simulatedPosition or self.position,
        velocity     = velocity,
        attacker     = attacker,
        spellId      = spellId,
        userData     = userData,
        soundAnchor  = soundAnchor,
        lightAnchor  = lightAnchor,
        reason       = reason,
    })
    return true
end
-- onUpdate is already at LuaJIT's 60-upvalue ceiling. Store this helper in
-- the existing bundled state so lifetime expiry does not capture a 61st value.
orientationState.expireProjectile = expireProjectile

local function attachProjectileVfx()
    local data = pendingVfxInitData
    if data == nil or boltVfxAttached or not self:isActive() then
        return false
    end
    -- This guard is what makes the addVfx calls below safe, so it is called
    -- directly rather than through pcall: if hasAnimation itself cannot run,
    -- that is a real error and should not be swallowed into "no VFX".
    if not anim.hasAnimation(self) then
        return false
    end

    if data.boltModels and #data.boltModels > 0 then
        debugLog(string.format("Layering %d bolt VFX models on projectile", #data.boltModels))
        for i, model in ipairs(data.boltModels) do
            local vfxId = string.format("MagExpBolt_%s_%d", tostring(self.id), i)
            local particle = (data.particleTextures and data.particleTextures[i]) or ""
            local opts = {
                loop = true,
                vfxId = vfxId,
                boneName = "",
            }
            if particle ~= "" then
                opts.particleTextureOverride = particle
            end
            anim.addVfx(self, model, opts)
        end
    elseif data.boltModel and data.boltModel ~= "" then
        boltVfxId = vfxRecId or ("MagExp_Bolt_" .. tostring(self.id))
        local opts = {
            loop = true,
            vfxId = boltVfxId,
            boneName = "",
        }
        if data.particle and data.particle ~= "" then
            opts.particleTextureOverride = data.particle
        end
        anim.addVfx(self, data.boltModel, opts)
    end
    boltVfxAttached = true
    pendingVfxInitData = nil
    return true
end

-- Segment history is local to one bounded update, never a movement backlog.
function orientationState.noteMotionSegment(from, to)
    local segments = orientationState.motionSegments
    if segments then segments[#segments + 1] = { startPos = from, endPos = to } end
end
function orientationState.flushMotionMove()
    local move = orientationState.motionMove
    if move then
        move.motionSegments = orientationState.motionSegments
        move.localMotionPath = true
        move.velocity = velocity
        core.sendGlobalEvent('MagExp_ProjectileMove', move)
        orientationState.motionMove = nil
    end
end
function orientationState.publishMove(data)
    if orientationState.motionSegments then
        local previous = orientationState.motionMove
        if previous and previous.warped then
            data.warped, data.warpTag = true, previous.warpTag
        end
        orientationState.motionMove = data
    else
        core.sendGlobalEvent('MagExp_ProjectileMove', data)
    end
end

-- ============================================================
-- [EVENT] MagExp_InitProjectile / MagExp_InitSound
-- ============================================================
local function onInit(data)
    if data and data.velocity then
        -- ---- Main projectile initialization ----
        isProjectile    = true
        velocity        = data.velocity
        attacker        = data.attacker
        canHitCasterAfter = tonumber(data.canHitCasterAfter)
        spellId         = data.spellId
        area            = data.area            or 0
        boltSound       = data.boltSound       or nil
        lifetime        = 0
        hasCollided     = false
        isRotating      = false
        currentRotation = self.rotation
        simulatedPosition = self.position
        spinSpeed       = data.spinSpeed       or 0
        orientationState.followRate = math.max(0, tonumber(data.rotationFollowRate) or 0)
        orientationState.undirected = data.rotationDirectionUndirected == true
        orientationState.allowForceReversal = data.forceCanReverse == true
        orientationState.direction = nil
        orientationState.warpIgnoreObject = nil
        orientationState.warpIgnoreUntil = 0
        orientationState.pendingWarp = false
        orientationState.pendingWarpTag = nil
        maxLifetime     = data.maxLifetime     or 10
        collisionMode   = data.collisionMode   or "default"
        effectIndexes   = data.effectIndexes   or nil
        accelerationExp = data.accelerationExp or 0
        forceVec        = data.forceVec        or nil
        maxSpeed        = data.maxSpeed        or 0
        isPaused        = data.isPaused        or false
        -- VFX
        vfxRecId        = data.vfxRecId
        areaVfxRecId    = data.areaVfxRecId
        hitModel        = data.hitModel
        orientationState.hitModelExplicit = data.hitModelExplicit == true
        -- Bounce
        bounceEnabled      = data.bounceEnabled      or false
        bounceMax          = data.bounceMax          or 0
        bouncePower        = data.bouncePower        or 0.7
        detonateOnActorHit = (data.detonateOnActorHit ~= false)
        -- Piercing
        piercing           = data.piercing           or false
        pierceLimit        = data.pierceLimit
        pierceCount        = 0
        piercePulseCount   = 0
        pierceRepeatHits   = data.pierceRepeatHits   == true
        pierceRateLimit    = tonumber(data.pierceRateLimit) or 60
        piercedActors      = {}
        piercedActorObjects = {}
        unreflectable      = data.unreflectable      or false
        casterLinked       = data.casterLinked       or false
        -- Impact
        impactImpulse = data.impactImpulse or 0
        userData      = data.userData      or nil
        muteAudio     = data.muteAudio     or false
        muteLight     = data.muteLight     or false
        continuousVfx = data.continuousVfx or false
        effectScale   = data.effectScale
        anchorRecordId = data.anchorRecordId or anchorRecordId

        -- [FIX] Always set baseDir from the provided direction, never default to North
        if data.direction then
            baseDir = data.direction:normalize()
        elseif velocity and velocity:length() > 0.01 then
            baseDir = velocity:normalize()
        end
        orientationState.direction = baseDir
        if spinSpeed > 0 or orientationState.followRate > 0 then
            isRotating = true
        end

        -- Initialise signed-speed tracking
        if velocity then
            signedSpeed = velocity:length()
        end

        orientationState.motionPath = nil
        if data.motionPath then
            local provider = require(data.motionPath.module)
            orientationState.motionPath = provider.create(data.motionPath.config, {
                position = simulatedPosition, direction = baseDir,
            })
            velocity = orientationState.motionPath:velocity()
        end

        -- addVfx is a delayed engine action and requires an active animation
        -- object. Defer it until activation instead of queuing hundreds of
        -- guaranteed failures for Larpa copies created in unloaded cells.
        pendingVfxInitData = data
        boltVfxAttached = false
        attachProjectileVfx()

        -- Request Sound Anchor creation on global side
        if boltSound and boltSound ~= "" then
            core.sendGlobalEvent('MagExp_CreateSoundAnchor', { 
                recordId = anchorRecordId, 
                sound = boltSound, 
                projectile = self 
            })
            boltSound = nil
        end

        -- Request Light Anchor creation on global side
        if data.boltLightId then
            core.sendGlobalEvent('MagExp_CreateLightAnchor', {
                recordId   = data.boltLightId,
                projectile = self
            })
        end

    elseif data and data.isSoundAnchor then
        -- ---- Sound anchor initialization ----
        isProjectile = false
        boltSound    = data.sound
        if boltSound then
            core.sound.playSound3d(boltSound, self, { loop = true })
        end
    end
end

local function castProjectileRay(startPos, endPos, ignore)
    local options = { ignore = ignore }
    if collisionMode == "actors_only" then
        options.collisionType = nearby.COLLISION_TYPE.Actor
    end
    return nearby.castRay(startPos, endPos, options)
end
        
-- ============================================================
-- [PER FRAME] Physics update
-- ============================================================
local function simulateStep(dt)
    -- A paused world still receives updates with dt=0. Do not publish
    -- stationary movement samples or run simulation-only termination rules.
    if dt <= 0 or isPaused or not isProjectile or hasCollided or not velocity then return end

    lifetime = lifetime + dt
    if lifetime > maxLifetime then
        orientationState.expireProjectile('lifetime')
        return
    end

    local pathTo
    if orientationState.motionPath then
        pathTo, velocity = orientationState.motionPath:advance(dt)
    end

    -- ---- Spin ----
    if isRotating then
        rotSpinLog = rotSpinLog + spinSpeed * dt
        local spd = velocity:length()
        local targetDir = (spd > 0.01) and velocity:normalize() or baseDir
        local dir = targetDir
        local followRate = orientationState.followRate
        if followRate > 0 then
            local currentDir = orientationState.direction or targetDir
            -- A flat circular blade has no meaningful forward/backward side.
            -- Choosing the equivalent normal prevents a 180-degree flip when
            -- a returning disc reverses along its launch axis.
            if orientationState.undirected and currentDir:dot(targetDir) < 0 then
                targetDir = targetDir * -1
            end
            local blend = 1 - math.exp(-followRate * math.max(0, dt))
            local blended = currentDir * (1 - blend) + targetDir * blend
            if blended:length() > 0.001 then
                dir = blended:normalize()
            end
        end
        orientationState.direction = dir
        
        local yaw   = math.atan2(dir.x, dir.y)
        local pitch = math.asin(math.max(-1, math.min(1, dir.z)))
        currentRotation = util.transform.rotateZ(yaw)
                        * util.transform.rotateX(-pitch)
                        * util.transform.rotateY(rotSpinLog)
    end

    -- ---- accelerationExp: exponential signed speed multiplier (positive=accelerate, negative=decelerate/reverse) ----
    -- signedSpeed can cross zero: when it goes negative the spell reverses along baseDir.
    if not pathTo and accelerationExp ~= 0 then
        signedSpeed = signedSpeed * math.exp(accelerationExp * dt)
        -- Optional cap: applies to magnitude (|signedSpeed|)
        if maxSpeed > 0 and math.abs(signedSpeed) > maxSpeed then
            signedSpeed = signedSpeed > 0 and maxSpeed or -maxSpeed
        end
        -- Reconstruct velocity: negative signedSpeed flips the direction
        velocity = baseDir * signedSpeed
    end

    -- ---- forceVec: true directional continuous force (units/sec²) ----
    -- Use this for deceleration, homing, gravity, or any directional push.
    if not pathTo and forceVec then
        velocity = velocity + forceVec * dt
        local spd = velocity:length()
        if spd < 0.5
            and orientationState.allowForceReversal
            and forceVec:length() > 0.001
        then
            -- Keep a valid direction across the single turnaround frame.
            velocity = forceVec:normalize() * 0.5
            spd = 0.5
        end
        if spd < 0.5 then
            -- Spell has effectively stopped — expire gracefully
            hasCollided = true
            stopSound()
            core.sendGlobalEvent('MagExp_ProjectileExpired', {
                projectile   = self,
                projectileId = self.id,
                position     = simulatedPosition or self.position,
                velocity     = velocity,
                attacker     = attacker,
                spellId      = spellId,
                userData     = userData,
                soundAnchor  = soundAnchor,
                lightAnchor  = lightAnchor
            })
            return
        end
    end

    -- Global teleports arrive asynchronously. Keep local physics authoritative
    -- so a discontinuous bounce cannot alternate between stale world positions.
    local from     = simulatedPosition or self.position
    local moveDist = velocity:length() * dt
    local dir      = velocity:normalize()
    local to       = pathTo or (from + dir * moveDist)
    if pathTo then
        local displacement = to - from
        moveDist = displacement:length()
        if moveDist <= 0.000001 then return end
        dir = displacement:normalize()
    end

    -- ---- 5-point cross raycast (physical volume simulation, radius ~12 units) ----
    local right = util.vector3(dir.y, -dir.x, 0)
    if right:length() < 0.01 then right = util.vector3(1, 0, 0) else right = right:normalize() end
    local up      = dir:cross(right):normalize()
    local radius  = 12
    local offsets = {
        util.vector3(0, 0, 0),
        right * radius, -right * radius,
        up * radius,    -up * radius,
    }

    local lookAheadDist = pathTo and moveDist or (moveDist * 2.0)
    local ray           = nil
    local framePiercedActorObjects = {}

    local function isActorObject(obj)
        return obj and obj:isValid() and types.Actor.objectIsInstance(obj)
    end

    local function isLiveActorObject(obj)
        return isActorObject(obj) and not types.Actor.isDead(obj)
    end

    local function normalizedRecordId(obj)
        local recordId = obj and obj.recordId or nil
        if recordId == nil then
            return ""
        end
        return string.lower(tostring(recordId))
    end

    local function userDataIgnoresActor(obj)
        if not isActorObject(obj) or type(userData) ~= "table" then
            return false
        end
        local ignored = userData.ignoreActorRecordIds
        if type(ignored) ~= "table" then
            return false
        end
        local recordId = normalizedRecordId(obj)
        if recordId == "" then
            return false
        end
        for key, value in pairs(ignored) do
            if type(key) == "string" and value == true
                and string.lower(key) == recordId then
                return true
            end
            if type(value) == "string" and string.lower(value) == recordId then
                return true
            end
        end
        return false
    end

    local function buildIgnoreList()
        local ignore = { self }
        if attacker and (canHitCasterAfter == nil or lifetime < canHitCasterAfter) then
            ignore[#ignore + 1] = attacker
        end
        local pierceIgnore = pierceRepeatHits and framePiercedActorObjects or piercedActorObjects
        for _, actor in pairs(pierceIgnore) do
            if actor and actor:isValid() then
                ignore[#ignore + 1] = actor
            end
        end
        local warpIgnoreObject = orientationState.warpIgnoreObject
        if warpIgnoreObject ~= nil and lifetime < (tonumber(orientationState.warpIgnoreUntil) or 0) then
            if warpIgnoreObject:isValid() == true then
                ignore[#ignore + 1] = warpIgnoreObject
            end
        elseif warpIgnoreObject ~= nil then
            orientationState.warpIgnoreObject = nil
            orientationState.warpIgnoreUntil = 0
        end
        return ignore
    end

    local function castFirstHit(segmentFrom, segmentDistance)
        if segmentDistance <= 0 then return nil end
        local ignore = buildIgnoreList()

        local function castOffset(offset)
            local startPos = segmentFrom + offset
            local endPos   = startPos + dir * segmentDistance
            -- Recast through dead actors and caller-specified allies. Adding
            -- each skipped actor to the ray ignore list keeps the projectile's
            -- original trajectory and still permits a valid target or wall
            -- behind that actor to receive the collision.
            for _ = 1, 16 do
                local hit = castProjectileRay(startPos, endPos, ignore)
                if not hit.hit then return nil end
                local hitObj = hit.hitObject
                local passThrough = isActorObject(hitObj)
                    and (types.Actor.isDead(hitObj) or userDataIgnoresActor(hitObj))
                if passThrough then
                    ignore[#ignore + 1] = hitObj
                else
                    return {
                        hit = hit.hit,
                        hitObject = hit.hitObject,
                        hitPos = hit.hitPos,
                        hitNormal = hit.hitNormal,
                        projectileOffset = offset,
                        rayStartPos = startPos,
                        distance = (hit.hitPos - startPos):length(),
                    }
                end
            end
            return nil
        end

        -- The centre ray is the projectile's own path, so when it hits it is
        -- authoritative - on a flat surface every offset ray lands at the same
        -- distance and the centre is the one that says where.
        local centre = castOffset(offsets[1])
        if centre then return centre end

        -- The side rays exist to give the projectile volume. Among them take
        -- the nearest hit, so an actor standing just off the aim line still
        -- gets hit before a wall further along. But when the two nearest are
        -- the same distance the projectile is passing symmetrically through a
        -- gap, and letting either edge claim the impact would decide it by
        -- whichever offset happens to be listed first - +right before -right -
        -- which is what used to detonate spells on the side of a doorway they
        -- should have flown through.
        local best, second
        for i = 2, #offsets do
            local r = castOffset(offsets[i])
            if r then
                if not best or r.distance < best.distance then
                    second, best = best, r
                elseif not second or r.distance < second.distance then
                    second = r
                end
            end
        end
        if not best then return nil end
        if second and math.abs(second.distance - best.distance) < 1e-4 then
            return nil
        end
        return best
    end

    local function pierceRate()
        return math.max(1, math.min(60, tonumber(pierceRateLimit) or 60))
    end

    local function piercePulseAllowed(state)
        if not pierceRepeatHits then
            return state.pulseCount == 0
        end

        local rate = pierceRate()
        local interval = 1 / rate
        return state.lastPulseLifetime == nil
            or (lifetime - state.lastPulseLifetime) >= (interval - 0.0001)
    end

    local function sendPierceEvent(hitObj, hit, state)
        piercePulseCount = piercePulseCount + 1
        state.pulseCount = (state.pulseCount or 0) + 1
        state.lastPulseLifetime = lifetime
        state.lastHitPos = hit.hitPos or state.lastHitPos
        state.lastHitNormal = hit.hitNormal or state.lastHitNormal
        core.sendGlobalEvent('MagExp_OnProjectilePierce', {
            projectile    = self,
            projectileId  = self.id,
            hitObject     = hitObj,
            hitPos        = hit.hitPos,
            hitNormal     = hit.hitNormal,
            velocity      = velocity,
            impactSpeed   = velocity:length(),
            attacker      = attacker,
            spellId       = spellId,
            area          = area,
            effectIndexes = effectIndexes,
            soundAnchor   = soundAnchor,
            lightAnchor   = lightAnchor,
            vfxRecId      = vfxRecId,
            areaVfxRecId  = areaVfxRecId,
            hitModel      = hitModel,
            hitModelExplicit = orientationState.hitModelExplicit,
            impactImpulse = impactImpulse,
            unreflectable = unreflectable,
            casterLinked  = casterLinked,
            userData      = userData,
            muteAudio     = muteAudio,
            muteLight     = muteLight,
            continuousVfx = continuousVfx,
            effectScale   = effectScale,
            pierceCount   = pierceCount,
            piercePulseCount = piercePulseCount,
            pierceHitCount = state.pulseCount,
            pierceLimit   = pierceLimit,
            pierceEntryPos = state.entryHitPos or hit.hitPos,
            pierceEntryNormal = state.entryHitNormal or hit.hitNormal,
            pierceRepeatHits = pierceRepeatHits,
            pierceRateLimit = pierceRateLimit,
            isPierce      = true
        })
    end
    local function collideAfterPierceLimit(hitObj, hit)
        if pathTo then
            local center = hit.hitPos - (hit.projectileOffset or util.vector3(0, 0, 0))
            orientationState.noteMotionSegment(from, center)
            orientationState.motionMove = { projectile = self, projectileId = self.id,
                newPos = center, newRot = currentRotation }
            orientationState.flushMotionMove()
            simulatedPosition = center
        end
        impactSpeed = velocity:length()
        hasCollided = true
        stopSound()
        core.sendGlobalEvent('MagExp_ProjectileCollision', {
            projectile    = self,
            projectileId  = self.id,
            hitObject     = hitObj,
            hitPos        = hit.hitPos,
            hitNormal     = hit.hitNormal,
            velocity      = velocity,
            impactSpeed   = impactSpeed,
            attacker      = attacker,
            spellId       = spellId,
            area          = area,
            effectIndexes = effectIndexes,
            soundAnchor   = soundAnchor,
            lightAnchor   = lightAnchor,
            vfxRecId      = vfxRecId,
            areaVfxRecId  = areaVfxRecId,
            hitModel      = hitModel,
            hitModelExplicit = orientationState.hitModelExplicit,
            impactImpulse = impactImpulse,
            unreflectable = unreflectable,
            casterLinked  = casterLinked,
            userData      = userData,
            muteAudio     = muteAudio,
            muteLight     = muteLight,
            continuousVfx = continuousVfx,
            effectScale   = effectScale,
            pierceCount   = pierceCount,
            piercePulseCount = piercePulseCount,
            pierceLimit   = pierceLimit,
            pierceRepeatHits = pierceRepeatHits,
            pierceRateLimit = pierceRateLimit,
            isPierce      = false
        })
    end

    local segmentFrom = from
    local segmentDistance = lookAheadDist
    local maxPierceChecks = 1
    if piercing then
        maxPierceChecks = math.min((tonumber(pierceLimit) or 8) + 1, 16)
    end

    for _ = 1, maxPierceChecks do
        ray = castFirstHit(segmentFrom, segmentDistance)
        if not ray then break end

        local hitObj = ray.hitObject
        if piercing and isLiveActorObject(hitObj) then
            local actorKey = tostring(hitObj)
            local state = piercedActors[actorKey]
            if state == nil then
                state = {
                    actor = hitObj,
                    pulseCount = 0,
                    lastPulseLifetime = nil
                }
                piercedActors[actorKey] = state
            end
            if not state.counted then
                -- pierceLimit is a pass-through budget: Pierce 3 ignores
                -- actors 1-3, then actor 4 collides through the normal path.
                if pierceLimit and pierceCount >= pierceLimit then
                    collideAfterPierceLimit(hitObj, ray)
                    return
                end

                state.counted = true
                pierceCount = pierceCount + 1
            end
            state.actor = hitObj
            if state.entryHitPos == nil then
                state.entryHitPos = ray.hitPos
                state.entryHitNormal = ray.hitNormal
            end
            if pierceRepeatHits then
                framePiercedActorObjects[actorKey] = hitObj
            else
                piercedActorObjects[actorKey] = hitObj
            end
            if piercePulseAllowed(state) then
                sendPierceEvent(hitObj, ray, state)
            end

            -- Treat the pierced actor as non-blocking and keep checking the
            -- remaining segment so walls/statics behind the actor still collide.
            segmentFrom = ray.hitPos + dir * 1
            segmentDistance = lookAheadDist - (segmentFrom - from):length()
            ray = nil
            if segmentDistance <= 0 then break end
        else
            break
        end
    end

    -- ---- Collision / Bounce / Piercing decision ----
    if ray then
        local hitObj  = ray.hitObject
        local isActor = hitObj and hitObj:isValid()
                        and types.Actor.objectIsInstance(hitObj)
                        and not types.Actor.isDead(hitObj)

        local bounceLimitReached = (bounceMax > 0 and bounceCount >= bounceMax)

        -- Determine whether to detonate or bounce (non-piercing path)
        local shouldDetonate = true
        if bounceEnabled then
            if isActor then
                -- Actor: detonate unless detonateOnActorHit is disabled
                shouldDetonate = detonateOnActorHit or bounceLimitReached
            else
                -- Static / terrain: bounce unless limit reached
                shouldDetonate = bounceLimitReached
            end
        end

        if not shouldDetonate then
            -- ---- BOUNCE ----
            local n = normalizedOrNil(ray.hitNormal) or (dir * -1)
            local bouncedVelocity = reflectedBounceVelocity(velocity, n, bouncePower) or (n * (velocity:length() * bouncePower))
            velocity = bouncedVelocity
            local bouncedSpeed = velocity:length()
            if bouncedSpeed > 0.01 then
                signedSpeed = bouncedSpeed
                baseDir = velocity:normalize()
            end
            bounceCount = bounceCount + 1

            -- Rebuild the projectile center from the offset ray that hit, then
            -- push it outside the simulated projectile radius. A shallow 8-unit
            -- nudge leaves fast projectiles riding rough collision meshes.
            local projectileOffset = ray.projectileOffset or util.vector3(0, 0, 0)
            local centerAtHit = ray.hitPos - projectileOffset
            local clearance = math.min(BOUNCE_MAX_CLEARANCE, math.max(radius + BOUNCE_EXTRA_CLEARANCE, moveDist * 0.25))
            local bouncedPos = centerAtHit + n * clearance
            if pathTo then
                orientationState.noteMotionSegment(from, centerAtHit)
                orientationState.motionPath:bounce(bouncedPos, n, bouncePower)
            end
            simulatedPosition = bouncedPos
            local pendingWarp = orientationState.pendingWarp == true
            orientationState.publishMove({
                projectile  = self,
                projectileId = self.id,
                newPos      = bouncedPos,
                newRot      = currentRotation,
                velocity    = pendingWarp and velocity or nil,
                warped      = pendingWarp,
                warpTag     = orientationState.pendingWarpTag,
                soundAnchor = soundAnchor,
                lightAnchor = lightAnchor
            })
            orientationState.pendingWarp = false
            orientationState.pendingWarpTag = nil
            orientationState.flushMotionMove()
            core.sendGlobalEvent('MagExp_OnProjectileBounce', {
                projectile   = self,
                projectileId = self.id,
                spellId      = spellId,
                attacker     = attacker,
                hitPos       = ray.hitPos,
                hitNormal    = n,
                bounceCount  = bounceCount,
                speed        = velocity:length(),
                velocity     = velocity,
                userData     = userData,
                soundAnchor  = soundAnchor,
                lightAnchor  = lightAnchor
            })
            -- Continue flying — do NOT set hasCollided
            return
        end

        -- ---- DETONATE ----
        if pathTo then
            local center = ray.hitPos - (ray.projectileOffset or util.vector3(0, 0, 0))
            orientationState.noteMotionSegment(from, center)
            orientationState.motionMove = { projectile = self, projectileId = self.id,
                newPos = center, newRot = currentRotation }
            orientationState.flushMotionMove()
            simulatedPosition = center
        end
        impactSpeed = velocity:length()
        hasCollided = true
        stopSound()
        core.sendGlobalEvent('MagExp_ProjectileCollision', {
            projectile    = self,
            projectileId  = self.id,
            hitObject     = ray.hitObject,
            hitPos        = ray.hitPos,
            hitNormal     = ray.hitNormal,
            velocity      = velocity,
            impactSpeed   = impactSpeed,
            attacker      = attacker,
            spellId       = spellId,
            area          = area,
            effectIndexes = effectIndexes,
            soundAnchor   = soundAnchor,
            lightAnchor   = lightAnchor,
            vfxRecId      = vfxRecId,
            areaVfxRecId  = areaVfxRecId,
            hitModel      = hitModel,
            hitModelExplicit = orientationState.hitModelExplicit,
            impactImpulse = impactImpulse,
            unreflectable = unreflectable,
            casterLinked  = casterLinked,
            userData      = userData,
            muteAudio     = muteAudio,
            muteLight     = muteLight,
            continuousVfx = continuousVfx,
            effectScale   = effectScale
        })
        return
    end

    orientationState.noteMotionSegment(from, to)
    simulatedPosition = to
    local pendingWarp = orientationState.pendingWarp == true
    orientationState.publishMove({
        projectile  = self,
        projectileId = self.id,
        newPos      = to,
        newRot      = currentRotation,
        velocity    = pendingWarp and velocity or nil,
        warped      = pendingWarp,
        warpTag     = orientationState.pendingWarpTag,
        soundAnchor = soundAnchor,
        lightAnchor = lightAnchor
    })
    orientationState.pendingWarp = false
    orientationState.pendingWarpTag = nil
end

-- Only opted-in paths are subdivided. Native collision/piercing runs on each
-- actual chord; one movement event carries the traversed segments to consumers.
-- At most eight 1/60s steps run per update. Excess frame time ages the spell,
-- but does not create a backlog or skip an unchecked stretch of the path.
local function onUpdate(dt)
    if not orientationState.motionPath then return simulateStep(dt) end
    if dt <= 0 or isPaused or not isProjectile or hasCollided or not velocity then return end
    if lifetime + dt > maxLifetime then
        lifetime = lifetime + dt
        orientationState.expireProjectile('lifetime')
        return
    end
    orientationState.motionSegments = {}
    local remaining = math.min(dt, 8 / 60)
    local advanced = 0
    for _ = 1, 8 do
        if remaining <= 0.0000001 or hasCollided then break end
        local step = orientationState.motionPath:stepDuration(math.min(1 / 60, remaining))
        local priorBounce = bounceCount
        simulateStep(step)
        advanced = advanced + step
        remaining = remaining - step
        if bounceCount ~= priorBounce then break end
    end
    lifetime = lifetime + math.max(0, dt - advanced)
    orientationState.flushMotionMove()
    orientationState.motionSegments = nil
end

-- ============================================================
-- Event Handlers
-- ============================================================
return {
    engineHandlers = {
        onUpdate = onUpdate,
        onActive = attachProjectileVfx,
        -- Inactive cells do not advance local onUpdate/lifetime. Expire while
        -- onInactive is still allowed to notify the always-active global script.
        onInactive = function()
            expireProjectile('inactive_cell')
        end,
        -- This script does not persist projectile simulation state. Any carrier
        -- restored from an older save is therefore an inert orphan and should be
        -- removed instead of reappearing when its cell becomes active.
        onLoad = function()
            core.sendGlobalEvent('MagExp_RemoveObject', self)
        end,
    },
    eventHandlers = {
        MagExp_InitProjectile = onInit,
        MagExp_InitSound      = onInit,
        MagExp_StopSound      = stopSound,

        MagExp_SetSoundAnchor = function(data) soundAnchor = data.anchor end,
        MagExp_SetLightAnchor = function(data) lightAnchor = data.anchor end,

        -- ----------------------------------------------------------------
        -- MagExp_SetPhysics: Full in-flight property mutation.
        -- All fields are optional; only provided keys are changed.
        -- ----------------------------------------------------------------
        MagExp_SetPhysics = function(data)
            -- Auto-unpause if speed/velocity provided unless isPaused is explicitly requested
            if (data.speed ~= nil or data.velocity ~= nil or data.direction ~= nil) and data.isPaused == nil then
                isPaused = false
            end

            if data.velocity ~= nil then
                velocity    = data.velocity
                signedSpeed = velocity:length()
                if signedSpeed > 0.01 then baseDir = velocity:normalize() end
            end
            -- speed: override magnitude, preserve direction
            if data.speed ~= nil then
                signedSpeed = data.speed   -- can be negative to travel backward from baseDir
                velocity    = baseDir * signedSpeed
            end
            -- direction: redirect, preserve current signed speed
            if data.direction ~= nil then
                baseDir  = data.direction:normalize()
                velocity = baseDir * signedSpeed
            end
            if orientationState.motionPath and (data.velocity ~= nil or data.speed ~= nil or data.direction ~= nil) then
                orientationState.motionPath:redirect(simulatedPosition, velocity)
            end
            if data.accelerationExp    ~= nil then accelerationExp    = data.accelerationExp end
            if data.forceVec           ~= nil then forceVec           = data.forceVec end
            if data.maxSpeed           ~= nil then maxSpeed           = data.maxSpeed end
            if data.rotationFollowRate ~= nil then
                orientationState.followRate = math.max(0, tonumber(data.rotationFollowRate) or 0)
                isRotating = spinSpeed > 0 or orientationState.followRate > 0
            end
            if data.rotationDirectionUndirected ~= nil then
                orientationState.undirected = data.rotationDirectionUndirected == true
            end
            if data.forceCanReverse ~= nil then
                orientationState.allowForceReversal = data.forceCanReverse == true
            end
            if data.bounceEnabled      ~= nil then bounceEnabled      = data.bounceEnabled end
            if data.bounceMax          ~= nil then bounceMax          = data.bounceMax end
            if data.bouncePower        ~= nil then bouncePower        = data.bouncePower end
            if data.detonateOnActorHit ~= nil then detonateOnActorHit = data.detonateOnActorHit end
            if data.piercing           ~= nil then piercing           = data.piercing end
            if data.pierceLimit        ~= nil then pierceLimit        = data.pierceLimit end
            if data.pierceRepeatHits   ~= nil then pierceRepeatHits   = data.pierceRepeatHits == true end
            if data.pierceRateLimit    ~= nil then pierceRateLimit    = tonumber(data.pierceRateLimit) or pierceRateLimit end
            if data.canHitCasterAfter   ~= nil then canHitCasterAfter  = tonumber(data.canHitCasterAfter) end
            if data.collisionMode       ~= nil then collisionMode      = data.collisionMode end
            if data.spellId            ~= nil then spellId            = data.spellId end
            if data.area               ~= nil then area               = data.area end
            if data.areaVfxRecId       ~= nil then areaVfxRecId       = data.areaVfxRecId end
            if data.vfxRecId           ~= nil then vfxRecId           = data.vfxRecId end
            if data.hitModel ~= nil then
                hitModel = data.hitModel
                orientationState.hitModelExplicit = data.hitModelExplicit ~= false
            elseif data.hitModelExplicit ~= nil then
                orientationState.hitModelExplicit = data.hitModelExplicit == true
            end
            if data.maxLifetime        ~= nil then maxLifetime        = data.maxLifetime end
            if data.impactImpulse      ~= nil then impactImpulse      = data.impactImpulse end
            if data.isPaused           ~= nil then isPaused           = data.isPaused end

            -- [SYNC] Tell global to update its registry so damage scales stay correct
            if data.maxSpeed or data.spellId or data.area then
                core.sendGlobalEvent('MagExp_UpdateRegistry', {
                    projId = self.id,
                    maxSpeed = maxSpeed,
                    spellId = spellId,
                    area = area
                })
            end
        end,

        -- ----------------------------------------------------------------
        -- MagExp_WarpProjectile: Same-cell discontinuous repositioning.
        -- Lifetime, collision state, payload ownership, and attached anchors
        -- remain intact. The traversed path is intentionally not raycast.
        -- ----------------------------------------------------------------
        MagExp_WarpProjectile = function(data)
            if hasCollided or not isProjectile or type(data) ~= "table" then return end
            local position = data.position or data.pos
            if position == nil then return end

            simulatedPosition = position
            if orientationState.motionPath then
                orientationState.motionPath:warp(position)
            end
            if data.velocity ~= nil then
                velocity = data.velocity
                signedSpeed = velocity:length()
                if signedSpeed > 0.01 then baseDir = velocity:normalize() end
            else
                if data.direction ~= nil and data.direction:length() > 0.001 then
                    baseDir = data.direction:normalize()
                    velocity = baseDir * signedSpeed
                end
                if data.speed ~= nil then
                    signedSpeed = tonumber(data.speed) or signedSpeed
                    velocity = baseDir * signedSpeed
                end
            end
            if orientationState.motionPath and (data.velocity ~= nil or data.speed ~= nil or data.direction ~= nil) then
                orientationState.motionPath:redirect(simulatedPosition, velocity)
            end
            orientationState.direction = baseDir

            local ignoreDuration = math.max(0, tonumber(data.ignoreDuration) or 0)
            if data.ignoreObject ~= nil and ignoreDuration > 0 then
                orientationState.warpIgnoreObject = data.ignoreObject
                orientationState.warpIgnoreUntil = lifetime + ignoreDuration
            else
                orientationState.warpIgnoreObject = nil
                orientationState.warpIgnoreUntil = 0
            end

            orientationState.pendingWarp = true
            orientationState.pendingWarpTag = data.tag
            if isPaused then
                orientationState.publishMove({
                    projectile  = self,
                    projectileId = self.id,
                    newPos      = simulatedPosition,
                    newRot      = currentRotation,
                    velocity    = velocity,
                    warped      = true,
                    warpTag     = data.tag,
                    soundAnchor = soundAnchor,
                    lightAnchor = lightAnchor
                })
                orientationState.pendingWarp = false
                orientationState.pendingWarpTag = nil
            end
        end,

        -- ----------------------------------------------------------------
        -- MagExp_UpdatePhysics: Backward-compatibility alias.
        -- Always unpauses. New code should use MagExp_SetPhysics.
        -- ----------------------------------------------------------------
        MagExp_UpdatePhysics = function(data)
            if data.velocity        ~= nil then velocity        = data.velocity end
            if data.accelerationExp ~= nil then accelerationExp = data.accelerationExp end
            if data.maxSpeed        ~= nil then maxSpeed        = data.maxSpeed end
            if data.spellId         ~= nil then spellId         = data.spellId end
            if data.areaVfxRecId    ~= nil then areaVfxRecId    = data.areaVfxRecId end
            if data.hitModel ~= nil then
                hitModel = data.hitModel
                orientationState.hitModelExplicit = data.hitModelExplicit ~= false
            elseif data.hitModelExplicit ~= nil then
                orientationState.hitModelExplicit = data.hitModelExplicit == true
            end
            isPaused = false  -- always unpauses (original behaviour)
        end,

        -- ----------------------------------------------------------------
        -- MagExp_GetState: Returns a full state snapshot.
        -- Reply arrives as global event MagExp_SpellState { tag = ... }.
        -- ----------------------------------------------------------------
        MagExp_GetState = function(data)
            core.sendGlobalEvent('MagExp_SpellState', {
                projectile         = self,
                tag                = data and data.tag,
                velocity           = velocity,
                speed              = velocity and velocity:length() or 0,
                direction          = velocity and velocity:normalize() or util.vector3(0, 1, 0),
                position           = simulatedPosition or self.position,
                hitModel           = hitModel,
                hitModelExplicit   = orientationState.hitModelExplicit,
                spellId            = spellId,
                area               = area,
                lifetime           = lifetime,
                maxLifetime        = maxLifetime,
                isPaused           = isPaused,
                accelerationExp    = accelerationExp,
                forceVec           = forceVec,
                maxSpeed           = maxSpeed,
                bounceEnabled      = bounceEnabled,
                bounceCount        = bounceCount,
                bounceMax          = bounceMax,
                bouncePower        = bouncePower,
                detonateOnActorHit = detonateOnActorHit,
                piercing           = piercing,
                pierceLimit        = pierceLimit,
                pierceCount        = pierceCount,
                piercePulseCount   = piercePulseCount,
                pierceRepeatHits   = pierceRepeatHits,
                pierceRateLimit    = pierceRateLimit,
                canHitCasterAfter   = canHitCasterAfter,
                collisionMode       = collisionMode,
                hasCollided        = hasCollided,
                vfxRecId           = vfxRecId,
                areaVfxRecId       = areaVfxRecId,
                impactImpulse      = impactImpulse,
                userData           = userData
            })
        end,

        -- ----------------------------------------------------------------
        -- MagExp_ForceCancel: Immediately expire the projectile.
        -- ----------------------------------------------------------------
        MagExp_ForceCancel = function()
            expireProjectile('force_cancel')
        end,

        -- ----------------------------------------------------------------
        -- MagExp_ForceTeleport: Sync anchors when global moves the object.
        -- ----------------------------------------------------------------
        MagExp_ForceTeleport = function(data)
            local cellName, pos = data.cellName, data.pos
            if not pos then return end
            core.sendGlobalEvent('MagExp_AnchorTeleport', {
                projectile  = self,
                cellName    = cellName,
                pos         = pos,
                lightAnchor = lightAnchor,
                soundAnchor = soundAnchor
            })
        end,
    },
}
