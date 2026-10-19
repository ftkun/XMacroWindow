local addonName, ns = ...

------------------------------------------------------------------------
-- XMacro Browser (saved macros of every character, deleted macros) and the copy window
------------------------------------------------------------------------
local L = ns.L
local ipairs, pairs, tostring, pcall, max = ipairs, pairs, tostring, pcall, math.max
local tinsert, tremove, tsort = table.insert, table.remove, table.sort
local CreateFrame, C_Timer, InCombatLockdown, GameTooltip = CreateFrame, C_Timer, InCombatLockdown, GameTooltip

local copy, browser, rows, content
local RefreshBrowser

-- create a macro from a saved entry (copy window buttons, browser right-click menu)
function ns.CreateFromEntry(entry, perChar)
    if not entry then return end
    if InCombatLockdown() then
        ns.Print(L["Can't create macros in combat."])
        return
    end
    local ok, res = pcall(CreateMacro, entry.name, entry.icon, entry.body, perChar)
    if ok and res then
        ns.Print(perChar and L["Created character macro %s"]:format(entry.name)
            or L["Created account-wide macro %s"]:format(entry.name))
    else
        ns.Print(L["Could not create macro (no free slots?)"], ok and "" or tostring(res))
    end
end

-- remove an entry from the Deleted list (copy window button, browser right-click menu)
function ns.ForgetDeleted(ref)
    local db = ns.db
    if not ref then return end
    for i, d in ipairs(db.deleted) do
        if d == ref then tremove(db.deleted, i) break end
    end
    if copy and copy:IsShown() and copy.entry and copy.entry.ref == ref then copy:Hide() end
    RefreshBrowser()
end

------------------------------------------------------------------------
-- Copy window (select text, press Ctrl+C)
------------------------------------------------------------------------
local function CreateCopy()
    local f = CreateFrame("Frame", "XMWCopy", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(460, 260)
    f:SetPoint("CENTER", 0, 40)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.TitleText then f.TitleText:SetText(L["Copy macro"]) end
    tinsert(UISpecialFrames, "XMWCopy") -- Esc closes it

    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.hint:SetPoint("TOPLEFT", 14, -32)
    f.hint:SetWidth(430)
    f.hint:SetJustifyH("LEFT")

    local sf = CreateFrame("ScrollFrame", "XMWCopyScroll", f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 14, -56)
    sf:SetPoint("BOTTOMRIGHT", -34, 44)

    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetFontObject(ChatFontNormal)
    eb:SetSize(400, 150)
    eb:SetAutoFocus(false)
    eb:SetScript("OnEscapePressed", function() f:Hide() end)
    -- close shortly after Ctrl+C / Ctrl+X (the copy itself happens after OnKeyDown)
    eb:SetScript("OnKeyDown", function(_, key)
        if IsControlKeyDown() and (key == "C" or key == "X") then
            C_Timer.After(0.15, function() f:Hide() end)
        end
    end)
    sf:SetScrollChild(eb)
    f.eb = eb

    -- colored copy of the text drawn over the edit box (same trick as the macro editor)
    local ov = eb:CreateFontString(nil, "OVERLAY")
    local fp, fs, ff = eb:GetFont()
    if fp then ov:SetFont(fp, fs, ff) else ov:SetFontObject(ChatFontNormal) end
    local l, r, t = eb:GetTextInsets()
    ov:SetPoint("TOPLEFT", eb, "TOPLEFT", l, -t)
    ov:SetPoint("TOPRIGHT", eb, "TOPRIGHT", -r, -t)
    ov:SetJustifyH("LEFT")
    ov:SetJustifyV("TOP")
    if ov.SetNonSpaceWrap then ov:SetNonSpaceWrap(true) end
    f.refresh = function()
        if ns.db.colors then
            ov:Show()
            ns.PaintOverlay(ov, eb:GetText() or "")
        else
            ov:Hide()
        end
    end
    eb:SetScript("OnTextChanged", f.refresh)

    local b1 = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b1:SetSize(140, 24)
    b1:SetPoint("BOTTOMLEFT", 14, 12)
    b1:SetText(L["Create: character"])
    b1:SetScript("OnClick", function() ns.CreateFromEntry(f.entry, true) end)

    local b2 = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b2:SetSize(150, 24)
    b2:SetPoint("LEFT", b1, "RIGHT", 4, 0)
    b2:SetText(L["Create: account-wide"])
    b2:SetScript("OnClick", function() ns.CreateFromEntry(f.entry, false) end)

    -- only for entries from the "Deleted macros" list
    local b3 = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b3:SetSize(80, 24)
    b3:SetPoint("BOTTOMRIGHT", -14, 12)
    b3:SetText(L["Forget"])
    b3:SetScript("OnClick", function() ns.ForgetDeleted(f.entry and f.entry.ref) end)
    f.forget = b3

    copy = f
end

-- e = { name, icon, body, owner [, ref = entry of db.deleted] }
function ns.ShowCopy(e)
    if not copy then CreateCopy() end
    copy.entry = e
    copy.forget:SetShown(e.ref ~= nil)
    copy.hint:SetText(e.name .. "  -  " .. e.owner .. "\n|cff999999" .. L["Text is selected: press Ctrl+C"] .. "|r")
    copy:Show()
    copy.eb:SetText(e.body)
    copy.refresh()
    copy.eb:SetFocus()
    copy.eb:HighlightText()
end

-- recolor an open copy window (colors toggled / theme changed in the options)
function ns.RefreshCopy()
    if copy then copy.refresh() end
end

------------------------------------------------------------------------
-- Macro browser: character dropdown + search across all characters
------------------------------------------------------------------------
local filterKey = "ALL" -- "ALL", "ACCOUNT", "DELETED" or a character key "Name-Realm"
local ROW_H = 26

-- "Name Realm" with the name in class color (realm in grey)
local function ColoredName(info)
    local c = info.class and RAID_CLASS_COLORS[info.class]
    local name = c and c:WrapTextInColorCode(info.name) or info.name
    return name .. " |cff888888" .. (info.realm or "") .. "|r"
end

local function SortedCharKeys(db)
    local keys = {}
    for k in pairs(db.chars) do keys[#keys + 1] = k end
    tsort(keys)
    return keys
end

-- the list for the current dropdown choice and search text
local function BuildEntries(query)
    local db = ns.db
    local out = {}
    query = ns.Lower(query or "")

    -- lower-case copies are kept while the browser is open, so typing doesn't redo them every key
    local lc = browser.lc
    local function low(s)
        local v = lc[s]
        if not v then v = ns.Lower(s); lc[s] = v end
        return v
    end
    local function add(owner, m, ref, charKey)
        if query == "" or low(m.name):find(query, 1, true) or low(m.body):find(query, 1, true) then
            out[#out + 1] = { name = m.name, icon = m.icon, body = m.body, owner = owner, ref = ref, charKey = charKey }
        end
    end

    if filterKey == "DELETED" then
        for _, d in ipairs(db.deleted) do
            local who = d.scope == "account" and L["account"] or ((d.char or "?"):match("^[^-]+") or "?")
            add(("|cffff8080%s|r |cff888888(%s)|r"):format(date("%d %b", d.time or 0), who), d, d)
        end
        return out
    end

    if filterKey == "ALL" or filterKey == "ACCOUNT" then
        local label = "|cffaaaaaa" .. L["Account-wide"] .. "|r"
        for _, m in ipairs(db.account or {}) do add(label, m) end
    end

    for _, k in ipairs(SortedCharKeys(db)) do
        if filterKey == "ALL" or filterKey == k then
            local c = db.chars[k]
            local label = ColoredName(c)
            for _, m in ipairs(c.macros) do
                add(label, m, nil, k) -- (charKey: for "copy all to this character", Extras.lua)
            end
        end
    end
    return out
end

-- list rows are created on demand and reused
local function GetRow(i)
    if rows[i] then return rows[i] end
    local r = CreateFrame("Button", nil, content)
    r:SetHeight(ROW_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    r:SetPoint("RIGHT", content, "RIGHT")

    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.12)

    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(22, 22)
    r.icon:SetPoint("LEFT", 2, 0)

    r.owner = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.owner:SetPoint("RIGHT", -4, 0)
    r.owner:SetWidth(170)
    r.owner:SetJustifyH("RIGHT")
    r.owner:SetWordWrap(false)

    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.name:SetPoint("RIGHT", r.owner, "LEFT", -6, 0)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)

    r:SetScript("OnEnter", function(self)
        local e = self.entry
        if not e then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(e.name, 1, 1, 1)
        GameTooltip:AddLine(e.owner)
        ns.AddBodyLines(GameTooltip, e.body)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(e.ref and L["Click to restore or copy"] or L["Click to copy"], 0.2, 1, 0.2)
        GameTooltip:AddLine(e.ref and L["Right-click: create, copy, forget"] or L["Right-click: create, copy"], 0.5, 0.5, 0.5)
        GameTooltip:Show()
        ns.SolidTooltip()
    end)
    r:SetScript("OnLeave", GameTooltip_Hide)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function(self, mouse)
        if not self.entry then return end
        if mouse == "RightButton" then
            ns.OpenBrowserMenu(self, self.entry) -- Extras.lua
        else
            ns.ShowCopy(self.entry)
        end
    end)

    rows[i] = r
    return r
end

RefreshBrowser = function()
    if not (browser and browser:IsShown()) then return end
    local list = BuildEntries(browser.search:GetText())
    for i, e in ipairs(list) do
        local r = GetRow(i)
        r.entry = e
        r.icon:SetTexture(e.icon)
        r.name:SetText(e.name)
        r.owner:SetText(e.owner)
        r:Show()
    end
    for i = #list + 1, #rows do
        rows[i]:Hide()
        rows[i].entry = nil
    end
    content:SetHeight(max(1, #list * ROW_H))
    browser.count:SetText(L["%d macros"]:format(#list))
    browser.ShowLabel() -- dropdown text (counts may have changed)
end
ns.RefreshBrowser = RefreshBrowser

local function CreateBrowser()
    local db = ns.db
    local f = CreateFrame("Frame", "XMWBrowser", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(460, 480)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.TitleText then f.TitleText:SetText(L["XMacro Browser"]) end
    tinsert(UISpecialFrames, "XMWBrowser") -- Esc closes it

    -- Character dropdown: plain lines (no radio dots); the dropdown itself shows what is picked
    local dd = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    dd:SetPoint("TOPLEFT", 12, -30)
    dd:SetWidth(180)
    local function Label()
        if filterKey == "ACCOUNT" then return L["Account-wide macros"] end
        if filterKey == "DELETED" then return L["Deleted macros (%d)"]:format(#db.deleted) end
        local c = db.chars[filterKey]
        return c and ColoredName(c) or L["All characters"]
    end
    local function ShowLabel()
        if dd.OverrideText then dd:OverrideText(Label()) elseif dd.Text then dd.Text:SetText(Label()) end
    end
    local function Pick(key)
        filterKey = key
        ShowLabel()
        RefreshBrowser()
    end
    f.ShowLabel = ShowLabel
    dd:SetupMenu(function(_, root)
        root:CreateButton(L["All characters"], function() Pick("ALL") end)
        root:CreateButton(L["Account-wide macros"], function() Pick("ACCOUNT") end)
        root:CreateButton(L["Deleted macros (%d)"]:format(#db.deleted), function() Pick("DELETED") end)
        local me = ns.CharKey()
        for _, k in ipairs(SortedCharKeys(db)) do
            local c = db.chars[k]
            local line = root:CreateButton(ColoredName(c) .. " (" .. #c.macros .. ")", function() Pick(k) end)
            -- another character with macros: a submenu (hover the line) to copy them all here (Extras.lua)
            if k ~= me and #c.macros > 0 then
                line:CreateButton(L["Copy all %d macros to this character"]:format(#c.macros), function()
                    ns.CopyAllFromCharacter(k)
                end)
            end
        end
    end)
    ShowLabel()

    -- Search box: searches once typing pauses for a moment, not on every key
    local search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
    search:SetPoint("TOPLEFT", 206, -34)
    search:SetSize(222, 20)
    if search.Instructions then search.Instructions:SetText(L["Search name or code"]) end
    local token = 0
    search:HookScript("OnTextChanged", function()
        token = token + 1
        local mine = token
        C_Timer.After(0.15, function()
            if mine == token then RefreshBrowser() end
        end)
    end)
    f.search = search
    f.lc = {} -- [text] = ns.Lower(text), see BuildEntries

    -- List
    local scroll = CreateFrame("ScrollFrame", "XMWBrowserScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -62)
    scroll:SetPoint("BOTTOMRIGHT", -32, 28)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(410, 1)
    scroll:SetScrollChild(content)
    rows = {}

    f.count = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.count:SetPoint("BOTTOMLEFT", 14, 10)

    f:SetScript("OnShow", function()
        ns.Snapshot() -- make sure the current character is up to date
        RefreshBrowser()
    end)
    f:SetScript("OnHide", function() f.lc = {} end)

    f:Hide() -- so the first Show() fires OnShow
    browser = f
end

function ns.ToggleBrowser()
    if not browser then CreateBrowser() end
    browser:SetShown(not browser:IsShown())
end
