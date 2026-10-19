local addonName, ns = ...

------------------------------------------------------------------------
-- Macro list: hover preview, search filter, duplicate
------------------------------------------------------------------------
local L = ns.L
local _G = _G
local ipairs, type, pcall, tostring = ipairs, type, pcall, tostring
local CreateFrame, C_Timer, InCombatLockdown, GameTooltip = CreateFrame, C_Timer, InCombatLockdown, GameTooltip
local GetMacroInfo, GetNumMacros = GetMacroInfo, GetNumMacros
local MaxAccount, Lower = ns.MaxAccount, ns.Lower

local listQuery = "" -- lower-case search text, "" = no search

local function CurrentTabIsCharacter()
    local mf = MacroFrame
    if not mf then return false end
    if type(mf.macroBase) == "number" then
        return mf.macroBase >= MaxAccount()
    end
    return (mf.selectedTab or PanelTemplates_GetSelectedTab(mf)) == 2
end
ns.CurrentTabIsCharacter = CurrentTabIsCharacter

-- { first slot, last slot, offset between list position and slot }: current tab first, other one second
local function MacroRanges()
    local maxAcc = MaxAccount()
    local numAcc, numChar = GetNumMacros()
    local acc = { 1, numAcc, 0 }
    local chr = { maxAcc + 1, maxAcc + numChar, maxAcc }
    if CurrentTabIsCharacter() then return chr, acc end
    return acc, chr
end
ns.MacroRanges = MacroRanges

-- the macro name written on a list button
local function ButtonText(button)
    local n = button.Name or (button:GetName() and _G[button:GetName() .. "Name"])
    if n then return n:GetText() end
    for _, r in ipairs({ button:GetRegions() }) do
        if r:GetObjectType() == "FontString" then
            local t = r:GetText()
            if t and t ~= "" then return t end
        end
    end
end

local function Matches(name, body)
    return Lower(name):find(listQuery, 1, true) or Lower(body or ""):find(listQuery, 1, true)
end

------------------------------------------------------------------------
-- Search filter
------------------------------------------------------------------------
-- While searching, the list only holds the macros that match.
-- listMap: list position -> real slot (nil = no search, the stock list is shown)
local listMap, listMapKey, listDirty
local filterOK          -- the stock list could be hooked (otherwise the search box is hidden)
local listSearchBox
local ApplyListProvider -- set by InstallListFilter

local function GetListMap()
    if listQuery == "" or not filterOK then
        listMap = nil
        return nil
    end
    local first = MacroRanges()
    if listMap and not listDirty and listMapKey == first[3] then return listMap end
    listMap, listMapKey, listDirty = {}, first[3], false
    for i = first[1], first[2] do
        local name, _, body = GetMacroInfo(i)
        if name and Matches(name, body) then listMap[#listMap + 1] = i end
    end
    return listMap
end

-- which macro is a list button showing?  returns slot, name, icon, body
local function MacroForButton(button)
    local shown = ButtonText(button)
    local first, second = MacroRanges()

    local data = button.GetElementData and button:GetElementData()
    if type(data) == "number" then
        local map = GetListMap()
        local idx
        if map then idx = map[data] else idx = first[3] + data end
        idx = idx or 0
        if idx >= first[1] and idx <= first[2] then
            local name, icon, body = GetMacroInfo(idx)
            if name and (not shown or shown == "" or shown == name) then
                return idx, name, icon, body
            end
        end
    end
    -- fallback: find it by the name on the button
    if shown and shown ~= "" then
        for _, r in ipairs({ first, second }) do
            for i = r[1], r[2] do
                local name, icon, body = GetMacroInfo(i)
                if name == shown then return i, name, icon, body end
            end
        end
    end
end
ns.MacroForButton = MacroForButton

-- hover preview of the macro text + the right-click menu (Extras.lua)
local function HookListButton(button)
    if button.xmwHooked then return end
    button.xmwHooked = true
    button:HookScript("OnEnter", function(self)
        local idx, name, _, body = MacroForButton(self)
        if not idx then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(name, 1, 1, 1)
        ns.AddBodyLines(GameTooltip, body or "")
        GameTooltip:AddLine(L["Right-click: move, duplicate, copy, delete"], 0.5, 0.5, 0.5)
        GameTooltip:Show()
        ns.SolidTooltip()
    end)
    button:HookScript("OnLeave", GameTooltip_Hide)
    ns.Safe("macro list menu", ns.OnListButton, button) -- Extras.lua
end

-- list position of the selected macro in the stock window
local function SelectedPos(f)
    if f.GetSelectedIndex then
        local ok, i = pcall(f.GetSelectedIndex, f)
        if ok then return i end
    end
    return f.selectedMacro
end

local function ClearListSearch()
    if listQuery == "" then return end
    listQuery, listMap = "", nil
    if listSearchBox then listSearchBox:SetText("") end -- SetListQuery then sees no change
end

-- Make the stock list show only matching macros: the list asks MacroFrame:GetMacroDataIndex()
-- which macro sits at a list position, so we answer through listMap and shrink the list to #listMap.
-- (This replaces a method on Blizzard's MacroFrame. The macro functions it leads to are not
-- protected, so this taint is harmless; if "action blocked" errors ever mention the macro
-- window, look here first.)
local function InstallListFilter()
    local f = MacroFrame
    local sel = f and f.MacroSelector
    if not (sel and f.GetMacroDataIndex and f.SelectMacro and f.Update and sel.SetSelectionsDataProvider) then
        return
    end

    local stockIndex = f.GetMacroDataIndex
    f.GetMacroDataIndex = function(self, index)
        local map = GetListMap()
        if map and #map > 0 and type(index) == "number" then
            return map[index] or map[#map]
        end
        return stockIndex(self, index)
    end

    local stockGet, stockCount, busy
    local function FilteredGet(i) return stockGet(i) end -- the stock getter already goes through the map
    local function FilteredCount()
        local map = GetListMap()
        return map and #map or 0
    end
    -- give the list the filtered provider while searching, the stock one otherwise
    local function ApplyProvider(force)
        if busy or not stockGet then return end
        local map = GetListMap()
        if not map and not force then return end
        busy = true
        local ok, err = pcall(function()
            if map then
                sel:SetSelectionsDataProvider(FilteredGet, FilteredCount)
            else
                sel:SetSelectionsDataProvider(stockGet, stockCount)
            end
            if sel.UpdateSelections then sel:UpdateSelections() end
        end)
        busy = false
        if not ok then ns.Print(L["macro search problem:"], err) end
    end
    ApplyListProvider = ApplyProvider
    -- remember the stock provider whenever Blizzard sets one, and swap ours in while searching
    hooksecurefunc(sel, "SetSelectionsDataProvider", function(_, getSel, getCount)
        if busy then return end
        stockGet, stockCount = getSel, getCount
        ApplyProvider()
    end)

    -- after the stock window refreshes: keep the selection inside the filtered list
    local fixing
    hooksecurefunc(f, "Update", function(self)
        if fixing then return end
        local map = GetListMap()
        if not map then return end
        local cur = SelectedPos(self)
        if cur and cur > #map then
            fixing = true
            pcall(self.SelectMacro, self, #map > 0 and #map or nil)
            pcall(self.Update, self)
            fixing = false
        end
    end)

    -- macro slots change when macros are added, deleted or renamed
    hooksecurefunc("DeleteMacro", function() listDirty = true end)
    -- the stock window selects a new/renamed macro by its real slot, so the search has to go first
    hooksecurefunc("CreateMacro", function() listDirty = true; ClearListSearch() end)
    hooksecurefunc("EditMacro", function(_, name)
        listDirty = true
        if name then ClearListSearch() end -- rename (saving just the text passes no name)
    end)

    filterOK = true
end

-- the search changed: rebuild the list, keep the selected macro (oldReal) if it still matches
local function RefreshFilteredList(oldReal)
    local f = MacroFrame
    listDirty, listMap = true, nil
    local map = GetListMap()
    local first = MacroRanges()
    local pos
    if oldReal then
        if map then
            for p, i in ipairs(map) do
                if i == oldReal then pos = p break end
            end
        elseif oldReal >= first[1] and oldReal <= first[2] then
            pos = oldReal - first[3]
        end
    end
    if not pos then
        if map then
            pos = map[1] and 1 or nil
        else
            pos = first[2] >= first[1] and 1 or nil
        end
    end

    pcall(f.SelectMacro, f, pos)
    pcall(f.Update, f)
    ApplyListProvider(true) -- in case Update didn't reset the list itself
    local sel = f.MacroSelector
    if pos and sel.SetSelectedIndex then pcall(sel.SetSelectedIndex, sel, pos) end
    local sb = sel.ScrollBox
    if sb then
        if map and sb.ScrollToBegin then
            pcall(sb.ScrollToBegin, sb)
        elseif pos and sb.ScrollToElementDataIndex then
            pcall(sb.ScrollToElementDataIndex, sb, pos)
        end
    end
end

local function SetListQuery(text)
    local q = Lower(strtrim(text or ""))
    if q == listQuery or not filterOK then return end
    local f = MacroFrame
    -- find the selected macro while the old search is still in place
    local oldReal
    local cur = SelectedPos(f)
    if cur then
        if f.SaveMacro and not InCombatLockdown() then pcall(f.SaveMacro, f) end -- don't lose typed text
        local ok, i = pcall(f.GetMacroDataIndex, f, cur)
        if ok then oldReal = i end
    end
    listQuery = q
    RefreshFilteredList(oldReal)
end

-- list buttons are created by the ScrollBox as needed: hook each one once
local listErrorShown
local function HookAllListButtons()
    local sb = MacroFrame.MacroSelector and MacroFrame.MacroSelector.ScrollBox
    if not (sb and sb.ForEachFrame) then return end
    local ok, err = pcall(sb.ForEachFrame, sb, HookListButton)
    if not ok and not listErrorShown then
        listErrorShown = true
        ns.Print(L["macro list problem:"], err)
    end
end

local function InitListHooks()
    local sel = MacroFrame.MacroSelector
    local sb = sel and sel.ScrollBox
    if not sb then return end
    local ok, err = pcall(InstallListFilter)
    if not ok then ns.Print(L["macro search is not available on this build:"], err) end
    -- (false: the list has no buttons yet while the Blizzard UI is loading)
    local ok2, err2 = pcall(ScrollUtil.AddAcquiredFrameCallback, sb,
        function(_, frame) HookListButton(frame) end, sel, false)
    if not ok2 then ns.Print(L["hover preview: can't watch the macro list:"], err2) end
    -- buttons that already exist once the window is open
    MacroFrame:HookScript("OnShow", function() C_Timer.After(0.1, HookAllListButtons) end)
end

------------------------------------------------------------------------
-- Selected macro, duplicate
------------------------------------------------------------------------
-- the macro that is selected in the stock window: slot, name, icon, body
local function SelectedMacro()
    local fs = _G.MacroFrameSelectedMacroName
    local shown = fs and fs:GetText()
    if not shown or shown == "" then return end
    -- the selected slot first (two macros may have the same name)
    local f = MacroFrame
    local pos = f and SelectedPos(f)
    if pos then
        local ok, i = pcall(f.GetMacroDataIndex, f, pos)
        if ok and type(i) == "number" then
            local name, icon, body = GetMacroInfo(i)
            if name == shown then return i, name, icon, body end
        end
    end
    -- otherwise the first macro with that name
    local first, second = MacroRanges()
    for _, r in ipairs({ first, second }) do
        for i = r[1], r[2] do
            local name, icon, body = GetMacroInfo(i)
            if name == shown then return i, name, icon, body end
        end
    end
end
ns.SelectedMacro = SelectedMacro

-- first n characters of str; UTF-8 aware, so a Cyrillic (2-byte) letter is never cut in half
local function FirstChars(str, n)
    local out = {}
    for ch in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if #out >= n then break end
        out[#out + 1] = ch
    end
    return table.concat(out)
end

-- useIdx: duplicate this slot (right-click menu) instead of the selected macro
function ns.DuplicateSelected(useIdx)
    if InCombatLockdown() then
        ns.Print(L["Can't create macros in combat."])
        return
    end
    local idx, name, icon, body
    if type(useIdx) == "number" then
        name, icon, body = GetMacroInfo(useIdx)
        if name then idx = useIdx end
    else
        idx, name, icon, body = SelectedMacro()
    end
    if not idx then
        ns.Print(L["Select a macro first."])
        return
    end
    local maxAcc = MaxAccount()
    local numAcc, numChar = GetNumMacros()
    local perChar = idx > maxAcc
    local lo, hi = 1, numAcc
    if perChar then lo, hi = maxAcc + 1, maxAcc + numChar end

    -- "Name 2", "Name 3", ... (macro names are at most 16 characters)
    local used = {}
    for i = lo, hi do
        local n = GetMacroInfo(i)
        if n then used[n] = true end
    end
    -- base name without an old " 2" suffix and trailing spaces,
    -- so duplicating "Name 2" gives "Name 3", not "Name 2 2" / "Name  2"
    local base = name:gsub("%s+%d+$", ""):gsub("%s+$", "")
    if base == "" then base = name end
    local newName = name
    for n = 2, 99 do
        local suffix = " " .. n
        newName = FirstChars(base, 16 - #suffix):gsub("%s+$", "") .. suffix
        if not used[newName] then break end
    end

    local ok, res = pcall(CreateMacro, newName, icon, body or "", perChar)
    if ok and res then
        ns.Print(L["Duplicated as %s"]:format(newName))
        -- (creating a macro clears the list search) select the copy
        local f = MacroFrame
        if f and type(res) == "number" then
            local first = MacroRanges()
            if res >= first[1] and res <= first[2] then
                pcall(f.SelectMacro, f, res - first[3])
                pcall(f.Update, f)
            end
        end
    else
        ns.Print(L["Could not duplicate (no free slots?)"], ok and "" or tostring(res))
    end
end

-- select a macro of the current tab by its real slot (works while the list is filtered too)
function ns.SelectReal(idx)
    local f = MacroFrame
    local first = MacroRanges()
    if not (f and idx and idx >= first[1] and idx <= first[2]) then return end
    local map = GetListMap()
    local pos
    if map then
        for p, i in ipairs(map) do
            if i == idx then pos = p break end
        end
    else
        pos = idx - first[3]
    end
    if not pos then return end
    pcall(f.SelectMacro, f, pos)
    pcall(f.Update, f)
    local sel = f.MacroSelector
    if sel and sel.SetSelectedIndex then pcall(sel.SetSelectedIndex, sel, pos) end
    local sb = sel and sel.ScrollBox
    if sb and sb.ScrollToElementDataIndex then pcall(sb.ScrollToElementDataIndex, sb, pos) end
end

------------------------------------------------------------------------
-- Setup (called from Core.lua's Tweak, before the title bar is laid out)
------------------------------------------------------------------------
function ns.SetupMacroList(f)
    -- search box for the macro list (placed by Window.lua next to the portrait)
    local lsearch = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
    listSearchBox = lsearch
    ns.listSearchBox = lsearch
    lsearch:SetSize(120, 20)
    if lsearch.Instructions then lsearch.Instructions:SetText(L["Search"]) end
    lsearch:HookScript("OnTextChanged", function(self) SetListQuery(self:GetText()) end)

    -- duplicate the selected macro (also in the right-click menu of the macro list, Extras.lua)
    local dup = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    dup:SetSize(84, 22)
    dup:SetText(L["Duplicate"])
    local del = _G.MacroDeleteButton
    if del then
        dup:SetPoint("LEFT", del, "RIGHT", 2, 0)
    else
        dup:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 96, 8)
    end
    dup:SetScript("OnClick", function() ns.DuplicateSelected() end) -- (not the button as useIdx)

    InitListHooks()
    if not filterOK then lsearch:Hide() end -- the list can't be filtered on this build
end
