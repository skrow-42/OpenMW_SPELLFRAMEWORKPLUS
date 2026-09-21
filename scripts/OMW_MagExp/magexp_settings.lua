local I = require('openmw.interfaces')
local storage = require('openmw.storage')
local SkillModes = require('scripts/OMW_MagExp/magexp_skillmodes')

if I.Settings and I.Settings.registerGroup then
    -- 'ncg+se (auto)' was dropped as a separate choice: it ran the same external
    -- handler chain as 'skillevo'. Rewrite a stored value the menu no longer
    -- offers so the renderer can show it and the player script reads the mode
    -- that was actually meant. Reading our own section here is safe - the
    -- registerGroup call below creates it anyway.
    local magExpStorage = storage.globalSection('SettingsMagExp_General')
    if magExpStorage then
        local v = magExpStorage:get('SkillProgressionMode')
        if v ~= nil and not SkillModes.valid[tostring(v)] then
            magExpStorage:set('SkillProgressionMode', SkillModes.normalize(v))
        end
    end

    I.Settings.registerGroup({
        key = 'SettingsMagExp_General',
        page = 'MagExpPage',
        l10n = 'OMW_MagExp',
        name = 'SettingsGeneralTitle',
        permanentStorage = true,
        order = 1,
        settings = {
            {
                key = 'DebugMode',
                name = 'SettingsDebugModeTitle',
                description = 'SettingsDebugModeDescription',
                renderer = 'checkbox',
                default = false
            },
            {
                key         = 'NormaliseRaceSpeed',
                name        = 'Normalise Race Speed',
                description =
                    'Matches the OpenMW launcher\'s "normalise race speed" setting for magic projectiles.\n\n' ..
                    'YES / true (checked)   : the race weight IS normalised, so every race casts bolts at the same speed. ' ..
                    'This matches OpenMW "normalise race speed = true".\n' ..
                    'NO / false (unchecked) : the race weight is NOT normalised, so bolt speed will be different when casting ' ..
                    '(heavier races cast faster, lighter races slower). ' ..
                    'This matches OpenMW "normalise race speed = false" (the Morrowind default).\n\n' ..
                    'Set this to the same value as "normalise race speed" in your launcher so OSSC quick-casts ' ..
                    'fly at exactly the same speed as a normal vanilla cast of the same spell.',
                renderer    = 'checkbox',
                default     = false,
            },
            {
                key         = 'BlockTargetSpellsWhileSwimming',
                name        = 'Block Target Spells While Swimming',
                description =
                    'Prevents spells with Target-range effects from being launched while the caster is ' ..
                    'swimming — the whole body in the water (the engine\'s swim test: water level above ' ..
                    'roughly 90% of the character\'s height), not merely feet wading through shallows.\n\n' ..
                    'Self and Touch spells can still be cast while swimming.\n\n' ..
                    'OSSC enforces the same rule at quick-cast start (its own "Block Target Spell Quick ' ..
                    'Casts While Swimming" toggle); this setting covers every launch that goes through ' ..
                    'Spell Framework Plus.',
                renderer    = 'checkbox',
                default     = true,
            },
            {
                key         = 'SkillProgressionMode',
                name        = 'Skill Progression Mode',
                description =
                    'How MagExp awards spellcasting skill experience.\n\n' ..
                    'magexp : Internal only (default). Uses MagExp custom formula.\n' ..
                    'ncg    : Natural Character Growth. Engine handles progress; NCG reacts on level-up.\n' ..
                    'skillevo : Skill Evolution. SE intercepts skillUsed and runs its full handler chain. SE detects whether MBSP is enabled on its own, so this covers what the old NCG+SE choice did.\n' ..
                    'sus    : Skill Uses Scaled. Patches SUS spell pointer before calling skillUsed.\n' ..
                    'mbsp   : Standalone MBSP mod. Intercepts skillUsed, applies cost-scaled XP formula.\n' ..
                    'none   : award no skill experience at all, leaving spellcasting progression entirely to another mod.\n\n' ..
                    'In all external modes the external mod owns the XP formula.\n' ..
                    'The XP Multiplier setting below is only active in magexp mode.',
                default     = 'magexp',
                renderer    = 'select',
                argument    = {
                    disabled = false,
                    l10n     = 'OMW_MagExp',
                    items    = SkillModes.items,
                },
            },
            -- ── vanilla / mbsp shared knob ────────────────────────────────────────
            {
                key         = 'MagickaXPMult',
                name        = 'Magicka XP Multiplier',
                description =
                    'vanilla formula : progress = spellCost * this value.\n' ..
                    '  Default 0.0005 gives roughly one skill level per ~2000 magicka spent.\n\n' ..
                    'mbsp formula    : progress = baseGain/2 + baseGain * cost * this value.\n' ..
                    '  Default 0.1 matches the standalone MBSP mod default.\n\n' ..
                    'Ignored when formula = se_ncg_mbsp.',
                renderer    = 'number',
                default     = 0.1,
                min         = 0,
                max         = 1,
            },
            -- ── se_ncg_mbsp rate knob ─────────────────────────────────────────────
            {
                key         = 'MBSPRate',
                name        = 'MBSP Rate (legacy override)',
                description =
                    'Only used in magexp mode if you have legacy setup requiring cost division.\n' ..
                    'Higher value = less XP per cast.',
                renderer    = 'number',
                default     = 10,
                min         = 1,
                max         = 200,
            },
        }
    })
end
