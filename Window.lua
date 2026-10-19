local addonName, ns = ...

------------------------------------------------------------------------
-- Macro window: scale, position, size, layout, resize grip, title bar buttons
------------------------------------------------------------------------
local L = ns.L
local _G = _G
local ipairs, pairs, pcall, unpack, tonumber, type = ipairs, pairs, pcall, unpack, tonumber, type
local min, max, floor, ceil = math.min, math.max, math.floor, math.ceil
local CreateFrame, C_Timer, InCombatLockdown, GameTooltip = CreateFrame, C_Timer, InCombatLockdown, GameTooltip
local GetCursorPosition, IsMouseButtonDown = GetCursorPosition, IsMouseButtonDown

local origSize      -- { w, h } of the stock window, measured before we touch it
local shrinkRoom    -- how much shorter than stock the window may get (CaptureLayout)
local spellbookOpen -- the spellbook / talents panel is open: the macro window sits left of it
local ApplyLayout   -- defined in the layout section

-- frames hidden while the window is locked (grip, divider; IconPicker.lua adds its own)
ns.lockFrames = {}

function ns.UpdateLock()
    local locked = ns.db.locked
    for _, fr in ipairs(ns.lockFrames) do fr:SetShown(not locked) end
end

function ns.IsSpellbookOpen() return spellbookOpen end

-- never narrower than stock; may be shorter than stock (the macro list and the text field give up
-- the room); never bigger than 3x stock or the screen
local function ClampSize(w, h)
    local f = MacroFrame
    if not (origSize and f) then return w, h end
    local s = f:GetScale() or 1
    local maxW = max(origSize.w, min(origSize.w * 3, UIParent:GetWidth() / s))
    local maxH = max(origSize.h, min(origSize.h * 3, UIParent:GetHeight() / s))
    local minH = origSize.h - (shrinkRoom or 0)
    return min(max(w, origSize.w), maxW), min(max(h, minH), maxH)
end
ns.ClampSize = ClampSize

------------------------------------------------------------------------
-- Position (+ spellbook side by side)
------------------------------------------------------------------------
-- The spellbook (and talents) open on the left. While one is open the macro window takes Blizzard's
-- far-left default slot (default width, own height) and the spellbook is moved to its right. Both go
-- back when the spellbook or the macro window closes.
local SPELLBOOK_FRAMES = { "PlayerSpellsFrame", "SpellBookFrame" }
local SPELLBOOK_GAP = 0 -- extra pixels between the macro window and the spellbook

local function OpenSpellbookFrame()
    for _, name in ipairs(SPELLBOOK_FRAMES) do
        local sb = _G[name]
        if sb and sb:IsShown() then return sb end
    end
end

local function IsSpellbookFrame(rel)
    if not rel then return false end
    for _, name in ipairs(SPELLBOOK_FRAMES) do
        if rel == _G[name] then return true end
    end
    return false
end

-- Blizzard's own panel spot: UIParent's panel offsets plus the frame's offsets from UIPanelWindows
local function PanelOffsets(fr)
    local left = tonumber(UIParent:GetAttribute("LEFT_OFFSET")) or 16
    local top = tonumber(UIParent:GetAttribute("TOP_OFFSET")) or -116
    local info = UIPanelWindows and UIPanelWindows[fr:GetName() or ""]
    local xo = (type(info) == "table" and tonumber(info.xoffset)) or 0
    local yo = (type(info) == "table" and tonumber(info.yoffset)) or 0
    return left + xo, top + yo
end

-- can we move it right now? (a protected frame can't be moved in combat)
local function CanMove(fr)
    return not (InCombatLockdown() and fr:IsProtected())
end

-- Something we couldn't move in combat is done once combat ends. The event is only registered
-- while such a move is pending.
local regen = CreateFrame("Frame")
local function RetryAfterCombat()
    regen:RegisterEvent("PLAYER_REGEN_ENABLED")
end

local sbSaved = {} -- [spellbook frame] = its own anchor points from before we moved it

local function RestoreSpellbook()
    for fr, pts in pairs(sbSaved) do
        if CanMove(fr) then
            if #pts > 0 then
                fr:ClearAllPoints()
                for _, p in ipairs(pts) do pcall(fr.SetPoint, fr, unpack(p)) end
            end
            sbSaved[fr] = nil
        else
            RetryAfterCombat()
        end
    end
end

local function PlaceSideBySide(f, sb)
    if not (CanMove(f) and CanMove(sb)) then
        RetryAfterCombat()
        return
    end
    -- macro window: the far-left default slot
    local mx, my = PanelOffsets(f)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", mx, my)
    -- spellbook: right after the macro window (in screen pixels, then in the spellbook's own units)
    if not sbSaved[sb] then
        local pts = {}
        for i = 1, sb:GetNumPoints() do pts[i] = { sb:GetPoint(i) } end
        sbSaved[sb] = pts
    end
    local fs, ss = f:GetEffectiveScale(), sb:GetEffectiveScale()
    local rightPx = (mx + f:GetWidth()) * fs + SPELLBOOK_GAP * fs
    local _, sy = PanelOffsets(sb)
    sb:ClearAllPoints()
    sb:SetPoint("TOPLEFT", UIParent, "TOPLEFT", rightPx / ss, sy)
end

local function ApplyPosition()
    local f, db = MacroFrame, ns.db
    if not f or not db or f.xmwMoving then return end

    local sb = spellbookOpen and OpenSpellbookFrame()
    if sb then
        PlaceSideBySide(f, sb)
        return
    end
    RestoreSpellbook()

    if db.point then
        f:ClearAllPoints()
        f:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
    else
        -- never moved by the user: don't stay glued to a closed spellbook, Blizzard places it from here
        local _, rel = f:GetPoint(1)
        if IsSpellbookFrame(rel) then
            local l, t = f:GetLeft(), f:GetTop()
            f:ClearAllPoints()
            if l and t then f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t) end
        end
    end
end

regen:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_REGEN_ENABLED")
    if MacroFrame and MacroFrame:IsShown() then ApplyPosition() else RestoreSpellbook() end
end)

-- scale, saved size and position (on every OnShow and after option changes)
local function Apply()
    local f, db = MacroFrame, ns.db
    if not f or not db then return end
    f:SetScale(db.scale)
    -- while the spellbook is open: default width, own height
    local wantW = db.width
    if spellbookOpen and origSize then wantW = origSize.w end
    local wantH = db.height or (origSize and f:GetHeight())
    if wantW and wantH then f:SetSize(ClampSize(wantW, wantH)) end
    ApplyLayout()
    ApplyPosition()
end
ns.Apply = Apply

-- forget the saved spot and put the macro window back in Blizzard's default slot
local function ResetPosition()
    local db = ns.db
    db.point, db.relPoint, db.x, db.y = nil, nil, nil, nil
    local f = MacroFrame
    if not (f and f:IsShown()) then return end
    if spellbookOpen then ApplyPosition() return end -- side-by-side slot is already the default
    if not CanMove(f) then
        ns.Print(L["can't move the macro window in combat; it resets next time you open it"])
        return
    end
    local x, y = PanelOffsets(f)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, y)
end
ns.ResetPosition = ResetPosition

-- /xmw reset position: every addon window back to the spot it opens at by default
-- (the icon picker follows the macro window)
function ns.ResetAllPositions()
    ResetPosition()
    local function back(name, x, y)
        local fr = _G[name]
        if not fr then return end -- not created yet: it opens at its default spot anyway
        fr:ClearAllPoints()
        fr:SetPoint("CENTER", UIParent, "CENTER", x, y)
        fr:SetUserPlaced(false) -- forget any spot WoW remembered
    end
    back("XMWOptions", 0, 0)
    back("XMWBrowser", 0, 0)
    back("XMWCopy", 0, 40)
    ns.Print(L["window positions reset"])
end

local function SpellbookUpdate()
    local open = OpenSpellbookFrame() ~= nil
    if open == (spellbookOpen or false) then return end
    spellbookOpen = open
    local function refresh()
        if MacroFrame and MacroFrame:IsShown() then
            Apply()
            if ns.ApplyPopupLayout then ns.ApplyPopupLayout() end
        end
    end
    refresh()
    C_Timer.After(0, refresh) -- again once Blizzard has finished arranging the panels
end

-- called at login and whenever a spellbook addon loads (the frames are load-on-demand)
function ns.HookSpellbookFrames()
    for _, name in ipairs(SPELLBOOK_FRAMES) do
        local f = _G[name]
        if f and not f.xmwSpellbookHooked then
            f.xmwSpellbookHooked = true
            f:HookScript("OnShow", SpellbookUpdate)
            f:HookScript("OnHide", SpellbookUpdate)
        end
    end
    SpellbookUpdate()
end

-- Blizzard's panel manager puts the macro window back to its default spot whenever panels are
-- re-arranged (for example when the icon picker opens), so put it back where the user left it.
function ns.InstallPositionHook()
    if _G.UpdateUIPanelPositions then
        hooksecurefunc("UpdateUIPanelPositions", function()
            if MacroFrame and MacroFrame:IsShown() then ApplyPosition() end
        end)
    end
    local pf = _G.MacroPopupFrame
    if pf then
        pf:HookScript("OnShow", function() C_Timer.After(0, ApplyPosition) end)
        pf:HookScript("OnHide", function() C_Timer.After(0, ApplyPosition) end)
    end
end

------------------------------------------------------------------------
-- Layout inside the window
------------------------------------------------------------------------
-- The stock window only knows one size. When it is resized:
--  * everything gets wider; the macro list reflows into more columns
--  * extra window height goes to the macro text field
--  * the divider under the macro list can be dragged down: the list gets taller,
--    the editor below moves down and the text field gets shorter
local BASE_COLS = 6     -- stock icon columns (read from the list when possible)
local MIN_TEXT_H = 40   -- the text field never gets shorter than this
local PARTS = {
    -- name,                                wider, text height, moves with the divider
    { "MacroFrameScrollFrame",              true,  true,  false },
    { "MacroFrameTextButton",               true,  true,  false }, -- invisible click area over the text field
    { "MacroFrameTextBackground",           true,  true,  true  },
    { "MacroHorizontalBarLeft",             true,  false, true  },
    { "MacroHorizontalBarRight",            true,  false, true  },
    { "MacroFrameSelectedMacroBackground",  false, false, true  },
}

local layout          -- { el, pts, w, h, wider, text, moves, list } per part, stock values
local listItem, listW, listH, lastCols, textItem, lastSplit
local grip, divider

local function CaptureLayout()
    local f = MacroFrame
    layout = {}
    local seen = {}
    local function add(el, wider, text, moves, isList)
        if el and not seen[el] then
            seen[el] = true
            local pts = {}
            for i = 1, el:GetNumPoints() do
                local p, rel, rp, x, y = el:GetPoint(i)
                pts[i] = { p, rel, rp, x or 0, y or 0 }
            end
            local it = {
                el = el, pts = pts, w = el:GetWidth() or 0, h = el:GetHeight() or 0,
                wider = wider, text = text, moves = moves, list = isList,
            }
            layout[#layout + 1] = it
            return it
        end
    end

    listItem = f.MacroSelector
    add(listItem, true, false, false, true)
    listW = listItem and listItem:GetWidth() or 0
    listH = listItem and listItem:GetHeight() or 0
    local sb0 = listItem and listItem.ScrollBox
    local view0 = sb0 and sb0.GetView and sb0:GetView()
    if view0 and view0.GetStride then BASE_COLS = view0:GetStride() or BASE_COLS end
    for _, e in ipairs(PARTS) do
        local it = add(_G[e[1]], e[2], e[3], e[4])
        if it and e[1] == "MacroFrameScrollFrame" then textItem = it end
    end
    -- how much shorter than stock the window can get: the list down to one row, the text field down to MIN_TEXT_H
    shrinkRoom = 0
    if listH > 0 then shrinkRoom = shrinkRoom + (listH - ceil(listH / 3)) end
    if textItem and textItem.h > MIN_TEXT_H then shrinkRoom = shrinkRoom + (textItem.h - MIN_TEXT_H) end

    -- keep the text box as wide as its scroll frame
    local sf, tx = _G.MacroFrameScrollFrame, _G.MacroFrameText
    if sf and tx then
        local d0 = 20
        local sw, tw = sf:GetWidth(), tx:GetWidth()
        if sw > 0 and tw > 0 and sw >= tw then d0 = sw - tw end
        sf:HookScript("OnSizeChanged", function(_, w)
            if w and w > 0 then tx:SetWidth(max(1, w - d0)) end
        end)
    end
end

-- number of icon columns in the macro list (the ScrollBox view or the selector, depending on build)
local function SetListStride(sel, cols)
    local sb = sel and sel.ScrollBox
    local view = sb and sb.GetView and sb:GetView()
    if view and view.SetStride then
        view:SetStride(cols)
        if sb.FullUpdate then sb:FullUpdate(ScrollBoxConstants.UpdateImmediately) end
    elseif sel and sel.SetCustomStride then
        sel:SetCustomStride(cols)
    end
end

ApplyLayout = function()
    local f, db = MacroFrame, ns.db
    if not (layout and f and origSize and db) then return end
    local dw = max(0, f:GetWidth() - origSize.w)
    local dh = f:GetHeight() - origSize.h -- negative when the window is shorter than stock

    -- how far the divider may go down: the text field keeps at least MIN_TEXT_H
    local splitMax = dh
    if textItem and textItem.h > 0 then splitMax = dh + max(0, textItem.h - MIN_TEXT_H) end
    -- ... and how far up: the list keeps at least one row (the stock list shows three)
    local splitMin = 0
    if listH > 0 then splitMin = -(listH - ceil(listH / 3)) end
    -- (a shorter window pushes the divider up as far as needed; the saved preference is kept for when it grows again)
    local split = min(max(db.split or 0, splitMin), splitMax)
    lastSplit = split

    for _, it in ipairs(layout) do
        local el = it.el
        if it.moves then
            -- parts hanging from the top of the window move down with the divider;
            -- parts anchored to other parts follow them by themselves
            el:ClearAllPoints()
            for _, p in ipairs(it.pts) do
                local y = p[5]
                if p[1]:find("^TOP") and (p[2] == f or p[2] == nil) then y = y - split end
                pcall(el.SetPoint, el, p[1], p[2], p[3], p[4], y)
            end
        end
        if #it.pts == 1 and it.w > 0 and it.h > 0 then
            local h = it.h
            if it.list then
                h = h + split
            elseif it.text then
                h = h + dh - split
            end
            el:SetSize(it.w + (it.wider and dw or 0), h)
        end
    end
    if divider then divider:SetWidth(max(1, f:GetWidth() - 12)) end

    -- reflow the macro icons: as many columns as fit the new width
    if listItem and listW > 0 then
        local cols = max(BASE_COLS, floor(BASE_COLS * (listW + dw) / listW))
        if cols ~= lastCols then
            lastCols = cols
            pcall(SetListStride, listItem, cols)
        end
    end
end

-- Reset size button (options): stock size, divider and picker width
function ns.ResetSize()
    local db = ns.db
    db.width, db.height, db.split, db.popupW = nil, nil, nil, nil
    if MacroFrame and origSize then MacroFrame:SetSize(origSize.w, origSize.h) end
    ApplyLayout()
    if ns.ApplyPopupLayout then ns.ApplyPopupLayout() end
end

-- remember the size (and spot) after a resize; used by the window grip and the icon picker grip
function ns.SaveWindowSize()
    local f, db = MacroFrame, ns.db
    if spellbookOpen then
        -- width and spot are only borrowed while the spellbook is open: keep just the height
        db.width = db.width or origSize.w
        db.height = f:GetHeight()
        return
    end
    db.width, db.height = f:GetWidth(), f:GetHeight()
    local point, _, relPoint, x, y = f:GetPoint()
    if point then db.point, db.relPoint, db.x, db.y = point, relPoint, x, y end
end

-- the strip over the separator under the macro list: drag it up (smaller list) or down (bigger list)
local function SetupDivider(f)
    local bar = _G.MacroHorizontalBarLeft
    if divider or not bar then return end
    local db = ns.db
    divider = CreateFrame("Button", nil, f)
    divider:SetHeight(12)
    divider:SetWidth(max(1, f:GetWidth() - 12))
    divider:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
    divider:SetFrameLevel(f:GetFrameLevel() + 15)
    local hl = divider:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.12)

    local drag
    local function stop()
        if not drag then return end
        drag = nil
        divider:SetScript("OnUpdate", nil)
    end
    local function update()
        if not drag then return end
        if not IsMouseButtonDown("LeftButton") then
            stop()
            return
        end
        local _, cy = GetCursorPosition()
        if cy == drag.lastY then return end -- mouse hasn't moved: nothing to redo this frame
        drag.lastY = cy
        db.split = drag.split + (drag.y - cy) / f:GetEffectiveScale()
        ApplyLayout()
        db.split = lastSplit -- what actually fits, so dragging past a limit doesn't "wind up"
    end
    divider:SetScript("OnMouseDown", function(self, button)
        if db.locked or button ~= "LeftButton" then return end
        local _, cy = GetCursorPosition()
        drag = { y = cy, split = db.split or 0 }
        self:SetScript("OnUpdate", update)
    end)
    divider:SetScript("OnMouseUp", stop)
    divider:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L["Drag up or down to resize the macro list"])
        GameTooltip:Show()
        ns.SolidTooltip()
    end)
    divider:SetScript("OnLeave", GameTooltip_Hide)
    f:HookScript("OnHide", stop)
    ns.lockFrames[#ns.lockFrames + 1] = divider
end

-- the corner grip; also measures the stock layout, so it runs before anything is resized
function ns.SetupGrip(f)
    if grip then return end
    local db = ns.db
    origSize = { w = f:GetWidth(), h = f:GetHeight() }
    CaptureLayout()
    f:HookScript("OnSizeChanged", function() ApplyLayout() end)

    grip = CreateFrame("Button", nil, f)
    grip:SetSize(14, 14)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 5, -6)
    grip:SetFrameLevel(f:GetFrameLevel() + 20)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    ns.lockFrames[#ns.lockFrames + 1] = grip

    -- We do the sizing ourselves instead of using the engine's StartSizing: the window size is
    -- "size when you pressed the button + how far the mouse moved since", so it can't jump, and
    -- it stops as soon as the button is up (even if the release happened away from the grip).
    local sizing

    local function StopSizing()
        if not sizing then return end
        sizing = nil
        f.xmwMoving = nil
        grip:SetScript("OnUpdate", nil)
        ns.SaveWindowSize()
    end

    local function OnUpdate()
        local d = sizing
        if not d then return end
        if not IsMouseButtonDown("LeftButton") then
            StopSizing()
            return
        end
        local cx, cy = GetCursorPosition()
        if cx == d.lastX and cy == d.lastY then return end -- mouse hasn't moved
        d.lastX, d.lastY = cx, cy
        local scale = f:GetEffectiveScale()
        local newW = spellbookOpen and d.w or (d.w + (cx - d.x) / scale) -- width is fixed while the spellbook is open
        local w, h = ClampSize(newW, d.h + (d.y - cy) / scale)
        f:SetSize(w, h)
        -- keep the top-left corner where it was, whatever the frame is anchored to
        f:ClearAllPoints()
        f:SetPoint(d.p, d.rel, d.rp, d.ox + d.hf * (w - d.w), d.oy - d.vf * (h - d.h))
    end

    grip:SetScript("OnMouseDown", function(self, button)
        if db.locked or button ~= "LeftButton" then return end
        local p, rel, rp, ox, oy = f:GetPoint()
        if not p then return end
        local cx, cy = GetCursorPosition()
        sizing = {
            x = cx, y = cy, w = f:GetWidth(), h = f:GetHeight(),
            p = p, rel = rel, rp = rp, ox = ox, oy = oy,
            -- how much the anchor moves per pixel of growth, so the top-left corner stays put
            hf = p:find("LEFT") and 0 or (p:find("RIGHT") and 1 or 0.5),
            vf = p:find("TOP") and 0 or (p:find("BOTTOM") and 1 or 0.5),
        }
        f.xmwMoving = true -- (ApplyPosition leaves the window alone meanwhile)
        self:SetScript("OnUpdate", OnUpdate)
    end)
    grip:SetScript("OnMouseUp", StopSizing)
    f:HookScript("OnHide", StopSizing)
    ns.Safe("list divider", SetupDivider, f)
    ns.UpdateLock()
    ApplyLayout()
end

------------------------------------------------------------------------
-- Moving the window + title bar buttons (Options, ALL)
------------------------------------------------------------------------
function ns.SetupWindow(f)
    local db = ns.db
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if db.locked then return end
        self.xmwMoving = true
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self.xmwMoving = nil
        self:SetUserPlaced(false) -- we save the spot ourselves
        if db.locked then return end
        if spellbookOpen then
            ApplyPosition() -- back to the far-left slot; nothing is saved
            return
        end
        local point, _, relPoint, x, y = self:GetPoint()
        db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
    end)
    f:HookScript("OnShow", Apply)
    f:HookScript("OnHide", RestoreSpellbook) -- the spellbook goes back to its own spot

    local opt = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    opt:SetSize(62, 20)
    opt:SetText(L["Options"])
    opt:SetScript("OnClick", function() ns.ToggleOptions() end)

    local browse = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    browse:SetSize(36, 20)
    browse:SetText(L["ALL"])
    browse:SetScript("OnClick", function() ns.ToggleBrowser() end)
    browse:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(L["Macros of all characters"])
        GameTooltip:AddLine(L["Browse, search, copy and restore deleted macros"], 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
        ns.SolidTooltip()
    end)
    browse:SetScript("OnLeave", GameTooltip_Hide)

    local search = ns.listSearchBox -- MacroList.lua
    local close = f.CloseButton or _G.MacroFrameCloseButton
    local function PlaceButtons()
        -- sit above everything the frame template put into the title bar
        local lvl = f:GetFrameLevel()
        for _, c in ipairs({ f:GetChildren() }) do
            if c ~= opt and c ~= browse and c ~= grip then
                lvl = max(lvl, c:GetFrameLevel())
                for _, gc in ipairs({ c:GetChildren() }) do
                    lvl = max(lvl, gc:GetFrameLevel())
                end
            end
        end
        opt:SetFrameLevel(lvl + 1)
        browse:SetFrameLevel(lvl + 1)
        browse:ClearAllPoints()
        opt:ClearAllPoints()
        if close and close:IsShown() then
            browse:SetPoint("RIGHT", close, "LEFT", -2, 0)
        else
            browse:SetPoint("TOPRIGHT", f, "TOPRIGHT", -36, -6)
        end
        opt:SetPoint("RIGHT", browse, "LEFT", -2, 0)
        if search then
            search:SetFrameLevel(lvl + 1)
            search:ClearAllPoints()
            search:SetPoint("TOPLEFT", f, "TOPLEFT", 56, -1) -- right next to the round portrait
        end
    end
    PlaceButtons()
    f:HookScript("OnShow", PlaceButtons)
end
