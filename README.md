# OpenMW Magicka Expanded v1.3 Framework

**OpenMW's Magicka Expanded** is a standardized spell-launching engine for OpenMW Lua. It kind of dehardcodes the magic system with available methods from the API, providing a unified public interface (`I.MagExp`) for modders to trigger spell casts and effects. Using MaxYari Lua Physics as a hard dependency.

---

## 1. Setup for Modders
To use this framework with your mod:
0. Ensure you have Max Yari Lua Physics enabled.
1. Ensure `OpenMW_Magicka_Expanded_Framework.omwscripts` is loaded.
2. Ensure your mod has a dependency or check for the interface.

---

## 2. Public API: `I.MagExp` (Global)

If you are writing a **Global Script**, you can call the interface directly.

### `launchSpell(data)`
This is the primary way to cast a spell. It automatically detects if a spell should be a Projectile, a Touch spell, or a Self-buff based on the spell record, but allows full overrides.

#### Basic Usage:
```lua
local I = require('openmw.interfaces')
local util = require('openmw.util')

I.MagExp.launchSpell({
    attacker  = myNPC,             -- The Actor casting
    spellId   = "fireball_unique", -- Spell Record ID
    startPos  = myNPC.position + util.vector3(0,0,100),
    direction = myNPC.rotation * util.vector3(0,1,0),
})
```

### `STACK_CONFIG`
You can modify how spells stack on actors globally.
```lua
I.MagExp.STACK_CONFIG.DEFAULT_LIMIT = 2 -- All spells stack twice by default
I.MagExp.STACK_CONFIG.SPELL_LIMITS["shield"] = 5 -- Specific spell can stack 5 times
```

### `registerPersistentEffect(id)`
Register a magic effect ID (e.g., "shield" or "soultrap") to use authoritative looping VFX.
```lua
I.MagExp.registerPersistentEffect("my_custom_aura")
```

### `registerHostileEffect(id)`
Flags a non-damaging effect as a hostile act (provokes combat and bounty).
```lua
I.MagExp.registerHostileEffect("soultrap")
```

### `setTargetFilter(function)`
Define a global filter to block spells from hitting specific objects (return `false` to veto).
```lua
I.MagExp.setTargetFilter(function(target)
    if target.type == types.NPC and types.Actor.stats.dynamic.health(target).current <= 0 then
        return false -- Don't hit corpses
    end
    return true
end)
```

---

## 3. The `data` Parameter Table
All fields except the first four are optional.

| Parameter      | Type      | Default  | Description |
| **attacker**   | `Actor`   | Required | The actor responsible for the spell. |
| **spellId**    | `string`  | Required | The ID of the spell record to cast. |
| **startPos**   | `Vector3` | Required | Position where the spell/projectile spawns. |
| **direction**  | `Vector3` | Required | Finalized flight vector. |
| **spellType**  | `number`  | Auto     | Routing: 0=self, 1=touch, 2=target |
| **area**       | `number`  | Auto     | Impact radius in game units, use only with AoE spells. |
| **isFree**     | `boolean` | `false`  | Skip magicka cost check if `true`. |
| **speed**      | `number`  | `1500`   | Speed of the projectile (units/sec). |
| **spawnOffset**| `number`  | `80`     | Teleport distance on launch. Use `10` for point-blank accuracy. |
| **maxLifetime**| `number`  | `10`     | Seconds until projectile is destroyed. |
| **vfxRecId**   | `string`  | Auto     | The Record ID for the bolt (e.g. `VFX_DestructBolt`). |
| **boltSound**  | `string`  | Auto     | Looping flight sound ID. |
| **boltLightId**| `string`  | Auto     | Record ID of the light attached to the bolt. |
| **itemObject** | `Object`  | `nil`    | Required for Items/Scrolls to handle visuals correctly. |
| **hitObject**  | `Object`  | `nil`    | Priority target for authoritative hits (ignores physics). |

---

## 4. Precision Targeting: `I.SharedRay` (Player)
The framework now includes the **SharedRay** service. This provides a single, high-precision rendering raycast per frame that is shared across all mods. Using `SharedRay` ensures that Touch spells and projectiles align perfectly with the player's crosshair.

### Usage in Player Scripts:
```lua
local I = require('openmw.interfaces')
local ray = I.SharedRay.get()

if ray.hit and ray.hitObject then
    core.sendGlobalEvent('MagExp_CastRequest', {
        attacker  = self,
        spellId   = "spark",
        hitObject = ray.hitObject, -- Pass this for pixel-perfect Touch aiming
        -- ... other params ...
    })
end
```

---

## 4. Usage from Player/Local Scripts
Player and Local scripts cannot access `I.` interfaces directly. Use the global event contract instead:

```lua
local core = require('openmw.core')
local self = require('openmw.self')

core.sendGlobalEvent('MagExp_CastRequest', {
    attacker  = self,
    spellId   = "ice_storm",
    startPos  = self.position + util.vector3(0,0,120),
    direction = self.rotation * util.vector3(0,1,0),
    isFree    = true -- e.g. if player magicka was already deducted locally
})
```

---

## 5. Magic Impact Events: `MagExp_OnMagicHit`
The framework broadcasts a global event whenever a spell (Projectile, Touch, or Self) connects with a target. This allows other mods to react to magic impacts.

### `MagicHitInfo` Data Structure
| Field         | Type         | Description |
| :---          | :---         | :--- |
| **attacker**  | `GameObject` | The actor who cast the spell. |
| **target**    | `GameObject` | The victim hit (Actor, Door, Static, etc). |
| **spellId**   | `string`     | The ID of the spell. |
| **hitPos**    | `Vector3`    | Precise coordinates of the impact. |
| **hitNormal** | `Vector3`    | Surface normal at impact (for aligning decals). |
| **school**    | `string`     | Magic school (e.g. "destruction"). |
| **element**   | `string`     | fire, frost, shock, poison, heal, or default. |
| **damage**    | `table`      | Calculated damage: `{health, magicka, fatigue}`. |
| **spellType** | `number`     | 0=Self, 1=Touch, 2=Target. |
| **isAoE**     | `boolean`    | `true` if this hit is part of a splash/area effect. |
| **stackLimit**| `number`     | Stacking limit for this spell on this target. |
| **stackCount**| `number`     | Current instances on target after this hit. |

#### Usage Example (Global Script):
```lua
core.events.addHandler('MagExp_OnMagicHit', function(info)
    if info.element == "fire" and info.target.recordId == "wooden_barrel" then
        -- Burn the barrel!
    end
end)
```

---

## 6. Examples

### A. The "Chain Lightning" Trick
You want a spell that looks like a standard bolt but moves extremely fast and has a custom impact model.
```lua
I.MagExp.launchSpell({
    attacker = actor,
    spellId  = "lightning_bolt",
    speed    = 5000,
    hitModel = "meshes\\vfx\\custom_explosion.nif",
    boltLightId = "Light_Purple_512"
})
```

### B. Spawning Spells from World Objects
Since the `attacker` can be any Actor, you can have a trap or a "Magical Pillar" cast spells at the player.
```lua
I.MagExp.launchSpell({
    attacker  = world.getPlayer(), -- The 'target' becomes the attacker if you want a backfire
    spellId   = "trap_curse",
    spellType = core.magic.RANGE.Target, -- Forces it to launch as a projectile
    startPos  = world.getPlayer().position,
    direction = util.vector3(0,0,1)
})
```

### C. Restricting Stacking from another Mod
```lua
-- In your mod's initialization
local I = require('openmw.interfaces')
if I.MagExp then
    -- Make "God's Shield" unique (only 1 instance allowed)
    I.MagExp.STACK_CONFIG.SPELL_LIMITS["gods_shield"] = 1
end
```

---

---

## 7. Utility Events

### `MagExp_BreakInvisibility`
Forces an actor to lose all active Invisibility effects.
```lua
core.sendGlobalEvent('MagExp_BreakInvisibility', { actor = myPlayer })
```

## 8. Internal Logic & Fallbacks
- **Dynamic Spawning:** Providing a `spawnOffset` (e.g. `10`) prevents projectiles from spawning "inside" actors when at point-blank range.
- **Auto-Detection:** MagExp parses spell records to assign school-accurate visuals and sounds automatically.
- **Safety:** Uses persistent `Colony_Assassin_act` carrier objects for maximum compatibility.
