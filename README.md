# SPELL FRAMEWORK PLUS (MagExp) v1.7

**SPELL FRAMEWORK PLUS** is a standardized spell-launching engine for OpenMW Lua. It dehardcodes the magic system and provides a unified public interface (`I.MagExp`) for modders to trigger spell casts, control projectiles in flight, and hook into lifecycle events.

---

## 1. Setup for Modders

0. (Optional) Have **MaxYari's LuaPhysics** enabled for physics impulse support.
1. Ensure `SPELL_FRAMEWORK_PLUS.omwscripts` is loaded.
2. Ensure your mod has a dependency or check for the interface.

> [!NOTE]
> MaxYari's LuaPhysics is no longer a hard dependency. SFP degrades gracefully — the `impactImpulse` feature will silently do nothing if LuaPhysics is not loaded.

---

## 2. Public API: `I.MagExp` (Global)

Call these from any **Global Script** using `local I = require('openmw.interfaces')`.

### Core

| Function | Description |
|:--|:--|
| `launchSpell(data)` | Launch a spell. Auto-detects routing (Self/Touch/Target). Returns the projectile object. |
| `emitProjectileFromObject(data)` | Emit a projectile spell directly from a non-actor Static/Door/Activator `data.source` without causing engine crashes. |
| `applySpellToActor(...)` | Directly apply a spell to an actor. (Ordered arguments, see signature below). |
| `detonateSpellAtPos(...)` | Trigger an AoE blast at a world position. (Ordered arguments, see signature below). |
| `addTargetFilter(fn)` | Register a global filter `fn(target) → bool` to veto hits. |
| `registerLockableEffect(id)` | Register an effect ID to allow spells to interact with doors and containers. |
| `registerUniversalEffect(id)`| Register an effect ID to allow Touch spells to interact with ANY game object (Statics, Activators, etc.) and emit a `MagExp_OnMagicHit` hook for it. |
| **Engine Safety** | All internal VFX and sound dispatchers include `target.enabled` guards to prevent "Can't use a disabled object" errors during high-intensity combat or unsummoning. |
| `STACK_CONFIG` | Table controlling spell stacking limits. |

#### Advanced Application Parameters
- **`forcedEffects`**: (Array of ints) A list of 0-based effect indices from the spell record. If provided, only these specific effects are applied, ignoring the rest.
The forcedEffects parameter is a specialized filter for the spell's effect list.

How it works technically:
When SFP applies a spell to a target, it usually applies every effect found in the spell record (index 0, 1, 2, etc.). However, if you pass forcedEffects, you are overriding this behavior with a specific "allow-list."

Example: Imagine a spell record called my_super_spell with three effects:

Index 0: Fire Damage (Target)
Index 1: Restore Health (Self)
Index 2: Paralyze (Target)
If you call I.MagExp.applySpellToActor with forcedEffects = {0, 2}, the target will receive the Fire Damage and the Paralyze effect, but the Restore Health effect will be completely ignored.

Why this is useful:
Splitting Spells: You can have one master spell record and use forcedEffects to launch different parts of it from different projectiles (e.g., a "scattering shot" where each fragment only carries one piece of the spell).
Self vs. Target Logic: In the SFP core, this is used to strip "Self" effects away from a projectile so they apply to the caster immediately, while the "Target" effects travel with the bolt.
Conditional Effects: You can use your mod's logic to decide during the hit event which effects from the record should actually "stick" to the target.
Note: In the code, these indices are 0-based (matching the OpenMW engine's internal data structure). Passing {0} always targets the first effect in the list.

- **`excludeTarget`**: (Object) Used in `detonateSpellAtPos`. This specific object will be ignored by the AoE blast (used to prevent double-hits on the primary target).

### In-Flight Spell Control

| Function | Description |
|:--|:--|
| `getSpellState(projId, tag)` | Request a state snapshot. Reply arrives as `MagExp_SpellState` event with the same `tag`. |
| `setSpellPhysics(projId, data)` | Mutate any physics property of a live spell (see full field list below). |
| `redirectSpell(projId, direction)` | Change the flight direction. Speed is preserved. |
| `setSpellSpeed(projId, speed)` | Set the projectile speed. Direction is preserved. |
| `setSpellPaused(projId, paused)` | Freeze or unfreeze a projectile in place. |
| `cancelSpell(projId)` | Force-cancel and remove a live spell. |
| `setSpellBounce(projId, enabled, max, power)` | Configure bounce on a live spell. |
| `setSpellDetonateOnActor(projId, bool)` | Toggle whether actor contact detonates a bouncing spell. |
| `getActiveSpellIds()` | Returns a table of all live spell projectile IDs. |

### Lifecycle Hooks

Override these to respond to events globally:
```lua
I.MagExp.onEffectApplied    = function(actor, effect) end
I.MagExp.onEffectTick       = function(actor, effect) end
I.MagExp.onEffectOver       = function(actor, effect) end
I.MagExp.onProjectileBounce = function(data) end
-- data: { projectile, spellId, attacker, hitPos, hitNormal, bounceCount, speed }
```

---

## 3. Usage from Player / Local Scripts

Player and local scripts cannot call `I.MagExp` directly. Use global events:

```lua
local core = require('openmw.core')
local self = require('openmw.self')

core.sendGlobalEvent('MagExp_CastRequest', {
    attacker  = self,
    spellId   = "fireball",
    startPos  = self.position + util.vector3(0, 0, 120),
    direction = self.rotation * util.vector3(0, 1, 0),
    isFree    = true
})
```

---

## 4. `launchSpell` Parameter Reference

All fields except the first four are optional.

| Parameter | Type | Default | Description |
|:--- |:--- |:--- |:--- |
| **Identity & Source** | | | |
| **attacker** | `Actor` | Required | The casting actor. |
| **spellId** | `string` | Required | Spell record ID. |
| **itemObject** | `Object` | `nil` | Source item (for enchantment logic). |
| **casterLinked** | `boolean` | `false` | If true, hostile reactions are attributed to the `attacker`. |
| **userData** | `table` | `nil` | Custom per-launch cookie. Returned in all events. |
| **Movement & Lifecycle** | | | |
| **startPos** | `Vector3` | Required | World position where the spell spawns. |
| **direction** | `Vector3` | Required | Initial flight direction. |
| **speed** | `number` | `1500` | Initial speed (units/sec). |
| **maxSpeed** | `number` | `0` | Speed cap (0 = unlimited). |
| **minSpeed** | `number` | `0` | Speed floor when decelerating. |
| **accelerationExp** | `number` | `0` | Exponential speed multiplier per frame. |
| **forceVec** | `Vector3` | `nil` | Continuous acceleration vector (units/sec²). |
| **maxLifetime** | `number` | `10` | Seconds before expiry. |
| **spawnOffset** | `number` | `80` | Distance ahead of `startPos` to spawn. |
| **isPaused** | `boolean` | `false` | Spawn frozen in place. |
| **Collision & Bouncing** | | | |
| **bounceEnabled** | `boolean` | `false` | Reflect off static geometry. |
| **bounceMax** | `number` | `0` | Max bounces (0 = unlimited). |
| **bouncePower** | `number` | `0.7` | Restitution coefficient (0-1). |
| **detonateOnActorHit** | `boolean` | `true` | If false, actors are treated as static for bounce. |
| **impactImpulse** | `number` | `0` | MaxYari LuaPhysics knockback magnitude. |
| **Audiovisual** | | | |
| **vfxRecId** | `string` | Auto | Bolt VFX record ID (auto-detected). |
| **boltModel** | `string` | Auto | Bolt mesh path override. |
| **areaVfxRecId** | `string` | Auto | Override area explosion static VFX. |
| **areaVfxScale** | `number` | `1.0` | Visual scale for AoE explosion. |
| **boltSound** | `string` | Auto | Looping flight sound. |
| **boltLightId** | `string\|table`| `nil` | Light record ID OR dynamic `recordDraft`. |
| **spinSpeed** | `number` | Auto | Rotation speed in rad/sec. |
| **muteAudio** | `boolean` | `false` | Skips flight and impact sounds. |
| **muteLight** | `boolean` | `false` | Skips environmental lighting on bolt. |
| **muteCastGlow** | `boolean` | `false` | Skips cast glow VFX on attacker. |
| **continuousVfx** | `boolean` | `false` | Cast VFX follows target until expiry. |
| **Logic & Constraints** | | | |
| **spellType** | `number` | Auto | Routing: Self/Touch/Target. |
| **area** | `number` | Auto | AoE radius in game units. |
| **isFree** | `boolean` | `false` | Skip magicka cost check. |
| **unreflectable** | `boolean` | `false` | Cannot be reflected. |
| **nonRecastable** | `boolean` | `false` | Aborts if spell is already active on caster. |
| **itemRequirements** | `table` | `nil` | Inventory requirements check. |

#### `itemRequirements` Details
The framework can automate inventory checks for the caster. If items are missing, the spell is aborted and a message is displayed to the player.
- `all`: (Table) A list of item IDs. Caster must have **all** of them.
- `any`: (Table) A list of item IDs. Caster must have **at least one**.

```lua
itemRequirements = {
    all = { "gold_001", "repair_prongs_01" },
    any = { "ingred_fire_salt_01", "ingred_frost_salt_01" }
}
```

#### `Dynamic Lighting (Record Drafts)`
You can pass a dynamically generated Light record draft to `boltLightId` to create custom colors, radius, or flickering for your spell. (use this for data reference for draft https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_types.html##(LightRecord) )

```lua
local types = require('openmw.types')
local draft = types.Light.createRecordDraft({
    color = util.color.rgb(1, 0.5, 0), -- Orange
    radius = 256,
    isCarriable = false
})

I.MagExp.launchSpell({
    ...,
    boltLightId = draft
})
```

---

## 5. Overrides & Live Modification

### 5.1 `setSpellPhysics` / `MagExp_SetPhysics`
These fields can be passed as a table to mutate a live projectile.

| Field | Type | Description |
|:--- |:--- |:--- |
| **Movement** | | |
| `velocity` | `Vector3` | Full velocity override. |
| `speed` | `number` | Speed override (direction unchanged). |
| `direction` | `Vector3` | Direction redirect (speed unchanged). |
| `accelerationExp` | `number` | New exponential speed multiplier. |
| `forceVec` | `Vector3` | New continuous force vector. |
| `maxSpeed` | `number` | New terminal velocity cap. |
| `isPaused` | `boolean` | Pause or unpause. |
| **Collision & Lifecycle** | | |
| `bounceEnabled` | `boolean` | Enable/disable bouncing. |
| `bounceMax` | `number` | Max bounce count. |
| `bouncePower` | `number` | Restitution. |
| `detonateOnActorHit` | `boolean` | Actor-detonation toggle. |
| `maxLifetime` | `number` | Override max lifetime. |
| `impactImpulse` | `number` | Override physics knockback. |
| **Identity & Visuals** | | |
| `spellId` | `string` | Override what is applied on impact. |
| `area` | `number` | Override area radius. |
| `vfxRecId` | `string` | Override bolt VFX. |
| `areaVfxRecId` | `string` | Override explosion VFX. |

---

## 6. In-Flight Spell Control

The **Live Spell Registry** tracks every projectile launched by MagExp. Each projectile's `proj.id` is the key.

```lua
local I = require('openmw.interfaces')

-- Get all live projectile IDs
local ids = I.MagExp.getActiveSpellIds()

-- Redirect the first one mid-flight
if ids[1] then
    I.MagExp.redirectSpell(ids[1], util.vector3(1, 0, 0))
end

-- Apply braking force (opposing velocity direction)
I.MagExp.setSpellPhysics(ids[1], {
    forceVec = util.vector3(0, -300, 0)  -- backward force
})

-- Query state asynchronously
I.MagExp.getSpellState(ids[1], "my_tag")
-- Then listen for:
-- MagExp_SpellState { tag = "my_tag", velocity = ..., position = ..., ... }
```

---

## 7. Bounce Physics

When `bounceEnabled = true`, a projectile reflects off static geometry using surface normal reflection:


**Rules:**
- **Actors**: Always detonate immediately (unless `detonateOnActorHit = false`).
- **Static / terrain**: Bounce up to `bounceMax` times. At the limit, the next hit detonates.
- Each bounce fires the `MagExp_OnProjectileBounce` global event and the `I.MagExp.onProjectileBounce` hook.

```lua
-- Bouncing grenade example
I.MagExp.launchSpell({
    attacker      = actor,
    spellId       = "grenade",
    startPos      = spawnPos, direction = dir,
    bounceEnabled = true,
    bounceMax     = 4,
    bouncePower   = 0.6,
    detonateOnActorHit = true,  -- default
})

-- Listen for bounces
I.MagExp.onProjectileBounce = function(data)
    print("Bounce #" .. data.bounceCount .. " at " .. tostring(data.hitPos))
end
```

---

## 8. Acceleration & Force Vectors

### `accelerationExp` — Exponential Signed Speed Modifier

Multiplies `signedSpeed` (a number that can be negative) each frame:
```
signedSpeed = signedSpeed × exp(accelerationExp × dt)
velocity    = baseDir × signedSpeed
```

- **Positive** → spell accelerates exponentially toward `maxSpeed`.
- **Negative** → spell decelerates. When `signedSpeed` drops through zero it **continues into negative territory**, reversing the velocity direction along the original launch axis. The spell will then accelerate backwards.
- `baseDir` is the "positive forward" axis captured at launch (or at the last explicit direction/velocity override). It is never changed by `accelerationExp` itself — only the sign of `signedSpeed` flips.
- `maxSpeed` caps `|signedSpeed|` in both directions (forward and reverse).

```lua
-- A spell that launches forward, slows, reverses, and flies back
I.MagExp.launchSpell({
    attacker      = actor, spellId = "boomerang",
    startPos      = pos, direction = dir,
    speed         = 2000,
    accelerationExp = -1.5,   -- decelerates, crosses zero, reverses
    maxSpeed      = 2000,     -- applies to |speed| in both directions
    maxLifetime   = 5,
})
```

> [!NOTE]
> To stop reversal at zero (classic deceleration only), use `forceVec` instead of `accelerationExp` and zero it out once velocity is near-zero.

### `forceVec` — True Directional Force

Added directly to velocity each frame:
```
velocity = velocity + forceVec * dt
```
Use for: homing, gravity, braking, sideways drift. To decelerate, set `forceVec` opposite to the initial direction:
```lua
-- Apply braking force on a launched spell
I.MagExp.setSpellPhysics(projId, {
    forceVec = dir:normalize() * -800   -- decelerate at 800 units/sec²
})
```
When `velocity:length() < 0.5` due to a forceVec, the projectile expires gracefully.

---

## 9. Speed-Scaled Damage

`impactSpeed` is captured at the exact frame of collision and forwarded in the `MagExp_OnMagicHit` event payload alongside `maxSpeed` from the registry. Use this to apply proportional damage:

```lua
-- In your global script's MagExp_OnMagicHit handler:
MagExp_OnMagicHit = function(data)
    if data.spellId ~= 'my_kinetic_spell' then return end
    
    -- We scale from magMin (at low speed) to magMax (at max speed)
    local magMin    = data.magMin or 10
    local magMax    = data.magMax or magMin
    local maxSpeed  = data.maxSpeed or 5000
    
    local ratio     = math.max(0.0, math.min(1.0, data.impactSpeed / maxSpeed))
    local finalDmg  = magMin + (magMax - magMin) * ratio
    
    if data.target and data.target:isValid() then
        -- Use Hit event to ensure reactions/bounties trigger correctly:
        data.target:sendEvent('Hit', {
            attacker = data.attacker,
            damage = { health = finalDmg },
            type = 'Thrust', sourceType = 'Magic', successful = true
        })
    end
end
```

### Magnitude Detection Logic
The framework provides `magMin` and `magMax` by:
1. Using the magnitude of the **primary (first) effect** in the spell record.
2. This ensures 1:1 parity with the vanilla engine's display and event logic, allowing multi-effect spells to be processed independently by the engine while reporting the primary impact strength for combat logs.

---

## 10. Physics Impulse on Impact (MaxYari LuaPhysics)

Set `impactImpulse` (a magnitude in LuaPhysics force units) to knock back a hit actor using MaxYari's physics engine:

```lua
I.MagExp.launchSpell({
    attacker      = actor,
    spellId       = "kinetic_bolt",
    startPos      = pos, direction = dir,
    impactImpulse = 2000,   -- knocked back proportional to hit direction
})
```

The impulse is applied via `LuaPhysics_ApplyImpulse` event sent directly to the hit actor. If MaxYari LuaPhysics is not loaded, this is a no-op (the event is silently ignored).

---

## 11. Magic Impact Event: `MagExp_OnMagicHit`

Broadcasted globally on every spell impact (projectile, touch, self).

### Field Reference (`MagicHitInfo`)

| Field | Type | Description |
|:--- |:--- |:--- |
| **Primary Entities** | | |
| `attacker` | `GameObject` | The casting actor. |
| `target` | `GameObject` | The hit object. |
| **Spatial & Physics** | | |
| `hitPos` | `Vector3` | Impact world position. |
| `hitNormal` | `Vector3` | Surface normal at impact. |
| `impactSpeed` | `number` | Speed (units/sec) at collision. |
| `maxSpeed` | `number` | Speed cap from launch parameters. |
| `velocity` | `Vector3` | Final velocity vector at impact. |
| **Record Metadata** | | |
| `spellId` | `string` | Spell record ID. |
| `school` | `string` | Magic school (e.g. `"alteration"`). |
| `element` | `string` | `fire`, `frost`, `shock`, `poison`, `heal`, or `default`. |
| `damage` | `table` | `{ health, magicka, fatigue }` (Average values). |
| `magMin` | `number` | Aggregated minimum magnitude. |
| `magMax` | `number` | Aggregated maximum magnitude. |
| `spellType` | `number` | 0=Self, 1=Touch, 2=Target. |
| **Context & Status** | | |
| `isAoE` | `boolean` | True if part of an area blast. |
| `area` | `number` | AoE radius (if applicable). |
| `unreflectable` | `boolean` | Cannot be reflected. |
| `casterLinked` | `boolean` | Attributed to caster. |
| `userData` | `table` | Custom launch cookie. |
| `muteAudio` | `boolean` | Audio suppression status. |
| `muteLight` | `boolean` | VFX suppression status. |
| `stackLimit` | `number` | Stacking limit for this spell. |
| `stackCount` | `number` | Current instances after this hit. |
| `proxyLookup` | `boolean` | True if resolved via iterative search. |

### Robust Record Identification
The framework uses a two-phase lookup system for `spellId`. If the engine cannot find a record by direct key (common when using numeric proxies in OSSC or Trap mods), SFP performs an iterative case-insensitive search to locate the correct spell or enchantment data. This ensures Area and Damage metadata is never lost.

---

## 12. Effect Lifecycle Events

| Event/Hook | When fired |
|:--|:--|
| `onEffectApplied` / `MagExp_OnEffectApplied` | Spell is added to an actor's active spells. |
| `onEffectTick` / `MagExp_OnEffectTick` | Each cleanup cycle while spell is still active (~10/sec). |
| `onEffectOver` / `MagExp_OnEffectOver` | Spell expires or actor dies. |

---

## 13. Precision Targeting: `I.SharedRay`

```lua
local I   = require('openmw.interfaces')
local ray = I.SharedRay.get()

if ray.hit and ray.hitObject then
    core.sendGlobalEvent('MagExp_CastRequest', {
        attacker  = self,
        spellId   = "spark",
        hitObject = ray.hitObject,
        hitPos    = ray.hitPos
    })
end
```

---

## 14. Code Examples

### A. Kinetic Bolt (Paused Phase 1 → Active Phase 2)

```lua
-- Phase 1: Launch frozen in place
local bolt = I.MagExp.launchSpell({
    attacker = actor, spellId = 'kb_launch',
    startPos = spawnPos, direction = dir,
    speed = 0, isPaused = true,
    vfxRecId = 'VFX_Soul_Trap', boltModel = 'meshes/w/magic_target.nif',
    boltLightId = 'kinetic_light', boltSound = 'alteration bolt',
    maxSpeed = 5000, isFree = true,
})

-- Phase 2: Release it
bolt:sendEvent('MagExp_SetPhysics', {
    velocity        = dir * 40,
    accelerationExp = 2.25,
    isPaused        = false
})
```

### B. Bouncing Grenade

```lua
I.MagExp.launchSpell({
    attacker = actor, spellId = 'grenade', startPos = pos, direction = dir,
    speed    = 1800, bounceEnabled = true, bounceMax = 5, bouncePower = 0.55,
    areaVfxRecId = 'VFX_DefaultHit', impactImpulse = 1500
})
```

### C. Decelerating Homing Bolt (Mid-Flight Redirect)

```lua
-- Launch normally
local ids = I.MagExp.getActiveSpellIds()

-- On next frame, redirect and brake
I.MagExp.redirectSpell(ids[1], targetDir)
I.MagExp.setSpellPhysics(ids[1], {
    forceVec = targetDir:normalize() * -200   -- gentle brake
})
```

### D. Restricting Stacking

```lua
local I = require('openmw.interfaces')
if I.MagExp then
    I.MagExp.STACK_CONFIG.SPELL_LIMITS["gods_shield"] = 1
end
```

### E. Multicast / Burst (Instance Suppression)

When launching many projectiles at once, you can silence the additional projectiles to avoid audio/VFX clutter while keeping them visible:

```lua
local clusterTag = "burst_" .. tostring(os.clock())

for i = 1, 32 do
    I.MagExp.launchSpell({
        attacker  = self,
        spellId   = "spark",
        startPos  = pos,
        direction = dir,
        -- Only mute if it's NOT the first projectile
        muteAudio = (i > 1),
        muteLight = (i > 1),
        -- Per-launch identity for routing:
        userData = { 
            clusterId = clusterTag,
            slotIndex = i 
        }
    })
end
```

### F. Dynamic Lighting + Item Requirements

Create a custom colored light and require specific items for the cast:

```lua
local types = require('openmw.types')
local util  = require('openmw.util')

-- 1. Create the light draft
local draft = types.Light.createRecordDraft({
    color  = util.color.rgb(0, 0.8, 1), -- Cyan
    radius = 300,
    isFire = false
})

-- 2. Launch with requirements
I.MagExp.launchSpell({
    attacker  = self,
    spellId   = "fireball",
    startPos  = pos,
    direction = dir,
    
    -- Dynamic Light
    boltLightId = draft,
    
    -- Item Requirements
    itemRequirements = {
        all = { "gold_001" },           -- Costs 1 gold
        any = { "ingred_fire_salt_01" } -- Requires fire salts
    }
})
```

---

## 15. Utility Events

### `MagExp_BreakInvisibility`
```lua
core.sendGlobalEvent('MagExp_BreakInvisibility', { actor = myPlayer })
```

### `MagExp_CastRequest`
Launch a spell from a player/local script (see §3).

---

## 16. Internal Notes

- **Carrier Object**: Projectiles use `Colony_Assassin_act` dummy static as the physical carrier.
- **Collision**: 5-point cross raycast pattern every frame, simulating a ~12-unit-radius sphere.
- **Sound/Light Anchors**: Separate carrier objects parented to the projectile via teleport each frame.
- **Bounding Box Awareness**: Distance checks for AoE registration use the target's physical center (bounding box center via `.halfSize`) rather than their origin (feet). This accounts for an object's physical radius, providing 1:1 hit-parity with vanilla's volume-based detection.

---

## 17. Engine Parity: 1:1 AoE Radius

SFP synchronizes exactly with the engine's internal magic constants and global settings to ensure your spells reach exactly as far as they do in vanilla:

1. **Vanilla Constant (22.1 Units/Foot)**: The framework uses the standard Morrowind conversion of 22.1 game units per 1 foot of Area.
2. **GMST Integration**: `fAreaRadiusMult` is queried directly. If you (or another mod) increase the global explosion size in the GMSTs, SFP's hit registration and visual scaling will automatically adapt to maintain parity.
3. **Primary-Only Logic**: SFP strictly follows the vanilla engine's rule where Area and impact metadata are derived only from the **first effect** in a spell record. This ensures perfect rotational and logical parity with base game spells.

---

## 17. Static Object Interactions

Here are three APIs for configurable interactions with non-actors:

### A. Targeting Lockables (Doors & Containers)
Spells that should affect doors/containers must be registered with the interface function below:
```lua
I.MagExp.registerLockableEffect("my_custom_door_breaker")
```

### B. Universal Object Targeting
If you want a Touch or Projectile spell to detect absolutely ANY world object it hits (Walls, Statics, Activators, Lights) so you can attach a VFX emitter or a script to that mesh for any reason - register the effect as universal:
```lua
I.MagExp.registerUniversalEffect("my_custom_paint_spell")
```

### C. Emitting Projectiles From Non-Actors
To make a wall trap or an explosive barrel shoot a fireball, use this wrapper. All of the available fields are specified below:
```lua
I.MagExp.emitProjectileFromObject({
    -- Core Options
    source    = myMechanicalTrapStatic, -- A non-actor Static object (Required)
    spellId   = "fireball",             -- Spell record ID (Required)
    direction = util.vector3(0, 1, 0),  -- Forward trajectory vector (Required)
    -- Optional Overrides (Behavior is otherwise inherited from the spell record)
    attacker         = someActor, -- Attribution (for reactions/stats)
    startPos         = spawnPos,  -- Defaults to the object's center bounding box
    speed            = 2500,      -- Initial speed (Defaults to 1500)
    spawnOffset      = 80,        -- Distance ahead of startPos to spawn
    maxLifetime      = 10,        -- Expiry timeout in seconds
    area             = 15,        -- AoE override
    isPaused         = false,     -- Spawn frozen?
    unreflectable    = true,
    casterLinked     = true,      -- Attributed to the provided 'attacker'
    -- Optional Physics Config (MaxSpeed, Bouncing, Impulse)
    maxSpeed         = 3000,      -- Speed cap
    accelerationExp  = 1.5,       -- Exponential speed multiplier per frame
    impactImpulse    = 1500,      -- MaxYari LuaPhysics knockback
    bounceEnabled    = true,
    bounceMax         = 3,
    bouncePower      = 0.7,
    -- Optional Audiovisual Overrides
    vfxRecId         = "my_bolt_vfx_record",
    areaVfxRecId     = "my_area_vfx_record",
    boltModel        = "meshes/my/custom_bolt.nif",
    boltSound        = "alteration bolt",
    boltLightId      = "my_bolt_light_record",
    spinSpeed        = 15.0
})
```

## 19. Engine-Accurate Cast Glow and Colored Projectile Light (`MagicEffect.color`) Override Behavior

You can now manually provide a `boltLightId` draft to override the auto-derived light:

```lua
local types = require('openmw.types')

I.MagExp.launchSpell({
    attacker = actor, spellId = "fireball",
    startPos = pos,   direction = dir,
    -- Override auto-color with a custom cyan light
    boltLightId = types.Light.createRecordDraft({
        color  = util.color.rgb(0, 0.8, 1),
        radius = 300,
        isFire = false
    }),
    -- Suppress the cast glow on the caster if needed
    muteCastGlow = true,
})
```

| Parameter | Type | Default | Description |
|:--|:--|:--|:--|
| `muteCastGlow` | `boolean` | `false` | If true, skips spawning the cast glow VFX on the attacker. |
| `boltLightId` | `string\|table` | Auto (from `mgef.color`) | Explicit light override. Overrides auto-derived color light. |

---

## 20. Persistent Effect VFX (`continuousVfx`)

Pass `continuousVfx = true` in `launchSpell` data to make the spell's cast VFX persist on the **target** for the full duration of the active effect. This is intended for spells like Shield, Fortify, and Elemental Ward that benefit from a continuous visual indicator.

The framework tracks this using the existing `activeVfxRegistry`. The VFX is automatically removed the moment the spell expires or is dispelled.

```lua
I.MagExp.launchSpell({
    attacker = actor, spellId = "lightning_shield",
    startPos = pos,   direction = dir,
    continuousVfx = true,  -- VFX follows the target until the spell ends
})
```

You can also register a specific effect ID as always-persistent without needing to pass the flag each time:

```lua
-- Register once during mod initialization
I.MagExp.registerPersistentEffect("lightning_shield_effect")
```

| Parameter | Type | Default | Description |
|:--|:--|:--|:--|
| `continuousVfx` | `boolean` | `false` | If true, the cast VFX is attached to the target and tracked until the spell expires. |

---

## 21. Non-Recastable Spells (`nonRecastable`)

Pass `nonRecastable = true` to silently prevent re-casting a spell that is already active on the caster. Useful for shield barriers, unique summons, and buff spells that should not be stacked, without having to manage stacking rules manually.

```lua
I.MagExp.launchSpell({
    attacker = actor, spellId = "gods_shield",
    startPos = pos,   direction = dir,
    nonRecastable = true,  -- Silently ignored if already active
})
```

| Parameter | Type | Default | Description |
|:--|:--|:--|:--|
| `nonRecastable` | `boolean` | `false` | If true, aborts launch silently if the spell is already in the caster's active spell list. |

> [!NOTE]
> `nonRecastable` checks the **caster's** active spells, not the target's. If you need to prevent stacking on targets, use `STACK_CONFIG.SPELL_LIMITS` instead.

---

## 22. Custom Cast Animation API: `launchSpellAnim`

Trigger any custom animation on an actor on part of the spell cast lifecycle, with full control over bone group, blend mask, and scheduling priority.

```lua
local I = require('openmw.interfaces')

I.MagExp.launchSpellAnim({
    actor     = myActor,
    animGroup = "quickcast",                    -- animation group name in the NIF/KF
    blendMask = I.MagExp.BLEND_MASK.UpperBody,  -- animate upper body only
    priority  = I.MagExp.PRIORITY.Weapon,       -- scheduling priority
    isCharged = false,                          -- instant cast (start→release→stop)
})
```

To gracefully conclude a looping or charged animation (triggering the release and spell launch):

```lua
-- Releases the held charge: animation proceeds to 'release' → spell fires → 'stop'
I.MagExp.stopSpellAnim(myActor, "quickcast")
```

> [!IMPORTANT]
> `stopSpellAnim` does **not** abruptly cancel the animation. It seeks to the `release` text key position, which fires the spell through the standard `onTextKey` handler, then lets the animation play through to `stop` naturally.

### `BLEND_MASK` Constants

| Name | Value | Bones Affected |
|:--|:--|:--|
| `LowerBody` | `1` | `Bip01 pelvis` and below |
| `Torso` | `2` | `Bip01 Spine1` and up, excluding arms |
| `LeftArm` | `4` | `Bip01 L Clavicle` and out |
| `RightArm` | `8` | `Bip01 R Clavicle` and out |
| `UpperBody` | `14` | `Bip01 Spine1` and up, including arms |
| `All` | `15` | All bones |

### `PRIORITY` Constants

| Name | Value | Use Case |
|:--|:--|:--|
| `Default` | `0` | Ambient/idle |
| `WeaponLowerBody` | `1` | Weapon walk cycle |
| `SneakIdleLowerBody` | `2` | Sneak stance lower body |
| `SwimIdle` | `3` | Swimming |
| `Jump` | `4` | Jump arc |
| `Movement` | `5` | Walk/run |
| `Hit` | `6` | Hit reaction |
| `Weapon` | `7` | Standard weapon play ← **default for spells** |
| `Block` | `8` | Block stance |
| `Knockdown` | `9` | Knockdown |
| `Torch` | `10` | Torch hold |
| `Storm` | `11` | Environmental storm |
| `Death` | `12` | Death |
| `Scripted` | `13` | Overrides all non-scripted animations |

### Animation Lifecycle

Both instant and charged spells **launch at the `release` text key**. The difference is how they reach it:

| `isCharged` | Flow |
|:--|:--|
| `false` | `start` → `release` ← *spell fires here* → `stop` |
| `true` | `start` → loop on `charge` (hold key) → `release` ← *spell fires here* → `stop` |

### `launchSpellAnim` Parameter Table

| Parameter | Type | Default | Description |
|:--|:--|:--|:--|
| **actor** | `Actor` | Required | The actor to animate. |
| **animGroup** | `string` | Required | Animation group name (as defined in the NIF/KF). |
| `blendMask` | `number` | `BLEND_MASK.All` | Which bones to drive. |
| `priority` | `number` | `PRIORITY.Weapon` | Animation scheduling priority. |
| `isCharged` | `boolean` | `false` | If true, loops on `charge` text key until `stopSpellAnim` is called. |
| `chargeKey` | `string` | `nil` | Registered charge key ID (see §23). Used with `isCharged = true`. |
| `onRelease` | `function` | `nil` | Optional callback invoked when the release phase begins. |

---

## 23. Charged Spell System + Cross-Mod Key Binding

When `isCharged = true`, the animation loops on the `charge` text key until the registered key binding is released. The spell then proceeds automatically to `release` (firing the launch) and then `stop`.

### Registering a Charge Key (from any player/local script)

```lua
local I     = require('openmw.interfaces')
local input = require('openmw.input')

-- Register once, typically in onInit or on first cast:
I.MagExp.registerChargeKey("MyMod_HoldKey", function()
    return input.isKeyPressed(input.KEY.X)  -- or any key/action
end)
```

### Launching a Charged Spell

```lua
-- In your global script:
I.MagExp.launchSpellAnim({
    actor     = player,
    animGroup = "spellcharge",
    blendMask = I.MagExp.BLEND_MASK.UpperBody,
    priority  = I.MagExp.PRIORITY.Scripted,
    isCharged = true,
    chargeKey = "MyMod_HoldKey",  -- must match the registered ID
})
```

MagExp's player script polls this key every frame. When it detects the key released, it automatically:
1. Breaks out of the charge loop.
2. Lets the animation proceed to the `release` text key.
3. The existing `onTextKey` handler fires `MagExp_CastRequest` at the `release` key.
4. The animation finishes at `stop` and cast state is cleared.

### Cross-Mod Key Binding API

| Function | Description |
|:--|:--|
| `I.MagExp.registerChargeKey(keyId, isPressFn)` | Register a key binding. `isPressFn` returns `true` while held. |
| `I.MagExp.isChargeKeyHeld(keyId)` | Query if a registered key is currently pressed. |

> [!WARNING]
> `isChargeKeyHeld` internally calls `input.isKeyPressed`, which is a **player-side API**. It must only be called from player scripts or from SFP's own `magexp_player.lua` onUpdate poll. Do not call it from a global script.

> [!NOTE]
> Each mod should use a unique `keyId` string to avoid collision with other mods' bindings. Convention: `"ModName_PurposeKey"` (e.g. `"OSSC_ChargeKey"`).


### Credits
Credits go to OpenMW dev team for pushing MR with Magic Api methods for creating draft spells which made it possible to do in the first place

Credits to MaxYari for his Lua Physics engine

Credits to hyacinth and ownlyme for SharedRay lib

Credits to all of the users supporting me in the OpenMW Discord