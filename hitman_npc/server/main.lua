local RESOURCE = 'hitman_npc'
local KVP_PROFILE = RESOURCE .. ':profile:'

local Profiles = {}      -- [charId] = { rep, kills, earned, failed }
local Sessions = {}      -- [src]    = { offers, offersAt, contract, cooldownUntil }
local LastCall = {}      -- [src]    = { [key] = timestamp }
local ContractSeq = 0
local OfferSeq = 0

-- Server side entity checks need OneSync.
local oneSync = GetConvar('onesync', 'off')
local UseValidation = Config.ServerValidation
    and (oneSync ~= 'off' or GetConvar('onesync_enabled', 'false') == 'true')

--------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------
local function now()
    return os.time()
end

local function debugLog(...)
    if Config.Debug then print(('^3[%s:debug]^7'):format(RESOURCE), ...) end
end

local function Log(title, text)
    print(('^5[%s]^7 %s: %s'):format(RESOURCE, title, text))
    local hook = Config.Webhook
    if hook and hook.url and hook.url ~= '' then
        PerformHttpRequest(hook.url, function() end, 'POST', json.encode({
            username = hook.name or 'Hitman Contracts',
            embeds = { {
                title = title,
                description = text,
                color = 12134463,
                timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
            } },
        }), { ['Content-Type'] = 'application/json' })
    end
end

local function rateLimit(src, key, ms)
    local t = GetGameTimer()
    LastCall[src] = LastCall[src] or {}
    local last = LastCall[src][key]
    if last and t - last < ms then return false end
    LastCall[src][key] = t
    return true
end

local function pick(list)
    return list[math.random(#list)]
end

local function roundTo(n, step)
    return math.floor(n / step + 0.5) * step
end

local function getSession(src)
    local s = Sessions[src]
    if not s then
        s = { cooldownUntil = 0, offersAt = 0 }
        Sessions[src] = s
    end
    return s
end

--------------------------------------------------------------------------
-- profile (reputation) - persisted in resource KVP, keyed by character
--------------------------------------------------------------------------
local function getProfile(charId)
    local p = Profiles[charId]
    if p then return p end
    local raw = GetResourceKvpString(KVP_PROFILE .. charId)
    local decoded = raw and json.decode(raw)
    p = type(decoded) == 'table' and decoded or {}
    p.rep = math.max(0, math.floor(tonumber(p.rep) or 0))
    p.kills = math.floor(tonumber(p.kills) or 0)
    p.earned = math.floor(tonumber(p.earned) or 0)
    p.failed = math.floor(tonumber(p.failed) or 0)
    Profiles[charId] = p
    return p
end

local function saveProfile(charId)
    local p = Profiles[charId]
    if p then SetResourceKvp(KVP_PROFILE .. charId, json.encode(p)) end
end

local function levelFor(rep)
    local idx = 1
    for i, lvl in ipairs(Config.Levels) do
        if rep >= lvl.rep then idx = i end
    end
    return idx, Config.Levels[idx], Config.Levels[idx + 1]
end

--------------------------------------------------------------------------
-- access rules
--------------------------------------------------------------------------
local function countPolice()
    local lookup = {}
    for _, job in ipairs(Config.PoliceJobs) do lookup[job] = true end
    local n = 0
    for _, id in ipairs(GetPlayers()) do
        local job = Bridge.GetJob(tonumber(id))
        if job and lookup[job] then n = n + 1 end
    end
    return n
end

-- returns charId on success, or nil + locale key + argument
local function checkAccess(src)
    if not Bridge.ready then return nil, 'err_not_ready' end
    local charId = Bridge.GetCharId(src)
    if not charId then return nil, 'err_no_char' end
    if Config.RequireJob and Bridge.GetJob(src) ~= Config.JobName then
        return nil, 'err_job'
    end
    if Config.MinPolice > 0 and countPolice() < Config.MinPolice then
        return nil, 'err_police', Config.MinPolice
    end
    return charId
end

local function nearBroker(src)
    if not UseValidation then return true end
    local ped = GetPlayerPed(src)
    if ped == 0 then return true end
    local b = Config.Broker.coords
    return #(GetEntityCoords(ped) - vec3(b.x, b.y, b.z)) <= 15.0
end

--------------------------------------------------------------------------
-- offers
--------------------------------------------------------------------------
local function unlockedTiers(rep)
    local list = {}
    for tier, def in ipairs(Config.Tiers) do
        if rep >= def.unlockRep then list[#list + 1] = tier end
    end
    return list
end

local function locationsForTier(tier)
    local list = {}
    for idx, loc in ipairs(Config.Locations) do
        for _, t in ipairs(loc.tiers or {}) do
            if t == tier then
                list[#list + 1] = idx
                break
            end
        end
    end
    return list
end

local function generateOffers(profile)
    local tiers = unlockedTiers(profile.rep)
    local _, level = levelFor(profile.rep)
    local offers, usedLocations = {}, {}

    for _ = 1, Config.OfferCount do
        local tier = pick(tiers)
        local def = Config.Tiers[tier]

        local pool, free = locationsForTier(tier), {}
        for _, idx in ipairs(pool) do
            if not usedLocations[idx] then free[#free + 1] = idx end
        end
        local locIdx
        if #free > 0 then
            locIdx = pick(free)
        elseif #pool > 0 then
            locIdx = pick(pool)
        else
            locIdx = math.random(#Config.Locations)
        end
        usedLocations[locIdx] = true

        local gender = (math.random() < (Config.Targets.femaleChance or 0)) and 'female' or 'male'
        local name = ('%s %s'):format(pick(Config.Targets[gender].names), pick(Config.Targets.surnames))

        local base = math.random(def.reward.min, def.reward.max)
        local reward = roundTo(base * level.payMult * (Config.Payment.multiplier or 1.0), 50)

        local bonuses = {}
        for key in pairs(Config.Bonuses) do
            if math.random() < Config.BonusChance then bonuses[#bonuses + 1] = key end
        end
        table.sort(bonuses)

        OfferSeq = OfferSeq + 1
        offers[#offers + 1] = {
            id = OfferSeq,
            tier = tier,
            location = locIdx,
            target = name,
            gender = gender,
            reward = reward,
            timeLimit = def.timeLimit,
            guards = math.random(def.guards.min, def.guards.max),
            bonuses = bonuses,
        }
    end
    return offers
end

local function bonusInfo(keys)
    local list = {}
    for _, key in ipairs(keys) do
        local b = Config.Bonuses[key]
        if b then
            list[#list + 1] = { key = key, percent = b.percent, label = L('bonus_' .. key) }
        end
    end
    return list
end

local function publicOffer(o)
    local def = Config.Tiers[o.tier]
    return {
        id = o.id,
        tier = o.tier,
        tierLabel = def.label,
        target = o.target,
        location = Config.Locations[o.location].label,
        reward = o.reward,
        timeLimit = o.timeLimit,
        guards = o.guards,
        bonuses = bonusInfo(o.bonuses),
    }
end

local function publicContract(c)
    local def = Config.Tiers[c.tier]
    return {
        id = c.id,
        tier = c.tier,
        tierLabel = def.label,
        target = c.target,
        location = Config.Locations[c.location].label,
        reward = c.reward,
        timeLimit = c.timeLimit,
        remaining = math.max(0, c.expiresAt - now()),
        guards = c.guards,
        bonuses = bonusInfo(c.bonuses),
    }
end

-- what the client needs to run the mission
local function clientContract(c)
    local data = publicContract(c)
    data.locationIndex = c.location
    data.gender = c.gender
    return data
end

local function buildBoard(src, charId)
    local session = getSession(src)
    local profile = getProfile(charId)

    if not session.offers or now() - session.offersAt > Config.OfferLifetime then
        session.offers = generateOffers(profile)
        session.offersAt = now()
    end

    local _, level, nextLevel = levelFor(profile.rep)
    local offers = {}
    for _, o in ipairs(session.offers) do offers[#offers + 1] = publicOffer(o) end

    return {
        profile = {
            rep = profile.rep,
            kills = profile.kills,
            earned = profile.earned,
            failed = profile.failed,
            level = level.name,
            levelRep = level.rep,
            payMult = level.payMult,
            nextName = nextLevel and nextLevel.name or nil,
            nextRep = nextLevel and nextLevel.rep or nil,
        },
        offers = offers,
        cooldown = math.max(0, session.cooldownUntil - now()),
        active = session.contract and publicContract(session.contract) or nil,
        currency = Config.Currency,
    }
end

--------------------------------------------------------------------------
-- entity helpers (OneSync)
--------------------------------------------------------------------------
local function getEntity(netId)
    if not netId then return nil end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if ent and ent ~= 0 and DoesEntityExist(ent) then return ent end
    return nil
end

local function deleteContractEntities(c)
    if not UseValidation then return end
    local ids = { c.targetNetId }
    for _, id in ipairs(c.guardNetIds or {}) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do
        local ent = getEntity(id)
        if ent then DeleteEntity(ent) end
    end
end

local function scheduleCleanup(c, delaySeconds)
    if delaySeconds <= 0 then
        deleteContractEntities(c)
    else
        SetTimeout(delaySeconds * 1000, function() deleteContractEntities(c) end)
    end
end

--------------------------------------------------------------------------
-- ending a contract
--------------------------------------------------------------------------
local END_REASONS = {
    cancelled = { key = 'contract_cancelled', kind = 'error', penalty = 'cancelPenalty' },
    failed    = { key = 'contract_failed',    kind = 'error', penalty = 'failPenalty' },
    expired   = { key = 'contract_expired',   kind = 'error', penalty = 'failPenalty' },
    stolen    = { key = 'contract_stolen',    kind = 'info', void = true },
    lost      = { key = 'contract_lost',      kind = 'info', void = true },
    invalid   = { key = 'contract_invalid',   kind = 'info', void = true },
}

local function endContract(src, reason)
    local session = Sessions[src]
    local c = session and session.contract
    if not c then return end
    local info = END_REASONS[reason]
    if not info then return end

    session.contract = nil
    session.offers = nil
    c.state = 'closed'

    local penalty = 0
    if info.penalty then
        penalty = Config.Reputation[info.penalty] or 0
        local profile = getProfile(c.charId)
        profile.rep = math.max(0, profile.rep - penalty)
        profile.failed = profile.failed + 1
        saveProfile(c.charId)
    end
    session.cooldownUntil = now() + (info.void and Config.VoidCooldown or Config.Cooldown)

    scheduleCleanup(c, 5)
    Bridge.Notify(src, L(info.key, penalty), info.kind)
    TriggerClientEvent('hitman_npc:client:finish', src, reason)
    Log('Contract ' .. reason, ('#%d %s (%s) - %s'):format(c.id, c.target, Config.Tiers[c.tier].label, c.charId))
end

-- A contract belongs to a character. If the player switched characters without
-- reconnecting, the old character's contract is voided.
local function dropForeignContract(src, charId)
    local session = Sessions[src]
    local c = session and session.contract
    if c and c.charId ~= charId then
        endContract(src, 'invalid')
        return true
    end
    return false
end

--------------------------------------------------------------------------
-- verification of the kill
--------------------------------------------------------------------------
local function isOtherPlayerPed(entity, src)
    for _, id in ipairs(GetPlayers()) do
        local pid = tonumber(id)
        if pid ~= src and GetPlayerPed(pid) == entity then return true end
    end
    return false
end

-- 'ok' | 'stolen' | 'pending' (not provable yet, client will retry) | 'far' | 'unknown'
local function verifyKill(src, c)
    local ent = getEntity(c.targetNetId)
    if not ent then return 'pending' end
    if GetEntityHealth(ent) > 100 then return 'pending' end

    local playerPed = GetPlayerPed(src)
    if playerPed == 0 then return 'ok' end

    if #(GetEntityCoords(playerPed) - GetEntityCoords(ent)) > Config.MaxKillDistance then
        return 'far'
    end

    local killer = GetPedSourceOfDeath(ent)
    if killer and killer ~= 0 then
        if killer == playerPed then return 'ok' end
        local vehicle = GetVehiclePedIsIn(playerPed, false)
        if vehicle ~= 0 and killer == vehicle then return 'ok' end
        if isOtherPlayerPed(killer, src) then return 'stolen' end
    end
    if Config.StrictKillCheck then return 'unknown' end
    return 'ok'
end

--------------------------------------------------------------------------
-- net events
--------------------------------------------------------------------------
RegisterNetEvent('hitman_npc:server:openBoard', function()
    local src = source
    if not rateLimit(src, 'openBoard', 800) then return end

    local charId, errKey, errArg = checkAccess(src)
    if not charId then return Bridge.Notify(src, L(errKey, errArg), 'error') end
    dropForeignContract(src, charId)
    if not nearBroker(src) then return Bridge.Notify(src, L('err_too_far'), 'error') end

    TriggerClientEvent('hitman_npc:client:board', src, buildBoard(src, charId))
end)

RegisterNetEvent('hitman_npc:server:accept', function(offerId)
    local src = source
    if not rateLimit(src, 'accept', 1000) then return end

    local charId, errKey, errArg = checkAccess(src)
    if not charId then return Bridge.Notify(src, L(errKey, errArg), 'error') end
    dropForeignContract(src, charId)

    local session = getSession(src)
    if session.contract then return Bridge.Notify(src, L('err_active'), 'error') end

    local remaining = session.cooldownUntil - now()
    if remaining > 0 then
        return Bridge.Notify(src, L('err_cooldown', Duration(remaining)), 'error')
    end
    if not nearBroker(src) then return Bridge.Notify(src, L('err_too_far'), 'error') end

    offerId = tonumber(offerId)
    local offer
    for _, o in ipairs(session.offers or {}) do
        if o.id == offerId then offer = o break end
    end
    if not offer then
        Bridge.Notify(src, L('err_offer_gone'), 'error')
        return TriggerClientEvent('hitman_npc:client:board', src, buildBoard(src, charId))
    end

    local profile = getProfile(charId)
    if profile.rep < Config.Tiers[offer.tier].unlockRep then
        return Bridge.Notify(src, L('err_locked'), 'error')
    end

    ContractSeq = ContractSeq + 1
    local c = {
        id = ContractSeq,
        charId = charId,
        tier = offer.tier,
        location = offer.location,
        target = offer.target,
        gender = offer.gender,
        reward = offer.reward,
        timeLimit = offer.timeLimit,
        guards = offer.guards,
        bonuses = offer.bonuses,
        startedAt = now(),
        expiresAt = now() + offer.timeLimit,
        state = 'active',
        guardNetIds = {},
    }
    session.contract = c
    session.offers = nil

    TriggerClientEvent('hitman_npc:client:start', src, clientContract(c))
    Bridge.Notify(src, L('contract_accepted', c.target), 'success')
    Log('Contract accepted', ('#%d %s (%s) %s - %s'):format(
        c.id, c.target, Config.Tiers[c.tier].label, Money(c.reward), charId))
end)

RegisterNetEvent('hitman_npc:server:cancel', function()
    local src = source
    if not rateLimit(src, 'cancel', 1000) then return end
    local session = Sessions[src]
    if not session or not session.contract then
        return Bridge.Notify(src, L('err_no_active'), 'error')
    end
    endContract(src, 'cancelled')
end)

-- the client reports the ped network ids once the target and guards exist
RegisterNetEvent('hitman_npc:server:register', function(contractId, targetNetId, guardNetIds)
    local src = source
    if not rateLimit(src, 'register', 1000) then return end
    local session = Sessions[src]
    local c = session and session.contract
    if not c or c.id ~= tonumber(contractId) or c.state ~= 'active' then return end
    if c.targetNetId then return end -- the first registered target is the target

    targetNetId = tonumber(targetNetId)
    if not targetNetId then return end
    c.targetNetId = targetNetId
    c.guardNetIds = {}
    if type(guardNetIds) == 'table' then
        for i = 1, math.min(#guardNetIds, 12) do
            local id = tonumber(guardNetIds[i])
            if id then c.guardNetIds[#c.guardNetIds + 1] = id end
        end
    end

    if not UseValidation then
        c.registered = true
        return
    end

    CreateThread(function()
        local loc = Config.Locations[c.location]
        local maxDistance = (loc.scatter or 25.0) + 120.0
        for _ = 1, 16 do
            if c.state ~= 'active' then return end
            local ent = getEntity(targetNetId)
            if ent then
                local pos = GetEntityCoords(ent)
                if GetEntityType(ent) == 1 and #(pos - loc.coords) <= maxDistance then
                    c.registered = true
                    return
                end
                if pos.x ~= 0.0 or pos.y ~= 0.0 then break end -- synced, but in the wrong place
            end
            Wait(250)
        end
        if c.state == 'active' and not c.registered then
            debugLog('target registration failed for contract', c.id)
            endContract(src, 'invalid')
        end
    end)
end)

RegisterNetEvent('hitman_npc:server:complete', function(contractId, report)
    local src = source
    if not rateLimit(src, 'complete', 1500) then return end

    local session = Sessions[src]
    local c = session and session.contract
    if not c or c.id ~= tonumber(contractId) or c.state ~= 'active' then return end

    if Bridge.GetCharId(src) ~= c.charId then return endContract(src, 'invalid') end
    if now() > c.expiresAt + 5 then return endContract(src, 'expired') end
    report = type(report) == 'table' and report or {}

    if UseValidation then
        if not c.registered then return end -- registration still in flight, the client retries
        local verdict = verifyKill(src, c)
        if verdict == 'stolen' then return endContract(src, 'stolen') end
        if verdict ~= 'ok' then
            c.verifyFails = (c.verifyFails or 0) + 1
            debugLog('kill verification', verdict, 'attempt', c.verifyFails)
            if c.verifyFails >= 4 then endContract(src, 'invalid') end
            return
        end
    end

    -- payout
    local elapsed = now() - c.startedAt
    local percent, applied = 0, {}
    for _, key in ipairs(c.bonuses) do
        local def = Config.Bonuses[key]
        local earned = false
        if key == 'fast' then
            earned = elapsed <= c.timeLimit * (def.fraction or 0.5)
        elseif key == 'headshot' then
            earned = report.headshot == true
        elseif key == 'silent' then
            earned = report.silent == true
        end
        if earned then
            percent = percent + def.percent
            applied[#applied + 1] = { key = key, percent = def.percent }
        end
    end
    local total = math.floor(c.reward * (1 + percent / 100))

    session.contract = nil
    session.offers = nil
    session.cooldownUntil = now() + Config.Cooldown
    c.state = 'done'

    local paid = Bridge.AddMoney(src, Config.Payment.account, total, 'hitman-npc-contract')
    if not paid then
        Log('PAYMENT FAILED', ('#%d %s owed %s'):format(c.id, c.charId, Money(total)))
    end

    local profile = getProfile(c.charId)
    local levelBefore = levelFor(profile.rep)
    profile.rep = profile.rep + Config.Tiers[c.tier].repReward
    profile.kills = profile.kills + 1
    profile.earned = profile.earned + total
    saveProfile(c.charId)
    local levelAfter, level = levelFor(profile.rep)

    scheduleCleanup(c, Config.CleanupDelay)
    TriggerClientEvent('hitman_npc:client:finish', src, 'completed', { payout = total })

    Bridge.Notify(src, L('contract_complete', Money(total)), 'success')
    for _, b in ipairs(applied) do
        Bridge.Notify(src, L('contract_bonus', L('bonus_' .. b.key), b.percent), 'success')
    end
    if levelAfter > levelBefore then
        Bridge.Notify(src, L('level_up', level.name), 'success')
    end
    Log('Contract complete', ('#%d %s paid %s (base %s, +%d%%) - %s'):format(
        c.id, c.target, Money(total), Money(c.reward), percent, c.charId))
end)

local CLIENT_FAIL_REASONS = { died = 'failed', spawn_failed = 'lost', lost = 'lost' }

RegisterNetEvent('hitman_npc:server:fail', function(contractId, reason)
    local src = source
    if not rateLimit(src, 'fail', 500) then return end
    local session = Sessions[src]
    local c = session and session.contract
    if not c or c.id ~= tonumber(contractId) or c.state ~= 'active' then return end
    local mapped = CLIENT_FAIL_REASONS[tostring(reason)]
    if mapped then endContract(src, mapped) end
end)

--------------------------------------------------------------------------
-- housekeeping
--------------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait(5000)
        local t = now()
        for src, session in pairs(Sessions) do
            local c = session.contract
            if c and c.state == 'active' and t >= c.expiresAt then
                endContract(src, 'expired')
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    local session = Sessions[src]
    if session and session.contract then
        session.contract.state = 'closed'
        scheduleCleanup(session.contract, 0)
    end
    Sessions[src] = nil
    LastCall[src] = nil
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for _, session in pairs(Sessions) do
        if session.contract then scheduleCleanup(session.contract, 0) end
    end
end)

--------------------------------------------------------------------------
-- admin command (needs: add_ace group.admin command.<name> allow)
--------------------------------------------------------------------------
RegisterCommand(Config.Commands.admin, function(source, args)
    local function reply(message)
        if source == 0 then print(message) else Bridge.Notify(source, message, 'info') end
    end

    local sub, target, value = args[1], tonumber(args[2]), tonumber(args[3])
    if not sub or not target or not GetPlayerName(target) then
        return reply(('usage: /%s reset <id> | setrep <id> <rep> | give <id> <amount>'):format(Config.Commands.admin))
    end

    if sub == 'reset' then
        local session = Sessions[target]
        if session then
            if session.contract then
                session.contract.state = 'closed'
                scheduleCleanup(session.contract, 0)
                TriggerClientEvent('hitman_npc:client:finish', target, 'invalid')
            end
            session.contract = nil
            session.offers = nil
            session.cooldownUntil = 0
        end
        reply(('reset player %d'):format(target))
    elseif sub == 'setrep' and value then
        local charId = Bridge.GetCharId(target)
        if not charId then return reply('character not loaded') end
        local profile = getProfile(charId)
        profile.rep = math.max(0, math.floor(value))
        saveProfile(charId)
        if Sessions[target] then Sessions[target].offers = nil end
        reply(('reputation of player %d is now %d'):format(target, profile.rep))
    elseif sub == 'give' and value then
        local ok = Bridge.AddMoney(target, 'cash', value, 'hitman-npc-admin')
        reply(ok and ('gave %s to player %d'):format(Money(value), target) or 'could not add money')
    else
        reply(('usage: /%s reset <id> | setrep <id> <rep> | give <id> <amount>'):format(Config.Commands.admin))
    end
end, true)

CreateThread(function()
    Wait(1000)
    print(('^2[%s]^7 started. Server side kill validation: %s'):format(
        RESOURCE, UseValidation and 'ON (OneSync)' or 'OFF'))
end)
