local addonName, ns = ...

-- XMacroWindow: a better stock macro window (resizable, movable, colored macro code, macro and
-- icon search, every character's macros saved account-wide, deleted macros kept).
--
-- Files (load order, see the .toc):
--   Locale.lua      L["..."] text lookup
--   Fonts.lua       bundled Cascadia Mono, registered with LibSharedMedia
--   Core.lua        shared helpers, saved variables, macro saver + Deleted list, events, /xmw
--   Colorize.lua    color themes and macro code coloring
--   Editor.lua      macro text box: font, size, colored overlay
--   Browser.lua     XMacro Browser (all characters' macros) and the copy window
--   Window.lua      macro window position, size, layout, resize grip, title bar buttons
--   MacroList.lua   macro list: hover preview, search filter, duplicate
--   IconPicker.lua  icon search and icon picker size
--   Config.lua      options window
--   Extras.lua      right-click menus, shortcuts, last selection, command check
-- Files share functions and data through `ns`. Cross-file calls (ns.Foo()) are looked up when
-- they run, so the load order only matters for code that runs while the files load.

local L = ns.L
local _G = _G
local pairs, ipairs, tostring, pcall, print = pairs, ipairs, tostring, pcall, print
local tinsert, tremove, tsort = table.insert, table.remove, table.sort
local CreateFrame, C_Timer, GetTime, time = CreateFrame, C_Timer, GetTime, time
local GetMacroInfo, GetNumMacros = GetMacroInfo, GetNumMacros
local UnitName, UnitClass, GetRealmName = UnitName, UnitClass, GetRealmName

local MAX_DELETED = 666 -- how many deleted macros the Deleted list keeps
local DEFAULTS = { scale = 1.2, colors = true, locked = false, preset = "DarkModeDefault" }

------------------------------------------------------------------------
-- Shared helpers
------------------------------------------------------------------------
local function Print(...)
    print("|cff33ccffXMacro Window:|r", ...)
end
ns.Print = Print

-- run one setup step; if it fails, say so and keep going with the rest
function ns.Safe(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then Print(L["error in %s: %s"]:format(what, tostring(err))) end
end

-- first character macro slot - 1 (account macros are 1..MaxAccount)
local function MaxAccount() return MAX_ACCOUNT_MACROS or 120 end
ns.MaxAccount = MaxAccount

-- string.lower in WoW only changes A-Z. This also lowers Cyrillic (UTF-8 lead byte 0xD0):
-- Ѐ-Џ (D0 80-8F) -> ѐ-џ (D1 90-9F), А-П (D0 90-9F) -> а-п (D0 B0-BF), Р-Я (D0 A0-AF) -> р-я (D1 80-8F)
local CYR = {}
for b = 0x80, 0x8F do CYR["\208" .. string.char(b)] = "\209" .. string.char(b + 0x10) end
for b = 0x90, 0x9F do CYR["\208" .. string.char(b)] = "\208" .. string.char(b + 0x20) end
for b = 0xA0, 0xAF do CYR["\208" .. string.char(b)] = "\209" .. string.char(b - 0x20) end

function ns.Lower(s)
    s = s:lower()
    if s:find("\208", 1, true) then s = s:gsub("\208[\128-\175]", CYR) end
    return s
end

local function CharKey()
    return UnitName("player") .. "-" .. GetRealmName()
end
ns.CharKey = CharKey

-- Make the tooltip background fully opaque while one of our tooltips is shown.
-- Blizzard's tooltip art is slightly see-through, so besides recoloring it we put a solid layer
-- of our own behind the text. Both are undone when the tooltip hides.
local tipSaved, tipHooked
function ns.SolidTooltip()
    local tt = GameTooltip
    if not tt then return end
    local nine = tt.NineSlice -- the tooltip's border/background art

    if not tipHooked then
        tipHooked = true
        tt:HookScript("OnHide", function()
            if tt.xmwBg then tt.xmwBg:Hide() end
            if tt.xmwSolid and tipSaved and nine and nine.SetCenterColor then
                pcall(nine.SetCenterColor, nine, unpack(tipSaved))
            end
            tt.xmwSolid = nil
        end)
    end

    if not tt.xmwBg then
        local t = tt:CreateTexture(nil, "BACKGROUND", nil, -8)
        t:SetPoint("TOPLEFT", 3, -3)
        t:SetPoint("BOTTOMRIGHT", -3, 3)
        t:SetColorTexture(0.06, 0.06, 0.08, 1)
        tt.xmwBg = t
    end
    tt.xmwBg:Show()

    if nine and nine.SetCenterColor then
        if not tt.xmwSolid and nine.GetCenterColor then tipSaved = { nine:GetCenterColor() } end
        nine:SetCenterColor(0.06, 0.06, 0.08, 1)
    end
    tt.xmwSolid = true
end

------------------------------------------------------------------------
-- Saving macros of every character + the Deleted list
------------------------------------------------------------------------
-- db.account          account-wide macros (as last seen by any character)
-- db.chars[key]       { name, realm, class, macros } per "Name-Realm"
-- db.deleted          newest first: { name, icon, body, scope, char, class, time }
local db
local known = {} -- [macro slot] = macro, kept in memory so we can see what a delete removed

-- read slots first..last; a macro that didn't change keeps its table (less garbage, every
-- macro save runs this)
local function ReadMacros(first, last, before)
    local t = {}
    for i = first, last do
        local name, icon, body = GetMacroInfo(i)
        if name then
            body = body or ""
            local m = before[i]
            if not (m and m.name == name and m.icon == icon and m.body == body) then
                m = { name = name, icon = icon, body = body }
            end
            t[#t + 1] = m
            known[i] = m
        end
    end
    return t
end

-- DeleteMacro calls whose macro we haven't logged yet. The client can apply a delete (and fire
-- UPDATE_MACROS) before or after our hook runs, so old and new lists are compared instead of slots.
local pendingDeletes, pendingTime = 0, 0

local function Sig(m) return m.name .. "\0" .. m.body end -- (not the icon: #showtooltip icons change)

-- log the macros that were in `before` but are gone now (only as many as DeleteMacro calls are pending)
local function LogMissing(before)
    if pendingDeletes <= 0 then return end
    if GetTime() - pendingTime > 5 then pendingDeletes = 0 return end -- a delete that never happened
    -- how many macros with each name+text exist now (two identical macros count as two)
    local now = {}
    for _, m in pairs(known) do
        local s = Sig(m)
        now[s] = (now[s] or 0) + 1
    end
    local order = {}
    for i in pairs(before) do order[#order + 1] = i end
    tsort(order)
    -- a macro still in the same slot is surely not the deleted one: count those first
    local left = {}
    for _, i in ipairs(order) do
        local s, cur = Sig(before[i]), known[i]
        if cur and Sig(cur) == s and now[s] > 0 then
            now[s] = now[s] - 1
        else
            left[#left + 1] = i
        end
    end
    -- the rest: still there in another slot (moved, sorted, twin) or really gone
    local gone = {}
    for _, i in ipairs(left) do
        local s = Sig(before[i])
        if (now[s] or 0) > 0 then now[s] = now[s] - 1 else gone[#gone + 1] = i end
    end
    local maxAccount = MaxAccount()
    local _, class = UnitClass("player")
    for _, i in ipairs(gone) do
        if pendingDeletes <= 0 then break end
        pendingDeletes = pendingDeletes - 1
        local m, perChar = before[i], i > maxAccount
        tinsert(db.deleted, 1, {
            name = m.name, icon = m.icon, body = m.body,
            scope = perChar and "character" or "account",
            char = perChar and CharKey() or nil, class = perChar and class or nil,
            time = time(),
        })
    end
    while #db.deleted > MAX_DELETED do tremove(db.deleted) end
end

local function Snapshot()
    if not db then return end
    local before = {}
    for k, m in pairs(known) do before[k] = m; known[k] = nil end
    local numAccount, numChar = GetNumMacros()
    local maxAccount = MaxAccount()
    -- An empty list only replaces a saved non-empty one right after a DeleteMacro call. Otherwise
    -- (macros not loaded yet at login, a server sync problem) the saved copy is kept as a backup.
    local recentDelete = GetTime() - pendingTime < 5
    local acc = ReadMacros(1, numAccount, before)
    if #acc > 0 or recentDelete or not (db.account and #db.account > 0) then db.account = acc end
    local key = CharKey()
    local old = db.chars[key]
    local mine = ReadMacros(maxAccount + 1, maxAccount + numChar, before)
    if #mine > 0 or recentDelete or not (old and old.macros and #old.macros > 0) then
        local _, class = UnitClass("player")
        db.chars[key] = { name = UnitName("player"), realm = GetRealmName(), class = class, macros = mine }
    end
    LogMissing(before)
end
ns.Snapshot = Snapshot

-- UPDATE_MACROS can fire inside DeleteMacro, before our hook: re-read on the next frame, so the
-- hook still sees the list from before the delete
local snapshotQueued
local function QueueSnapshot()
    if snapshotQueued then return end
    snapshotQueued = true
    C_Timer.After(0, function()
        snapshotQueued = nil
        Snapshot()
        if ns.RefreshBrowser then ns.RefreshBrowser() end -- keep an open browser in step
    end)
end

-- Remember every macro that gets deleted (by the stock Delete button, a script, anything).
-- Create/Edit re-read at once, so a delete in the same frame compares against the newest list.
local deleteHooked
local function InstallDeleteHook()
    if deleteHooked then return end
    deleteHooked = true
    hooksecurefunc("DeleteMacro", function()
        if not db then return end
        if not ns.moving then -- (moving a macro to the other tab, Extras.lua, is not a delete)
            pendingDeletes = pendingDeletes + 1
        end
        pendingTime = GetTime() -- (also lets Snapshot save a list that just became empty)
        -- if the client already removed it, this logs it now; otherwise the next UPDATE_MACROS does
        Snapshot()
    end)
    hooksecurefunc("CreateMacro", Snapshot)
    hooksecurefunc("EditMacro", Snapshot)
end

------------------------------------------------------------------------
-- Hook everything into the stock MacroFrame (once Blizzard_MacroUI is loaded)
------------------------------------------------------------------------
local function Tweak()
    local f = MacroFrame
    if not f or f.xmacroDone then return end
    f.xmacroDone = true
    local Safe = ns.Safe
    Safe("macro list", ns.SetupMacroList, f)       -- MacroList.lua (before the title bar: it places the search box)
    Safe("title bar", ns.SetupWindow, f)           -- Window.lua
    Safe("icon search", ns.SetupIconSearch)        -- IconPicker.lua
    Safe("icon picker size", ns.SetupPopupSize)    -- IconPicker.lua
    Safe("window position", ns.InstallPositionHook)
    Safe("spellbook", ns.HookSpellbookFrames)
    Safe("macro editor", ns.SetupEditor)           -- Editor.lua
    Safe("resize grip", ns.SetupGrip, f)
    Safe("window layout", ns.Apply)
    Safe("extras", ns.OnTweak, f)                  -- Extras.lua
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_LOGOUT")
ev:RegisterEvent("UPDATE_MACROS")
ev:SetScript("OnEvent", function(_, event, name)
    if event == "ADDON_LOADED" then
        if name == addonName then
            local firstRun = XMacroWindowDB == nil
            XMacroWindowDB = XMacroWindowDB or {}
            db = XMacroWindowDB
            ns.db = db
            if firstRun then db.fontPath = ns.DefaultFontPath() end -- Cascadia Mono on a fresh install
            for k, v in pairs(DEFAULTS) do
                if db[k] == nil then db[k] = v end
            end
            db.chars = db.chars or {}
            db.deleted = db.deleted or {}
            if db.preset == "Dark (default)" then db.preset = "Dark" end -- renamed
            if not ns.PRESETS[db.preset] then db.preset = DEFAULTS.preset end -- theme renamed/removed
            ns.ApplyPreset(db.preset)
            InstallDeleteHook()
            ns.Safe("spellbook", ns.HookSpellbookFrames)
            if C_AddOns.IsAddOnLoaded("Blizzard_MacroUI") then Tweak() end
        elseif not db then
            return
        elseif name == "Blizzard_MacroUI" then
            Tweak()
        elseif name == "Blizzard_PlayerSpells" or name == "Blizzard_SpellBook" then
            ns.Safe("spellbook", ns.HookSpellbookFrames)
        end
    elseif event == "UPDATE_MACROS" then
        QueueSnapshot()
    else -- PLAYER_LOGIN, PLAYER_LOGOUT
        Snapshot()
    end
end)

------------------------------------------------------------------------
-- /xmw
------------------------------------------------------------------------
local function SetLocked(on)
    db.locked = on and true or false
    ns.UpdateLock()
    local opt = _G.XMWOptions -- keep an open options window in step
    if opt and opt.lock then opt.lock:SetChecked(db.locked) end
    Print(db.locked and L["window locked"] or L["window unlocked"])
end

local function PrintHelp()
    Print(L["commands:"])
    Print("  /xmw opt - " .. L["options window"])
    Print("  /xmw lock - " .. L["lock the macro window (no moving or resizing)"])
    Print("  /xmw unlock - " .. L["unlock the macro window"])
    Print("  /xmw reset position - " .. L["move all addon windows back to their default spots"])
    Print("  /xmw help - " .. L["this help"])
end

SLASH_XMACROWINDOW1 = "/xmw"
SlashCmdList["XMACROWINDOW"] = function(input)
    if not db then return end
    local msg = (strtrim(input or ""):lower():gsub("%s+", " ")) -- "reset   position" works too
    if msg == "opt" then
        ns.ToggleOptions()
    elseif msg == "lock" then
        SetLocked(true)
    elseif msg == "unlock" then
        SetLocked(false)
    elseif msg == "reset position" then
        ns.ResetAllPositions()
    else -- "", "help" and anything unknown
        PrintHelp()
    end
end
