local addonName, ns = ...

------------------------------------------------------------------------
-- Macro text box: font, font size and colored overlay
------------------------------------------------------------------------
-- The edit box itself can't show colors while typing, so a FontString with the colored copy of
-- the text sits exactly over it (same font, insets and spacing). The edit box text stays visible
-- underneath; the overlay draws on top of it.
local L = ns.L
local ipairs, floor, max, select = ipairs, math.floor, math.max, select

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
    ns.SetupItemLinks()
end

------------------------------------------------------------------------
-- Ctrl-click an item, recipe or spell: insert its full link into the macro text
------------------------------------------------------------------------
-- Works from any window while the macro window is open:
--  * on mouse down (GLOBAL_MOUSE_DOWN) the frame under the mouse is checked: a recipe row of the
--    professions window gives C_TradeSkillUI.GetRecipeLink(recipeID) (same call Skillet uses);
--    anything else gives the item or spell of the tooltip it is showing (bags, spellbook, ...)
--  * HandleModifiedItemClick is post-hooked too, for clicks that show no tooltip (chat links)
-- Side effects of the stock ctrl-click are undone: spell/item picked up onto the cursor is dropped,
-- dressing room closed, recipe tracking set back.
-- Shift-click keeps the stock behavior. /xmw links turns it on/off. No taint (hooks/events only).
local downHandled        -- the current click was already handled on mouse down
local pendingFix         -- { track = { id, was }, dress = wasShown, cursor = hadSomething } checked after mouse up
local lastLink, lastTime -- HandleModifiedItemClick called twice for one click
local dressShownAt       -- GetTime() the dressing room last opened

local function CtrlOnly()
    return IsControlKeyDown() and not IsShiftKeyDown() and not IsAltKeyDown()
end

local function Active()
    local eb, db = MacroFrameText, ns.db
    -- only while the macro text is being edited (same rule as the stock shift-click insert)
    return eb and db and db.itemLinks and eb:IsVisible() and eb:HasFocus()
end

-- fr is owner or one of its children (up to `depth` levels, default 8)
local function IsInside(fr, owner, depth)
    for _ = 1, depth or 8 do
        if not fr then return false end
        if fr == owner then return true end
        fr = fr.GetParent and fr:GetParent()
    end
    return false
end

-- action bar / secure action buttons: a ctrl-click there casts, never insert from them
local function IsActionButton(fr)
    for _ = 1, 2 do
        if not fr then return false end
        if fr.action ~= nil then return true end
        if fr.GetAttribute then
            local ok, t = pcall(fr.GetAttribute, fr, "type")
            if ok and t ~= nil then return true end
        end
        fr = fr.GetParent and fr:GetParent()
    end
    return false
end

local function FocusFrame()
    if _G.GetMouseFoci then
        local t = GetMouseFoci()
        return t and t[1]
    end
    if _G.GetMouseFocus then return GetMouseFocus() end
end

-- recipe id of a professions list row (ScrollBox element data, or a recipeInfo field)
local function RecipeIDFrom(fr)
    for _ = 1, 6 do
        if not fr then return end
        if fr.GetElementData then
            local ok, data = pcall(fr.GetElementData, fr)
            if ok and type(data) == "table" then
                local d = data
                if type(data.GetData) == "function" then
                    local ok2, dd = pcall(data.GetData, data)
                    if ok2 and type(dd) == "table" then d = dd end
                end
                local ri = d.recipeInfo
                local id = (type(ri) == "table" and ri.recipeID) or d.recipeID
                if type(id) == "number" then return id end
            end
        end
        local ri = fr.recipeInfo
        if type(ri) == "table" and type(ri.recipeID) == "number" then return ri.recipeID end
        fr = fr.GetParent and fr:GetParent()
    end
end

-- A profession itself (Enchanting, ...) gets a profession link like the professions window's link
-- button / Skillet: |Htrade:<player GUID>:<spell>:<skill line>|h[Name]|h. A spell link of a
-- profession is sent as plain text.
local function ProfessionLink(spellID, spellName)
    if not (_G.GetProfessions and _G.GetProfessionInfo and spellName) then return end
    -- prof1, prof2, archaeology, fishing, cooking (+ more on some clients); unknown ones are nil
    local profs = { GetProfessions() }
    for i = 1, max(5, select("#", GetProfessions())) do
        local idx = profs[i]
        if idx then
            local name, _, _, _, _, _, skillLine = GetProfessionInfo(idx)
            if name and name == spellName and type(skillLine) == "number" then
                -- the profession that is open in the professions window: Blizzard's own link
                local TS = _G.C_TradeSkillUI
                if TS and TS.GetTradeSkillListLink then
                    local ok, l = pcall(TS.GetTradeSkillListLink)
                    if ok and type(l) == "string" and l:find(":" .. skillLine .. "|h", 1, true) then return l end
                end
                local guid = UnitGUID("player")
                if guid then
                    return ("|cffffd000|Htrade:%s:%d:%d|h[%s]|h|r"):format(guid, spellID, skillLine, name)
                end
            end
        end
    end
end

-- spell link the way the spellbook makes it (slot + bank of a spellbook button), if there is one
local function SpellBookLink(fr)
    local SB = _G.C_SpellBook
    if not (SB and SB.GetSpellBookItemLink) then return end
    for _ = 1, 4 do
        if not fr then return end
        local slot, bank = fr.slotIndex, fr.spellBank
        if not slot and fr.GetElementData then
            local ok, d = pcall(fr.GetElementData, fr)
            if ok and type(d) == "table" then slot, bank = d.slotIndex, d.spellBank end
        end
        if type(slot) == "number" and bank ~= nil then
            local ok, l = pcall(SB.GetSpellBookItemLink, slot, bank)
            if ok and type(l) == "string" and l ~= "" then return l end
        end
        fr = fr.GetParent and fr:GetParent()
    end
end

-- item or spell link of the tooltip shown by the frame under the mouse
local function TooltipLink(fr)
    local tt = GameTooltip
    if not (tt and tt:IsShown()) then return end
    local owner = tt:GetOwner()
    if not (owner and IsInside(fr, owner, 2)) then return end -- tooltip of this frame, not a far ancestor
    local ok, _, link = pcall(tt.GetItem, tt)
    if ok and type(link) == "string" and link:find("|H", 1, true) then return link end
    local ok2, name, id = pcall(tt.GetSpell, tt)
    if ok2 and type(id) == "number" then
        local prof = ProfessionLink(id, name)
        if prof then return prof end
        local sb = SpellBookLink(fr)
        if sb then return sb end
        local get = (_G.C_Spell and C_Spell.GetSpellLink) or _G.GetSpellLink
        if get then
            local ok3, l = pcall(get, id)
            if ok3 and type(l) == "string" and l ~= "" then return l end
        end
    end
end

local function RecipeTracked(id)
    local TS = _G.C_TradeSkillUI
    if not (TS and TS.IsRecipeTracked and TS.SetRecipeTracked) then return end
    local ok, was = pcall(TS.IsRecipeTracked, id, false)
    if ok and type(was) == "boolean" then return was end
end

local function CursorHolds()
    return _G.GetCursorInfo and GetCursorInfo() ~= nil
end

-- the click picked something up (spellbook, professions window): drop it again
local function UndoPickup(fix)
    if fix and fix.cursor == false and CursorHolds() and _G.ClearCursor then ClearCursor() end
end

-- put cursor / recipe tracking / dressing room back the way they were before the click
local function UndoSideEffects(fix)
    if not fix then return end
    UndoPickup(fix)
    if fix.track then
        local id, was = fix.track[1], fix.track[2]
        local now = RecipeTracked(id)
        if now ~= nil and now ~= was then pcall(C_TradeSkillUI.SetRecipeTracked, id, was, false) end
    end
    local dress = _G.DressUpFrame
    if fix.dress == false and dress and dress:IsShown() then HideUIPanel(dress) end
end

-- This client writes the spell's subtext into spell link names: "[Fireball (Rank 1)]",
-- "[Escape Artist (Racial)]". The server rejects such a link and sends plain text, so the extra
-- part moves out of the link, right behind it as plain text: "[Escape Artist] (Racial)".
-- The id still points to that exact spell/rank (its tooltip shows it).
-- Which part is extra: 1) the spell's subtext from the game ("Rank 2", "Racial"), 2) else what
-- follows the real name, 3) else any "(...)" at the end of the name.
local function CleanSpellLink(link)
    local head, id, name, tail = link:match("^(.-|Hspell:(%d+)[^|]*|h%[)(.-)(%]|h.*)$")
    if not head then return link end -- not a spell link
    id = tonumber(id)
    local base, extra
    local S = _G.C_Spell
    -- 1) subtext: "Fireball (Rank 2)" = name .. " (" .. subtext .. ")"
    if S and S.GetSpellSubtext then
        local ok, sub = pcall(S.GetSpellSubtext, id)
        if ok and type(sub) == "string" and sub ~= "" then
            local suffix = "(" .. sub .. ")"
            if #name > #suffix and name:sub(-#suffix) == suffix then
                base, extra = name:sub(1, -#suffix - 1):match("^(.-)%s*$"), suffix
            end
        end
    end
    -- 2) real name: whatever follows it is extra; the same as the real name = nothing to do
    if not base and S and S.GetSpellName then
        local ok, real = pcall(S.GetSpellName, id)
        if ok and real == name then return link end
        if ok and type(real) == "string" and real ~= "" and #name > #real
            and name:sub(1, #real) == real then
            base, extra = real, name:sub(#real + 1):match("^%s*(.-)%s*$")
        end
    end
    -- 3) no help from the game: a "(...)" at the end
    if not base then base, extra = name:match("^(.-)%s*(%b())$") end
    if not base or base == "" or not extra or extra == "" then return link end
    return head .. base .. tail .. " " .. extra
end
ns.CleanSpellLink = CleanSpellLink

local function InsertLink(link)
    link = CleanSpellLink(link)
    local eb = MacroFrameText
    local before, pos = eb:GetText() or "", eb:GetCursorPosition()
    eb:Insert(link)
    if #(eb:GetText() or "") ~= #before + #link then -- over the 255 limit: undo
        eb:SetText(before)
        eb:SetCursorPosition(pos)
        ns.Print(L["no room for the link (macro limit 255 characters)"])
        return false
    end
    return true
end

local mouse = CreateFrame("Frame")
mouse:SetScript("OnEvent", function(_, event, button)
    if event == "GLOBAL_MOUSE_UP" then
        local fix = pendingFix
        pendingFix = nil
        if fix then
            UndoPickup(fix)                                       -- picked up before this event
            C_Timer.After(0, function() UndoSideEffects(fix) end) -- after the click's OnClick
        end
        return
    end
    downHandled = false
    if button ~= "LeftButton" or not Active() or not CtrlOnly() then return end
    local fr = FocusFrame()
    if not fr or IsInside(fr, MacroFrame) or IsInside(fr, _G.MacroPopupFrame) then return end
    if IsActionButton(fr) then return end
    local ok, link, recipeID = pcall(function()
        local id = RecipeIDFrom(fr)
        local TS = _G.C_TradeSkillUI
        if id and TS and TS.GetRecipeLink then
            local l = TS.GetRecipeLink(id)
            if type(l) == "string" and l ~= "" then return l, id end
        end
        return TooltipLink(fr)
    end)
    if not (ok and type(link) == "string" and link ~= "") then return end
    downHandled = true
    local dress = _G.DressUpFrame
    pendingFix = { dress = dress and dress:IsShown() or false, cursor = CursorHolds() }
    local fix = pendingFix
    C_Timer.After(0, function() UndoPickup(fix) end) -- picked up on mouse down
    if recipeID then
        local was = RecipeTracked(recipeID)
        if was ~= nil then pendingFix.track = { recipeID, was } end
    end
    InsertLink(link)
end)

-- clicks without a tooltip (chat links) still come through here
local function OnModifiedItemClick(link)
    if not Active() or not CtrlOnly() then return end
    if type(link) ~= "string" or not link:find("|H", 1, true) then return end
    local mb = _G.GetMouseButtonClicked and GetMouseButtonClicked()
    if mb and mb ~= "LeftButton" then return end
    local now = GetTime()
    if link == lastLink and now == lastTime then return end
    lastLink, lastTime = link, now
    -- side effects of this same click (dressing room / tracking happen after this hook)
    local fix = { dress = false }
    local dress = _G.DressUpFrame
    if dress and dress:IsShown() and dressShownAt ~= now then fix.dress = true end
    local id = tonumber(link:match("|Henchant:(%d+)") or link:match("|Hspell:(%d+)"))
    if id then
        local was = RecipeTracked(id)
        if was ~= nil then fix.track = { id, was } end
    end
    C_Timer.After(0, function() UndoSideEffects(fix) end)
    if downHandled then return end -- already inserted on mouse down
    InsertLink(link)
end

function ns.SetupItemLinks()
    local eb = MacroFrameText
    if not eb or eb.xmwLinksHooked then return end
    eb.xmwLinksHooked = true
    if _G.HandleModifiedItemClick then
        hooksecurefunc("HandleModifiedItemClick", OnModifiedItemClick)
    end
    if _G.DressUpFrame then
        DressUpFrame:HookScript("OnShow", function() dressShownAt = GetTime() end)
    end
    -- listen to mouse clicks only while the macro window is open
    local function on()
        mouse:RegisterEvent("GLOBAL_MOUSE_DOWN")
        mouse:RegisterEvent("GLOBAL_MOUSE_UP")
    end
    MacroFrame:HookScript("OnShow", on)
    MacroFrame:HookScript("OnHide", function() mouse:UnregisterAllEvents(); pendingFix = nil end)
    if MacroFrame:IsShown() then on() end
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
