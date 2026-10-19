local addonName, ns = ...

------------------------------------------------------------------------
-- Macro text box: font, font size and colored overlay
------------------------------------------------------------------------
-- The edit box itself can't show colors while typing, so a FontString with the colored copy of
-- the text sits exactly over it (same font, insets and spacing). The edit box text stays visible
-- underneath; the overlay draws on top of it.
local L = ns.L
local ipairs, floor = ipairs, math.floor

local origFont, overlay

-- Bundled Cascadia Mono (Fonts.lua); nil if the file was removed
function ns.DefaultFontPath()
    for _, f in ipairs(ns.fonts) do
        if f[1] == "Cascadia Mono" then return f[2] end
    end
end

-- useCache: called on a text change; skip the recoloring if the text is the same as last time
local function RefreshEditor(useCache)
    local eb, db = MacroFrameText, ns.db
    if not (eb and overlay and db) then return end
    if db.colors then
        local text = eb:GetText() or ""
        if useCache and overlay:IsShown() and text == overlay.xmwText then return end
        overlay.xmwText = text
        overlay:Show()
        ns.PaintOverlay(overlay, text)
    else
        overlay:Hide()
    end
end
ns.RefreshEditor = RefreshEditor

local function ApplyEditor()
    local eb, db = MacroFrameText, ns.db
    if not (eb and overlay and db) then return end
    local path = db.fontPath or origFont.path
    local size = db.fontSize or origFont.size
    if eb:SetFont(path, size, origFont.flags) == false then
        if db.fontPath then ns.Print(L["can't load font %s - using the stock font. Pick another in Options"]:format(db.fontPath)) end
        eb:SetFont(origFont.path, size, origFont.flags)
    end
    overlay:SetFont(eb:GetFont())
    if eb.GetSpacing and overlay.SetSpacing then
        overlay:SetSpacing(eb:GetSpacing())
    end
    RefreshEditor()
end
ns.ApplyEditor = ApplyEditor

function ns.SetupEditor()
    local eb = MacroFrameText
    if overlay then return end
    if not eb then
        ns.Print(L["Couldn't find the macro text box; font and color options are disabled."])
        return
    end

    local path, size, flags = eb:GetFont()
    origFont = { path = path, size = size, flags = flags }

    overlay = eb:CreateFontString(nil, "OVERLAY")
    overlay:SetFontObject(GameFontHighlightSmall)
    local l, r, t = eb:GetTextInsets()
    overlay:SetPoint("TOPLEFT", eb, "TOPLEFT", l, -t)
    overlay:SetPoint("TOPRIGHT", eb, "TOPRIGHT", -r, -t)
    overlay:SetJustifyH("LEFT")
    overlay:SetJustifyV("TOP")
    -- break long words like the edit box does (default is to truncate them)
    if overlay.SetNonSpaceWrap then overlay:SetNonSpaceWrap(true) end

    eb:HookScript("OnTextChanged", function() RefreshEditor(true) end)
    MacroFrame:HookScript("OnShow", ApplyEditor)
    ApplyEditor()
end

-- font size shown in the options slider (the saved one, or the stock box's)
function ns.CurrentFontSize()
    local db = ns.db
    return floor((db.fontSize or (origFont and origFont.size) or 12) + 0.5)
end

-- { name, path } for the font dropdown in the options window
function ns.GetFontList()
    local db = ns.db
    local list = {
        { "Friz Quadrata", "Fonts\\FRIZQT__.TTF" },
        { "Arial Narrow", "Fonts\\ARIALN.TTF" },
        { "Skurri", "Fonts\\skurri.ttf" },
        { "Morpheus", "Fonts\\MORPHEUS.ttf" },
    }
    -- fonts bundled with this addon (Fonts.lua)
    for _, f in ipairs(ns.fonts) do list[#list + 1] = { f[1], f[2] } end
    -- LibSharedMedia (embedded, and shared with other addons): every font registered there too
    local LSM = LibStub("LibSharedMedia-3.0", true)
    if LSM then
        local seen = {}
        for _, f in ipairs(list) do seen[f[2]:lower()] = true end
        for _, name in ipairs(LSM:List("font")) do
            local p = LSM:Fetch("font", name)
            if p and not seen[p:lower()] then
                seen[p:lower()] = true
                list[#list + 1] = { name, p }
            end
        end
    end
    -- a saved font that is in none of the lists above (e.g. from an LSM addon that is now disabled)
    if db.fontPath then
        local want, found = db.fontPath:lower(), false
        for _, f in ipairs(list) do
            if f[2]:lower() == want then found = true break end
        end
        if not found then list[#list + 1] = { L["Custom: "] .. db.fontPath, db.fontPath } end
    end
    return list
end
