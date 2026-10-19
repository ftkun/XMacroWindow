local addonName, ns = ...

------------------------------------------------------------------------
-- Options window (/xmw opt, or the Options button on the macro window)
------------------------------------------------------------------------
local L = ns.L
local _G = _G
local ipairs, floor, min, max = ipairs, math.floor, math.min, math.max
local CreateFrame = CreateFrame

local options
local updatingUI -- true while the window fills in its controls (no saving then)

-- a child of a template frame: newer templates use keys (s.Text), older ones global names (MySliderText)
local function Sub(frame, key)
    return frame[key] or _G[frame:GetName() .. key]
end

local function MakeSlider(parent, name, y, minv, maxv, step, low, high)
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetPoint("TOP", 0, y)
    s:SetWidth(240)
    s:SetMinMaxValues(minv, maxv)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)
    s:EnableMouseWheel(true)
    s:SetScript("OnMouseWheel", function(self, delta)
        local lo, hi = self:GetMinMaxValues()
        self:SetValue(min(hi, max(lo, self:GetValue() + delta * step)))
    end)
    Sub(s, "Low"):SetText(low)
    Sub(s, "High"):SetText(high)
    return s
end

-- set a slider without saving anything, but with its label refreshed
local function SetSliderValue(s, v)
    updatingUI = true
    s:SetValue(v)
    local handler = s:GetScript("OnValueChanged")
    if handler then handler(s, s:GetValue()) end
    updatingUI = false
end

local function MakeCheck(parent, name, y, text, onClick)
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 16, y)
    Sub(cb, "Text"):SetText(text)
    cb:SetScript("OnClick", onClick)
    return cb
end

local function MakeButton(parent, w, text, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 24)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function CreateOptions()
    local db = ns.db
    local f = CreateFrame("Frame", "XMWOptions", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(300, 400)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self:SetUserPlaced(false) -- don't let WoW remember the spot
    end)
    if f.TitleText then f.TitleText:SetText(L["XMacro Window options"]) end
    tinsert(UISpecialFrames, "XMWOptions") -- Esc closes it

    -- Window scale
    local scale = MakeSlider(f, "XMWScaleSlider", -62, 0.5, 2, 0.05, "0.5", "2.0")
    scale:SetScript("OnValueChanged", function(self, v)
        v = floor(v * 20 + 0.5) / 20
        Sub(self, "Text"):SetText(L["Window scale: %.2f"]:format(v))
        if updatingUI then return end
        db.scale = v
        ns.Apply()
    end)
    f.scale = scale

    -- Font size
    local fsize = MakeSlider(f, "XMWFontSizeSlider", -112, 5, 35, 1, "5", "35")
    fsize:SetScript("OnValueChanged", function(self, v)
        v = floor(v + 0.5)
        Sub(self, "Text"):SetText(L["Macro font size: %d"]:format(v))
        if updatingUI then return end
        db.fontSize = v
        ns.ApplyEditor()
    end)
    f.fontSize = fsize

    -- Font face
    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", 22, -140)
    label:SetText(L["Macro font"])

    local dd = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    dd:SetPoint("TOPLEFT", 18, -158)
    dd:SetWidth(250)
    dd:SetupMenu(function(_, root)
        root:SetScrollMode(360)
        root:CreateRadio(L["Stock macro font"],
            function() return db.fontPath == nil end,
            function() db.fontPath = nil; ns.ApplyEditor() end)
        for _, entry in ipairs(ns.GetFontList()) do
            local name, path = entry[1], entry[2]
            local lpath = path:lower()
            root:CreateRadio(name,
                function() return db.fontPath and db.fontPath:lower() == lpath end,
                function() db.fontPath = path; ns.ApplyEditor() end)
        end
    end)
    f.dropdown = dd

    -- Colors toggle
    f.colors = MakeCheck(f, "XMWColorCheck", -198, L["Color-coded macro code"], function(self)
        db.colors = self:GetChecked() and true or false
        ns.RefreshEditor()
        ns.RefreshCopy() -- the copy window colors its text too
    end)

    -- Color theme
    local plabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    plabel:SetPoint("TOPLEFT", 22, -230)
    plabel:SetText(L["Color theme"])

    local pdd = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    pdd:SetPoint("TOPLEFT", 18, -248)
    pdd:SetWidth(250)
    pdd:SetupMenu(function(_, root)
        for _, name in ipairs(ns.PRESET_ORDER) do
            root:CreateRadio(name,
                function() return db.preset == name end,
                function()
                    db.preset = name
                    ns.ApplyPreset(name)
                    ns.RefreshEditor()
                    ns.RefreshCopy()
                end)
        end
    end)
    f.presets = pdd

    -- Lock window
    f.lock = MakeCheck(f, "XMWLockCheck", -280, L["Lock window (no moving or resizing)"], function(self)
        db.locked = self:GetChecked() and true or false
        ns.UpdateLock()
    end)

    -- Reset position / size / font
    MakeButton(f, 160, L["Reset window position"], function() ns.ResetPosition() end)
        :SetPoint("BOTTOM", 0, 64)
    MakeButton(f, 120, L["Reset size"], function() ns.ResetSize() end)
        :SetPoint("BOTTOMRIGHT", -24, 34)
    MakeButton(f, 120, L["Reset font"], function()
        db.fontPath, db.fontSize = ns.DefaultFontPath(), nil
        ns.ApplyEditor()
        SetSliderValue(f.fontSize, ns.CurrentFontSize())
        dd:GenerateMenu()
    end):SetPoint("BOTTOMLEFT", 24, 34)

    -- Version (read from the .toc)
    local info = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    info:SetPoint("BOTTOM", 0, 10)
    info:SetText(("XMacro Window v%s"):format(C_AddOns.GetAddOnMetadata(addonName, "Version") or "?"))

    -- fill in the controls from the saved settings every time it opens
    f:SetScript("OnShow", function(self)
        SetSliderValue(self.scale, db.scale)
        SetSliderValue(self.fontSize, ns.CurrentFontSize())
        self.colors:SetChecked(db.colors)
        self.lock:SetChecked(db.locked)
        self.presets:GenerateMenu()
        self.dropdown:GenerateMenu()
    end)

    f:Hide() -- so the first Show() fires OnShow and fills in the controls
    options = f
end

function ns.ToggleOptions()
    if options and options:IsShown() then
        options:Hide()
        return
    end
    if not options then CreateOptions() end
    -- always open in the middle of the screen (it can be dragged, but never gets lost off-screen)
    options:ClearAllPoints()
    options:SetPoint("CENTER")
    options:Show()
end
