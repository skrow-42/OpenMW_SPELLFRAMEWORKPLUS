---@omw-context player
--[[
    LookTarget - Shared Raycast Service v1

    Provides a single rendering raycast per frame for all mods to consume.
    Ship this file with any mod that needs look-target data.

    Version priority:
        - Multiple mods can ship this at the same path
        - VFS dedupes identical files
        - If different versions exist, highest version wins the interface
        - Lower versions skip their raycast via version check

    Usage:
        local result = I.SharedRay.get()
        if result.hit then
            -- player is looking at something
        end

    Result fields (the same table is refreshed every frame; copy any field
    you need to keep across frames):
        hit         - boolean
        hitPos      - Vector3 or nil
        hitNormal   - Vector3 or nil
        hitObject   - GameObject or nil
        hitTypeName - string (e.g. "Container", "NPC") or nil
]]
local core = require('openmw.core')
local nearby = require('openmw.nearby')
local camera = require('openmw.camera')
local util = require('openmw.util')
local self = require('openmw.self')
local types = require('openmw.types')
local I = require('openmw.interfaces')

local MY_VERSION = 1

if I.SharedRay and I.SharedRay.version >= MY_VERSION then
    return
end

local iMaxActivateDist = core.getGMST("iMaxActivateDist") or 192
local TELEKINESIS_UNITS_PER_POINT = 22
local raycast = nearby.castRenderingRay
local rayOptions = { ignore = self }

local cachedResult = {
    hit = false,
    hitPos = nil,
    hitNormal = nil,
    hitObject = nil,
    hitTypeName = nil,
}

local function getCameraVector()
    local yaw = camera.getYaw()
    local pitch = camera.getPitch()
    local cosPitch = math.cos(pitch)
    return util.vector3(
        math.sin(yaw) * cosPitch,
        math.cos(yaw) * cosPitch,
        -math.sin(pitch)
    )
end

local function onFrame()
    -- Defer to a higher version if one exists
    if I.SharedRay.version > MY_VERSION then return end

    local cameraPos = camera.getPosition()
    local maxDist = iMaxActivateDist + camera.getThirdPersonDistance()

    local telekinesis = types.Actor.activeEffects(self):getEffect(core.magic.EFFECT_TYPE.Telekinesis)
    if telekinesis then
        maxDist = maxDist + telekinesis.magnitude * TELEKINESIS_UNITS_PER_POINT
    end

    local ray = raycast(cameraPos, cameraPos + getCameraVector() * maxDist, rayOptions)
    local hitObject = ray.hitObject
    cachedResult.hit = ray.hit
    cachedResult.hitPos = ray.hitPos
    cachedResult.hitNormal = ray.hitNormal
    cachedResult.hitObject = hitObject
    cachedResult.hitTypeName = hitObject and tostring(hitObject.type) or nil
end

local function get()
    return cachedResult
end

local function setRayType(func)
    raycast = func
    if func == nearby.castRenderingRay then
        print("[SharedRay] changing raycast to castRenderingRay")
    elseif func == nearby.castRay then
        print("[SharedRay] changing raycast to castRay")
    else
        print("[SharedRay] changing raycast to unknown")
    end
end

return {
    interfaceName = "SharedRay",
    interface = {
        version = MY_VERSION,
        get = get,
        setRayType = setRayType,
    },
    engineHandlers = {
        onFrame = onFrame,
    },
}
