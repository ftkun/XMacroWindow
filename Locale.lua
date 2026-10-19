local addonName, ns = ...

------------------------------------------------------------------------
-- Locale: every text the player sees goes through L["English text"]
------------------------------------------------------------------------
-- A key without a translation returns itself, so English needs no table of its own.
-- To translate, add a block for the client language with the same keys, for example:
--   if GetLocale() == "ruRU" then
--       L["Options"] = "Настройки"
--   end
-- Keys with %s / %d are format strings: keep the same placeholders in the same order.
local L = setmetatable({}, { __index = function(_, key) return key end })
ns.L = L
