-- Shared Skill Progression Mode definitions for the Spell Framework Plus
-- settings and player scripts.
--
-- 'ncg+se (auto)' used to be a separate menu choice. It routed to exactly the
-- same external handler chain as 'skillevo' - the only difference was the
-- promise that Skill Evolution would auto-detect MBSP, which Skill Evolution
-- does for itself - so it is gone from the menu. Values written by older saves
-- are normalised to 'skillevo' rather than rejected.
--
-- This mirrors scripts/ossc/ossc_skillmodes.lua, but SFP's internal mode is
-- named 'magexp' and is its default, so the two cannot simply share one table.

local SkillModes = {}

-- 'none' awards no skill experience at all. It exists for players who drive
-- spellcasting progression from a mod that does not hook skillUsed: without it
-- the only way to stop SFP adding its own XP on top was to pick an external
-- mode and hope that mod was installed.
SkillModes.items = { 'magexp', 'ncg', 'skillevo', 'sus', 'mbsp', 'none' }

SkillModes.DEFAULT = 'magexp'

SkillModes.valid = {}
for _, mode in ipairs(SkillModes.items) do
    SkillModes.valid[mode] = true
end

--- Values older releases stored, mapped onto a current choice.
SkillModes.aliases = {
    ['ncg+se']       = 'skillevo',
    ['ncg+se (auto)'] = 'skillevo',
    ['ncg+se(auto)'] = 'skillevo',
    -- 'ossc' is OSSC's internal mode name; read it as SFP's own formula.
    ['ossc']         = 'magexp',
}

--- The mode to actually run for a value exactly as stored in settings.
--- Anything unrecognised falls back to the default internal formula, so a
--- hand-edited value degrades to working behaviour instead of to nothing.
function SkillModes.normalize(rawValue)
    if rawValue == nil then return SkillModes.DEFAULT end
    local v = tostring(rawValue)
    if SkillModes.valid[v] then return v end
    local lowered = v:lower():gsub('^%s+', ''):gsub('%s+$', '')
    if SkillModes.valid[lowered] then return lowered end
    return SkillModes.aliases[v] or SkillModes.aliases[lowered] or SkillModes.DEFAULT
end

--- True when the mode hands skill progression to an external mod, which then
--- owns the XP formula and SFP must not apply its own.
function SkillModes.isExternal(mode)
    local m = SkillModes.normalize(mode)
    return m == 'ncg' or m == 'skillevo' or m == 'mbsp'
end

--- True when the mode awards no experience at all.
function SkillModes.isDisabled(mode)
    return SkillModes.normalize(mode) == 'none'
end

return SkillModes
