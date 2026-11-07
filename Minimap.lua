-- HoTForecast minimap button: a LibDBIcon button (so minimap addons can
-- collect it). Click opens the settings.

local ADDON, HF = ...

local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
local DBI = LibStub and LibStub("LibDBIcon-1.0", true)

function HF.SetMinimapShown(on)
    HF.db.minimap.hide = not on
    if not DBI then return end
    if on then DBI:Show("HoTForecast") else DBI:Hide("HoTForecast") end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    if not (LDB and DBI and HF.db) then return end
    local launcher = LDB:NewDataObject("HoTForecast", {
        type = "launcher",
        text = "HoTForecast",
        icon = HF.ICON,
        OnClick = function() HF.ToggleConfig() end,
        OnTooltipShow = function(tt)
            tt:AddLine("HoTForecast")
            tt:AddLine("|cffffd100Click|r to open the settings", 1, 1, 1)
            tt:AddLine("|cffffd100Drag|r to move this button", 1, 1, 1)
        end,
    })
    DBI:Register("HoTForecast", launcher, HF.db.minimap)
end)
