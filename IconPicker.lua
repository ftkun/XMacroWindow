local addonName, ns = ...

------------------------------------------------------------------------
-- Icon picker (MacroPopupFrame): icon search by spell name, picker size
------------------------------------------------------------------------
local L = ns.L
local _G = _G
local ipairs, pairs, type, tostring, pcall = ipairs, pairs, type, tostring, pcall
local min, max, floor = math.min, math.max, math.floor
local tconcat = table.concat
local CreateFrame, C_Timer, InCombatLockdown, GameTooltip = CreateFrame, C_Timer, InCombatLockdown, GameTooltip
local GetCursorPosition, IsMouseButtonDown = GetCursorPosition, IsMouseButtonDown
local Lower = ns.Lower

local iconSearch, iconStatus, PlaceIconSearch
local ApplyPopupLayout -- defined in the picker size section

------------------------------------------------------------------------
-- Icon search
------------------------------------------------------------------------
-- >>> ICON SEARCH BOX SETTINGS (position and size) <<<
-- The search box always has the same width and height as the macro name box, and sits to its right.
local SEARCH_GAP = 18     -- pixels between the name box and the search box (more = further right)
local SEARCH_Y = 0        -- move the search box up (+) or down (-)
local SEARCH_EXTRA_W = 0  -- wider (+) / narrower (-) than the name box, in pixels
local SEARCH_EXTRA_H = 0  -- taller (+) / shorter (-) than the name box, in pixels

local filtered         -- nil = show all icons, otherwise array of icon ids
local resetting, warned
local iconNames        -- [iconID] = "spell name | other spell name" (lower case, for searching)
local iconTitle        -- [iconID] = "Spell Name, Other Spell" (as written, for the tooltip)
local indexing

-- Blizzard icon lists have no names, so we build an index of iconID -> spell names by scanning
-- spell ids a little at a time. Each frame scans batches of BATCH ids until FRAME_BUDGET_MS is
-- used up, so a fast PC finishes sooner and a slow one doesn't stutter. Paused while in combat.
-- The index lives in memory only (rebuilt once per session, the first time the picker opens).
local MAX_SPELL_ID = 2000000
local BATCH = 1000
local FRAME_BUDGET_MS = 6
local MAX_NAMES = 20      -- spell names kept per icon (search)
local MAX_TITLE = 120     -- tooltip title length

local ApplyIconFilter

local function BuildIndex()
    if iconNames or indexing then return end
    indexing = true
    -- while scanning: [iconID] = "Name" or { "Name", "Other name", ... } (a table only when needed);
    -- turned into iconNames / iconTitle strings once at the end (no string building per spell)
    local found = {}
    -- two plain lookups instead of C_Spell.GetSpellInfo's table: no garbage for hundreds of thousands of hits
    local GetSpellName, GetSpellTexture = C_Spell.GetSpellName, C_Spell.GetSpellTexture
    local now = debugprofilestop -- milliseconds, high precision
    local id = 1

    -- The highest spell id that has an icon is remembered per game build: later sessions stop a
    -- little past it instead of scanning all MAX_SPELL_ID ids. A new build scans everything again.
    local db = ns.db
    local ver, bnum = GetBuildInfo()
    local buildKey = tostring(ver) .. "." .. tostring(bnum)
    local scanTo = MAX_SPELL_ID
    local saved = db.spellScan
    if type(saved) == "table" and saved.build == buildKey and tonumber(saved.max) then
        scanTo = min(MAX_SPELL_ID, saved.max + 50000) -- (margin for hotfixed spells)
    end
    local lastHit = 0

    local function scan(first, last)
        for s = first, last do
            local sname = GetSpellName(s)
            local sicon = sname and GetSpellTexture(s)
            if sicon then
                lastHit = s
                local cur = found[sicon]
                if not cur then
                    found[sicon] = sname
                elseif type(cur) == "string" then
                    if cur ~= sname then found[sicon] = { cur, sname } end
                elseif #cur < MAX_NAMES then
                    local dup
                    for i = 1, #cur do
                        if cur[i] == sname then dup = true break end
                    end
                    if not dup then cur[#cur + 1] = sname end
                end
            end
        end
    end

    -- found -> iconNames (lower case, " | ") and iconTitle (", ", up to MAX_TITLE characters)
    local function finish()
        local names, titles = {}, {}
        for icon, v in pairs(found) do
            if type(v) == "string" then
                titles[icon] = v
                names[icon] = Lower(v)
            else
                local t = v[1]
                for i = 2, #v do
                    if #t + #v[i] + 2 > MAX_TITLE then break end
                    t = t .. ", " .. v[i]
                end
                titles[icon] = t
                names[icon] = Lower(tconcat(v, " | "))
            end
        end
        iconNames, iconTitle = names, titles
    end

    local function step()
        if InCombatLockdown() then
            C_Timer.After(1, step) -- don't take frame time during a fight; carry on afterwards
            return
        end
        local stopAt = now() + FRAME_BUDGET_MS
        repeat
            local last = min(id + BATCH - 1, scanTo)
            scan(id, last)
            id = last + 1
        until id > scanTo or now() >= stopAt
        if id > scanTo then
            finish()
            indexing = false
            db.spellScan = { build = buildKey, max = lastHit }
            if iconStatus then iconStatus:SetText("") end
            -- re-run a search typed while indexing; with an empty box there is nothing to redo
            -- (re-applying would only scroll the picker back to the top)
            if iconSearch and strtrim(iconSearch:GetText() or "") ~= "" then ApplyIconFilter() end
        else
            if iconStatus then
                iconStatus:SetText(L["Indexing %d%%"]:format(floor(id / scanTo * 100)))
            end
            C_Timer.After(0, step)
        end
    end
    C_Timer.After(0, step)
end

-- the picker asks these for its icons: our filtered list, or the stock provider
local function IconGet(i)
    if filtered then return filtered[i] end
    local p = MacroPopupFrame and MacroPopupFrame.iconDataProvider
    return p and p:GetIconByIndex(i)
end

local function IconCount()
    if filtered then return #filtered end
    local p = MacroPopupFrame and MacroPopupFrame.iconDataProvider
    return p and p:GetNumIcons() or 0
end

-- search text -> filtered list: by spell name, by file ID (digits only) or by texture path
ApplyIconFilter = function()
    local popup = MacroPopupFrame
    local provider = popup and popup.iconDataProvider
    if not (provider and popup.IconSelector and iconSearch) then return end

    local q = Lower(strtrim(iconSearch:GetText() or ""))
    if q == "" then
        filtered = nil
    else
        BuildIndex()
        filtered = {}
        local names = iconNames -- nil while indexing: only IDs/paths match until it is done
        local isNum = q:find("^%d+$")
        for i = 1, provider:GetNumIcons() do
            local icon = provider:GetIconByIndex(i)
            if icon then
                local nm = names and names[icon]
                local hit = nm and nm:find(q, 1, true)
                if not hit then
                    if type(icon) == "number" then
                        hit = isNum and tostring(icon):find(q, 1, true)
                    else
                        hit = icon:lower():find(q, 1, true)
                    end
                end
                if hit then filtered[#filtered + 1] = icon end
            end
        end
    end

    local ok, err = pcall(function()
        local sel = popup.IconSelector
        sel:SetSelectionsDataProvider(IconGet, IconCount)
        if sel.UpdateSelections then sel:UpdateSelections() end
        if sel.ScrollBox and sel.ScrollBox.ScrollToBegin then sel.ScrollBox:ScrollToBegin() end
    end)
    if not ok and not warned then
        warned = true
        ns.Print(L["Icon search failed on this build:"], err)
    end
end

-- the picture an icon button is showing (file id or path)
local function IconButtonTexture(button)
    local t = button.Icon or button.icon
    if t then return t:GetTexture() end
    for _, r in ipairs({ button:GetRegions() }) do
        if r:GetObjectType() == "Texture" then
            local tex = r:GetTexture()
            if tex then return tex end
        end
    end
end

-- hovering an icon in the picker shows what it is
local function HookIconButton(button)
    if button.xmwIconHooked then return end
    button.xmwIconHooked = true
    button:HookScript("OnEnter", function(self)
        local icon = IconButtonTexture(self)
        if not icon then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local title = iconTitle and iconTitle[icon]
        if not title and type(icon) == "string" then title = icon:match("([^\\/]+)$") end
        if title then
            GameTooltip:AddLine(title, 1, 1, 1, true)
        elseif indexing then
            GameTooltip:AddLine(L["Looking up the name..."], 0.7, 0.7, 0.7)
        else
            GameTooltip:AddLine(L["No spell uses this icon"], 0.7, 0.7, 0.7)
        end
        GameTooltip:AddLine(type(icon) == "number" and (L["File ID: "] .. icon) or tostring(icon), 0.6, 0.6, 0.6)
        GameTooltip:Show()
        ns.SolidTooltip()
    end)
    button:HookScript("OnLeave", GameTooltip_Hide)
end

function ns.SetupIconSearch()
    local popup = MacroPopupFrame
    if not popup or iconSearch then return end

    iconSearch = CreateFrame("EditBox", nil, popup, "SearchBoxTemplate")
    iconSearch:SetPoint("BOTTOMLEFT", popup, "TOPLEFT", 14, 4) -- used only if the name box can't be found
    iconSearch:SetSize(150, 20)
    if iconSearch.Instructions then iconSearch.Instructions:SetText(L["Search icons"]) end

    iconStatus = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    iconStatus:SetPoint("TOPLEFT", iconSearch, "BOTTOMLEFT", 4, -1)

    -- put the search box right next to the macro name box, same height
    PlaceIconSearch = function()
        local border = popup.BorderBox
        local nameBox = (border and border.IconSelectorEditBox) or _G.MacroPopupEditBox
        if not nameBox then return end
        iconSearch:ClearAllPoints()
        iconSearch:SetPoint("LEFT", nameBox, "RIGHT", SEARCH_GAP, SEARCH_Y)
        iconSearch:SetHeight(nameBox:GetHeight() + SEARCH_EXTRA_H)
        iconSearch:SetFrameLevel((border and border:GetFrameLevel() or popup:GetFrameLevel()) + 5)
    end

    -- search once typing pauses
    local token = 0
    iconSearch:HookScript("OnTextChanged", function()
        if resetting then return end
        token = token + 1
        local mine = token
        C_Timer.After(0.25, function()
            if mine == token then ApplyIconFilter() end
        end)
    end)

    -- icon names for the tooltips
    local sel = popup.IconSelector
    local sb = sel and sel.ScrollBox
    if sb then
        pcall(ScrollUtil.AddAcquiredFrameCallback, sb, function(_, frame) HookIconButton(frame) end, sel, false)
    end

    popup:HookScript("OnShow", function()
        resetting = true
        filtered = nil
        iconSearch:SetText("")
        resetting = false
        PlaceIconSearch()
        BuildIndex() -- starts looking up icon names (once per session)
        C_Timer.After(0, function()
            PlaceIconSearch() -- again, once the popup has been laid out
            if sb and sb.ForEachFrame then pcall(sb.ForEachFrame, sb, HookIconButton) end
        end)
    end)
end

------------------------------------------------------------------------
-- Icon picker size: same height as the macro window, own width (edge strip + corner grip)
------------------------------------------------------------------------
local MIN_POPUP_H = 240
local POPUP_MIN_W = 195         -- narrowest the picker may get (stock is 525)
local POPUP_TOP_OFFSET = 10     -- picker top relative to the macro window top (Blizzard's own value is 5)
local POPUP_HEIGHT_TRIM = 18    -- add/subtract pixels here if the bottoms don't line up exactly
local MIN_FIELD_W = 20          -- narrowest the name box / search box get
local popupBase                 -- stock sizes and anchors of the picker and its top row (CapturePopup)

-- change the number of icon columns (the selector may keep its own stride, so set both)
local function SetGridStride(sel, cols)
    if sel.SetCustomStride then sel:SetCustomStride(cols) end
    local sb = sel.ScrollBox
    local view = sb and sb.GetView and sb:GetView()
    if view and view.SetStride then
        view:SetStride(cols)
        if sb.FullUpdate then sb:FullUpdate(ScrollBoxConstants.UpdateImmediately) end
    end
end

local function ReadPopupColumns(sel)
    if not sel then return nil end
    local sb = sel.ScrollBox
    local view = sb and sb.GetView and sb:GetView()
    return (sel.GetStride and sel:GetStride()) or (view and view.GetStride and view:GetStride()) or nil
end

local function CapturePopup()
    local pf = MacroPopupFrame
    local _, rel = pf:GetPoint(1)
    local bb = pf.BorderBox
    popupBase = {
        w = pf:GetWidth(), h = pf:GetHeight(),
        anchored = (rel == MacroFrame),
        items = {}, hideList = {}, hidden = {},
    }
    -- parts with a fixed size grow together with the picker (parts anchored on two sides stretch by themselves)
    for _, el in ipairs({ bb or false, pf.IconSelector or false, (bb and bb.IconDragArea) or false }) do
        if el and el:GetNumPoints() == 1 then
            popupBase.items[#popupBase.items + 1] = { el = el, w = el:GetWidth() or 0, h = el:GetHeight() or 0 }
        end
    end
    -- the top row: name box, selected-icon area, icon type dropdown and their labels
    local function info(el)
        if not el then return nil end
        local p, relTo, rp, x, y = el:GetPoint(1)
        return { el = el, w = el:GetWidth() or 0, x = x or 0, y = y or 0, p = p, rel = relTo, rp = rp }
    end
    popupBase.name = info((bb and bb.IconSelectorEditBox) or _G.MacroPopupEditBox)
    if bb then
        popupBase.area = info(bb.SelectedIconArea)
        popupBase.dropdown = info(bb.IconTypeDropdown)
        popupBase.label = info(bb.IconSelectionText)
        popupBase.header = info(bb.EditBoxHeaderText)
    end
    popupBase.cols = ReadPopupColumns(pf.IconSelector)
    popupBase.lastCols = popupBase.cols
end

-- "Currently Selected / click to view in the list": only the small icon button stays when narrow
local function SetAreaCompact(compact)
    local b = popupBase
    local area = b.area and b.area.el
    if not area then return end
    if compact then
        if not b.compact then
            b.compact = true
            b.hideList, b.hidden = {}, {}
            local btn = area.SelectedIconButton
            if btn then
                for _, c in ipairs({ area:GetChildren() }) do
                    if c ~= btn then b.hideList[#b.hideList + 1] = c end
                end
                for _, r in ipairs({ area:GetRegions() }) do
                    if r:GetObjectType() == "FontString" then b.hideList[#b.hideList + 1] = r end
                end
            elseif area.SelectedIconText then
                b.hideList[1] = area.SelectedIconText
            end
            for _, o in ipairs(b.hideList) do
                if o:IsShown() then b.hidden[#b.hidden + 1] = o end
            end
        end
        for _, o in ipairs(b.hideList) do -- (Blizzard may show them again when the icon changes)
            if o:IsShown() then o:Hide() end
        end
    elseif b.compact then
        b.compact = nil
        for _, o in ipairs(b.hidden) do o:Show() end
        b.hidden, b.hideList = {}, {}
    end
end

-- >>> ICON PICKER TOP ROW SETTINGS <<<
local AREA_MIN_COLS = 5      -- fewer icon columns than this: the selected-icon button + text are hidden
local ROW_PAD = 8            -- space between the search box and the selected icon / its text
local ROW_RIGHT_MARGIN = 26  -- space between the search box and the picker's right edge (icon hidden)

-- Blizzard draws the name box border as pieces with FIXED sizes (left cap, middle, right cap), so the
-- box could get narrower while its border stayed full length. Here every piece is measured once and
-- re-anchored to the box's edges: the caps keep their size, everything between them stretches.
-- The search box gets copies of the same pieces, so both look the same and shrink the same way.
local function MeasureArt(box)
    local bl, bt, br, bb = box:GetLeft(), box:GetTop(), box:GetRight(), box:GetBottom()
    if not (bl and bt and br and bb) then return nil end
    local list = {}
    for _, r in ipairs({ box:GetRegions() }) do
        if r:GetObjectType() == "Texture" and r:IsShown() then
            local l, t, rr, bo = r:GetLeft(), r:GetTop(), r:GetRight(), r:GetBottom()
            if l and t and rr and bo and rr > l and t > bo then
                list[#list + 1] = { tex = r, l = l - bl, t = t - bt, r = rr - br, b = bo - bb,
                                    w = rr - l, h = t - bo, absL = l, absR = rr }
            end
        end
    end
    if #list == 0 then return nil end
    local boxW = br - bl
    local leftCap, rightCap = list[1], list[1]
    for _, p in ipairs(list) do
        if p.absL < leftCap.absL then leftCap = p end
        if p.absR > rightCap.absR then rightCap = p end
    end
    for _, p in ipairs(list) do
        if p == leftCap and p ~= rightCap and p.w < boxW / 2 then p.kind = "left"
        elseif p == rightCap and p ~= leftCap and p.w < boxW / 2 then p.kind = "right"
        else p.kind = "stretch" end
    end
    return list
end

local function AnchorArt(t, p, box)
    t:ClearAllPoints()
    if p.kind == "left" then
        t:SetPoint("TOPLEFT", box, "TOPLEFT", p.l, p.t)
        t:SetSize(p.w, p.h)
    elseif p.kind == "right" then
        t:SetPoint("TOPRIGHT", box, "TOPRIGHT", p.r, p.t)
        t:SetSize(p.w, p.h)
    else
        t:SetPoint("TOPLEFT", box, "TOPLEFT", p.l, p.t)
        t:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", p.r, p.b)
    end
end

local function StretchBoxArt(nameBox, searchBox)
    local b = popupBase
    if b.artDone then return end
    local list = MeasureArt(nameBox)
    if not list then return end
    b.artDone = true
    for _, p in ipairs(list) do AnchorArt(p.tex, p, nameBox) end
    if not searchBox then return end
    -- search box: hide its own border (keep the magnifier; the X button is a separate frame)
    local keep = searchBox.searchIcon or searchBox.SearchIcon
    for _, r in ipairs({ searchBox:GetRegions() }) do
        if r:GetObjectType() == "Texture" and r ~= keep then r:SetAlpha(0) end
    end
    for _, p in ipairs(list) do
        local src = p.tex
        local layer, sub = src:GetDrawLayer()
        local t = searchBox:CreateTexture(nil, layer or "BACKGROUND", nil, sub or 0)
        local atlas = src:GetAtlas()
        if atlas then
            t:SetAtlas(atlas)
        else
            t:SetTexture(src:GetTexture())
            t:SetTexCoord(src:GetTexCoord())
        end
        t:SetVertexColor(src:GetVertexColor())
        t:SetAlpha(src:GetAlpha())
        AnchorArt(t, p, searchBox)
    end
end

-- Where the top-row parts really are, measured once on screen before we touch them, in the picker's
-- units: left edges from the picker's left, right-side parts as distances from the picker's right edge.
-- The "Currently selected" text can stick out of its frame, so the visible pieces are measured.
local function MeasurePopupRow()
    local b = popupBase
    if b.row then return b.row end
    local pf = MacroPopupFrame
    if not (b.name and pf and pf:IsVisible()) then return nil end
    local pl, pt, pr = pf:GetLeft(), pf:GetTop(), pf:GetRight()
    if not (pl and pt and pr) then return nil end
    local ps = pf:GetEffectiveScale()
    local function px(el, v) return v * el:GetEffectiveScale() / ps end -- el units -> picker units

    local n = b.name.el
    local nl, nt = n:GetLeft(), n:GetTop()
    if not (nl and nt) then return nil end
    local row = { name = { x = px(n, nl) - pl, y = px(n, nt) - pt } }

    if b.header then
        local hl = b.header.el:GetLeft()
        if hl then row.headerX = px(b.header.el, hl) - pl end
    end

    if b.area then
        local area = b.area.el
        local ar, at = area:GetRight(), area:GetTop()
        if not (ar and at) then return nil end
        row.area = { gap = pr - px(area, ar), y = px(area, at) - pt }
        -- left edge of everything visible in the area (text included) and of the icon button alone
        local minL = area:GetLeft() and px(area, area:GetLeft()) or nil
        local function consider(o)
            if o:IsShown() and o:GetLeft() then
                local l = px(o, o:GetLeft())
                if not minL or l < minL then minL = l end
            end
        end
        for _, c in ipairs({ area:GetChildren() }) do consider(c) end
        for _, r in ipairs({ area:GetRegions() }) do consider(r) end
        row.area.textGap = pr - (minL or pr) -- from the picker's right edge to the leftmost visible piece
        local btn = area.SelectedIconButton
        local bl = btn and btn:GetLeft()
        row.area.iconGap = bl and (pr - px(btn, bl)) or (row.area.gap + 46)
    end
    b.row = row
    local ok, err = pcall(StretchBoxArt, n, iconSearch)
    if not ok then ns.Print(L["error in %s: %s"]:format("name box artwork", tostring(err))) end
    return row
end

-- name box and search box: same width, side by side, shrinking together; nothing on the row overlaps
local function LayoutPopupRow(w, cols)
    local b = popupBase
    local pf = MacroPopupFrame
    local row = MeasurePopupRow()
    if not row then
        -- not on screen yet: leave the row alone, ApplyPopupLayout runs again a frame after OnShow
        if iconSearch and b.name then iconSearch:SetWidth(b.name.el:GetWidth() + SEARCH_EXTRA_W) end
        return
    end

    -- selected-icon area: only with AREA_MIN_COLS columns or more; pinned by its right edge, never resized
    local showArea = b.area and row.area and ((cols or AREA_MIN_COLS) >= AREA_MIN_COLS)
    if b.area then
        local a = b.area.el
        if row.area then
            a:ClearAllPoints()
            a:SetPoint("TOPRIGHT", pf, "TOPRIGHT", -row.area.gap, row.area.y)
        end
        b.areaHidden = not showArea
        if not b.areaHooked then -- Blizzard may show it again (e.g. when an icon is picked)
            b.areaHooked = true
            a:HookScript("OnShow", function(self) if popupBase.areaHidden then self:Hide() end end)
        end
        a:SetShown(showArea and true or false)
    end

    -- right limit for the boxes (picker units from its left edge): the icon button, or the picker edge
    local limit = showArea and (w - row.area.iconGap - ROW_PAD) or (w - ROW_RIGHT_MARGIN)
    local searchRight = row.name.x
    if b.name then
        local el, n = b.name.el, row.name
        local k = pf:GetEffectiveScale() / el:GetEffectiveScale() -- picker units -> name box units
        local room = limit - n.x - SEARCH_GAP / k - (b.fix or 0)
        local each = floor((room - SEARCH_EXTRA_W / k) / 2)
        local nameW = max(MIN_FIELD_W, min(b.name.w, each * k))
        local searchW = max(MIN_FIELD_W, nameW + SEARCH_EXTRA_W)
        el:ClearAllPoints()
        el:SetPoint("TOPLEFT", pf, "TOPLEFT", n.x * k, n.y * k)
        el:SetPoint("TOPRIGHT", pf, "TOPLEFT", n.x * k + nameW, n.y * k)
        if iconSearch then iconSearch:SetWidth(searchW) end
        searchRight = n.x + (nameW + SEARCH_GAP + searchW) / k
        b.fit = { w = w, nameW = nameW } -- read by CheckPopupRow one frame later
    end
    b.limit = limit

    -- "Currently selected / click to view in the list": only while it doesn't touch the search box
    local textFits = showArea and (searchRight + ROW_PAD <= w - row.area.textGap)
    if showArea then SetAreaCompact(not textFits) end

    -- "Enter macro name (max 16 characters):" stays where Blizzard put it, one line; too long = shortened
    if b.header then
        local h = b.header.el
        if not b.headerFixed then
            b.headerFixed = true
            h:SetWordWrap(false)
            h:SetJustifyH("LEFT")
            if h.SetMaxLines then h:SetMaxLines(1) end
        end
        local right = textFits and (w - row.area.textGap)
            or (showArea and (w - row.area.iconGap) or (w - ROW_RIGHT_MARGIN))
        local hx = row.headerX or b.header.x
        h:SetWidth(max(40, min(b.header.w, right - 4 - hx)))
    end

    -- icon type dropdown: the "select an icon" label gives way when there is no room beside it
    local dd = b.dropdown
    if dd then
        local right = -dd.x
        local labelEnd = b.label and (b.label.x + b.label.w + 6) or 0
        local labelFits = (w - right - labelEnd) >= dd.w
        if b.label then b.label.el:SetShown(labelFits) end
        dd.el:SetWidth(labelFits and dd.w or max(50, min(dd.w, w - right - 24)))
    end
end

-- One frame after a layout: where did the search box REALLY end up? If its right edge is past the limit
-- (or short of it while the boxes are below their full width), remember the difference and lay out again.
-- This makes the row fit even if the first measurement was off.
local function CheckPopupRow()
    local b, pf = popupBase, MacroPopupFrame
    b.checkQueued = nil
    if not (pf and pf:IsVisible() and iconSearch and iconSearch:IsVisible() and b.limit and b.fit) then return end
    local sr, pl = iconSearch:GetRight(), pf:GetLeft()
    if not (sr and pl) then return end
    local ps = pf:GetEffectiveScale()
    local realRight = sr * iconSearch:GetEffectiveScale() / ps - pl -- picker units from its left edge
    local over = realRight - b.limit
    if b.fit.w ~= b.lastCheckW then b.checks, b.lastCheckW = 0, b.fit.w end -- new width: allow new tries
    local atFull = b.fit.nameW >= b.name.w
    local atMin = b.fit.nameW <= MIN_FIELD_W
    if (over > 1 and not atMin) or (over < -1 and not atFull) then
        b.fix = max(-200, min(400, (b.fix or 0) + over))
        b.checks = (b.checks or 0) + 1
        if b.checks <= 6 then ApplyPopupLayout() end -- (at most 6 corrections per width)
    else
        b.checks = 0
    end
end

ApplyPopupLayout = function()
    local pf, mf, db = MacroPopupFrame, MacroFrame, ns.db
    if not (popupBase and pf and mf and db) then return end
    local spellbookOpen = ns.IsSpellbookOpen()

    -- width: chosen by the user, between POPUP_MIN_W and the screen
    local screen = UIParent:GetWidth() * UIParent:GetEffectiveScale() / pf:GetEffectiveScale()
    local maxW = max(popupBase.w, min(popupBase.w * 3, screen))
    local want = (not spellbookOpen) and db.popupW or nil -- default width while the spellbook is open
    local w = min(max(want or popupBase.w, POPUP_MIN_W), maxW)
    if db.popupW and not spellbookOpen then db.popupW = w end

    -- height: always the same as the macro window (plus the trim), tops lined up
    local h = mf:GetHeight() * mf:GetEffectiveScale() / pf:GetEffectiveScale() + POPUP_HEIGHT_TRIM
    h = max(MIN_POPUP_H, h)
    if popupBase.anchored then
        pf:ClearAllPoints()
        pf:SetPoint("TOPLEFT", mf, "TOPRIGHT", 0, POPUP_TOP_OFFSET)
    end

    pf:SetSize(w, h)
    local dw, dh = w - popupBase.w, h - popupBase.h
    local gridW
    for _, it in ipairs(popupBase.items) do
        if it.w > 0 and it.h > 0 then
            it.el:SetSize(max(100, it.w + dw), max(40, it.h + dh))
            if it.el == pf.IconSelector then gridW = it.w end
        end
    end

    -- more or fewer icon columns when it is wider or narrower
    local sel = pf.IconSelector
    local cols
    if sel then
        if not popupBase.cols then -- the grid may not have existed yet when we started
            popupBase.cols = ReadPopupColumns(sel)
            popupBase.lastCols = popupBase.cols
        end
        if popupBase.cols and popupBase.cols > 0 then
            gridW = (gridW and gridW > 0) and gridW or popupBase.w
            cols = max(3, floor(popupBase.cols * (gridW + dw) / gridW))
            if cols ~= popupBase.lastCols then
                popupBase.lastCols = cols
                pcall(SetGridStride, sel, cols)
            end
        end
    end

    -- top row (name box, search box, selected icon, icon type dropdown) for this width
    local ok, err = pcall(LayoutPopupRow, w, cols)
    if not ok and not popupBase.rowErr then
        popupBase.rowErr = true
        ns.Print(L["error in %s: %s"]:format("icon picker row", tostring(err)))
    end
    if PlaceIconSearch and pf:IsShown() then PlaceIconSearch() end
    if ok and not popupBase.checkQueued then
        popupBase.checkQueued = true
        C_Timer.After(0, CheckPopupRow)
    end
end
ns.ApplyPopupLayout = ApplyPopupLayout

function ns.SetupPopupSize()
    local pf = MacroPopupFrame
    if not pf or popupBase then return end
    local db = ns.db
    CapturePopup()

    local lvl = pf:GetFrameLevel()
    for _, c in ipairs({ pf:GetChildren() }) do lvl = max(lvl, c:GetFrameLevel()) end

    -- 1) a thin strip along the right edge: drag it to change only the width
    local edge = CreateFrame("Button", nil, pf)
    edge:SetWidth(8)
    edge:SetPoint("TOPRIGHT", pf, "TOPRIGHT", 0, -24)
    edge:SetPoint("BOTTOMRIGHT", pf, "BOTTOMRIGHT", 0, 24)
    edge:SetFrameLevel(lvl + 5)
    local hl = edge:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.15)

    local drag
    local function stop()
        if not drag then return end
        drag = nil
        edge:SetScript("OnUpdate", nil)
    end
    local function update()
        if not drag then return end
        if not IsMouseButtonDown("LeftButton") then
            stop()
            return
        end
        local cx = GetCursorPosition()
        if cx == drag.lastX then return end -- mouse hasn't moved sideways
        drag.lastX = cx
        db.popupW = drag.w + (cx - drag.x) / pf:GetEffectiveScale()
        ApplyPopupLayout() -- clamps db.popupW
    end
    edge:SetScript("OnMouseDown", function(self, button)
        if db.locked or button ~= "LeftButton" then return end
        local cx = GetCursorPosition()
        drag = { x = cx, w = pf:GetWidth() }
        self:SetScript("OnUpdate", update)
    end)
    edge:SetScript("OnMouseUp", stop)
    edge:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L["Drag to change the width of the icon picker"])
        GameTooltip:Show()
        ns.SolidTooltip()
    end)
    edge:SetScript("OnLeave", GameTooltip_Hide)

    -- 2) a grip in the lower right corner: sideways = picker width, up/down = height of BOTH windows
    local grip = CreateFrame("Button", nil, pf)
    grip:SetSize(14, 14)
    grip:SetPoint("BOTTOMRIGHT", pf, "BOTTOMRIGHT", 0, 2)
    grip:SetFrameLevel(lvl + 10)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")

    local gdrag
    local function gstop()
        if not gdrag then return end
        gdrag = nil
        MacroFrame.xmwMoving = nil
        grip:SetScript("OnUpdate", nil)
        ns.SaveWindowSize() -- Window.lua
    end
    local function gupdate()
        local d = gdrag
        if not d then return end
        if not IsMouseButtonDown("LeftButton") then
            gstop()
            return
        end
        local cx, cy = GetCursorPosition()
        if cx == d.lastX and cy == d.lastY then return end -- mouse hasn't moved
        d.lastX, d.lastY = cx, cy
        db.popupW = d.pw + (cx - d.x) / pf:GetEffectiveScale()
        local _, h = ns.ClampSize(d.mw, d.mh + (d.y - cy) / MacroFrame:GetEffectiveScale())
        MacroFrame:SetSize(d.mw, h) -- the size hook moves the picker's height along
        MacroFrame:ClearAllPoints() -- keep the macro window's top-left corner where it was
        MacroFrame:SetPoint(d.p, d.rel, d.rp, d.ox, d.oy - d.vf * (h - d.mh))
        ApplyPopupLayout()
    end
    grip:SetScript("OnMouseDown", function(self, button)
        if db.locked or button ~= "LeftButton" then return end
        local p, rel, rp, ox, oy = MacroFrame:GetPoint()
        if not p then return end
        local cx, cy = GetCursorPosition()
        gdrag = {
            x = cx, y = cy, pw = pf:GetWidth(), mw = MacroFrame:GetWidth(), mh = MacroFrame:GetHeight(),
            p = p, rel = rel, rp = rp, ox = ox, oy = oy,
            vf = p:find("TOP") and 0 or (p:find("BOTTOM") and 1 or 0.5),
        }
        MacroFrame.xmwMoving = true
        self:SetScript("OnUpdate", gupdate)
    end)
    grip:SetScript("OnMouseUp", gstop)
    grip:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L["Drag sideways: icon picker width"])
        GameTooltip:AddLine(L["Drag up/down: height of both windows"], 0.8, 0.8, 0.8)
        GameTooltip:Show()
        ns.SolidTooltip()
    end)
    grip:SetScript("OnLeave", GameTooltip_Hide)

    ns.lockFrames[#ns.lockFrames + 1] = edge
    ns.lockFrames[#ns.lockFrames + 1] = grip

    pf:HookScript("OnHide", function() stop(); gstop() end)
    pf:HookScript("OnShow", function()
        ApplyPopupLayout()
        C_Timer.After(0, ApplyPopupLayout) -- again after Blizzard has finished setting the picker up
    end)
    -- height follows the macro window (a hidden picker is laid out again when it opens)
    MacroFrame:HookScript("OnSizeChanged", function()
        if pf:IsShown() then ApplyPopupLayout() end
    end)
    ns.UpdateLock()
    ApplyPopupLayout()
end
