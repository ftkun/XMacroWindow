local addonName, ns = ...

------------------------------------------------------------------------
-- Extras for the stock macro window (uses helpers shared through ns):
--   * right-click a macro in the list: move / copy to the other tab, duplicate, copy text, delete
--   * right-click a macro in the XMacro Browser: create, copy text, copy all, forget
--   * Ctrl+F jumps to the macro search, Esc clears it, Enter goes back to the macro text
--   * the window reopens on the tab and macro you had selected last time (per character)
--   * unknown slash commands / #directives are shown in the error color; the character
--     counter turns orange near the limit and red at it
--   * the stock "delete this macro?" popup shows the macro's name
------------------------------------------------------------------------
local L = ns.L
local _G = _G
local pairs, ipairs, type, pcall, tostring = pairs, ipairs, type, pcall, tostring
local CreateFrame, C_Timer, GetMacroInfo, GetNumMacros, GetTime = CreateFrame, C_Timer, GetMacroInfo, GetNumMacros, GetTime
local InCombatLockdown, IsControlKeyDown, MenuUtil = InCombatLockdown, IsControlKeyDown, MenuUtil
local Print, MaxAccount, Lower = ns.Print, ns.MaxAccount, ns.Lower

local RED = "|cffff6060"

------------------------------------------------------------------------
-- Unknown slash commands and #directives
------------------------------------------------------------------------
local DIRECTIVES = { ["#show"] = true, ["#showtooltip"] = true }
-- commands every client has: if any of them isn't found, our list is incomplete on this client
-- and nothing is marked (better no check than every command shown red)
local PROBES = { "/cast", "/use", "/target", "/say", "/run", "/dance" }
local knownCmds, builtAt = nil, -1000 -- [lower-case "/command"] = true; GetTime() of the last look
local checkOK = false                 -- false: a probe is missing, the check is off on this client
local REBUILD_EVERY = 5 -- seconds; how often an unknown command makes us look for new addon commands

-- add a "/command" string to the set t (anything that isn't one is ignored)
local function AddCmd(t, v)
    if type(v) == "string" and v:sub(1, 1) == "/" then
        local k = v:match("^(/%S+)") -- (some strings carry a trailing space)
        if k then t[Lower(k)] = true end
    end
end

-- SLASH_<KEY>1, SLASH_<KEY>2, ... for every key of a command table (SlashCmdList: addon commands)
local function AddFromCmdList(t, list)
    if type(list) ~= "table" then return end
    for key in pairs(list) do
        if type(key) == "string" then
            local i = 1
            local v = _G["SLASH_" .. key .. i]
            while v do
                AddCmd(t, v)
                i = i + 1
                v = _G["SLASH_" .. key .. i]
            end
        end
    end
end

-- the full look: walks the whole global table once (slow, ~100k entries), so it runs only the
-- first time; later looks (Refresh below) only check the command lists, where addons add theirs
local function BuildCommands()
    local t = {}
    -- every SLASH_* string in the global table (SLASH_CAST1 = "/cast", addons' SLASH_FOO1, ...)
    for k, v in pairs(_G) do
        if type(k) == "string" and type(v) == "string" and k:sub(1, 6) == "SLASH_" then
            AddCmd(t, v)
        end
    end
    -- emotes: /dance, /wave, ... (EMOTE12_CMD1 = "/dance")
    for i = 1, (tonumber(_G.MAXEMOTEINDEX) or 800) do
        local j = 1
        local v = _G["EMOTE" .. i .. "_CMD" .. j]
        while v do
            AddCmd(t, v)
            j = j + 1
            v = _G["EMOTE" .. i .. "_CMD" .. j]
        end
    end
    -- the chat frame's own lookup tables, read only (command -> ...)
    for _, h in ipairs({ _G.hash_SlashCmdList, _G.hash_SecureCmdList, _G.hash_EmoteTokenList, _G.hash_ChatTypeInfo }) do
        if type(h) == "table" then
            for k in pairs(h) do AddCmd(t, k) end
        end
    end
    knownCmds = t
    builtAt = GetTime()
    checkOK = true
    for _, p in ipairs(PROBES) do
        if not t[p] then checkOK = false break end
    end
end

-- cheap look for commands registered since the last look
local function RefreshCommands()
    AddFromCmdList(knownCmds, _G.SlashCmdList)
    if type(_G.hash_SlashCmdList) == "table" then
        for k in pairs(_G.hash_SlashCmdList) do AddCmd(knownCmds, k) end
    end
    builtAt = GetTime()
end

-- Colorize.lua: is "/cmd" a command nobody knows?
ns.IsUnknownCommand = function(cmd)
    if not knownCmds then BuildCommands() end
    if not checkOK then return false end
    local k = Lower(cmd)
    if knownCmds[k] or k:find("^/%d+$") then return false end -- (/1, /2 ... are chat channels)
    if GetTime() - builtAt > REBUILD_EVERY then
        RefreshCommands()
        if knownCmds[k] then return false end
    end
    return true
end

-- only #show / #showtooltip do anything; any other #word is shown in the error color
ns.IsUnknownDirective = function(dir)
    return not DIRECTIVES[dir:lower()]
end

-- the "x/255 characters used" text: orange near the limit, red at it
local function SetupCharCounter()
    local eb = _G.MacroFrameText
    local lim = _G.MacroFrameCharLimitText or MacroFrame.CharLimitText
    if not (eb and lim) then return end
    local r, g, b = lim:GetTextColor()
    local function update(self)
        local maxLetters = self:GetMaxLetters()
        if maxLetters <= 0 then maxLetters = 255 end
        local n = self:GetNumLetters()
        if n >= maxLetters then
            lim:SetTextColor(1, 0.25, 0.25)
        elseif n >= maxLetters - 25 then
            lim:SetTextColor(1, 0.6, 0.1)
        else
            lim:SetTextColor(r, g, b)
        end
    end
    eb:HookScript("OnTextChanged", update)
    update(eb)
end

------------------------------------------------------------------------
-- Right-click menu on the macro list
------------------------------------------------------------------------
-- keep = true: copy to the other tab and leave the original where it is
local function MoveMacro(idx, keep)
    if InCombatLockdown() then
        Print(keep and L["Can't copy macros in combat."] or L["Can't move macros in combat."])
        return
    end
    local name, icon, body = GetMacroInfo(idx)
    if not name then return end
    local maxAcc = MaxAccount()
    -- no hard-coded fallback for the character limit (it differs between clients):
    -- if the game doesn't tell us, let CreateMacro decide
    local maxChar = MAX_CHARACTER_MACROS
    local toChar = idx <= maxAcc
    local where = toChar and L["character macros"] or L["account-wide macros"]
    local numAcc, numChar = GetNumMacros()
    if (toChar and maxChar and numChar >= maxChar) or (not toChar and numAcc >= maxAcc) then
        Print(L["No free slots in %s."]:format(where))
        return
    end
    local ok, res = pcall(CreateMacro, name, icon, body or "", toChar)
    if not (ok and res) then
        Print((keep and L["Could not copy %s"] or L["Could not move %s"]):format(name), ok and "" or tostring(res))
        return
    end
    if keep then
        Print(L["Copied %s to %s"]:format(name, where))
        return
    end
    -- account and character macros live in separate slot ranges, so the original's slot is unchanged
    ns.moving = true -- (Core.lua: don't put it in the "Deleted macros" list)
    local okDel, err = pcall(DeleteMacro, idx)
    ns.moving = nil
    if okDel then
        Print(L["Moved %s to %s"]:format(name, where))
    else
        Print(L["Copied %s but could not delete the original:"]:format(name), tostring(err))
    end
end

-- delete every macro on the character tab (each one still goes to the "Deleted macros" list)
local function DeleteAllCharacter()
    if InCombatLockdown() then
        Print(L["Can't delete macros in combat."])
        return
    end
    local maxAcc = MaxAccount()
    local _, numChar = GetNumMacros()
    local n = 0
    for i = maxAcc + numChar, maxAcc + 1, -1 do -- from the last slot down, so the others keep their slots
        if pcall(DeleteMacro, i) then n = n + 1 end
    end
    if MacroFrame and MacroFrame.Update then pcall(MacroFrame.Update, MacroFrame) end
    Print(L["Deleted %d character macros. They are in ALL > Deleted macros if you need one back."]:format(n))
end

local function ConfirmDeleteAllCharacter()
    local _, numChar = GetNumMacros()
    if numChar == 0 then
        Print(L["This character has no macros."])
        return
    end
    if not StaticPopupDialogs.XMW_DELETE_ALL_CHAR then
        StaticPopupDialogs.XMW_DELETE_ALL_CHAR = {
            text = L["Delete ALL %d character macros of %s?"],
            button1 = YES,
            button2 = NO,
            OnAccept = DeleteAllCharacter,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            showAlert = true,
        }
    end
    StaticPopup_Show("XMW_DELETE_ALL_CHAR", numChar, UnitName("player"))
end

local function OpenMenu(button)
    local idx, name, icon, body = ns.MacroForButton(button)
    if not idx then return end
    -- select it first (like a left-click), so Duplicate / Delete work on this macro
    pcall(button.Click, button, "LeftButton")
    local perChar = idx > MaxAccount()

    MenuUtil.CreateContextMenu(button, function(_, root)
        root:CreateTitle(name)
        root:CreateButton(perChar and L["Move to account-wide"] or L["Move to character"], function()
            MoveMacro(idx)
        end)
        root:CreateButton(perChar and L["Copy to account-wide"] or L["Copy to character"], function()
            MoveMacro(idx, true)
        end)
        root:CreateButton(L["Duplicate"], function() ns.DuplicateSelected(idx) end)
        root:CreateButton(L["Copy text"], function()
            ns.ShowCopy({ name = name, icon = icon, body = body or "",
                          owner = perChar and L["Character macro"] or L["Account-wide macro"] })
        end)
        local del = _G.MacroDeleteButton or MacroFrame.DeleteButton
        root:CreateDivider()
        if del then
            root:CreateButton(RED .. L["Delete"] .. "|r", function() del:Click() end) -- stock confirm popup
        end
        local _, numChar = GetNumMacros()
        if numChar > 0 then
            root:CreateButton(RED .. L["Delete all character macros (%d)"]:format(numChar) .. "|r",
                ConfirmDeleteAllCharacter)
        end
    end)
end

-- MacroList.lua calls this for every list button
ns.OnListButton = function(button)
    if button.xmwMenuHooked then return end
    button.xmwMenuHooked = true
    button:HookScript("OnMouseUp", function(self, mouse)
        if mouse == "RightButton" and self:IsMouseOver() then OpenMenu(self) end
    end)
end

------------------------------------------------------------------------
-- Right-click menu in the XMacro Browser (saved macros of every character, deleted macros)
------------------------------------------------------------------------
-- copy every saved macro of another character into this character's macros
-- (macros this character already has, same name and same text, are skipped)
local function CopyAllFromCharacter(key)
    local db = ns.db
    local src = db.chars[key]
    if not src then return end
    if InCombatLockdown() then
        Print(L["Can't create macros in combat."])
        return
    end
    local maxAcc = MaxAccount()
    local maxChar = MAX_CHARACTER_MACROS -- nil: unknown, let CreateMacro decide
    local _, numChar = GetNumMacros()
    local have = {}
    for i = maxAcc + 1, maxAcc + numChar do
        local n, _, b = GetMacroInfo(i)
        if n then have[n .. "\0" .. (b or "")] = true end
    end
    local list = {}
    for _, m in ipairs(src.macros or {}) do list[#list + 1] = m end -- (CreateMacro re-saves db.chars)
    local made, same, full = 0, 0, 0
    for _, m in ipairs(list) do
        if have[m.name .. "\0" .. (m.body or "")] then
            same = same + 1
        elseif maxChar and numChar >= maxChar then
            full = full + 1
        else
            local ok, res = pcall(CreateMacro, m.name, m.icon, m.body or "", true)
            if ok and res then
                made, numChar = made + 1, numChar + 1
            else
                full = full + 1
            end
        end
    end
    local msg = L["Copied %d macros from %s."]:format(made, src.name or key)
    if same > 0 then msg = msg .. " " .. L["%d already here."]:format(same) end
    if full > 0 then msg = msg .. " " .. RED .. L["%d didn't fit (no free character slots)."]:format(full) .. "|r" end
    Print(msg)
    ns.RefreshBrowser()
end
ns.CopyAllFromCharacter = CopyAllFromCharacter -- (also used by the character dropdown of the browser)

ns.OpenBrowserMenu = function(row, e)
    MenuUtil.CreateContextMenu(row, function(_, root)
        root:CreateTitle(e.name)
        root:CreateButton(L["Create as character macro"], function() ns.CreateFromEntry(e, true) end)
        root:CreateButton(L["Create as account-wide macro"], function() ns.CreateFromEntry(e, false) end)
        root:CreateButton(L["Copy text"], function() ns.ShowCopy(e) end)
        local src = e.charKey and ns.db.chars[e.charKey]
        if src and e.charKey ~= ns.CharKey() then -- a macro of another character
            root:CreateDivider()
            root:CreateButton(L["Copy all macros of %s to this character (%d)"]:format(
                src.name or e.charKey, #(src.macros or {})), function() CopyAllFromCharacter(e.charKey) end)
        end
        if e.ref then -- only entries of the "Deleted macros" list
            root:CreateDivider()
            root:CreateButton(RED .. L["Forget"] .. "|r", function() ns.ForgetDeleted(e.ref) end)
        end
    end)
end

------------------------------------------------------------------------
-- Keyboard shortcuts
------------------------------------------------------------------------
local function SetupShortcuts(f)
    local search = ns.listSearchBox
    if not (search and search:IsShown()) then return end -- (hidden: the list can't be filtered)

    local function FocusSearch()
        search:SetFocus()
        search:HighlightText()
    end

    -- Esc clears the search (and leaves the box); Enter goes back to the macro text
    search:HookScript("OnEscapePressed", function(self)
        if (self:GetText() or "") ~= "" then self:SetText("") end
    end)
    search:HookScript("OnEnterPressed", function(self)
        self:ClearFocus()
        if _G.MacroFrameText then _G.MacroFrameText:SetFocus() end
    end)

    -- Ctrl+F while typing a macro
    local eb = _G.MacroFrameText
    if eb then
        eb:HookScript("OnKeyDown", function(_, key)
            if key == "F" and IsControlKeyDown() then FocusSearch() end
        end)
    end

    -- Ctrl+F anywhere while the window is open: a keyboard listener that lets every other key through.
    -- (Keyboard pass-through can't be changed in combat, so the shortcut is off during fights.)
    local kf = CreateFrame("Frame", nil, f)
    kf:SetPropagateKeyboardInput(true)
    kf:EnableKeyboard(true)
    local function passAll()
        if not InCombatLockdown() then kf:SetPropagateKeyboardInput(true) end
    end
    kf:SetScript("OnKeyDown", function(self, key)
        if InCombatLockdown() then return end
        local mine = key == "F" and IsControlKeyDown()
        self:SetPropagateKeyboardInput(not mine)
        if mine then
            FocusSearch()
            C_Timer.After(0, passAll) -- back to letting everything through right away
        end
    end)
    kf:SetScript("OnKeyUp", passAll)
    kf:SetScript("OnHide", passAll)
end

------------------------------------------------------------------------
-- Reopen on the last tab and macro (per character)
------------------------------------------------------------------------
local function SetupMemory(f)
    local function Save()
        local db = ns.db
        local fs = _G.MacroFrameSelectedMacroName
        local name = fs and fs:GetText()
        local idx = ns.SelectedMacro() -- (slot: two macros may share a name)
        db.lastSel = db.lastSel or {}
        db.lastSel[ns.CharKey()] = {
            tab = ns.CurrentTabIsCharacter() and 2 or 1,
            name = (name and name ~= "") and name or nil,
            idx = idx,
        }
    end

    local function Restore()
        local db = ns.db
        local mem = db.lastSel and db.lastSel[ns.CharKey()]
        if not (mem and f:IsShown()) then return end
        local wantChar = mem.tab == 2
        if wantChar ~= ns.CurrentTabIsCharacter() then
            local tab = _G["MacroFrameTab" .. mem.tab] or (f.Tabs and f.Tabs[mem.tab])
            if tab then
                tab:Click()
            elseif f.ChangeTab then
                pcall(f.ChangeTab, f, mem.tab)
            end
        end
        if not mem.name then return end
        local first = ns.MacroRanges()
        -- the same slot if it still holds that macro, otherwise the first one with that name
        if mem.idx and mem.idx >= first[1] and mem.idx <= first[2] and GetMacroInfo(mem.idx) == mem.name then
            ns.SelectReal(mem.idx)
            return
        end
        for i = first[1], first[2] do
            if GetMacroInfo(i) == mem.name then
                ns.SelectReal(i)
                return
            end
        end
    end

    f:HookScript("OnHide", Save)
    f:HookScript("OnShow", function() C_Timer.After(0, Restore) end) -- after the stock window picks tab 1
    if f:IsShown() then C_Timer.After(0, Restore) end
end

------------------------------------------------------------------------
-- Stock "Do you want to delete this macro?" popup: add the macro's name
------------------------------------------------------------------------
-- Blizzard's popup table is left untouched (changing it could taint the popup system); the text is
-- only extended on screen after the popup is shown.
local function SelectedName()
    local fs = _G.MacroFrameSelectedMacroName
    local name = fs and fs:GetText()
    if name and name ~= "" and MacroFrame:IsShown() then return name end
end

-- is this the stock "delete this macro?" text?
local function IsDeleteText(t)
    if type(t) ~= "string" or t == "" then return false end
    if t:find("|cffffd100", 1, true) then return false end -- the name is already there
    local stock = _G.CONFIRM_DELETE_MACRO
    if stock and t == stock then return true end
    return t:lower():find("delete this macro", 1, true) ~= nil
end

-- look through the popups on screen; the text is found by what it says, not by a field name
-- (the popup code has been rewritten several times, field names differ between versions)
local function AddNameToPopups()
    local name = SelectedName()
    if not name then return end
    for i = 1, 4 do
        local d = _G["StaticPopup" .. i]
        if d and d:IsShown() then
            for _, r in ipairs({ d:GetRegions() }) do
                if r:GetObjectType() == "FontString" and r:IsShown() then
                    local t = r:GetText()
                    if IsDeleteText(t) then
                        r:SetText(t .. "\n|cffffd100" .. name:gsub("|", "||") .. "|r")
                        if _G.StaticPopup_Resize then pcall(_G.StaticPopup_Resize, d, d.which) end
                    end
                end
            end
        end
    end
end

local function SetupDeleteName()
    local function soon()
        AddNameToPopups()
        C_Timer.After(0, AddNameToPopups) -- again once the popup has finished setting itself up
    end
    if _G.StaticPopup_Show then hooksecurefunc("StaticPopup_Show", soon) end
    for i = 1, 4 do
        local d = _G["StaticPopup" .. i]
        if d then d:HookScript("OnShow", soon) end
    end
end

------------------------------------------------------------------------
-- Called by Core.lua once the stock macro window has been set up
------------------------------------------------------------------------
ns.OnTweak = function(f)
    local Safe = ns.Safe
    Safe("character counter", SetupCharCounter)
    Safe("shortcuts", SetupShortcuts, f)
    Safe("last selection", SetupMemory, f)
    Safe("delete popup name", SetupDeleteName)
end
