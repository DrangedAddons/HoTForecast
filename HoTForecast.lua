-- HoTForecast: a faint bar after EllesmereUI's incoming-heal prediction showing
-- what your own HoTs (any class) will still heal if they run their course.
--
-- Forever blocks aura reads in combat, so HoTs are timed from your own casts:
-- UNIT_SPELLCAST_SENT gives the target's name, SUCCEEDED confirms the cast, and
-- the spell description gives the total ("Heals the target for 298 over 15 sec").
-- Out of combat the real auras are readable and correct the timers.
--
-- Health, max health and incoming heals are secret. They are never read by Lua
-- here; they go straight into StatusBar min/max/value, which accept secrets.
-- The forecast itself is a plain number.

local ADDON = ...
local issecret = issecretvalue or function() return false end

-- Any spell of yours whose description has a healing "<n> over <d> sec" part
-- counts as a HoT: Rejuvenation, Regrowth, Renew and whatever else Forever has.
-- Ticks are assumed 3 sec unless the text says "every <t> sec".
local DEFAULT_TICK = 3

local DEFAULTS = {
    enabled = true,
    color = { r = 0.55, g = 1.0, b = 0.75 },
    alpha = 35,          -- percent, the rest of the HoTs
    tickAlpha = 65,      -- percent, the next tick
    flash = true,        -- pop the healed chunk when a tick goes off
}

local db
local hots = {}          -- guid -> spellName -> { start, dur, total, ticks, tick, spellID }
local pendingCasts = {}  -- castGUID -> target name from SENT
local descCache = {}     -- spellID -> { total, dur }
local overlays = setmetatable({}, { __mode = "k" }) -- button -> overlay
local testMode = false

local function Print(msg)
    print("|cff8cf2b8HoTForecast|r " .. msg)
end

------------------------------------------------------------------------------
-- Spell amounts from the description
------------------------------------------------------------------------------

-- Returns total, duration, tick from the healing-over-time part of a
-- description, or nil. Works per sentence: the sentence must mention healing
-- and not damage, which skips DoTs, drains and bandages ("Heals 66 damage
-- over 6 sec", a channel that breaks on damage). Regrowth:
-- "Heals a friendly target for 197 to 220 and another 295 over 27 sec."
-- The last "<n> over <d> sec" in a healing sentence is the HoT part.
local HEAL_WORDS = { heal = true, heals = true, healing = true, healed = true }

local function IsHealingSentence(low)
    if low:find("damage", 1, true) then return false end
    for w in low:gmatch("%a+") do
        if HEAL_WORDS[w] then return true end -- "health" is not a heal word
    end
    return false
end

local function ParseDesc(text)
    if type(text) ~= "string" or issecret(text) or text == "" then return nil end
    local total, dur, tick
    for sentence in (text .. ". "):gmatch("(.-%.)%s") do
        local low = sentence:lower()
        if IsHealingSentence(low) then
            for t, d, unit in low:gmatch("([%d,%.]+) over ([%d%.]+) (%a+)") do
                local secs = tonumber(d)
                if secs and (unit == "sec" or unit == "secs" or unit == "seconds") then
                    total, dur = t, secs
                elseif secs and (unit == "min" or unit == "mins" or unit == "minutes") then
                    total, dur = t, secs * 60
                end
            end
            local every = low:match("every ([%d%.]+) sec")
            if every then tick = tonumber(every) end
        end
    end
    if not total then return nil end
    total = tonumber((total:gsub(",", "")))
    if not total or total <= 0 or not dur or dur <= 0 then return nil end
    if not tick or tick <= 0 or tick > dur then tick = DEFAULT_TICK end
    return total, dur, tick
end

-- Read the description fresh when possible (it follows gear and buffs),
-- else use the last good read for that rank. false = known not a HoT.
local function SpellAmount(spellID)
    if issecret(spellID) or type(spellID) ~= "number" then return nil end
    if descCache[spellID] == false then return nil end
    local ok, text = pcall(C_Spell.GetSpellDescription, spellID)
    if ok and type(text) == "string" and not issecret(text) and text ~= "" then
        local total, dur, tick = ParseDesc(text)
        if total then
            descCache[spellID] = { total = total, dur = dur, tick = tick }
            return total, dur, tick
        elseif not descCache[spellID] then
            descCache[spellID] = false
            return nil
        end
    end
    local c = descCache[spellID]
    if c then return c.total, c.dur, c.tick end
    return nil
end

-- Spell name if spellID is one of your HoTs. Ranks share a name, so a recast
-- of a lower rank replaces the higher one, as the game does.
local function HotName(spellID)
    if not SpellAmount(spellID) then return nil end
    local ok, name = pcall(C_Spell.GetSpellName, spellID)
    if ok and type(name) == "string" and not issecret(name) then return name end
    return nil
end

-- Cache every spellbook spell out of combat, in case descriptions can't be
-- read mid-fight.
local function PrewarmSpells()
    local SB = C_SpellBook
    if not (SB and SB.GetNumSpellBookSkillLines and SB.GetSpellBookSkillLineInfo
            and SB.GetSpellBookItemInfo and Enum.SpellBookSpellBank) then return end
    local okN, lines = pcall(SB.GetNumSpellBookSkillLines)
    if not okN or type(lines) ~= "number" then return end
    for i = 1, lines do
        local okL, line = pcall(SB.GetSpellBookSkillLineInfo, i)
        if okL and type(line) == "table" and line.itemIndexOffset and line.numSpellBookItems then
            for j = line.itemIndexOffset + 1, line.itemIndexOffset + line.numSpellBookItems do
                local okI, item = pcall(SB.GetSpellBookItemInfo, j, Enum.SpellBookSpellBank.Player)
                if okI and type(item) == "table" and type(item.spellID) == "number"
                   and not issecret(item.spellID) then
                    descCache[item.spellID] = nil  -- re-read: gear may have changed
                    SpellAmount(item.spellID)
                end
            end
        end
    end
end

------------------------------------------------------------------------------
-- Group roster: name -> unit, unit -> guid
------------------------------------------------------------------------------

local function GroupUnits()
    local list = { "player" }
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do list[#list + 1] = "raid" .. i end
    else
        for i = 1, 4 do list[#list + 1] = "party" .. i end
    end
    return list
end

local function PlainGUID(unit)
    local g = UnitGUID(unit)
    if g == nil or issecret(g) then return nil end
    return g
end

-- SENT's target is "Name Surname" (Forever surnames); UnitName is "Name".
-- Prefer an exact match, then the longest "Name " prefix.
local function UnitFromCastTarget(targetName)
    if type(targetName) ~= "string" or issecret(targetName) then return nil end
    local best, bestLen
    for _, u in ipairs(GroupUnits()) do
        if UnitExists(u) then
            local n = UnitName(u)
            if type(n) == "string" and not issecret(n) then
                if n == targetName then return u end
                if #n < #targetName and targetName:sub(1, #n + 1) == n .. " " then
                    if not bestLen or #n > bestLen then best, bestLen = u, #n end
                end
            end
        end
    end
    return best
end

------------------------------------------------------------------------------
-- HoT timers
------------------------------------------------------------------------------

-- A tick is "landed" once the unit's health event arrives near its due time,
-- so the HP rises into the tick segment and the next tick starts from the new
-- edge in the same frame. EARLY: a health event this long before the due time
-- still counts (timer drift). LATE: with no health event (target at full HP,
-- so nothing changes) the tick lands on its own this long after.
local EARLY, LATE = 0.4, 0.6
local pendingFlash = {}  -- guid -> healing of ticks that just landed

local function StartHot(guid, name, spellID, start, dur, total, tick)
    tick = tick or DEFAULT_TICK
    local ticks = math.max(1, math.floor(dur / tick + 0.5))
    tick = dur / ticks
    hots[guid] = hots[guid] or {}
    local cur = hots[guid][name]
    local landed
    if cur and cur.spellID == spellID and math.abs(cur.start - start) < 0.5 then
        landed = cur.landed -- same HoT re-read from its aura: keep the hold state
    else
        landed = math.max(0, math.floor((GetTime() - start) / tick))
    end
    hots[guid][name] = { start = start, dur = dur, total = total, ticks = ticks,
                         tick = tick, spellID = spellID, landed = math.min(landed, ticks) }
end

local function Land(guid, h, n)
    h.landed = h.landed + n
    pendingFlash[guid] = (pendingFlash[guid] or 0) + h.total / h.ticks * n
end

-- Health changed on guid: land any tick that is due (or nearly due).
local function OnHealthEvent(guid, now)
    local list = hots[guid]
    if not list then return false end
    local any = false
    for _, h in pairs(list) do
        while h.landed < h.ticks and now >= h.start + (h.landed + 1) * h.tick - EARLY do
            Land(guid, h, 1)
            any = true
        end
    end
    return any
end

-- Healing still to come from the ticks that haven't landed, summed over my
-- HoTs on guid, plus the size of the soonest tick. HoTs ticking within 0.1s
-- of each other count as one tick (their amounts add).
local function Forecast(guid, now)
    local list = hots[guid]
    if not list then return 0, 0, nil end
    local sum, any = 0, false
    local nextAt, nextAmt = nil, 0
    for name, h in pairs(list) do
        -- Ticks overdue with no health event: land them now.
        while h.landed < h.ticks and now >= h.start + (h.landed + 1) * h.tick + LATE do
            Land(guid, h, 1)
        end
        local left = h.ticks - h.landed
        if left <= 0 then
            list[name] = nil
        else
            local perTick = h.total / h.ticks
            sum = sum + perTick * left
            local at = h.start + (h.landed + 1) * h.tick
            if not nextAt or at < nextAt - 0.1 then
                nextAt, nextAmt = at, perTick
            elseif at <= nextAt + 0.1 then
                nextAmt = nextAmt + perTick
                if at < nextAt then nextAt = at end
            end
            any = true
        end
    end
    if not any then hots[guid] = nil end
    return sum, nextAmt, nextAt
end

-- Out of combat the auras are the truth: rebuild timers from them.
local function AurasReadable()
    if C_Secrets and C_Secrets.ShouldAurasBeSecret then
        local ok, secret = pcall(C_Secrets.ShouldAurasBeSecret)
        if not ok or issecret(secret) or secret then return false end
    end
    return not InCombatLockdown()
end

local function SyncUnitFromAuras(unit)
    local guid = PlainGUID(unit)
    if not guid then return end
    local seen = {}
    for i = 1, 40 do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL|PLAYER")
        if not ok or not aura then break end
        local id, exp, dur = aura.spellId, aura.expirationTime, aura.duration
        if not issecret(id) and not issecret(exp) and not issecret(dur) then
            local name = HotName(id)
            if name and dur and dur > 0 and exp and exp > 0 then
                local total, _, tick = SpellAmount(id)
                local cur = hots[guid] and hots[guid][name]
                if cur and cur.spellID == id then total = cur.total end
                if total then StartHot(guid, name, id, exp - dur, dur, total, tick) end
                seen[name] = true
            end
        end
    end
    local list = hots[guid]
    if list then
        for name in pairs(list) do
            if not seen[name] then list[name] = nil end
        end
        if not next(list) then hots[guid] = nil end
    end
end

local function SyncAllFromAuras()
    if not AurasReadable() then return end
    for _, u in ipairs(GroupUnits()) do
        if UnitExists(u) then SyncUnitFromAuras(u) end
    end
end

------------------------------------------------------------------------------
-- Overlays on EllesmereUI buttons
------------------------------------------------------------------------------

local HEADERS = { "ERFPartyHeader", "ERFFlatHeader" }
for g = 1, 8 do HEADERS[#HEADERS + 1] = "ERFGroupHeader" .. g end

-- The health bar is the tallest StatusBar directly under the button
-- (power and the absorb strips are shorter); ties go to the lowest level.
local function FindHealthBar(button)
    local best, bestH, bestL
    for _, c in ipairs({ button:GetChildren() }) do
        if c.GetObjectType and c:GetObjectType() == "StatusBar" then
            local h = c:GetHeight()
            if not issecret(h) and h then
                local l = c:GetFrameLevel()
                if not bestH or h > bestH + 0.5 or (math.abs(h - bestH) <= 0.5 and l < bestL) then
                    best, bestH, bestL = c, h, l
                end
            end
        end
    end
    return best
end

local function NewBar(health, mask)
    local bar = CreateFrame("StatusBar", nil, health)
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    local fill = bar:GetStatusBarTexture()
    fill:SetDrawLayer("ARTWORK", 1)
    fill:AddMaskTexture(mask)
    bar:SetFrameLevel(health:GetFrameLevel() + 3)
    bar:Hide()
    return bar
end

local function ApplyColor(ov)
    local c = db.color
    ov.tick:SetStatusBarColor(c.r, c.g, c.b, (db.tickAlpha or 65) / 100)
    ov.hot:SetStatusBarColor(c.r, c.g, c.b, (db.alpha or 35) / 100)
    -- Flash: the bar colour pushed most of the way to white.
    ov.flash:SetStatusBarColor(c.r + (1 - c.r) * 0.6, c.g + (1 - c.g) * 0.6,
        c.b + (1 - c.b) * 0.6, 0.9)
end

-- Lay spacer then hot along the health bar's fill direction, each starting at
-- the previous fill's end. Both span the full bar length; the mask cuts
-- anything past full health.
local function Layout(ov)
    local health = ov.health
    local orient = health:GetOrientation() or "HORIZONTAL"
    local rev = health:GetReverseFill() and true or false
    local key = orient .. (rev and "R" or "")
    local w, h = health:GetWidth(), health:GetHeight()
    if issecret(w) or issecret(h) then return end
    if ov.key == key and ov.w == w and ov.h == h then return end
    ov.key, ov.w, ov.h = key, w, h

    local function place(bar, after)
        bar:ClearAllPoints()
        bar:SetOrientation(orient)
        bar:SetReverseFill(rev)
        if orient == "VERTICAL" then
            bar:SetHeight(h)
            if rev then -- fills top to bottom
                bar:SetPoint("TOPLEFT", after, "BOTTOMLEFT", 0, 0)
                bar:SetPoint("TOPRIGHT", after, "BOTTOMRIGHT", 0, 0)
            else
                bar:SetPoint("BOTTOMLEFT", after, "TOPLEFT", 0, 0)
                bar:SetPoint("BOTTOMRIGHT", after, "TOPRIGHT", 0, 0)
            end
        else
            bar:SetWidth(w)
            if rev then -- fills right to left
                bar:SetPoint("TOPRIGHT", after, "TOPLEFT", 0, 0)
                bar:SetPoint("BOTTOMRIGHT", after, "BOTTOMLEFT", 0, 0)
            else
                bar:SetPoint("TOPLEFT", after, "TOPRIGHT", 0, 0)
                bar:SetPoint("BOTTOMLEFT", after, "BOTTOMRIGHT", 0, 0)
            end
        end
    end
    place(ov.spacer, health:GetStatusBarTexture())
    place(ov.tick, ov.spacer:GetStatusBarTexture())
    place(ov.hot, ov.tick:GetStatusBarTexture())

    -- Flash: ends at the health fill's edge and grows back into the health,
    -- so it lights up the chunk the tick just healed and rides the fill as
    -- the real heal lands.
    local fl, fill = ov.flash, health:GetStatusBarTexture()
    fl:ClearAllPoints()
    fl:SetOrientation(orient)
    fl:SetReverseFill(not rev)
    if orient == "VERTICAL" then
        fl:SetHeight(h)
        if rev then
            fl:SetPoint("BOTTOMLEFT", fill, "BOTTOMLEFT", 0, 0)
            fl:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT", 0, 0)
        else
            fl:SetPoint("TOPLEFT", fill, "TOPLEFT", 0, 0)
            fl:SetPoint("TOPRIGHT", fill, "TOPRIGHT", 0, 0)
        end
    else
        fl:SetWidth(w)
        if rev then
            fl:SetPoint("TOPLEFT", fill, "TOPLEFT", 0, 0)
            fl:SetPoint("BOTTOMLEFT", fill, "BOTTOMLEFT", 0, 0)
        else
            fl:SetPoint("TOPRIGHT", fill, "TOPRIGHT", 0, 0)
            fl:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT", 0, 0)
        end
    end
end

-- Short pop: bright, then fade out. Engine-side animation, no OnUpdate.
local function NewFlash(health, mask)
    local fl = NewBar(health, mask)
    fl:SetFrameLevel(health:GetFrameLevel() + 4)
    fl:GetStatusBarTexture():SetDrawLayer("ARTWORK", 3)
    local ag = fl:CreateAnimationGroup()
    local a = ag:CreateAnimation("Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(0)
    a:SetDuration(0.5)
    a:SetSmoothing("OUT")
    ag:SetScript("OnFinished", function() fl:Hide() end)
    fl.anim = ag
    return fl
end

local function Flash(ov, amount, maxH)
    local fl = ov.flash
    fl.anim:Stop()
    fl:SetMinMaxValues(0, maxH)
    fl:SetValue(amount)
    fl:SetAlpha(1)
    fl:Show()
    fl.anim:Play()
end

local function Attach(button)
    local ov = overlays[button]
    if ov then return ov end
    local health = FindHealthBar(button)
    if not health then return nil end
    local mask = health:CreateMaskTexture()
    mask:SetAllPoints(health)
    mask:SetTexture("Interface\\Buttons\\WHITE8X8", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE", "NEAREST")
    ov = { button = button, health = health, mask = mask }
    -- Invisible stand-in for EllesmereUI's incoming-heal bar, so ours starts
    -- where its green ends.
    ov.spacer = NewBar(health, mask)
    ov.spacer:SetStatusBarColor(0, 0, 0, 0)
    ov.tick = NewBar(health, mask) -- next tick, brighter
    ov.hot = NewBar(health, mask)  -- the rest
    ov.flash = NewFlash(health, mask)
    if CreateUnitHealPredictionCalculator then
        local ok, calc = pcall(CreateUnitHealPredictionCalculator)
        if ok and calc then
            if calc.SetMaximumHealthMode and Enum.UnitMaximumHealthMode then
                pcall(calc.SetMaximumHealthMode, calc, Enum.UnitMaximumHealthMode.Default)
            end
            ov.calc = calc
        end
    end
    ApplyColor(ov)
    overlays[button] = ov
    return ov
end

local function ScanButtons()
    for _, hname in ipairs(HEADERS) do
        local hdr = _G[hname]
        if hdr then
            for i = 1, 40 do
                local btn = hdr[i]
                if not btn then break end
                local ov = Attach(btn)
                if ov then Layout(ov) end
            end
        end
    end
end

local function HideOverlay(ov)
    if ov.shown then
        ov.spacer:Hide()
        ov.tick:Hide()
        ov.hot:Hide()
        ov.shown = false
    end
end

local function PaintOverlay(ov, now)
    local btn = ov.button
    if not db.enabled or not btn:IsVisible() then return HideOverlay(ov) end
    local unit = btn:GetAttribute("unit")
    if type(unit) ~= "string" or not UnitExists(unit) then return HideOverlay(ov) end

    if testMode then
        ov.spacer:SetMinMaxValues(0, 100); ov.spacer:SetValue(0)
        ov.tick:SetMinMaxValues(0, 100); ov.tick:SetValue(10)
        ov.hot:SetMinMaxValues(0, 100); ov.hot:SetValue(20)
        ov.spacer:Show(); ov.tick:Show(); ov.hot:Show(); ov.shown = true
        if db.flash and (not ov.testFlashAt or now >= ov.testFlashAt) then
            ov.testFlashAt = now + 3
            Flash(ov, 10, 100)
        end
        return
    end

    local guid = PlainGUID(unit)
    local amount, nextTick, nextAt = 0, 0, nil
    if guid then amount, nextTick, nextAt = Forecast(guid, now) end

    -- Ticks that just landed: pop the chunk they healed. Runs before the
    -- amount check so the last tick of a HoT still flashes.
    local landedAmt = guid and pendingFlash[guid]
    if landedAmt then
        pendingFlash[guid] = nil
        if db.flash and landedAmt > 0 then Flash(ov, landedAmt, UnitHealthMax(unit)) end
    end

    if amount <= 0 then return HideOverlay(ov) end
    local dead = UnitIsDeadOrGhost(unit)
    if not issecret(dead) and dead then
        hots[guid] = nil
        return HideOverlay(ov)
    end

    -- Spacer = incoming heals on the same scale as EllesmereUI reads them.
    local calc = ov.calc
    if calc and UnitGetDetailedHealPrediction and pcall(UnitGetDetailedHealPrediction, unit, nil, calc) then
        ov.spacer:SetMinMaxValues(0, calc:GetMaximumHealth())
        local inc = calc:GetIncomingHeals()
        if not issecret(inc) and inc == nil then inc = 0 end
        ov.spacer:SetValue(inc)
    else
        ov.spacer:SetMinMaxValues(0, UnitHealthMax(unit))
        ov.spacer:SetValue(0)
    end
    local maxH = UnitHealthMax(unit)
    ov.tick:SetMinMaxValues(0, maxH)
    ov.tick:SetValue(nextTick)
    ov.hot:SetMinMaxValues(0, maxH)
    ov.hot:SetValue(math.max(0, amount - nextTick))
    if not ov.shown then
        ov.spacer:Show(); ov.tick:Show(); ov.hot:Show(); ov.shown = true
    end
end

local function PaintAll()
    local now = GetTime()
    for _, ov in pairs(overlays) do PaintOverlay(ov, now) end
end

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------

local f = CreateFrame("Frame")
local paintElapsed, scanElapsed = 0, 0

f:SetScript("OnUpdate", function(_, dt)
    paintElapsed = paintElapsed + dt
    scanElapsed = scanElapsed + dt
    if scanElapsed >= 1 then
        scanElapsed = 0
        ScanButtons()
    end
    if paintElapsed >= 0.1 then
        paintElapsed = 0
        PaintAll()
    end
end)

local function OnCastSent(targetName, castGUID, spellID)
    if issecret(castGUID) or not castGUID then return end
    if not HotName(spellID) then return end
    pendingCasts[castGUID] = targetName
end

local function OnCastSucceeded(castGUID, spellID)
    local name = HotName(spellID)
    if not name then return end
    if issecret(castGUID) or not castGUID then return end
    local targetName = pendingCasts[castGUID]
    pendingCasts[castGUID] = nil
    -- No target name means an untargeted (e.g. party-wide) cast: skip it
    -- rather than guess who it landed on.
    local unit = UnitFromCastTarget(targetName)
    if not unit then return end
    local guid = PlainGUID(unit)
    if not guid then return end
    local total, dur, tick = SpellAmount(spellID)
    if not total then return end
    StartHot(guid, name, spellID, GetTime(), dur, total, tick)
end

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("SPELLS_CHANGED")
f:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
f:RegisterEvent("UNIT_AURA")
f:RegisterEvent("UNIT_HEALTH")
f:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
f:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

f:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
    if event == "ADDON_LOADED" then
        if a1 ~= ADDON then return end
        HoTForecastCharDB = HoTForecastCharDB or {}
        db = HoTForecastCharDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then
                db[k] = type(v) == "table" and { r = v.r, g = v.g, b = v.b } or v
            end
        end
        return
    end
    if not db then return end

    if event == "PLAYER_LOGIN" then
        C_Timer.After(2, function()
            PrewarmSpells()
            ScanButtons()
            SyncAllFromAuras()
        end)
    elseif event == "UNIT_SPELLCAST_SENT" then
        OnCastSent(a2, a3, a4)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        OnCastSucceeded(a2, a3)
    elseif event == "UNIT_HEALTH" then
        if issecret(a1) or type(a1) ~= "string" then return end
        local guid = PlainGUID(a1)
        -- Repaint now, not on the next 0.1s pass, so the bars move on in the
        -- same frame the HP rises.
        if guid and OnHealthEvent(guid, GetTime()) then PaintAll() end
    elseif event == "UNIT_AURA" then
        if issecret(a1) or type(a1) ~= "string" then return end
        if (a1 == "player" or a1:match("^party%d$") or a1:match("^raid%d+$")) and AurasReadable() then
            SyncUnitFromAuras(a1)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        wipe(pendingCasts)
        wipe(pendingFlash)
        C_Timer.After(0.2, SyncAllFromAuras)
    elseif event == "GROUP_ROSTER_UPDATE" then
        C_Timer.After(0.5, function()
            ScanButtons()
            SyncAllFromAuras()
        end)
    elseif event == "SPELLS_CHANGED" or event == "PLAYER_EQUIPMENT_CHANGED" then
        if not InCombatLockdown() then PrewarmSpells() end
    end
end)

------------------------------------------------------------------------------
-- Slash command
------------------------------------------------------------------------------

local function RefreshColors()
    for _, ov in pairs(overlays) do ApplyColor(ov) end
end

SLASH_HOTFORECAST1 = "/hotf"
SLASH_HOTFORECAST2 = "/hotforecast"
SlashCmdList.HOTFORECAST = function(msg)
    if not db then return end
    local cmd, rest = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    if cmd == "on" or cmd == "off" then
        db.enabled = cmd == "on"
        Print(db.enabled and "on." or "off.")
    elseif cmd == "toggle" then
        db.enabled = not db.enabled
        Print(db.enabled and "on." or "off.")
    elseif cmd == "alpha" then
        local n = tonumber(rest)
        if n and n >= 0 and n <= 100 then
            db.alpha = n
            RefreshColors()
            Print("opacity " .. n .. "%.")
        else
            Print("usage: /hotf alpha 0-100")
        end
    elseif cmd == "tickalpha" then
        local n = tonumber(rest)
        if n and n >= 0 and n <= 100 then
            db.tickAlpha = n
            RefreshColors()
            Print("next-tick opacity " .. n .. "%.")
        else
            Print("usage: /hotf tickalpha 0-100")
        end
    elseif cmd == "flash" then
        if rest == "on" or rest == "off" then
            db.flash = rest == "on"
        else
            db.flash = not db.flash
        end
        Print("tick flash " .. (db.flash and "on." or "off."))
    elseif cmd == "color" then
        local r, g, b = rest:match("^([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)$")
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        if r and g and b then
            if r > 1 or g > 1 or b > 1 then r, g, b = r / 255, g / 255, b / 255 end
            db.color = { r = r, g = g, b = b }
            RefreshColors()
            Print(string.format("colour %.2f %.2f %.2f.", r, g, b))
        else
            Print("usage: /hotf color <r> <g> <b>  (0-1 or 0-255)")
        end
    elseif cmd == "test" then
        testMode = not testMode
        ScanButtons()
        Print(testMode and "test bars on (10% next tick + 20% rest on every frame). /hotf test again to stop."
            or "test bars off.")
    elseif cmd == "debug" then
        local n, now = 0, GetTime()
        for _ in pairs(overlays) do n = n + 1 end
        Print(n .. " frames attached.")
        for guid, list in pairs(hots) do
            for name, h in pairs(list) do
                Print(string.format("%s %s: %d of %d left, %d/%d ticks landed, %.1fs left",
                    guid:sub(-8), name, math.floor(h.total * (h.ticks - h.landed) / h.ticks),
                    h.total, h.landed, h.ticks, h.dur - (now - h.start)))
            end
        end
        for id, c in pairs(descCache) do
            if c then
                local okN, nm = pcall(C_Spell.GetSpellName, id)
                Print(string.format("HoT %s (%d): %d over %ss, tick %ss",
                    okN and type(nm) == "string" and nm or "?", id, c.total, c.dur, c.tick))
            end
        end
    else
        Print("/hotf on | off | alpha <0-100> | tickalpha <0-100> | flash [on|off] | color <r g b> | test | debug")
    end
end
