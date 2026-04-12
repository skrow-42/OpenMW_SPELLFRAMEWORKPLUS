-- ============================================================
-- OMW_MagExp: Magic Expansion Framework for OpenMW
-- magexp_player.lua (PLAYER script)
--
-- Exposes the SharedRay targeting service to all mods.
-- ============================================================

local SharedRay = require('scripts.SharedRay_v1')

return {
    interfaceName = SharedRay.interfaceName,
    interface     = SharedRay.interface,
    engineHandlers = SharedRay.engineHandlers,
}
