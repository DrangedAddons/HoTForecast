-- HoTForecast settings window: /hotf, the minimap button, or Options > AddOns.

local ADDON, HF = ...

local ICON = "Interface\\AddOns\\HoTForecast\\icon"
HF.ICON = ICON

local frame
local refreshers = {}

local function Track(w)
    refreshers[#refreshers + 1] = w
    return w
end

function HF.RefreshConfig()
    if not frame then return end
    for _, w in ipairs(refreshers) do w:Refresh() end
end

------------------------------------------------------------------------------
-- Widgets
------------------------------------------------------------------------------

local function Text(parent, text, template)
    local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlight")
    fs:SetText(text)
    return fs
end

local function Button(parent, text, w, h, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function Tip(widget, text)
    if not text then return end
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", GameTooltip_Hide)
end

-- get() returns the current state, set(on) stores it.
local function Check(parent, label, get, set, x, y, tip)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", x, y)
    local fs = Text(parent, label)
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    Tip(cb, tip)
    function cb:Refresh() self:SetChecked(get() and true or false) end
    return Track(cb)
end

-- One choice of a pair: get() says whether it's the selected one.
local function Radio(parent, label, get, pick, x, y, tip)
    local rb = CreateFrame("CheckButton", nil, parent, "UIRadioButtonTemplate")
    rb:SetSize(18, 18)
    rb:SetPoint("TOPLEFT", x + 3, y - 3)
    local fs = Text(parent, label)
    fs:SetPoint("LEFT", rb, "RIGHT", 4, 0)
    rb:SetScript("OnClick", function() pick() end)
    Tip(rb, tip)
    function rb:Refresh() self:SetChecked(get() and true or false) end
    return Track(rb)
end

local function Round(v, step)
    return math.floor(v / step + 0.5) * step
end

-- Slider with a typed-value box.
local function Slider(parent, label, get, set, min, max, step, x, y)
    local s = CreateFrame("Slider", nil, parent, "BackdropTemplate")
    s:SetOrientation("HORIZONTAL")
    s:SetSize(150, 16)
    s:SetPoint("TOPLEFT", x, y - 16)
    s:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    s:SetMinMaxValues(min, max)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)

    local title = Text(s, label, "GameFontNormalSmall")
    title:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 2)

    local box = CreateFrame("EditBox", nil, s, "InputBoxTemplate")
    box:SetSize(40, 18)
    box:SetPoint("LEFT", s, "RIGHT", 12, 0)
    box:SetAutoFocus(false)
    box:SetJustifyH("CENTER")

    s:SetScript("OnValueChanged", function(_, v, userInput)
        if not userInput then return end
        v = Round(v, step)
        set(v)
        box:SetText(tostring(v))
    end)
    box:SetScript("OnEnterPressed", function(self)
        local v = tonumber(self:GetText())
        if v then set(Round(math.max(min, math.min(max, v)), step)) end
        self:ClearFocus()
        s:Refresh()
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        s:Refresh()
    end)

    function s:Refresh()
        local v = get()
        self:SetValue(v)
        box:SetText(tostring(v))
    end
    return Track(s)
end

local function PickColor(c, onChange)
    local r, g, b = c.r, c.g, c.b
    local function Changed()
        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
        onChange({ r = nr, g = ng, b = nb })
    end
    local function Cancel() onChange({ r = r, g = g, b = b }) end
    if ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow({
            r = r, g = g, b = b, hasOpacity = false,
            swatchFunc = Changed, cancelFunc = Cancel,
        })
    else
        ColorPickerFrame.func, ColorPickerFrame.cancelFunc = Changed, Cancel
        ColorPickerFrame.hasOpacity = false
        ColorPickerFrame.previousValues = { r, g, b }
        ColorPickerFrame:SetColorRGB(r, g, b)
        ColorPickerFrame:Hide()
        ColorPickerFrame:Show()
    end
end

local function ColorSwatch(parent, label, x, y)
    local sw = CreateFrame("Button", nil, parent, "BackdropTemplate")
    sw:SetSize(20, 20)
    sw:SetPoint("TOPLEFT", x + 2, y)
    sw:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    sw:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    local fs = Text(parent, label)
    fs:SetPoint("LEFT", sw, "RIGHT", 8, 0)
    function sw:Refresh()
        local c = HF.db.color
        self:SetBackdropColor(c.r, c.g, c.b, 1)
    end
    sw:SetScript("OnClick", function(self)
        PickColor(HF.db.color, function(c)
            HF.SetColor(c)
            self:Refresh()
        end)
    end)
    return Track(sw)
end

------------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------------

local function Build()
    local db = HF.db
    frame = CreateFrame("Frame", "HoTForecastConfig", UIParent, "BackdropTemplate")
    frame:SetSize(520, 440)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    tinsert(UISpecialFrames, "HoTForecastConfig")

    local title = Text(frame, "HoTForecast", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18)
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetTexture(ICON)
    icon:SetPoint("RIGHT", title, "LEFT", -6, 0)
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local version = Text(frame, "v" .. (getMeta and getMeta(ADDON, "Version") or "?"), "GameFontDisableSmall")
    version:SetPoint("TOPLEFT", 20, -20)
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    -- Left column: general and look.
    local L = 24
    Text(frame, "General", "GameFontNormal"):SetPoint("TOPLEFT", L, -50)
    Check(frame, "Show HoT forecasts", function() return db.enabled end, HF.SetEnabled, L, -68)
    Check(frame, "Flash when a tick lands", function() return db.flash end, HF.SetFlash, L, -94)
    Check(frame, "Send your HoTs to the group", function() return db.share end, HF.SetShare, L, -120,
        "Group members who run HoTForecast see your HoTs on their frames.")

    Text(frame, "Show HoTs from", "GameFontNormal"):SetPoint("TOPLEFT", L, -156)
    Radio(frame, "Everyone", function() return db.showOthers end,
        function() HF.SetShowOthers(true) HF.RefreshConfig() end, L, -174,
        "Your HoTs plus those of other healers who run HoTForecast.")
    Radio(frame, "Only you", function() return not db.showOthers end,
        function() HF.SetShowOthers(false) HF.RefreshConfig() end, L + 110, -174)

    Text(frame, "Look", "GameFontNormal"):SetPoint("TOPLEFT", L, -212)
    ColorSwatch(frame, "Bar colour", L, -234)
    Slider(frame, "Next tick opacity", function() return db.tickAlpha end, HF.SetTickAlpha, 0, 100, 1, L + 4, -270)
    Slider(frame, "Rest of the HoT opacity", function() return db.alpha end, HF.SetAlpha, 0, 100, 1, L + 4, -314)

    -- Right column: which frames.
    local R = 280
    Text(frame, "Show on", "GameFontNormal"):SetPoint("TOPLEFT", R, -50)
    for i, key in ipairs(HF.SHOW_KEYS) do
        Check(frame, HF.SHOW_LABELS[key], function() return db.show[key] ~= false end,
            function(on) HF.SetShown(key, on) end, R, -68 - (i - 1) * 26)
    end
    local note = Text(frame, "EllesmereUI and WebbyFrames frames.", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", R + 4, -68 - #HF.SHOW_KEYS * 26 - 4)

    Check(frame, "Show minimap button", function() return not db.minimap.hide end,
        function(on) if HF.SetMinimapShown then HF.SetMinimapShown(on) end end, R, -284)

    -- Bottom row.
    local test = Button(frame, "", 110, 24, nil)
    test:SetPoint("BOTTOMLEFT", 24, 20)
    test:SetScript("OnClick", function()
        HF.SetTest(not HF.IsTesting())
        test:Refresh()
    end)
    Tip(test, "Draws sample bars and a flash on every frame HoTForecast is attached to.")
    function test:Refresh() self:SetText(HF.IsTesting() and "Stop test" or "Test bars") end
    Track(test)

    local reset = Button(frame, "Reset all", 110, 24, function()
        HF.ResetAll()
        HF.RefreshConfig()
    end)
    reset:SetPoint("LEFT", test, "RIGHT", 10, 0)
    local done = Button(frame, "Close", 110, 24, function() frame:Hide() end)
    done:SetPoint("BOTTOMRIGHT", -24, 20)

    frame:Hide()
end

function HF.ShowConfig()
    if not HF.db then return end
    if not frame then Build() end
    frame:Show()
    HF.RefreshConfig()
end

function HF.ToggleConfig()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        HF.ShowConfig()
    end
end

function HoTForecast_OnCompartmentClick()
    HF.ToggleConfig()
end

------------------------------------------------------------------------------
-- Options > AddOns entry: points at the window.
------------------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end
    local panel = CreateFrame("Frame")
    panel.name = "HoTForecast"
    local icon = panel:CreateTexture(nil, "ARTWORK")
    icon:SetSize(24, 24)
    icon:SetTexture(ICON)
    icon:SetPoint("TOPLEFT", 16, -12)
    local title = Text(panel, "HoTForecast", "GameFontNormalLarge")
    title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    local text = Text(panel, "HoTForecast has its own settings window. You can also open it with /hotf.")
    text:SetPoint("TOPLEFT", 16, -46)
    local open = Button(panel, "Open HoTForecast", 160, 24, function()
        if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
        HF.ShowConfig()
    end)
    open:SetPoint("TOPLEFT", 16, -74)
    local category = Settings.RegisterCanvasLayoutCategory(panel, "HoTForecast")
    Settings.RegisterAddOnCategory(category)
end)
