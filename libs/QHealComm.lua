--[[ QHealComm.lua
     Standalone heal communication library for QuickHeal.
     Based on pfUI libpredict - delegates to it when available,
     otherwise uses an identical standalone clone.
     Compatible with HealComm addon message protocol.
]]--

HealComm = {}

---------- STATE ----------
local player -- set lazily (UnitName may not be ready at load time)

local function getPlayerName()
    if not player then player = UnitName("player") end
    return player
end

-- Pending heal (set by QuickHeal before CastSpell, consumed by SPELLCAST_START)
local myPendingTarget = nil
local myPendingAmount = 0
local myPendingTime = 0

-- Current heal (set when SPELLCAST_START fires, cleared on cast end)
local myCurrentTarget = nil
local myCurrentAmount = 0
local isHealing = false
local isResurrecting = false

-- Standalone data tables (used when pfUI is not available)
local heals = {}       -- [targetName][senderName] = { [1]=amount, [2]=timeout }
local hots = {}        -- [targetName][spell] = { duration=N, start=T, rank=R }
local ress = {}        -- [targetName][senderName] = true
local ress_timers = {} -- [target][sender] = expiry_timestamp
local evts = {}        -- [timestamp] = { target1, ... }
local RESS_TIMEOUT = 60

-- Nampower check
local has_nampower = GetCastInfo and true or false

---------- pfUI DETECTION ----------

local function getLibpredict()
    return pfUI and pfUI.api and pfUI.api.libpredict
end

---------- HELPERS ----------

local function SendHealCommMsg(msg)
    if getLibpredict() then return end -- pfUI handles sending
    if GetNumRaidMembers() > 0 then
        SendAddonMessage("HealComm", msg, "RAID")
    elseif GetNumPartyMembers() > 0 then
        SendAddonMessage("HealComm", msg, "PARTY")
    end
end

local function SendResCommMsg(msg)
    if getLibpredict() then return end
    if GetNumRaidMembers() > 0 then
        SendAddonMessage("CTRA", msg, "RAID")
    elseif GetNumPartyMembers() > 0 then
        SendAddonMessage("CTRA", msg, "PARTY")
    end
end

-- Resolve unit argument to player name (accepts unit ID or name)
local function resolveName(unit)
    if not unit then return nil end
    local ok, name = pcall(UnitName, unit)
    if ok and name and name ~= UNKNOWNOBJECT and name ~= UKNOWNBEING then
        return name
    end
    -- Already a name (or unknown unit ID)
    if unit ~= UNKNOWNOBJECT and unit ~= UKNOWNBEING then
        return unit
    end
    return nil
end

---------- STANDALONE: INTERNAL TRACKING ----------

local function AddEvent(time, target)
    evts[time] = evts[time] or {}
    table.insert(evts[time], target)
end

local function ProcessHeal(sender, target, amount, duration)
    if not sender or not target or not amount or not duration then return end
    amount = tonumber(amount) or 0
    duration = tonumber(duration) or 0

    local now = GetTime()
    local timeout = duration / 1000 + now
    heals[target] = heals[target] or {}
    heals[target][sender] = { amount, timeout }
    AddEvent(timeout, target)
end

local function ProcessHealStop(sender)
    for target, senders in pairs(heals) do
        for s in pairs(senders) do
            if sender == s then
                heals[target][s] = nil
            end
        end
    end
end

local function ProcessHealDelay(sender, delay)
    delay = (tonumber(delay) or 0) / 1000
    for target, senders in pairs(heals) do
        for s, amount in pairs(senders) do
            if sender == s then
                amount[2] = amount[2] + delay
                AddEvent(amount[2], target)
            end
        end
    end
end

local function ProcessHot(sender, target, spell, duration, startTime, rank)
    hots[target] = hots[target] or {}
    hots[target][spell] = hots[target][spell] or {}

    if spell == "Regr" then duration = 20 end
    duration = tonumber(duration) or duration

    -- Rank protection: don't overwrite higher rank HoT with lower rank
    local existing = hots[target][spell]
    if existing and existing.rank and rank then
        local existingRank = tonumber(existing.rank) or 0
        local newRank = tonumber(rank) or 0
        local now = GetTime()
        local timeleft = ((existing.start or 0) + (existing.duration or 0)) - now
        if timeleft > 0 and newRank > 0 and newRank < existingRank then
            return -- don't overwrite
        end
    end

    local now = GetTime()
    hots[target][spell].duration = duration
    hots[target][spell].start = startTime or now
    hots[target][spell].rank = rank
end

local function ProcessRess(sender, target)
    ress[target] = ress[target] or {}
    ress[target][sender] = true
end

local function ProcessRessSetTimer(sender, target)
    ress_timers[target] = ress_timers[target] or {}
    local existing = ress_timers[target][sender]
    if not existing or GetTime() >= existing then
        ress_timers[target][sender] = GetTime() + RESS_TIMEOUT
    end
end

local function ProcessRessStop(sender)
    local now = GetTime()
    for target, senders in pairs(ress) do
        for s in pairs(senders) do
            if sender == s then
                local expiry = ress_timers[target] and ress_timers[target][s]
                if not expiry or now >= expiry then
                    ress[target][s] = nil
                    if ress_timers[target] then ress_timers[target][s] = nil end
                end
            end
        end
    end
end

---------- STANDALONE: MESSAGE PARSING (identical to libpredict) ----------

local function ParseComm(sender, msg)
    local msgtype, target, heal, time, rank

    if msg == "HealStop" or msg == "Healstop" or msg == "GrpHealstop" then
        msgtype = "Stop"
    elseif msg == "Resurrection/stop/" then
        msgtype = "RessStop"
    elseif msg then
        local msgobj
        if strsplit then
            msgobj = { strsplit("/", msg) }
        else
            msgobj = {}
            for part in string.gfind(msg .. "/", "([^/]*)/") do
                if part ~= "" then table.insert(msgobj, part) end
            end
        end

        if msgobj and msgobj[1] and msgobj[2] then
            if msgobj[1] == "GrpHealdelay" or msgobj[1] == "Healdelay" then
                msgtype, time = "Delay", msgobj[2]
            end

            if msgobj[1] == "Resurrection" and msgobj[2] then
                msgtype, target = "Ress", msgobj[2]
            end

            if msgobj[1] == "Heal" and msgobj[2] then
                msgtype, target, heal, time = "Heal", msgobj[2], msgobj[3], msgobj[4]
            end

            if msgobj[1] == "GrpHeal" and msgobj[2] then
                msgtype, heal, time = "Heal", msgobj[2], msgobj[3]
                target = {}
                for i = 4, 8 do
                    if msgobj[i] then table.insert(target, msgobj[i]) end
                end
            end

            if msgobj[1] == "Reju" or msgobj[1] == "Renew" or msgobj[1] == "Regr" then
                msgtype, target, heal, time = "Hot", msgobj[2], msgobj[1], msgobj[3]
                local rankStr = msgobj[4]
                if rankStr and rankStr ~= "" and rankStr ~= "/" and rankStr ~= "0" then
                    rank = tonumber(rankStr)
                end
            end
        end
    end

    return msgtype, target, heal, time, rank
end

-- Duplicate HoT detection
local recentHots = {}
local DUPLICATE_WINDOW = 0.5

local function ParseChatMessage(sender, msg, comm)
    local msgtype, target, heal, time, rank

    if comm == "HealComm" then
        msgtype, target, heal, time, rank = ParseComm(sender, msg)
    elseif comm == "CTRA" then
        local _, _, cmd, ctratarget = string.find(msg, "(%a+)%s?([^#]*)")
        if cmd and ctratarget and cmd == "RES" and ctratarget ~= "" then
            msgtype = "Ress"
            target = ctratarget
        end
    end

    if msgtype == "Stop" and sender then
        ProcessHealStop(sender)
        return
    elseif (msg == "RessStop" or msg == "RESNO") and sender then
        ProcessRessStop(sender)
        return
    elseif msgtype == "Delay" and time then
        ProcessHealDelay(sender, time)
    elseif msgtype == "Heal" and target and heal and time then
        if type(target) == "table" then
            for _, name in pairs(target) do
                ProcessHeal(sender, name, heal, time)
            end
        else
            ProcessHeal(sender, target, heal, time)
        end
    elseif msgtype == "Ress" then
        if sender ~= getPlayerName() then
            ProcessRess(sender, target)
        end
    elseif msgtype == "Hot" then
        local now = GetTime()
        local key = sender .. target .. heal
        if recentHots[key] and (now - recentHots[key]) < DUPLICATE_WINDOW then
            return
        end
        recentHots[key] = now

        -- Cleanup old entries periodically
        if not HealComm._lastCleanup or (now - HealComm._lastCleanup) > 10 then
            for k, v in pairs(recentHots) do
                if (now - v) > DUPLICATE_WINDOW then
                    recentHots[k] = nil
                end
            end
            HealComm._lastCleanup = now
        end

        -- For own HoTs: correct the startTime
        if sender == getPlayerName() then
            local existing = hots[target] and hots[target][heal]
            if existing and existing.start and existing.duration
               and (existing.start + existing.duration) > now then
                return -- don't overwrite active timer
            end
            local delay = (heal == "Regr") and 0.3 or 0
            ProcessHot(sender, target, heal, time, now - delay, rank)
            return
        end
        ProcessHot(sender, target, heal, time, nil, rank)
    end
end

---------- PUBLIC API ----------

function HealComm:getHeal(unit)
    local lp = getLibpredict()
    if lp then
        -- pfUI's UnitGetIncomingHeals expects a unit ID
        -- Try as unit ID first (pcall in case it's a name, not a valid unit ID)
        local ok, name = pcall(UnitName, unit)
        if ok and name then
            return lp:UnitGetIncomingHeals(unit) or 0
        end
        -- Got a name instead of unit ID - find the matching unit
        if unit == getPlayerName() then
            return lp:UnitGetIncomingHeals("player") or 0
        end
        for i = 1, GetNumRaidMembers() do
            if UnitName("raid" .. i) == unit then
                return lp:UnitGetIncomingHeals("raid" .. i) or 0
            end
        end
        for i = 1, GetNumPartyMembers() do
            if UnitName("party" .. i) == unit then
                return lp:UnitGetIncomingHeals("party" .. i) or 0
            end
        end
        return 0
    end

    -- Standalone path
    local name = resolveName(unit)
    if not name then return 0 end

    local sumheal = 0
    if not heals[name] then return 0 end

    local now = GetTime()
    for sender, amount in pairs(heals[name]) do
        if amount[2] <= now then
            heals[name][sender] = nil
        else
            sumheal = sumheal + amount[1]
        end
    end
    return sumheal
end

function HealComm:GetMyPendingHeal(unitName)
    if not myCurrentTarget then return 0 end
    local name = resolveName(unitName)
    if name and myCurrentTarget == name then return myCurrentAmount end
    return 0
end

function HealComm:getRejuTime(unit)
    local lp = getLibpredict()
    if lp then return lp:GetHotDuration(unit, "Reju") end

    local name = resolveName(unit)
    if not name then return end
    local data = hots[name] and hots[name]["Reju"]
    if data and data.start and data.duration and (data.start + data.duration) > GetTime() then
        return data.start, data.duration
    end
end

function HealComm:getRenewTime(unit)
    local lp = getLibpredict()
    if lp then return lp:GetHotDuration(unit, "Renew") end

    local name = resolveName(unit)
    if not name then return end
    local data = hots[name] and hots[name]["Renew"]
    if data and data.start and data.duration and (data.start + data.duration) > GetTime() then
        return data.start, data.duration
    end
end

function HealComm:getRegrTime(unit)
    local lp = getLibpredict()
    if lp then return lp:GetHotDuration(unit, "Regr") end

    local name = resolveName(unit)
    if not name then return end
    local data = hots[name] and hots[name]["Regr"]
    if data and data.start and data.duration and (data.start + data.duration) > GetTime() then
        return data.start, data.duration
    end
end

function HealComm:UnitisResurrecting(unit)
    local lp = getLibpredict()
    if lp then return lp:UnitHasIncomingResurrection(unit) end

    local name = resolveName(unit)
    if not name or not ress[name] then return nil end
    for sender, val in pairs(ress[name]) do
        if val == true then return true end
    end
    return nil
end

---------- SENDING API ----------

function HealComm:SetPendingHeal(targetName, amount)
    if not targetName or not amount then return end
    myPendingTarget = targetName
    myPendingAmount = amount
    myPendingTime = GetTime()
end

function HealComm:AnnounceHealStop()
    if isHealing and not getLibpredict() then
        ProcessHealStop(getPlayerName())
        SendHealCommMsg("Healstop")
    end
    isHealing = false
    myCurrentTarget = nil
    myCurrentAmount = 0
    -- Clear pending too (cast failed entirely)
    myPendingTarget = nil
    myPendingAmount = 0
    myPendingTime = 0
end

function HealComm:AnnounceHot(targetName, spell, duration, rank)
    if not targetName or not spell or not duration then return end
    if getLibpredict() then return end -- pfUI handles via hooks

    ProcessHot(getPlayerName(), targetName, spell, duration, nil, rank)
    local rankStr = rank and tostring(rank) or "0"
    SendHealCommMsg(spell .. "/" .. targetName .. "/" .. duration .. "/" .. rankStr .. "/")
end

function HealComm:AnnounceRess(targetName)
    if not targetName then return end
    if getLibpredict() then return end

    ProcessRess(getPlayerName(), targetName)
    isResurrecting = true
    SendHealCommMsg("Resurrection/" .. targetName .. "/start/")
    SendResCommMsg("RES " .. targetName)
end

---------- EVENT FRAME ----------

local frame = CreateFrame("Frame", "QHealCommFrame")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("UNIT_HEALTH")
frame:RegisterEvent("SPELLCAST_START")
frame:RegisterEvent("SPELLCAST_STOP")
frame:RegisterEvent("SPELLCAST_FAILED")
frame:RegisterEvent("SPELLCAST_INTERRUPTED")
frame:RegisterEvent("PLAYER_LOGOUT")

-- Nampower events
if has_nampower then
    frame:RegisterEvent("SPELL_FAILED_SELF")
    frame:RegisterEvent("SPELL_DELAYED_SELF")
end

frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGOUT" then
        this:UnregisterAllEvents()
        this:SetScript("OnEvent", nil)
        return
    end

    if event == "CHAT_MSG_ADDON" then
        if getLibpredict() then return end -- pfUI handles receiving
        if arg1 == "HealComm" or arg1 == "CTRA" then
            ParseChatMessage(arg4, arg2, arg1)
        end

    elseif event == "UNIT_HEALTH" then
        if getLibpredict() then return end
        local name = UnitName(arg1)
        if name and ress[name] and not UnitIsDeadOrGhost(arg1) then
            ress[name] = nil
        end

    elseif event == "SPELLCAST_START" then
        if getLibpredict() then return end -- pfUI handles via hooks
        -- arg1 = spellName, arg2 = castTime (ms)
        if myPendingTarget and myPendingAmount > 0
           and myPendingTime and (GetTime() - myPendingTime) < 2 then
            local casttime = arg2 or 2000
            myCurrentTarget = myPendingTarget
            myCurrentAmount = myPendingAmount
            myPendingTarget = nil
            myPendingAmount = 0
            myPendingTime = 0
            isHealing = true
            ProcessHeal(getPlayerName(), myCurrentTarget, myCurrentAmount, casttime)
            SendHealCommMsg("Heal/" .. myCurrentTarget .. "/" .. myCurrentAmount .. "/" .. casttime .. "/")
        end

    elseif event == "SPELLCAST_STOP" then
        -- Cast completed successfully (or stale event)
        if getLibpredict() then return end
        -- Check for stale event (Nampower)
        if has_nampower and GetCastInfo then
            local ok, info = pcall(GetCastInfo)
            if ok and info then
                return -- cast still active, ignore stale SPELLCAST_STOP
            end
        end
        if isHealing then
            ProcessHealStop(getPlayerName())
            -- Don't send Healstop on success - timeout handles remote cleanup
            -- (matches libpredict behavior: only HealStop on failure)
            isHealing = false
            myCurrentTarget = nil
            myCurrentAmount = 0
        end

    elseif event == "SPELLCAST_FAILED" then
        HealComm:AnnounceHealStop()

    elseif event == "SPELLCAST_INTERRUPTED" then
        -- Could be SpellStopCasting (chaining) or damage interrupt
        -- Send Healstop but preserve pending (new cast may follow)
        if isHealing and not getLibpredict() then
            ProcessHealStop(getPlayerName())
            SendHealCommMsg("Healstop")
        end
        isHealing = false
        myCurrentTarget = nil
        myCurrentAmount = 0
        -- NOTE: myPendingTarget preserved for heal chaining

    elseif event == "SPELL_FAILED_SELF" then
        -- Nampower: more reliable failure detection
        HealComm:AnnounceHealStop()

    elseif event == "SPELL_DELAYED_SELF" then
        -- Nampower: pushback
        if isHealing and arg2 and not getLibpredict() then
            ProcessHealDelay(getPlayerName(), arg2)
            SendHealCommMsg("Healdelay/" .. arg2 .. "/")
        end
    end
end)

-- OnUpdate cleanup (standalone mode only)
frame:SetScript("OnUpdate", function()
    if getLibpredict() then return end

    local now = GetTime()
    if (this.tick or 0) > now then return end
    this.tick = now + 0.1 -- 10 FPS

    -- Expire timed-out heal entries
    for timestamp, targets in pairs(evts) do
        if now >= timestamp then
            evts[timestamp] = nil
        end
    end

    -- Expire ress timers
    for target, senders in pairs(ress_timers) do
        for sender, expiry in pairs(senders) do
            if now >= expiry then
                senders[sender] = nil
                if ress[target] then ress[target][sender] = nil end
            end
        end
    end
end)
