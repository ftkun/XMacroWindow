local addonName, ns = ...

------------------------------------------------------------------------
-- Bundled fonts (Media\Fonts, Cascadia Mono, SIL OFL 1.1 - see OFL.txt)
------------------------------------------------------------------------
-- Registered with LibSharedMedia-3.0 so every LSM-aware addon (ForeverAuras, Details, ...) can
-- pick them from its own font list. ns.fonts feeds this addon's own font dropdown (Editor.lua).
local ipairs = ipairs
local PATH = "Interface\\AddOns\\" .. addonName .. "\\Media\\Fonts\\"

local FONTS = {
    { "Cascadia Mono",            "CascadiaMono-Regular.ttf" },
    { "Cascadia Mono ExtraLight", "CascadiaMono-ExtraLight.ttf" },
    { "Cascadia Mono Light",      "CascadiaMono-Light.ttf" },
    { "Cascadia Mono Medium",     "CascadiaMono-Medium.ttf" },
    { "Cascadia Mono SemiBold",   "CascadiaMono-SemiBold.ttf" },
    { "Cascadia Mono Bold",       "CascadiaMono-Bold.ttf" },
}

-- { name, full path }. Files deleted from Media\Fonts are skipped (no errors, not listed).
-- (C_UIFileAsset.IsKnownFile may be missing on some builds: then every font is listed.)
ns.fonts = {}
local IsKnownFile = C_UIFileAsset and C_UIFileAsset.IsKnownFile
for _, f in ipairs(FONTS) do
    local path = PATH .. f[2]
    if not IsKnownFile or IsKnownFile(path) then
        ns.fonts[#ns.fonts + 1] = { f[1], path }
    end
end

-- LibSharedMedia is embedded in Libs\ and loaded by the .toc before this file
local LSM = LibStub("LibSharedMedia-3.0", true)
if LSM then
    local mask = LSM.LOCALE_BIT_western + LSM.LOCALE_BIT_ruRU -- Cascadia covers Latin and Cyrillic
    for _, f in ipairs(ns.fonts) do
        LSM:Register(LSM.MediaType.FONT, f[1], f[2], mask)
    end
end
