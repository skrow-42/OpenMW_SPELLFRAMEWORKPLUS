# SPELL FRAMEWORK PLUS (MagExp) — OSSC bundle

**SPELL FRAMEWORK PLUS** is a standardized spell-launching engine for OpenMW Lua. It dehardcodes the magic system and provides a unified public interface (`I.MagExp`) for modders to trigger spell casts, control projectiles in flight, and hook into lifecycle events.

> [!NOTE]
> **This is the copy bundled in `OSSC/SPELLFRAMEWORKPLUS/`** — the SFP 3.14
> base **plus the OSSC-side changes 26–33** (world-pause-safe launching and
> cast queueing, the OpenMW 0.51 player AoE damage fix, caller-scoped target
> exclusions, creation-ownership cleanup, the curved `motionPath`
> projectile system, and scroll-cast support under the effect penalty). OSSC
> ships only this copy and is tested against it; do not install a separate or
> older Spell Framework Plus over it. The bundle changes are documented in
> [§27 Side Changelog (26–33)](#27-side-changelog-2633)
> and live in detail in `../side-slowchu-sfp-changes/changes.txt`.

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
| `launchSpell(data)` | Launch a spell. Returns the projectile object. |
| `emitProjectileFromObject(data)` | Emit from a non-actor. Returns the projectile object. |
| `applySpellToActor(spellId, caster, target, hitPos, isAoe, itemObject, forcedEffects, unreflectable, casterLinked, userData, muteAudio, muteLight, continuousVfx, effectScale, sourceData)` | Apply directly to actor. `effectScale` is the quick-cast penalty to apply the spell with (optional, default no penalty). A penalised cast also reduces what the engine spawns for it: a summoned creature arrives with its health / magicka / fatigue / attributes / skills and equipped weapon and armor scaled and replaced, and a bound item is swapped for a reduced copy the moment it equips — damage and armor values, and the enchantment a bound item carries (its own reduced enchantment record), all cut by the penalty (the replacement is removed again when the spell ends, and while it lasts the replacement cannot be dropped out of the caster's inventory — a drop attempt lands back in the pack on the next frame, with a player notice). The enchantment reduction needs the runtime enchantment record API of OpenMW 0.51+; on older engines the twin keeps the template's enchantment and the log says so once. The swap itself is applied by the actor's own local script, because `types.Actor.setEquipment` is a self-only binding: the global sweep generates the reduced record, moves the instance into the actor's inventory and sends `MagExp_EquipReducedItem`, and only removes the full-strength original once the actor confirms with `MagExp_EquipReducedItemApplied`. Stat writes are a self-only binding in OpenMW (`AttributeStat.base`, `DynamicStat.base`/`.current`, `SkillStat.base` may only be written by a local script running on that actor), so a summon's stats are scaled by `magexp_actor_stats.lua` attached to it with `addScript(path, initData)`; the sweep keeps asking until the actor confirms with `MagExp_StatScaleApplied`. |
| `detonateSpellAtPos(spellId, caster, pos, cell, item, forcedEffects, unreflectable, casterLinked, vfxOverride, impactSpeed, maxSpeed, areaVfxScale, excludeTarget, userData, muteAudio, muteLight, continuousVfx, effectScale, areaOverride)` | Trigger AoE blast. `effectScale` is the quick-cast penalty the cast was reduced with (optional, default no penalty); `areaOverride` is an already-resolved AoE area in feet (optional). Without an override the blast resolves the area from the record and scales it by `effectScale`, so a penalised blast is never wider than its reduced effects. |
| `addTargetFilter(fn)` | Register a global filter `fn(target) → bool` to veto hits. |
| `registerLockableEffect(id)` | Register an effect ID to allow spells to interact with doors and containers. |
| `registerUniversalEffect(id)`| Register an effect ID to allow Touch spells to interact with ANY game object (Statics, Activators, etc.) and emit a `MagExp_OnMagicHit` hook for it. |
| **Engine Safety** All internal VFX and sound dispatchers include `target.enabled` guards to prevent "Can't use a disabled object" errors during high-intensity combat or unsummoning. |
| `STACK_CONFIG` | Table controlling spell stacking limits. |

#### Effect-penalty sweep (state-based)

The displacement rules above — one summon per creature kind, one bound effect per **equipment slot**, newest cast wins, for quick casts and engine-native casts alike — are enforced from a per-actor **state watch**, not from a timed re-scan of the scene. The bound rule is the vanilla one: a whole set of bound equipment stands at once (cuirass, boots, helm, gauntlets, greaves, shield, weapon, modded clothing), while two spells that want the same slot — two bound weapons, two shields, a second gauntlets spell — replace each other. A bound item's slot is resolved from its own record's type (`types.Armor.TYPE` / `types.Clothing.TYPE`; every weapon is the right hand, a shield the left, a bound effect that equips two items — vanilla's Bound Gauntlets — holds both hands), memoised per item id; an effect whose item this build cannot name is keyed by its own effect id, so it never takes a slot away from a known bound item, and two such unknown effects coexist until the same one is re-cast. Each watched actor keeps the entry keys it has already classified and the summon/bound kind each cast currently holds; a pass looks only at entries whose key is new, or whose holder went away, and it takes the kind from the entry's own effect list whenever the engine exposes it. Record classification is memoised per record id, with a lazily built lowercase index per record store and a negative memo for records that are in no store. An unchanged scene therefore costs one `activeSpells` read per watched actor, no record reads and no string allocations per entry — a character carrying dozens of potions, ingredients and buffs is not walked at all. Actors this script holds live bookkeeping on (its quick-cast stand-ins) are checked every frame; everyone else is covered by the 0.2 s verification pass, which exists only because OpenMW has no active-spell-changed handler to subscribe to. `magexp_summon_penalty_harness.lua` pins that contract (`sweep cost:` checks) by counting record field reads and `tostring` calls over a scene of 20 actors and 500 active effects.

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
| `setSpellPiercing(projId, enabled, newLimit)` | Toggle piercing and/or change the pierce cap on a live spell. |
| `getActiveSpellIds()` | Returns a table of all live spell projectile IDs. |
| `getNormaliseRaceSpeed()` | Returns the SFP "normalise race speed" setting (mirrors the launcher setting of the same name). |
| `setNormaliseRaceSpeed(enabled)` | Set the "normalise race speed" behaviour at runtime and persist it to `SettingsMagExp_General.NormaliseRaceSpeed`. |

### Projectile Speed Parity

SFP's projectile speed mirrors OpenMW's magic-bolt pipeline:

```
speed = fTargetSpellMaxSpeed × average(effect.speed over ALL effects)
```

When a caster is an NPC/player, OpenMW additionally multiplies by the race's
male/female weight **unless** `normalise race speed` is enabled in
`settings.cfg`. Lua cannot read that engine setting, so SFP exposes its own
equivalent (with the exact same name and meaning) in the global
`SettingsMagExp_General` storage section:

| Setting | Default | Meaning |
|:--|:--|:--|
| `NormaliseRaceSpeed` | `false` | `true` = the race weight IS normalised (every race casts bolts at the same speed; matches OpenMW `normalise race speed = true`). `false` = the race weight is NOT normalised (bolt speed differs by race; matches OpenMW `normalise race speed = false`, the Morrowind default). |
| `BlockTargetSpellsWhileSwimming` | `true` | `true` = `launchSpell` refuses spells with Target-range effects while the caster is swimming (the whole body in the water — the engine's swim test, water level above ~90% of the caster's height; wading with feet wet still casts). `false` = no restriction. Self and Touch spells always cast. OSSC's own *Block Target Spell Quick Casts While Swimming* toggle gates quick-casts at the source; this setting covers every launch through SFP. |

Set this to the same value as `normalise race speed` in your launcher so SFP
quick-casts fly at exactly the same speed as vanilla casting. You can toggle
it in a global script with:

```lua
local I = require('openmw.interfaces')
I.MagExp.setNormaliseRaceSpeed(true) -- or false
```

### Lifecycle Hooks

Override these to respond to events globally:
```lua
I.MagExp.onEffectApplied    = function(actor, effect) end
I.MagExp.onEffectTick       = function(actor, effect) end
I.MagExp.onEffectOver       = function(actor, effect) end
I.MagExp.onProjectileBounce = function(data) end
-- data: { projectile, spellId, attacker, hitPos, hitNormal, bounceCount, speed, actor, actorId }
-- actor: the hit Actor object if the surface was an actor, nil if world geometry.
-- actorId: shorthand for actor.id, or nil.
I.MagExp.onProjectilePierce = function(data) end
-- data: { projectile, spellId, attacker, hitPos, hitNormal, velocity, actor, actorId, pierceCount, pierceLimit, userData }
-- Fires each time a piercing projectile passes through an actor.
-- actor is always a valid Actor here (non-actors never trigger the pierce path).
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

### Player Quick Cast Event: `MagExp_StartQuickCast`

For player-side casting with integrated animation control and optional charge behavior, use:

```lua
local self = require('openmw.self')

self:sendEvent('MagExp_StartQuickCast', {
    spellId   = "fireball",
    item      = nil,           -- optional: item source for enchantments
    isFree    = false,         -- optional: skip magicka check
    chargeKey = "MyMod_CastKey"  -- optional: key ID for charge-as-cast behavior
})
```

**Charge-as-Cast Behavior:**
- If `chargeKey` is omitted or `nil` → standard instant cast (tap to fire).
- If `chargeKey` is provided AND the player is **still holding the registered key** when the animation reaches the `start` text key → the animation enters a **charge loop**.
- The spell fires at the `release` text key **after** the player releases the key.
- If the key is released **before** the `start` text key → instant cast (no charge loop).

This enables a single input key to act as both the cast trigger and the charge hold key, creating a seamless tap-to-cast / hold-to-charge mechanic.

### Skill Progression: owning it from another mod

Setting **Skill Progression Mode** to `none` means SFP awards no spellcasting
experience at all — it is the setting to pick when *your* mod drives
progression. Two things make that usable:

**1. `MagExp_SkillProgressSkipped`** — fired (as a global event) for every cast
SFP silenced, so you know when to award:

```lua
-- in your GLOBAL script's eventHandlers
MagExp_SkillProgressSkipped = function(data)
    -- data: { actor, skillId, school, spellId, cost, isEnchant }
end
```

It fires only in the `none` mode; when SFP does the awarding itself, nothing is
announced.

**2. `I.MagExp_Player.awardSkillProgress(skillId, options?)`** — apply the gain
you computed. Callable from any **player** script, and deliberately *not* gated
by the setting (it is the way into the `none` mode):

```lua
local I = require('openmw.interfaces')

-- your own formula, your own amount
I.MagExp_Player.awardSkillProgress('destruction', { skillGain = 0.35 })

-- or let SFP's own formula size it (cost * MagickaXPMult, or the skill
-- record's vanilla base gain when no cost is given)
I.MagExp_Player.awardSkillProgress('destruction', { cost = 18 })

-- or hand the use to NCG / Skill Evolution / MBSP / SUS instead
I.MagExp_Player.awardSkillProgress('destruction', { backend = 'external' })
```

| Option | Meaning |
| --- | --- |
| `skillGain` | Progress to add, in the unit `skill.progress` is exposed in: `1.0` == one skill level. Major / minor / specialization bonuses are **not** applied — the formula is yours. |
| `cost` | Spell cost, used for the default gain when `skillGain` is absent. |
| `useType` | `I.SkillProgression` use type, forwarded on `backend = 'external'`. |
| `backend` | `'stat'` (default): apply it to the player's skill here. `'external'`: hand the use to `I.SkillProgression.skillUsed`. |

Returns `true` on success, or `false` plus a reason string
(`'unknown skill: …'`, `'skill is already at 100'`, …) — it never fails silently.
Crossing a full level raises the skill, plays the vanilla skill-up message and
sound, and bumps the level counters that feed attribute / specialization
bonuses at level up. Writing `skill.progress` yourself does none of that: the
engine only stores the write and never levels from it.

---

## 4. `launchSpell` Parameter Reference

All fields except the first four are optional.

| Parameter | Type | Default | Description |
|:--- |:--- |:--- |:--- |
| **Identity & Source** |
| **attacker** | `Actor` | Required | The casting actor. |
| **spellId** | `string` | Required | Spell record ID. |
| **itemObject** | `Object` | `nil` | Source item (for enchantment logic). |
| **casterLinked** | `boolean` | `false` | If true, hostile reactions are attributed to the `attacker`. |
| **userData** | `table` | `nil` | Custom per-launch cookie. Returned in all events. May include `ignoreActorRecordIds` — a caller-scoped exclusion list of record IDs (see §25). |
| |
| **Movement & Lifecycle** |
| **startPos** | `Vector3` | Required | World position where the spell spawns. |
| **direction** | `Vector3` | Required | Initial flight direction. |
| **speed** | `number` | *(auto)* | Initial speed (units/sec). If omitted, speed is auto-detected from the spell's effects using the `fTargetSpellMaxSpeed` GMST and the average of each effect's speed — this is vanilla-parity (Morrowind resolves to ~1000 u/s, not 1500). If that can't be read, the fallback is `fTargetSpellMaxSpeed` (1000 in Morrowind). |
| **maxSpeed** | `number` | `0` | Speed cap (0 = unlimited). |
| **minSpeed** | `number` | `0` | Speed floor when decelerating. |
| **accelerationExp** | `number` | `0` | Exponential speed multiplier per frame. |
| **forceVec** | `Vector3` | `nil` | Continuous acceleration vector (units/sec²). |
| **maxLifetime** | `number` | `10` | Seconds before expiry. |
| **spawnOffset** | `number` | `80` | Distance ahead of `startPos` to spawn. |
| **isPaused** | `boolean` | `false` | Spawn frozen in place. |
| |
| **Collision & Bouncing** |
| **bounceEnabled** | `boolean` | `false` | Reflect off static geometry. |
| **bounceMax** | `number` | `0` | Max bounces (0 = unlimited). |
| **bouncePower** | `number` | `0.7` | Restitution coefficient (0-1). |
| **detonateOnActorHit** | `boolean` | `true` | If false, actors are treated as static for bounce. |
| **impactImpulse** | `number` | `0` | MaxYari LuaPhysics knockback magnitude. |
| |
| **Piercing** |
| **piercing** | `boolean` | `false` | If `true`, the projectile passes through actors on contact, applying spell effects to each pierced actor, instead of stopping. Geometry collisions still cause normal detonation. |
| **pierceLimit** | `int` / `nil` | `nil` | Pass-through budget: number of actors the projectile can pierce before it force-detonates. `nil` = unlimited (flies through all actors until lifetime or geometry). |
| |
| **Audiovisual** |
| **vfxRecId** | `string` | Auto | Bolt VFX record ID (auto-detected). |
| **boltModel** | `string` | Auto | Bolt mesh path override. |
| **areaVfxRecId** | `string` | Auto | Override area explosion static VFX. |
| **areaVfxScale** | `number` | `1.0` | Visual scale for AoE explosion. |
| **boltSound** | `string` | Auto | Looping flight sound. |
| **hitSound** | `string` | Auto | Impact sound played on hit. |
| **castSound** | `string` | Auto | Cast sound played when spell is launched. |
| **boltLightId** | `string\|table`| `nil` | Light record ID OR dynamic `recordDraft`. |
| **spinSpeed** | `number` | Auto | Rotation speed in rad/sec. |
| **muteAudio** | `boolean` | `false` | Skips flight and impact sounds. |
| **muteLight** | `boolean` | `false` | Skips environmental lighting on bolt. |
| **muteCastGlow** | `boolean` | `false` | Skips cast glow VFX on attacker. |
| **continuousVfx** | `boolean` | `false` | Cast VFX follows target until expiry. |
| |
| **Logic & Constraints** |
| **spellType** | `number` | Auto | Routing: Self/Touch/Target. |
| **area** | `number` | Auto | AoE radius in game units. |
| **isFree** | `boolean` | `false` | Skip magicka cost check. |
| **unreflectable** | `boolean` | `false` | Cannot be reflected. |
| **nonRecastable** | `boolean` | `false` | Aborts if spell is already active on caster. |
| **itemRequirements** | `table` | `nil` | Inventory requirements check. |
| **effectScale** | `number` | `1.0` | Penalty to apply to the launch with (`1.0` = none). Magnitudes and the resolved AoE area are scaled by it, so a mod that only *starts* something else with this launch must forward the `effectScale` its cast request reported — otherwise the spell it fires afterwards hits at full strength. Affects everything - summon stats, bound item stats and enchantment stats, spell area, magnitude, duration, aoe visuals|
| **motionPath** | `table` | `nil` | Curved-path provider: `{ module = <require path>, config = <serializable table> }`. The provider owns the projectile's kinematics (straight-flight integrator is bypassed for opted-in paths). Check `I.MagExp.motionPathVersion` before using; see §24. |

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
| **Movement** |
| `velocity` | `Vector3` | Full velocity override. |
| `speed` | `number` | Speed override (direction unchanged). |
| `direction` | `Vector3` | Direction redirect (speed unchanged). |
| `accelerationExp` | `number` | New exponential speed multiplier. |
| `forceVec` | `Vector3` | New continuous force vector. |
| `maxSpeed` | `number` | New terminal velocity cap. |
| `isPaused` | `boolean` | Pause or unpause. |
| |
| **Collision & Lifecycle** |
| `bounceEnabled` | `boolean` | Enable/disable bouncing. |
| `bounceMax` | `number` | Max bounce count. |
| `bouncePower` | `number` | Restitution. |
| `detonateOnActorHit` | `boolean` | Actor-detonation toggle. |
| `maxLifetime` | `number` | Override max lifetime. |
| `impactImpulse` | `number` | Override physics knockback. |
| |
| **Piercing** |
| `piercing` | `boolean` | Enable/disable piercing mode mid-flight. |
| `pierceLimit` | `int` / `nil` | New pierce cap. `nil` = unlimited. |
| |
| **Identity & Visuals** |
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
    if data.actor then
        print("  Bounced off actor: " .. data.actor.recordId)
    else
        print("  Bounced off world geometry")
    end
end
```

---

## 7b. Piercing Physics

When `piercing = true`, a projectile **passes through actors** instead of detonating on contact. On each pass-through, the spell effects are applied to the pierced actor, all hit events fire, and the projectile continues flying with its original velocity. The projectile still detonates normally on world geometry (walls, terrain).

**Rules:**
- **Actors**: Spell effects are applied on contact, but the projectile does **not** stop. The same actor cannot be pierced more than once per projectile (tracked internally per-projectile).
- **Geometry**: Normal detonation (identical to non-piercing spells).
- **`pierceLimit`**: If set to an integer, it acts as a **pass-through budget**. The projectile will pierce through that many actors, then force-detonate on the **next** actor contact. If `nil`, the projectile flies through unlimited actors until lifetime expires or geometry is hit.
- Each pierce fires the `MagExp_OnProjectilePierce` global event and the `I.MagExp.onProjectilePierce` hook.

```lua
-- Chain lightning that passes through 3 enemies, then detonates on the 4th
I.MagExp.launchSpell({
    attacker    = actor,
    spellId     = "chain_lightning",
    startPos    = spawnPos, direction = dir,
    piercing    = true,
    pierceLimit = 3,   -- pierce budget of 3: passes through actors 1-3, detonates on actor 4
})

-- Listen for pierces
I.MagExp.onProjectilePierce = function(data)
    print("Pierced actor: " .. data.actor.recordId
       .. " (" .. data.pierceCount .. "/" .. tostring(data.pierceLimit or "∞") .. ")")
    -- Note: When pierceCount reaches pierceLimit, the next actor will trigger
    -- normal collision (isPierce = false) instead of another pierce event
end
```

### `onProjectilePierce` Data Fields

| Field | Type | Description |
|:--- |:--- |:--- |
| `projectile` | `Object` | The projectile object. |
| `spellId` | `string` | Spell record ID. |
| `attacker` | `Actor` | The casting actor. |
| `actor` | `Actor` | The actor being pierced. **Never nil** in this hook. |
| `actorId` | `string` | Shorthand for `actor.id`. |
| `hitPos` | `Vector3` | World position of the pierce contact. |
| `hitNormal` | `Vector3` | Surface normal at contact. |
| `velocity` | `Vector3` | Projectile velocity at time of pierce. |
| `pierceCount` | `number` | How many actors have been pierced so far (including this one). |
| `pierceLimit` | `int` / `nil` | The pierce budget, or `nil` if unlimited. |
| `isPierce` | `boolean` | Always `true` in this hook. When `false`, indicates a normal collision after the pierce budget was exhausted. |
| `userData` | `table` | Custom launch cookie. |

### `setSpellPiercing` — In-Flight Pierce Control

Toggles or reconfigures piercing on a live spell projectile.

```lua
I.MagExp.setSpellPiercing(projId, enabled, newLimit)
```

| Parameter | Type | Description |
|:--- |:--- |:--- |
| `projId` | `string` | The projectile object ID from `launchSpell` return value. |
| `enabled` | `boolean` | `true` to enable piercing, `false` to disable. |
| `newLimit` | `int` / `nil` | New pierce cap. `nil` = unlimited. |

```lua
-- Make a spell pierce up to 5 actors mid-flight
local proj = I.MagExp.launchSpell({ ... })
I.MagExp.setSpellPiercing(proj.id, true, 5)
```

### Collision After Pierce Limit

When a piercing projectile's `pierceLimit` budget is exhausted, the next actor contact triggers a **normal collision** instead of another pierce event. This collision follows the standard spell impact rules:

- The projectile detonates normally on the actor
- All standard collision events fire (`MagExp_OnMagicHit`, `MagExp_ProjectileCollision`)
- The `isPierce` field in event data is set to `false` to indicate this is a normal impact
- The collision data includes `pierceCount` and `pierceLimit` for context

**Example Flow with `pierceLimit = 3`:**
1. Actor 1 contact → `MagExp_OnProjectilePierce` (pierceCount=1, isPierce=true)
2. Actor 2 contact → `MagExp_OnProjectilePierce` (pierceCount=2, isPierce=true)  
3. Actor 3 contact → `MagExp_OnProjectilePierce` (pierceCount=3, isPierce=true)
4. Actor 4 contact → `MagExp_OnMagicHit` + `MagExp_ProjectileCollision` (pierceCount=3, isPierce=false)

> [!NOTE]
> Piercing and bouncing are independent systems. A spell can have both `piercing = true` and `bounceEnabled = true` — it will pass through actors (applying effects) and bounce off geometry. If `detonateOnActorHit = false` is also set on a bouncing spell, piercing takes priority for actor contacts.

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
| **Primary Entities** |
| `attacker` | `GameObject` | The casting actor. |
| `target` | `GameObject` | The hit object (may be actor, door, static, etc.). |
| `actor` | `Actor` / `nil` | The hit object resolved as an Actor if it is an NPC, Creature, or Player. `nil` if the target is world geometry or any non-actor object. Available in all event data tables. |
| |
| **Spatial & Physics** |
| `hitPos` | `Vector3` | Impact world position. |
| `hitNormal` | `Vector3` | Surface normal at impact. |
| `impactSpeed` | `number` | Speed (units/sec) at collision. |
| `maxSpeed` | `number` | Speed cap from launch parameters. |
| `velocity` | `Vector3` | Final velocity vector at impact. |
| |
| **Record Metadata** |
| `spellId` | `string` | Spell record ID. |
| `school` | `string` | Magic school (e.g. `"alteration"`). |
| `element` | `string` | `fire`, `frost`, `shock`, `poison`, `heal`, or `default`. |
| `damage` | `table` | `{ health, magicka, fatigue }` (Average values), scaled to the cast (reduced for a penalised quick-cast). |
| `magMin` | `number` | Aggregated minimum magnitude, scaled to the cast. |
| `magMax` | `number` | Aggregated maximum magnitude, scaled to the cast. |
| `spellType` | `number` | 0=Self, 1=Touch, 2=Target. |
| |
| **Context & Status** |
| `isAoE` | `boolean` | True if part of an area blast. |
| `area` | `number` | AoE radius (if applicable), already reduced when the hit came from a penalised quick-cast. |
| `effectScale` | `number` | The quick-cast penalty the hit landed with (`1.0` when the cast was not reduced). Every magnitude, damage and area value above already has it applied. |
| `unreflectable` | `boolean` | Cannot be reflected. |
| `casterLinked` | `boolean` | Attributed to caster. |
| `userData` | `table` | Custom launch cookie. |
| `muteAudio` | `boolean` | Audio suppression status. |
| `muteLight` | `boolean` | VFX suppression status. |
| `stackLimit` | `number` | Stacking limit for this spell. |
| `stackCount` | `number` | Current instances after this hit. |
| `proxyLookup` | `boolean` | True if resolved via iterative search. |
| |
| **Pierce Context** |
| `isPierce` | `boolean` | `true` if this hit was from a piercing pass-through, `false` if this is a normal collision after the pierce budget was exhausted. |
| `pierceCount` | `number` | How many actors have been pierced so far (including this one). |
| `pierceLimit` | `int` / `nil` | The pierce budget, or `nil` if unlimited. |

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

### G. Piercing Spell (Pass Through Enemies)

```lua
-- A lightning lance that pierces through up to 3 enemies, applying shock damage to each
I.MagExp.launchSpell({
    attacker    = actor,
    spellId     = "lightning_lance",
    startPos    = actor.position + util.vector3(0, 0, 100),
    direction   = actor.rotation * util.vector3(0, 1, 0),
    piercing    = true,
    pierceLimit = 3,   -- passes through 3 actors, detonates on 4th hit or geometry/lifetime
    isFree      = true,
})

-- Listen for each pierce event
I.MagExp.onProjectilePierce = function(data)
    print(string.format("Pierced %s (%d/%s)",
        data.actor.recordId,
        data.pierceCount,
        tostring(data.pierceLimit or "∞")))
end
```

### H. Unlimited Piercing Beam

```lua
-- A beam that passes through ALL actors it encounters until it hits a wall or expires
I.MagExp.launchSpell({
    attacker    = actor,
    spellId     = "death_ray",
    startPos    = pos,
    direction   = dir,
    piercing    = true,
    pierceLimit = nil,   -- unlimited: only geometry or lifetime stops it
    speed       = 6000,
    maxLifetime = 3,
    isFree      = true,
})
```

### I. Mid-Flight Pierce Toggle

```lua
-- Launch a normal bolt, then make it piercing after a delay
local proj = I.MagExp.launchSpell({
    attacker = actor, spellId = "shock_bolt",
    startPos = pos, direction = dir,
})

-- After some condition is met, enable piercing mid-flight
I.MagExp.setSpellPiercing(proj.id, true, 2)  -- pierce up to 2 actors from now on
```

### J. Tap-to-Cast / Hold-to-Charge (Single Key)

```lua
-- In your player script's onInit or when setting up keybinds:
local I     = require('openmw.interfaces')
local input = require('openmw.input')
local self  = require('openmw.self')

-- 1. Register the key once
I.MagExp.registerChargeKey("MyMod_CastKey", function()
    return input.isActionPressed(input.ACTION.Use)  -- or any key/action
end)

-- 2. Trigger cast (tap) or charge (hold) with the same key press
local function onCastKeyPressed()
    self:sendEvent('MagExp_StartQuickCast', {
        spellId   = "fireball",
        chargeKey = "MyMod_CastKey",  -- enables charge-as-cast behavior
    })
end

-- Usage:
-- TAP the key   → animation plays → 'start' fires → key already up → instant cast
-- HOLD the key  → animation plays → 'start' fires → key still down → charge loop → release key → spell fires
```

---

## 15. Utility Events

### `MagExp_BreakInvisibility`
```lua
core.sendGlobalEvent('MagExp_BreakInvisibility', { actor = myPlayer })
```

### `MagExp_CastRequest`
Launch a spell from a player/local script (see §3).

The payload carries `effectScale`, the quick-cast penalty the cast was reduced with (`1.0`, or absent, when it was not reduced). A mod whose spell only *starts* something else — Kinetic Forces launches `kb_launch` / `ke_launch` after the marker cast — must keep that value and pass it to `launchSpell` / `applySpellToActor`, otherwise the payload hits at full damage and detonates at full radius under a penalised quick-cast.

---

## 16. Internal Notes

- **Carrier Object**: Projectiles use `Colony_Assassin_act` dummy static as the physical carrier.
- **Collision**: 5-point cross raycast pattern every frame, simulating a ~12-unit-radius sphere.
- **Sound/Light Anchors**: Separate carrier objects parented to the projectile via teleport each frame.
- **Bounding Box Awareness**: Distance checks for AoE registration use the target's physical center (bounding box center via `.halfSize`) rather than their origin (feet). This accounts for an object's physical radius, providing 1:1 hit-parity with vanilla's volume-based detection.
- **Actor Resolution**: All event/callback data tables include a resolved `actor` field (the hit object as an Actor, or `nil` if it was not an actor). This is populated by the internal `resolveActorFromObject()` helper and applies uniformly to `MagExp_OnMagicHit`, `onProjectileBounce`, `onProjectilePierce`, and `MagExp_ProjectileCollision`.
- **Pierce Immunity**: When a piercing projectile passes through an actor, that actor's ID is recorded in a per-projectile set. The same actor cannot be pierced twice by the same projectile, preventing repeated hits from the projectile lingering inside a collision volume.
- **Charge-as-Cast Animation**: The player script polls the registered `chargeKey` at the `start` animation text key. If held, the animation enters a loop; if released before `start`, normal instant cast proceeds. This creates a seamless tap/hold mechanic with zero behavior change for tapped casts.

---

## 17. Engine Parity: 1:1 AoE Radius

SFP synchronizes exactly with the engine's internal magic constants and global settings to ensure your spells reach exactly as far as they do in vanilla:

1. **Vanilla Constant (22.1 Units/Foot)**: The framework uses the standard Morrowind conversion of 22.1 game units per 1 foot of Area.
2. **GMST Integration**: `fAreaRadiusMult` is queried directly. If you (or another mod) increase the global explosion size in the GMSTs, SFP's hit registration and visual scaling will automatically adapt to maintain parity.
3. **Primary-Only Logic**: SFP strictly follows the vanilla engine's rule where Area and impact metadata are derived only from the **first effect** in a spell record. This ensures perfect rotational and logical parity with base game spells.

---

## 18. Static Object Interactions

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
    speed            = 2500,      -- Initial speed (Defaults to auto-detected vanilla speed)
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
    -- Optional Piercing Config
    piercing         = true,      -- Pass through actors
    pierceLimit      = 2,         -- Max 2 actors pierced
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
})
```

| Parameter | Type | Default | Description |
|:--|:--|:--|:--|
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

### Cast Key as Charge Key (Seamless Tap/Hold)

The framework includes a **charge-as-cast** system: a single key press can act as both the cast trigger **and** the charge hold, creating a seamless tap-to-cast / hold-to-charge mechanic with **zero behavior change for instant casts**.

**How it works:**
1. The player presses a key (e.g., a custom "cast" hotkey or action button).
2. Your mod fires `MagExp_StartQuickCast` with a `chargeKey` field referencing a registered key.
3. The casting animation (`spellcast`) begins playing normally.
4. When the animation reaches the `start` text key (end of wind-up phase):
   - **If the key is still held** → the animation enters a charge loop (looping at the loop start/stop markers in the NIF/KF).
   - **If the key has already been released** → the animation continues naturally to `release` → instant cast.
5. While in the charge loop, the framework polls the key state every frame.
6. When the player **releases the key** → the animation resumes playing (loop = false) → proceeds to `release` → spell fires → `stop` clears state.

**Result:** Tapping the key = instant cast. Holding the key = charge loop → release key = spell fires. All with a single unified input.

### Registering a Charge Key (from any player/local script)

```lua
local I     = require('openmw.interfaces')
local input = require('openmw.input')

-- Register once, typically in onInit or when setting up keybinds:
I.MagExp.registerChargeKey("MyMod_CastKey", function()
    return input.isActionPressed(input.ACTION.Use)  -- or any key/action
end)
```

### Triggering a Charge-as-Cast Spell

```lua
-- In your player script (when the cast key is pressed):
local self = require('openmw.self')

self:sendEvent('MagExp_StartQuickCast', {
    spellId   = "fireball",
    chargeKey = "MyMod_CastKey",  -- enables charge-as-cast behavior
})
```

**Behavior:**
- **Tap** the key → animation plays → `start` fires → key already up → goes straight to `release` → instant cast (0.94s total).
- **Hold** the key → animation plays → `start` fires → key still down → enters charge loop → release key → `release` fires → spell launches.

### Cross-Mod Key Binding API

| Function | Description |
|:--|:--|
| `I.MagExp.registerChargeKey(keyId, isPressFn)` | Register a key binding. `isPressFn` returns `true` while held. |
| `I.MagExp.isChargeKeyHeld(keyId)` | Query if a registered key is currently pressed. |

> [!WARNING]
> `isChargeKeyHeld` internally calls `input.isKeyPressed`, which is a **player-side API**. It must only be called from player scripts or from SFP's own `magexp_player.lua` onUpdate poll. Do not call it from a global script.

> [!NOTE]
> Each mod should use a unique `keyId` string to avoid collision with other mods' bindings. Convention: `"ModName_PurposeKey"` (e.g. `"OSSC_ChargeKey"`).

### Backward Compatibility

- If you call `MagExp_StartQuickCast` **without** the `chargeKey` field (or pass `nil`), the system behaves exactly as before: instant cast only, no charge loop.
- Existing mods using the framework are unaffected.
- The `launchSpellAnim` API (§22) still supports explicit `isCharged = true` mode for custom animation groups with standalone charge loops independent of the cast trigger.

---

## 24. Curved Motion Paths (`motionPath`)

SFP can fly a projectile along a caller-owned curved path instead of its
default straight-line integrator. Check `I.MagExp.motionPathVersion`
(`= 1` in this bundle) before opting in:

```lua
local I = require('openmw.interfaces')
if I.MagExp and I.MagExp.motionPathVersion == 1 then
    I.MagExp.launchSpell({
        attacker = actor, spellId = 'orbit_bolt',
        startPos = pos, direction = dir,
        motionPath = {
            module = 'scripts/mymod/trajectory_path',  -- loadable in global AND local contexts
            config = { shape = 'orbiting', radius = 64 }, -- serializable; your schema
        },
    })
end
```

### Provider contract

`module` must `require()` to a table with at least:

| Function | Called | Purpose |
|:--|:--|:--|
| `validate(config)` | at launch, before any carrier is allocated | reject malformed configuration (raise an error) |
| `create(config, { position, direction })` | at launch | build the local path state (a table with the methods below) |

and the returned path state must provide:

| Method | Returns / effect |
|:--|:--|
| `velocity()` | current tangent vector |
| `stepDuration(maxDt)` | suggested step size ≤ `maxDt` (shorten at path corners) |
| `advance(dt)` | `nextPosition, nextVelocity` |
| `warp(position)` | re-anchor the path (e.g. a discrete jump) |
| `redirect(position, velocity)` | re-anchor with a new velocity — used by explicit `velocity`/`speed`/`direction` overrides |
| `bounce(position, normal, restitution)` | bounce the path off a surface (bounce-enabled projectiles) |

Rules and boundaries:

- **Providers own their kinematics**, including acceleration. The ordinary
  SFP force integrator (`forceVec`/`accelerationExp`/speed rules) is bypassed
  for opted-in paths; providers that want straight flight can still do it
  themselves.
- **Provider programming errors are not suppressed** — a provider that raises
  outside its `validate`/`create` calls will fail the launch visibly.
- Curved movement advances in **at most 8 sub-steps of at most 1/60 s per
  update**. Each straight chord passes through the *existing* actor/world
  collision and piercing logic — the chords approximate the curve, the
  individual raycasts are still straight.
- A long frame advances the projectile **lifetime fully** but caps path
  travel at the sub-step budget (no catch-up backlog); extreme hitches can
  briefly slow traversal without extending expiry.
- Warp and bounce-clearance gaps are **not** swept as travelled space.
- Ordinary callers are unaffected: without `motionPath`, everything behaves
  exactly as before and no provider module is required.

### Consuming the travelled path (beam geometry)

For path projectiles, SFP emits one `MagExp_ProjectileMove` per path update
with `localMotionPath = true`, the authoritative tangent `velocity`, and up
to eight `motionSegments = { startPos = v, endPos = v }` entries — the actual
chords travelled. Early termination flushes the travelled prefix, and warp
tags survive event coalescing. Beam and contact consumers (e.g. WandForge's
beam, Pollen) should consume these segments instead of assuming straight
motion between samples.

WandForge's own provider reuses its Orbiting Arc, Spiral Arc and composed
path formulas; global tangent steering stands down for these paths while
Phasing Arc's explicit warps remain. Speed-based damage (§9) uses the tangent
speed, so impact speed follows the curve.

---

## 25. Caller-Scoped Target Exclusions (`userData.ignoreActorRecordIds`)

Keep a launch from ever hitting specific actors — e.g. "mushroom-origin
attacks spare mushrooms". Pass the list in the `userData` of `launchSpell`,
`applySpellToActor`, `detonateSpellAtPos` or `MagExp_CastRequest`:

```lua
I.MagExp.launchSpell({
    attacker  = mushroom,
    spellId   = 'spore_cloud',
    startPos  = pos, direction = dir,
    userData  = {
        ignoreActorRecordIds = { 'brown_mushroom', 'blue_mushroom', 'elite_blue_mushroom' },
        -- or map form: { ['brown_mushroom'] = true, ... } — both work
    },
})
```

- Actors whose `recordId` is in the list (matched **case-insensitively**)
  are excluded from **projectile collision rays, direct spell application
  and AoE actor selection** — before damage, feedback and hit broadcasts.
- It is **caller-scoped, not a global immunity**: only the launch that
  carries the list honours it. Player-origin attacks that carry no list
  still damage the excluded actors (a targeted "your own family is safe"
  filter, not a spell-immunity toggle).
- No signature or registration change — it rides the existing `userData`
  cookie, which is also returned in all events.
- If your spell *launches another spell* (payloads, terminal bursts,
  scattering fragments), you must carry the exclusion list into each
  separately launched payload — SFP does not forward `userData` between
  independent launches.

---

## 26. World-Pause Behavior

During a world pause (menus, map, loading screen) OpenMW still delivers
events and **zero-duration** updates. This bundle makes SFP pause-safe:

- **`launchSpell`** — including every call routed through
  `emitProjectileFromObject` — raises
  `error('SFP launchSpell: world_paused; resume before calling or use
  MagExp_CastRequest')` *before* any resource consumption, effect
  application or carrier creation. This is an intentional behavior change,
  not an opt-in field: a synchronous caller that needs its projectile now
  must wait for resume. Returning `nil` was not an option because `nil`
  already means "successful non-projectile cast" for some callers.
- **`MagExp_CastRequest` is the deferred alternative.** While paused, up to
  **128** cast requests wait in the pause queue; overflow is rejected with
  one log message per pause, and invalid casters are discarded immediately.
  On resume the queue is flushed in order. A deferred failure reports the
  original error text plus the operation name and is **not replayed** — the
  earlier parts of a cast may already have succeeded, and replaying would
  double-apply them.
- **Projectile local scripts skip `dt <= 0` updates**: no position
  publication, no lifetime advance, no collision rays during a paused frame.
  Positive-duration updates resume normal movement and lifetime progression.
- **Native teleports are deferred, never issued while paused.** Projectile
  and anchor (sound/light) movements are retained as Lua data and placed
  natively only during an unpaused update; warp fields are notifications of
  local simulation, not native-completion acknowledgements, and are not
  rebroadcast.
- **Retries and cancellation pause-aware:** move-event retries stop while
  paused (they resume after, within their existing bounds); repeated
  `cancelSpell` during a pause does not renew the cancellation grace period;
  terminal cleanup discards waiting work while keeping the lifecycle
  backstop until cleanup completes.
- **Save/load:** pending pause work belongs to the current world and is
  *not* serialized into a loaded save (saving without loading does not
  permanently stop spells).
- The queued cast/anchor operations run their guards directly, as
  check-then-act preconditions (`dt <= 0` / `isActive` / `isValid`-style
  queries before each operation) — errors are not swallowed. The OpenMW Lua
  sandbox does not expose the standard `debug` library, so the early
  `debug.traceback` `xpcall` handlers crashed the global `onUpdate` instead
  (104 `attempt to index global 'debug'` errors in one playtest — the bug
  fixed in bundle change 27); the `pcall` guards added there have since been
  replaced by asking the condition first (the `anim.hasAnimation` guards in
  the projectile and actor VFX scripts are the same pattern). The one
  sanctioned `pcall` use in the bundle is `pcall(require, ...)` for optional
  companion modules, where absence is expected and keeps its fallback
  (change 33).
- Projectile freeze (`isPaused` / `setSpellPaused`) and world pause remain
  distinct mechanisms.

No public function arguments or existing event names were removed by these
changes.

---

## 27. Side Changelog (26–33)

Changes layered on the SFP 3.14 base by the OSSC maintainers. Full write-ups
with problems, validation and boundaries: `../side-slowchu-sfp-changes/changes.txt`.

| # | Date | Change |
|:--|:--|:--|
| 26 | 2026-09-11 | **World-pause movement and cast handling.** `dt <= 0` updates skipped in the projectile local script; native teleports deferred to unpaused updates; up-to-128 `MagExp_CastRequest` queue with overflow rejection; `world_paused` error from `launchSpell`. See §26. |
| 27 | 2026-09-14 | **OpenMW sandbox correction.** Replaced `debug.traceback` `xpcall` handlers with `pcall` in the pause-work guards — OpenMW has no `debug` library, so the section-26 patch itself was crashing the global `onUpdate` (104 errors in one playtest log). Operation boundaries and error messages unchanged. |
| 28 | 2026-09-16 (installed) | **Player AoE damage + caller ally exclusions.** SFP's AoE target list omitted the player on OpenMW 0.51 (area blasts could skip the player, including intended self-damage) — `detonateSpellAtPos` now combines `cell:getAll()` with `cell:getAll(types.Player)` and deduplicates by object ID, retaining the range/dead/lockable/`excludeTarget` behavior. `userData.ignoreActorRecordIds` extended to direct spell application and AoE actor selection. See §25. |
| 29 | deployed 2026-09-16 (tested) | **Creation ownership and queued-request failure handling.** `creationOwnership` tracks created carriers and sound/light anchors immediately after creation so partially-completed launches can never lose an object; required `hasScript`/`addScript` errors propagate; queued casts validate source, spell ID and position/direction inside each request's isolation boundary; removals are confirmed by object invalidity or a zero count on a later unpaused update (a zero count right after an accepted removal is not proof — OpenMW reuses it during pending teleports); pending cleanup references survive save/load for retirement. Validated by four LuaJIT suites plus a native 0.51 run (`20260916-165506-493-6ba8b6`). |
| 30 | deployed 2026-09-16 (tested) | **Local curved motion and travelled beam geometry.** The `motionPath` provider system, `I.MagExp.motionPathVersion = 1`, ≤ 8 × (1/60 s) sub-stepping with per-chord collision, and `motionSegments` on `MagExp_ProjectileMove`. Fixing it eliminated a ~66-unit orbit displacement over 150 ms of straight-tangent flight. See §24. |
| 31 | — | **Isolated mushroom-family integration and test package** (`WandForge-Mushroom-Family-v1_8.zip`). Exercises the bundle's caller-scoped exclusions and entries 26–30; introduces no new required SFP API. |
| 32 | 2026-09-21 | **Scroll casts under the effect penalty.** Enchanted casts now apply through the ITEM record id (never the enchantment id, which the engine cannot resolve), with the item identity folded to a record-id string before the scroll is consumed and every later handle read gated behind `isValid()`; stand-ins whose `active.item` is nil are matched by record identity; generated-record effect counts are read leniently; a cast with no resolvable item record falls back to an unpenalised generated clone instead of dying at `activeSpells:add`. OSSC's NPC/creature item quick-cast no longer pre-consumes scroll/charge (SFP's launch resource guard is the single consumer, mirroring the player path). `QuickCastEffectPenaltyScrollsExempt` semantics unchanged. See `../side-slowchu-sfp-changes/changes.txt` §32. |
| 33 | 2026-09-21 | **Error-handling policy made explicit (documentation).** `pcall` is used for exactly one thing in the bundle: `pcall(require, ...)` when loading an optional companion module (Pure Lua Multi Mark's `PMM_renameDialog`/`PMM_markWindow`, Skill Uses Scaled's data module) — absence is expected and keeps the existing fallbacks (rename stubs, the window-load cancel path, "SUS will use its own fallback"). Everything else — engine calls, item-handle reads (change 32), the pause/queue guards — runs unguarded behind check-then-act preconditions (`isValid()`, `hasAnimation`, `dt <= 0`) so real errors surface. §26's stale "caught with `pcall`" claim about the queued cast/anchor operations is corrected. See `../side-slowchu-sfp-changes/changes.txt` §33. |

---

### Credits
Credits go to OpenMW dev team for pushing MR with Magic Api methods for creating draft spells which made it possible to do in the first place (and also for the docs)

Credits to MaxYari for his Lua Physics engine

Credits to hyacinth and ownlyme for SharedRay lib

Credits to all of the users supporting me in the OpenMW Discord
```
