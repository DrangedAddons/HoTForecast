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

local ADDON, HF = ...
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
    share = true,        -- send your HoTs to the group
    showOthers = true,   -- show other HoTForecast users' HoTs (false: only yours)
    petDirect = true,    -- draw incoming direct heals on pet frames that have no such bar
    -- Which frames get the bars. Each covers EllesmereUI's and WebbyFrames'
    -- frame for that unit; "party" is every party and raid frame.
    show = { party = true, player = true, target = true, targettarget = true,
             focus = true, focustarget = true, pet = true },
    minimap = { hide = false },
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

-- Timing trace (/hotf trace): cast times, expected ticks, every health change
-- on a traced target and how each tick landed. Saved in HoTForecastCharDB.trace.
local TRACE_MAX = 4000
local tracing = false
local traceRef = {}      -- guid -> start time of the latest traced HoT
local traceUntil = {}    -- guid -> keep logging health changes until this time

local function Trace(fmt, ...)
    if not tracing or not db then return end
    local t = db.trace
    if not t or #t >= TRACE_MAX then return end
    t[#t + 1] = string.format("%.3f ", GetTime()) .. string.format(fmt, ...)
end

local function Rel(guid, now)
    local r = traceRef[guid]
    return r and (now - r) or -1
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

-- Group members, then their pets.
local function GroupUnits()
    local list = { "player" }
    if IsInRaid() then
        local n = GetNumGroupMembers()
        for i = 1, n do list[#list + 1] = "raid" .. i end
        list[#list + 1] = "pet"
        for i = 1, n do list[#list + 1] = "raidpet" .. i end
    else
        for i = 1, 4 do list[#list + 1] = "party" .. i end
        list[#list + 1] = "pet"
        for i = 1, 4 do list[#list + 1] = "partypet" .. i end
    end
    return list
end

-- Where a cast's target is looked for: the units you most likely aimed at
-- first, then the group and pets.
local function CastCandidates()
    local list = { "target", "focus", "mouseover" }
    for _, u in ipairs(GroupUnits()) do list[#list + 1] = u end
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
    for _, u in ipairs(CastCandidates()) do
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
-- still counts. LATE: with no health event (target at full HP, so nothing
-- changes) the tick lands on its own this long after. Traced Rejuvenation
-- ticks arrived 0.01-0.08s early, so the window is tight: a wider one let
-- regen and other heals land a tick ~0.4s before the real heal.
local EARLY, LATE = 0.15, 0.25
-- guid -> { id, amount, at } for the ticks that just landed. Every frame
-- showing that unit flashes it once (ov.flashSeen = id), so a unit on both an
-- EllesmereUI and a WebbyFrames frame lights up on both.
local pendingFlash = {}
local flashId = 0
local FLASH_WINDOW = 0.3 -- a frame that repaints later than this skips it

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
                         tick = tick, spellID = spellID, landed = math.min(landed, ticks),
                         name = name }
end

local function Land(guid, h, n, via, now)
    if tracing then
        Trace("LAND %s tick %d/%d via %s at +%.3f (due +%.3f) %s", h.name or "?",
            h.landed + n, h.ticks, via, Rel(guid, now), (h.landed + n) * h.tick + (h.start - (traceRef[guid] or h.start)),
            guid:sub(-8))
    end
    h.landed = h.landed + n
    if h.shared and not db.showOthers then return end
    local now2 = GetTime()
    local pf = pendingFlash[guid]
    if pf and now2 - pf.at < 0.05 then
        pf.amount = pf.amount + h.total / h.ticks * n -- same moment: one flash
    else
        flashId = flashId + 1
        pendingFlash[guid] = { id = flashId, amount = h.total / h.ticks * n, at = now2 }
    end
end

-- Health changed on guid: land any tick that is due (or nearly due).
local function OnHealthEvent(guid, now)
    local list = hots[guid]
    if not list then return false end
    local any = false
    for _, h in pairs(list) do
        while h.landed < h.ticks and now >= h.start + (h.landed + 1) * h.tick - EARLY do
            Land(guid, h, 1, "health", now)
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
            Land(guid, h, 1, "timeout", now)
        end
        local left = h.ticks - h.landed
        if left <= 0 then
            list[name] = nil
        elseif h.shared and not db.showOthers then
            any = true -- kept, so switching back to all shows it at once
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

------------------------------------------------------------------------------
-- Sharing: every HoTForecast user broadcasts their own HoTs to the group, so
-- you also see the HoTs of other healers who run it. Keys for shared HoTs are
-- "<casterGUID>@<spell name>" (own HoTs are keyed by spell name alone).
-- Fields are ";"-separated: "|" starts WoW escape codes.
--   1;S;<caster>;<target>;<spellID>;<total>;<dur>;<tick>;<age>   started/refreshed
--   1;R;<caster>;<target>;<spellID>                              removed early
-- age = seconds since it was applied, so clocks never need to agree.
------------------------------------------------------------------------------

local PREFIX = "HoTF"
local comm = { sent = 0, failed = 0, recv = 0, bad = 0, secret = 0, lastResult = "-" }

local function GroupChannel()
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

local function Send(msg)
    if not db or not db.share then return end
    local ch = GroupChannel()
    if not ch or not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
    local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, ch)
    local good = false
    if ok then
        if issecret(res) then
            comm.lastResult = "SECRET"
        else
            comm.lastResult = tostring(res)
            local okEnum = Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success
            good = res == nil or res == true or res == 0 or (okEnum ~= nil and res == okEnum)
        end
    else
        comm.lastResult = "ERR " .. tostring(res):sub(1, 80)
    end
    if good then comm.sent = comm.sent + 1 else comm.failed = comm.failed + 1 end
    Trace("SEND %s %s -> %s", ch, msg, comm.lastResult)
end

local function ShareStart(guid, spellID, total, dur, tick, age)
    local me = PlainGUID("player")
    if not me then return end
    Send(string.format("1;S;%s;%s;%d;%d;%.2f;%.2f;%.2f", me, guid, spellID,
        math.floor(total + 0.5), dur, tick, math.max(0, age)))
end

local function ShareStop(guid, spellID)
    local me = PlainGUID("player")
    if not me then return end
    Send(string.format("1;R;%s;%s;%d", me, guid, spellID))
end

local function OnAddonMessage(prefix, text, channel, sender)
    if issecret(prefix) or prefix ~= PREFIX then return end
    if issecret(text) or type(text) ~= "string" then
        comm.secret = comm.secret + 1
        return
    end
    comm.recv = comm.recv + 1
    Trace("RECV %s %s", issecret(sender) and "SECRET" or tostring(sender), text)
    local v, kind, caster, target, id, rest = text:match("^(%d+);(%a);([^;]+);([^;]+);(%d+);?(.*)$")
    if v ~= "1" then comm.bad = comm.bad + 1 return end
    if caster == PlainGUID("player") then return end -- our own echo
    if not db then return end
    local spellID = tonumber(id)
    local okN, nm = pcall(C_Spell.GetSpellName, spellID)
    if not okN or type(nm) ~= "string" or issecret(nm) then nm = tostring(id) end
    local key = caster .. "@" .. nm
    if kind == "S" then
        local total, dur, tick, age = rest:match("^(%d+);([%d%.]+);([%d%.]+);([%d%.]+)$")
        total, dur, tick, age = tonumber(total), tonumber(dur), tonumber(tick), tonumber(age)
        if not (total and dur and tick and age) or dur <= 0 or total <= 0 then
            comm.bad = comm.bad + 1
            return
        end
        if age >= dur then return end
        StartHot(target, key, spellID, GetTime() - age, dur, total, tick)
        local h = hots[target] and hots[target][key]
        if h then h.shared = true end
    elseif kind == "R" then
        local list = hots[target]
        if list then
            list[key] = nil
            if not next(list) then hots[target] = nil end
        end
    else
        comm.bad = comm.bad + 1
    end
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
                local changed = not cur or cur.spellID ~= id or math.abs(cur.start - (exp - dur)) > 0.5
                if total then
                    StartHot(guid, name, id, exp - dur, dur, total, tick)
                    if changed then ShareStart(guid, id, total, dur, tick or DEFAULT_TICK, GetTime() - (exp - dur)) end
                end
                seen[name] = true
            end
        end
    end
    local list = hots[guid]
    if list then
        local now = GetTime()
        for name, h in pairs(list) do
            -- (other healers' HoTs aren't in our PLAYER-filtered auras)
            if not seen[name] and not h.shared then
                -- The aura drops in the same moment as its last tick, often
                -- before the health event: land what's left so it flashes.
                if h.landed < h.ticks and now >= h.start + h.dur - EARLY - 0.1 then
                    Land(guid, h, h.ticks - h.landed, "aura end", now)
                else
                    ShareStop(guid, h.spellID) -- gone early (dispelled, cancelled)
                end
                list[name] = nil
            end
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

local function NewBar(health, mask, level, shapeMask)
    local bar = CreateFrame("StatusBar", nil, health)
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    local fill = bar:GetStatusBarTexture()
    fill:SetDrawLayer("ARTWORK", 1)
    fill:AddMaskTexture(mask)
    if shapeMask then pcall(fill.AddMaskTexture, fill, shapeMask) end
    bar:SetFrameLevel(health:GetFrameLevel() + (level or 3))
    bar:Hide()
    return bar
end

-- Our own incoming-heal bar, on frames with none: EllesmereUI's green.
local DIRECT_COLOR = { r = 102 / 255, g = 243 / 255, b = 102 / 255, a = 0.6 }

local function ApplyColor(ov)
    if ov.ownPred then
        local d = DIRECT_COLOR
        ov.spacer:SetStatusBarColor(d.r, d.g, d.b, d.a)
    end
    local c = db.color
    ov.tick:SetStatusBarColor(c.r, c.g, c.b, (db.tickAlpha or 65) / 100)
    ov.hot:SetStatusBarColor(c.r, c.g, c.b, (db.alpha or 35) / 100)
    -- Flash: the bar colour pushed partway to white.
    ov.flash:SetStatusBarColor(c.r + (1 - c.r) * 0.4, c.g + (1 - c.g) * 0.4,
        c.b + (1 - c.b) * 0.4, 0.9)
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

    -- Flash: pinned to where the tick heals into, i.e. from the health the
    -- unit had before the tick (flashBase, an invisible copy of the health bar
    -- fed that stored value) forward by the tick amount. With EllesmereUI's
    -- smooth bars the HP then slides up underneath it; it never covers HP the
    -- unit already had.
    local base = ov.flashBase
    base:ClearAllPoints()
    base:SetAllPoints(health)
    base:SetOrientation(orient)
    base:SetReverseFill(rev)
    place(ov.flash, base:GetStatusBarTexture())
end

-- Short pop: bright, then fade out. Engine-side animation, no OnUpdate.
local function NewFlash(health, mask, level, shapeMask)
    local fl = NewBar(health, mask, level, shapeMask)
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

-- baseHP/baseMax: the health before the tick (may be secret); amount/maxH:
-- the tick on its own scale. Each bar keeps its own min/max, so the two
-- scales never need combining in Lua.
local function Flash(ov, amount, maxH, baseHP, baseMax)
    local fl = ov.flash
    fl.anim:Stop()
    ov.flashBase:SetMinMaxValues(0, baseMax)
    ov.flashBase:SetValue(baseHP)
    ov.flashBase:Show()
    fl:SetMinMaxValues(0, maxH)
    fl:SetValue(amount)
    fl:SetAlpha(1)
    fl:Show()
    fl.anim:Play()
end

-- level: our bars' frame level above the health bar. EllesmereUI's own
-- prediction sits at +3; WebbyFrames' at +1 with its frame art above that.
-- shapeMask: the frame's health-shape mask, if it has one (WebbyFrames).
-- cat: the db.show key that switches this frame. predOn: for frames whose
-- incoming-heal bar can be off, returns whether it's drawn (no spacer if not).
-- ownPred: the frame draws no incoming heals of its own, so the spacer is
-- shown as our direct-heal bar (db.petDirect).
local function Attach(button, health, level, shapeMask, cat, predOn, ownPred)
    local ov = overlays[button]
    if ov then return ov end
    health = health or FindHealthBar(button)
    if not health then return nil end
    level = level or 3
    local mask = health:CreateMaskTexture()
    mask:SetAllPoints(health)
    mask:SetTexture("Interface\\Buttons\\WHITE8X8", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE", "NEAREST")
    ov = { button = button, health = health, mask = mask, cat = cat or "party", predOn = predOn,
           ownPred = ownPred }
    -- Invisible stand-in for EllesmereUI's incoming-heal bar, so ours starts
    -- where its green ends.
    ov.spacer = NewBar(health, mask, level, shapeMask)
    ov.spacer:SetStatusBarColor(0, 0, 0, 0)
    ov.tick = NewBar(health, mask, level, shapeMask) -- next tick, brighter
    ov.hot = NewBar(health, mask, level, shapeMask)  -- the rest
    ov.flashBase = NewBar(health, mask, level, shapeMask)
    ov.flashBase:SetStatusBarColor(0, 0, 0, 0)
    ov.flash = NewFlash(health, mask, level + 1, shapeMask)
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

-- WebbyFrames: unit frames (WebbyFrames_<unit>, live unit in .wfUnit) and the
-- raid-style party tiles (WebbyFrames_RaidParty<i>, unit attribute). Both keep
-- their health bar in .hp.
local WEBBY_UNITS = { "player", "target", "targettarget", "focus", "focustarget", "pet",
                      "party1", "party2", "party3", "party4" }

local function AttachWebby(f, cat, ownPred, shape)
    if not f or type(f.hp) ~= "table" or not f.hp.GetStatusBarTexture then return end
    if shape == nil then shape = f.hpMaskOn and f.hpMask or nil end
    local ov = Attach(f, f.hp, 1, shape or nil, cat, nil, ownPred)
    if ov then Layout(ov) end
end

-- WebbyFrames pets beyond the main pet frame: the minis under the party
-- frames (WebbyFrames_partypet<i>) and the raid-style pet tiles
-- (WebbyFrames_RaidPartyPet<i>). Neither draws incoming heals.
local function AttachWebbyPets()
    for i = 1, 4 do
        local m = _G["WebbyFrames_partypet" .. i]
        -- The mini's health shape mask gets its texture on the first paint;
        -- before that it would hide our bars, so wait for it.
        if m and not overlays[m] and m.hpTex then AttachWebby(m, "pet", true, m.hpMask or false) end
    end
    for i = 1, 40 do
        local t = _G["WebbyFrames_RaidPartyPet" .. i]
        if not t then break end
        AttachWebby(t, "pet", true, false)
    end
end

-- EllesmereUI raid-frame pets: the pet header (ERFPetHeader), and with
-- Beside Owner an unnamed button under each party button plus one for your
-- own pet on the party container. Health bar in ._health; no incoming heals.
local function IsEUIPetButton(b)
    return b:GetObjectType() == "Button" and b:GetName() == nil and type(b._health) == "table"
        and b._health.GetStatusBarTexture ~= nil
end

local function AttachEUIPet(b)
    if overlays[b] then return end
    local ov = Attach(b, b._health, 3, nil, "pet", nil, true)
    if ov then Layout(ov) end
end

local function AttachEUIPets()
    local hdr = _G.ERFPetHeader
    if hdr then
        for i = 1, 40 do
            local b = hdr[i]
            if not b then break end
            if type(b._health) == "table" then AttachEUIPet(b) end
        end
    end
    local party = _G.ERFPartyHeader
    if not party then return end
    local owners = { party:GetParent() } -- the container holds your own pet's button
    for i = 1, 5 do owners[#owners + 1] = party[i] end
    for _, o in ipairs(owners) do
        if o then
            for _, c in ipairs({ o:GetChildren() }) do
                if IsEUIPetButton(c) then AttachEUIPet(c) end
            end
        end
    end
end

-- EllesmereUI unit frames: EllesmereUIUnitFrames_<Name>, health bar in
-- .Health, live unit in ._euiUnit. Their incoming-heal bar is opt-in per
-- frame (damageAbsorb._predOn); text sits at +15, so ours at +3 stays under it.
local EUI_UNIT_FRAMES = {
    Player = "player", Target = "target", TargetTarget = "targettarget",
    Focus = "focus", FocusTarget = "focustarget", Pet = "pet",
}

local function AttachEUIUnit(f, cat)
    if not f or overlays[f] then return end
    local health = f.Health
    if type(health) ~= "table" or not health.GetStatusBarTexture then return end
    local ab = f.HealthPrediction and f.HealthPrediction.damageAbsorb
    local shape = ab and ab._blizzMaskOn and health._blizzMask or nil
    -- EllesmereUI offers incoming heals on player, target and focus only.
    local hasPred = cat == "player" or cat == "target" or cat == "focus"
    local predOn = hasPred and ab and function() return ab._predOn and true or false end or nil
    local ov = Attach(f, health, 3, shape, cat, predOn, cat == "pet")
    if ov then Layout(ov) end
end

local function ScanButtons()
    for _, hname in ipairs(HEADERS) do
        local hdr = _G[hname]
        if hdr then
            for i = 1, 40 do
                local btn = hdr[i]
                if not btn then break end
                local ov = Attach(btn, nil, nil, nil, "party")
                if ov then Layout(ov) end
            end
        end
    end
    -- With "Show Self First/Last" the player's party frame is this static
    -- button, outside the header.
    local selfBtn = _G.ERFPartySelfButton
    if selfBtn then
        local ov = Attach(selfBtn, nil, nil, nil, "party")
        if ov then Layout(ov) end
    end
    for _, u in ipairs(WEBBY_UNITS) do
        AttachWebby(_G["WebbyFrames_" .. u], u:match("^party%d$") and "party" or u)
    end
    for i = 1, 40 do
        local t = _G["WebbyFrames_RaidParty" .. i]
        if not t then break end
        AttachWebby(t, "party")
    end
    for name, cat in pairs(EUI_UNIT_FRAMES) do
        AttachEUIUnit(_G["EllesmereUIUnitFrames_" .. name], cat)
    end
    AttachEUIPets()
    AttachWebbyPets()
end

-- WebbyFrames keeps the live unit in .wfUnit (its party frames can switch
-- unit), EllesmereUI's unit frames in ._euiUnit (vehicle swaps); everything
-- else uses the secure "unit" attribute.
local function OverlayUnit(btn)
    local u = btn.wfUnit
    if type(u) == "string" and not issecret(u) then return u end
    u = btn._euiUnit
    if type(u) == "string" and not issecret(u) then return u end
    return btn:GetAttribute("unit")
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
    if not db.enabled or db.show[ov.cat] == false or not btn:IsVisible() then return HideOverlay(ov) end
    local unit = OverlayUnit(btn)
    if type(unit) ~= "string" or not UnitExists(unit) then return HideOverlay(ov) end

    if testMode then
        ov.spacer:SetMinMaxValues(0, 100); ov.spacer:SetValue(ov.ownPred and db.petDirect and 8 or 0)
        ov.tick:SetMinMaxValues(0, 100); ov.tick:SetValue(10)
        ov.hot:SetMinMaxValues(0, 100); ov.hot:SetValue(20)
        ov.spacer:Show(); ov.tick:Show(); ov.hot:Show(); ov.shown = true
        if db.flash and (not ov.testFlashAt or now >= ov.testFlashAt) then
            ov.testFlashAt = now + 3
            Flash(ov, 10, 100, UnitHealth(unit), UnitHealthMax(unit))
        end
        return
    end

    local guid = PlainGUID(unit)
    local amount, nextTick, nextAt = 0, 0, nil
    if guid then amount, nextTick, nextAt = Forecast(guid, now) end

    -- Ticks that just landed: pop the chunk they healed. Runs before the
    -- amount check so the last tick of a HoT still flashes.
    local pf = guid and pendingFlash[guid]
    if pf and now - pf.at > FLASH_WINDOW then
        pendingFlash[guid] = nil
        pf = nil
    end
    if pf and ov.flashSeen ~= pf.id then
        ov.flashSeen = pf.id
        local landedAmt = pf.amount
        if db.flash and landedAmt > 0 then
            local maxH = UnitHealthMax(unit)
            local base = ov.prevHP
            if not issecret(base) and base == nil then base = UnitHealth(unit) end
            Flash(ov, landedAmt, maxH, base, maxH)
        end
    end
    -- Health as of this paint (secret; stored, never compared): the next
    -- tick's flash starts from here.
    ov.prevHP = UnitHealth(unit)

    local direct = ov.ownPred and db.petDirect
    if amount <= 0 and not direct then return HideOverlay(ov) end
    local dead = UnitIsDeadOrGhost(unit)
    if not issecret(dead) and dead then
        if guid then hots[guid] = nil end
        return HideOverlay(ov)
    end

    -- Spacer = incoming heals on the same scale as EllesmereUI reads them.
    -- Invisible behind the frame's own bar; ours (coloured) where it has none.
    local calc = ov.calc
    if ov.predOn and not ov.predOn() then calc = nil end
    if ov.ownPred and not direct then calc = nil end
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

-- What happened to the last HoT cast, for /hotf debug.
local lastCast

local function Show(v)
    if issecret(v) then return "SECRET" end
    return tostring(v)
end

-- Saved in db.castLog (last 10) so a report needs only a /reload.
local function UnitInfo(u)
    if not UnitExists(u) then return nil end
    return string.format("name=%s guid=%s", Show(UnitName(u)), Show(UnitGUID(u)))
end

local function LogCast(lc)
    if not db then return end
    local units = {}
    for _, u in ipairs({ "target", "mouseover", "pet", "partypet1", "partypet2", "partypet3", "partypet4" }) do
        units[u] = UnitInfo(u)
    end
    lc.units = units
    lc.combat = InCombatLockdown() and true or false
    db.castLog = db.castLog or {}
    table.insert(db.castLog, 1, lc)
    while #db.castLog > 10 do table.remove(db.castLog) end
end

local function OnCastSent(targetName, castGUID, spellID)
    if not HotName(spellID) then return end
    lastCast = { spell = HotName(spellID), target = Show(targetName), result = "sent, no SUCCEEDED yet" }
    LogCast(lastCast)
    if issecret(castGUID) or not castGUID then
        lastCast.result = "cast id " .. Show(castGUID)
        return
    end
    pendingCasts[castGUID] = targetName
end

local function OnCastSucceeded(castGUID, spellID)
    local name = HotName(spellID)
    if not name then return end
    if issecret(castGUID) or not castGUID then return end
    local targetName = pendingCasts[castGUID]
    pendingCasts[castGUID] = nil
    local lc = lastCast or {}
    lastCast = lc
    lc.spell = name
    -- No target name means an untargeted (e.g. party-wide) cast: skip it
    -- rather than guess who it landed on.
    local unit = UnitFromCastTarget(targetName)
    if not unit then lc.result = "no unit matched that name" return end
    lc.unit = unit
    local guid = PlainGUID(unit)
    if not guid then lc.result = "unit " .. unit .. " has GUID " .. Show(UnitGUID(unit)) return end
    local total, dur, tick = SpellAmount(spellID)
    if not total then lc.result = "no amount in the description" return end
    lc.result = string.format("tracked on %s: %d over %ss", unit, total, tostring(dur))
    local now = GetTime()
    StartHot(guid, name, spellID, now, dur, total, tick)
    ShareStart(guid, spellID, total, dur, tick or DEFAULT_TICK, 0)
    if tracing then
        local h = hots[guid][name]
        traceRef[guid] = now
        traceUntil[guid] = now + dur + 5
        local due = {}
        for k = 1, h.ticks do due[#due + 1] = string.format("%.1f", k * h.tick) end
        Trace("CAST %s (%d) on %s %s combat=%s: %d over %ss, %d ticks of %.1f every %.2fs, due +%s",
            name, spellID, unit, guid:sub(-8), tostring(InCombatLockdown()), total, dur,
            h.ticks, total / h.ticks, h.tick, table.concat(due, " +"))
    end
end

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("SPELLS_CHANGED")
f:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
f:RegisterEvent("UNIT_AURA")
f:RegisterEvent("UNIT_HEALTH")
if not (C_EventUtils and C_EventUtils.IsEventValid) or C_EventUtils.IsEventValid("CHAT_MSG_ADDON") then
    f:RegisterEvent("CHAT_MSG_ADDON")
end
f:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
f:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

f:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
    if event == "ADDON_LOADED" then
        if a1 ~= ADDON then return end
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
        end
        HoTForecastCharDB = HoTForecastCharDB or {}
        db = HoTForecastCharDB
        for k, v in pairs(DEFAULTS) do
            if type(v) == "table" then
                if type(db[k]) ~= "table" then db[k] = {} end
                for k2, v2 in pairs(v) do
                    if db[k][k2] == nil then db[k][k2] = v2 end
                end
            elseif db[k] == nil then
                db[k] = v
            end
        end
        HF.db = db
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
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(a1, a2, a3, a4)
    elseif event == "UNIT_HEALTH" then
        if issecret(a1) or type(a1) ~= "string" then return end
        local guid = PlainGUID(a1)
        if tracing and guid and traceUntil[guid] then
            local now = GetTime()
            if now <= traceUntil[guid] then
                Trace("HP %s +%.3f %s", a1, Rel(guid, now), guid:sub(-8))
            else
                traceUntil[guid] = nil
            end
        end
        -- Repaint now, not on the next 0.1s pass, so the bars move on in the
        -- same frame the HP rises.
        if not guid or not hots[guid] then return end
        if OnHealthEvent(guid, GetTime()) then
            PaintAll()
        else
            -- Not a tick: just remember the new health, so a tick's flash
            -- starts from exactly where the HP was before that tick.
            for _, ov in pairs(overlays) do
                local u = OverlayUnit(ov.button)
                if type(u) == "string" and PlainGUID(u) == guid then
                    ov.prevHP = UnitHealth(u)
                end
            end
        end
    elseif event == "UNIT_AURA" then
        if issecret(a1) or type(a1) ~= "string" then return end
        if (a1 == "player" or a1 == "pet" or a1:match("^party%d$") or a1:match("^raid%d+$")
            or a1:match("^partypet%d$") or a1:match("^raidpet%d+$")) and AurasReadable() then
            SyncUnitFromAuras(a1)
            PaintAll()
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

------------------------------------------------------------------------------
-- API for the settings window and minimap button (Config.lua, Minimap.lua)
------------------------------------------------------------------------------

HF.SHOW_KEYS = { "party", "player", "target", "targettarget", "focus", "focustarget", "pet" }
HF.SHOW_LABELS = {
    party = "Party and raid frames", player = "Player", target = "Target",
    targettarget = "Target of target", focus = "Focus", focustarget = "Focus target", pet = "Pets",
}

function HF.SetEnabled(on)
    db.enabled = on and true or false
    PaintAll()
end

function HF.SetAlpha(n)
    db.alpha = n
    RefreshColors()
end

function HF.SetTickAlpha(n)
    db.tickAlpha = n
    RefreshColors()
end

function HF.SetColor(c)
    db.color = { r = c.r, g = c.g, b = c.b }
    RefreshColors()
end

function HF.SetFlash(on)
    db.flash = on and true or false
end

function HF.SetShare(on)
    db.share = on and true or false
end

function HF.SetShowOthers(on)
    db.showOthers = on and true or false
    PaintAll()
end

function HF.SetPetDirect(on)
    db.petDirect = on and true or false
    PaintAll()
end

function HF.SetShown(key, on)
    db.show[key] = on and true or false
    PaintAll()
end

function HF.IsTesting() return testMode end

function HF.SetTest(on)
    testMode = on and true or false
    ScanButtons()
    PaintAll()
end

-- Back to the defaults. The minimap button keeps its place and visibility.
function HF.ResetAll()
    for k, v in pairs(DEFAULTS) do
        if k ~= "minimap" then
            if type(v) == "table" then
                db[k] = {}
                for k2, v2 in pairs(v) do db[k][k2] = v2 end
            else
                db[k] = v
            end
        end
    end
    RefreshColors()
    PaintAll()
end

------------------------------------------------------------------------------
-- Slash command
------------------------------------------------------------------------------

local function OnOff(rest, cur)
    if rest == "on" then return true elseif rest == "off" then return false end
    return not cur
end

SLASH_HOTFORECAST1 = "/hotf"
SLASH_HOTFORECAST2 = "/hotforecast"
SlashCmdList.HOTFORECAST = function(msg)
    if not db then return end
    local cmd, rest = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    if cmd == "" or cmd == "config" or cmd == "options" then
        if HF.ToggleConfig then HF.ToggleConfig() end
    elseif cmd == "on" or cmd == "off" then
        HF.SetEnabled(cmd == "on")
        Print(db.enabled and "on." or "off.")
    elseif cmd == "toggle" then
        HF.SetEnabled(not db.enabled)
        Print(db.enabled and "on." or "off.")
    elseif cmd == "alpha" then
        local n = tonumber(rest)
        if n and n >= 0 and n <= 100 then
            HF.SetAlpha(n)
            Print("opacity " .. n .. "%.")
        else
            Print("usage: /hotf alpha 0-100")
        end
    elseif cmd == "tickalpha" then
        local n = tonumber(rest)
        if n and n >= 0 and n <= 100 then
            HF.SetTickAlpha(n)
            Print("next-tick opacity " .. n .. "%.")
        else
            Print("usage: /hotf tickalpha 0-100")
        end
    elseif cmd == "share" then
        HF.SetShare(OnOff(rest, db.share))
        Print("sharing " .. (db.share and "on: your HoTs go to the group." or "off."))
    elseif cmd == "show" then
        if rest == "mine" or rest == "all" then
            HF.SetShowOthers(rest == "all")
            if HF.RefreshConfig then HF.RefreshConfig() end
        end
        Print(db.showOthers and "showing everyone's HoTs (other HoTForecast users' too)."
            or "showing only your HoTs.")
    elseif cmd == "flash" then
        HF.SetFlash(OnOff(rest, db.flash))
        Print("tick flash " .. (db.flash and "on." or "off."))
    elseif cmd == "color" then
        local r, g, b = rest:match("^([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)$")
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        if r and g and b then
            if r > 1 or g > 1 or b > 1 then r, g, b = r / 255, g / 255, b / 255 end
            HF.SetColor({ r = r, g = g, b = b })
            Print(string.format("colour %.2f %.2f %.2f.", r, g, b))
        else
            Print("usage: /hotf color <r> <g> <b>  (0-1 or 0-255)")
        end
    elseif cmd == "test" then
        HF.SetTest(not testMode)
        if HF.RefreshConfig then HF.RefreshConfig() end
        Print(testMode and "test bars on (10% next tick + 20% rest on every frame). /hotf test again to stop."
            or "test bars off.")
    elseif cmd == "trace" then
        if rest == "clear" then
            db.trace = {}
            Print("trace cleared.")
        elseif tracing then
            tracing = false
            Print("trace off (" .. #(db.trace or {}) .. " lines). /reload to save it.")
        else
            db.trace = db.trace or {}
            tracing = true
            Trace("---- trace on")
            Print("trace on. Cast one HoT on someone who isn't taking damage, "
                .. "let it run out, then /hotf trace again and /reload.")
        end
    elseif cmd == "debug" then
        local n, now = 0, GetTime()
        for _ in pairs(overlays) do n = n + 1 end
        Print(n .. " frames attached.")
        if lastCast then
            Print(string.format("last HoT cast: %s on \"%s\" -> %s", lastCast.spell or "?",
                lastCast.target or "?", lastCast.result or "?"))
        end
        if UnitExists("target") then
            local okA, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "target", 1, "HELPFUL|PLAYER")
            Print(string.format("target: name %s, GUID %s, your buffs readable %s",
                Show(UnitName("target")), Show(UnitGUID("target")),
                okA and (aura and "yes" or "yes (none)") or "no"))
        end
        Print(string.format("sharing %s, channel %s: sent %d, failed %d (last %s), received %d, unreadable %d, bad %d",
            (db.share and "on" or "off") .. (db.showOthers and ", showing all" or ", showing mine"), GroupChannel() or "none", comm.sent, comm.failed,
            comm.lastResult, comm.recv, comm.secret, comm.bad))
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
        Print("/hotf opens the settings. Also: on | off | alpha <0-100> | tickalpha <0-100> | flash [on|off] | share [on|off] | show mine|all | color <r g b> | test | debug | trace [clear]")
    end
end
