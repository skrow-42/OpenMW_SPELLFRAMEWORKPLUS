# OpenMW Magicka Expanded (OMW_MagExp) Framework Documentation

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

---

## 3. The `data` Parameter Table
All fields except the first four are optional.

```
| Parameter      | Type      | Default  | Description |
| **attacker**   | `Actor`   | Required | The actor responsible for the spell. |
| **spellId**    | `string`  | Required | The ID of the spell record to cast. |
| **startPos**   | `Vector3` | Required | Position where the spell/projectile spawns. |
| **direction**  | `Vector3` | Required | Finalized flight vector. |
| **spellType**  | `number`  | Auto     | Routing: 0=self, 1=touch, 2=target |
| **area**       | `number`  | Auto     | Impact radius in game units, use only with AoE spells. |
| **isFree**     | `boolean` | `false`  | Skip magicka cost check if `true`. |
| **speed**      | `number`  | `1500`   | Speed of the projectile (units/sec). |
| **maxLifetime**| `number`  | `10`     | Seconds until projectile is destroyed. |
| **vfxRecId**   | `string`  | Auto     | The Record ID for the bolt (e.g. `VFX_DestructBolt`). |
| **boltSound**  | `string`  | Auto     | Looping flight sound ID. |
| **spinSpeed**  | `number`  | Auto     | Mesh rotation speed (radians per second). |
| **boltLightId**| `string`  | Auto     | Record ID of the light attached to the bolt. |
| **hitModel**   | `string`  | Auto     | Model path to spawn on impact. |
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

## 5. Examples

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

---

## 6. Internal Logic & Fallbacks
- **Auto-Detection:** If `vfxRecId`, `boltSound`, or `spinSpeed` are omitted, MagickaExpanded parses the first effect of the spell. It detects the School (Alteration, Destruction, etc.) and Element (Fire, Frost, Poison) to assign appropriate vanilla-accurate visuals and audio.
- **Safety:** The framework uses `Colony_Assassin_act` (dummy id from the CS) as the invisible carrier object. It is guaranteed to be present in all OpenMW installations.
