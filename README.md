# SPELL FRAMEWORK PLUS v1.61 Framework

**SPELL FRAMEWORK PLUS** is a standardized spell-launching engine for OpenMW Lua. It kind of dehardcodes the magic system with available methods from the API, providing a unified public interface (`I.MagExp`) for modders to trigger spell casts and effects. Using MaxYari Lua Physics as a hard dependency.

---

## 1. Setup for Modders
To use this framework with your mod:

0. Ensure you have Max Yari Lua Physics enabled.
1. Ensure `SPELL_FRAMEWORK_PLUS.omwscripts` is loaded.
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

### `applySpellToActor(spellId, caster, target, hitPos, isAoe, itemObject)`
Directly applies a spell to an actor, bypassing projectile logic.
- **hitPos**: World coordinates for VFX spawning.
- **itemObject**: (Optional) The item record if source is an enchantment.

### `detonateSpellAtPos(spellId, caster, pos, cell, itemObject)`
Triggers an AoE blast at a specific world position.
- **pos**: World Vector3.
- **cell**: The Cell object where the explosion occurs.

### `addTargetFilter(function)`
Register a global filter to block spells from hitting specific objects (return `false` to veto).
```lua
I.MagExp.addTargetFilter(function(target)
    if target.type == types.NPC and types.Actor.isDead(target) then
        return false -- Don't hit corpses
    end
    return true
end)
```

---

## 3. Advanced Features

### Split-Range Handling
SpellFrameworkPlus automatically handles spells with mixed ranges. If a spell has both **Self** and **Target/Touch** effects:
1. "Self" effects are applied instantly to the caster.
2. The remaining "Target/Touch" effects continue to the projectile/impact logic.

### Caster-Linked Effects
If a magic effect has the `casterLinked` flag (defined in its record), SpellFrameworkPlus will track the instance. If the caster dies or is removed from the world, the effect is automatically purged from all targets.

### Automatic School Visuals
The framework detects the magic school and element (Fire, Frost, Shock, Poison) from the spell record and automatically applies:
- School-accurate hit sounds.
- Element-accurate projectile models and particles.
- School-accurate hit static VFX.

---

## 4. The `data` Parameter Table
All fields except the first four are optional.

| Parameter      | Type      | Default  | Description |
| :---           | :---      | :---     | :--- |
| **attacker**   | `Actor`   | Required | The actor responsible for the spell. |
| **spellId**    | `string`  | Required | The ID of the spell record to cast. |
| **startPos**   | `Vector3` | Required | Position where the spell/projectile spawns. |
| **direction**  | `Vector3` | Required | Finalized flight vector. |
| **spellType**  | `number`  | Auto     | Routing: 0=self, 1=touch, 2=target |
| **area**       | `number`  | Auto     | Impact radius in game units. |
| **isFree**     | `boolean` | `false`  | Skip magicka cost check if `true`. |
| **speed**      | `number`  | `1500`   | Speed of the projectile (units/sec). |
| **spawnOffset**| `number`  | `80`     | Teleport distance on launch. |
| **maxLifetime**| `number`  | `10`     | Seconds until projectile is destroyed. |
| **vfxRecId**   | `string`  | Auto     | The Record ID for the bolt VFX. |
| **boltSound**  | `string`  | Auto     | Looping flight sound ID. |
| **boltLightId**| `string`  | Auto     | Record ID of the light attached to the bolt. |
| **itemObject** | `Object`  | `nil`    | Source item (for correct enchantment logic). |
| **hitObject**  | `Object`  | `nil`    | Priority target for authoritative hits. |
| **unreflectable** | `boolean` | `false`  | If true, the hit/effect cannot be reflected. |

---

## 5. Precision Targeting: `I.SharedRay` (Player)
The framework includes the **SharedRay** service. This provides a single, high-precision rendering raycast per frame that is shared across all mods. Using `SharedRay` ensures that Touch spells and projectiles align perfectly with the player's crosshair.

### Usage in Player Scripts:
```lua
local I = require('openmw.interfaces')
local ray = I.SharedRay.get()

if ray.hit and ray.hitObject then
    core.sendGlobalEvent('MagExp_CastRequest', {
        attacker  = self,
        spellId   = "spark",
        hitObject = ray.hitObject, -- Pass this for pixel-perfect Touch aiming
        hitPos    = ray.hitPos
    })
end
```

---

## 6. Usage from Player/Local Scripts
Player and Local scripts cannot access `I.` interfaces directly. Use the global event contract instead:

```lua
local core = require('openmw.core')
local self = require('openmw.self')

core.sendGlobalEvent('MagExp_CastRequest', {
    attacker  = self,
    spellId   = "ice_storm",
    startPos  = self.position + util.vector3(0,0,120),
    direction = self.rotation * util.vector3(0,1,0),
    isFree    = true
})
```

---

## 7. Magic Impact Events: `MagExp_OnMagicHit`
The framework broadcasts a global event whenever a spell (Projectile, Touch, or Self) connects with a target.

### `MagicHitInfo` Data Structure
| Field         | Type         | Description |
| :---          | :---         | :--- |
| **attacker**  | `GameObject` | The actor who cast the spell. |
| **target**    | `GameObject` | The victim hit (Actor, Door, Static, etc). |
| **spellId**   | `string`     | The ID of the spell. |
| **hitPos**    | `Vector3`    | Precise coordinates of the impact. |
| **hitNormal** | `Vector3`    | Surface normal at impact. |
| **school**    | `string`     | Magic school (e.g. "destruction"). |
| **element**   | `string`     | fire, frost, shock, poison, heal, or default. |
| **damage**    | `table`      | Calculated damage: `{health, magicka, fatigue}`. |
| **spellType** | `number`     | 0=Self, 1=Touch, 2=Target. |
| **isAoE**     | `boolean`    | `true` if this hit is part of a splash/area effect. |
| **stackLimit**| `number`     | Stacking limit for this spell on this target. |
| **stackCount**| `number`     | Current instances on target after this hit. |
| **unreflectable**| `boolean`    | `true` if the spell cannot be reflected. |

---

## 8. Effect Lifecycle Events (New in 1.6)
SpellFrameworkPlus now tracks the complete lifecycle of its spawned spells, providing hooks for when effects start, tick, and end.

### Interface Hooks: `I.MagExp`
Assign your own functions to these hooks to respond globally.
```lua
I.MagExp.onEffectApplied = function(actor, effect) ... end
I.MagExp.onEffectTick    = function(actor, effect) ... end
I.MagExp.onEffectOver    = function(actor, effect) ... end
```

### Global Events
Alternatively, listen for these events from any script:
- `MagExp_OnEffectApplied`
- `MagExp_OnEffectTick`
- `MagExp_OnEffectOver`

### `EffectInfo` Structure
| Field         | Type         | Description |
| :---          | :---         | :--- |
| **id**        | `string`     | The Magic Effect Record ID (e.g. "fire damage"). |
| **spellId**   | `string`     | The ID of the parent spell/enchantment. |
| **index**     | `number`     | The index of the effect within the spell record. |
| **magnitude** | `number`     | The rolled magnitude for this instance. |
| **duration**  | `number`     | Remaining duration (or total if applied). |
| **caster**    | `GameObject` | The actor who applied the effect. |
| **unreflectable**| `boolean`    | `true` if the effect cannot be reflected. |

---

## 9. Examples

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
    attacker  = world.getPlayer(),
    spellId   = "trap_curse",
    spellType = core.magic.RANGE.Target,
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

## 10. Utility Events

### `MagExp_BreakInvisibility`
Forces an actor to lose all active Invisibility effects.
```lua
core.sendGlobalEvent('MagExp_BreakInvisibility', { actor = myPlayer })
```

---

## 11. Internal Logic & Fallbacks
- **Dynamic Spawning:** Providing a `spawnOffset` prevents projectiles from spawning "inside" actors.
- **Auto-Detection:** SpellFrameworkPlus parses spell records to assign school-accurate visuals and sounds automatically.
- **Safety:** Uses persistent `Colony_Assassin_act` carrier objects for maximum compatibility.




## 12. Credits
Credits go to OpenMW dev team for pushing MR with Magic Api methods for creating draft spells which made it possible to do in the first place

Credits to MaxYari for his Lua Physics engine

Credits to hyacinth and ownlyme for SharedRay lib

Credits to all of the users supporting me in the OpenMW Discord

