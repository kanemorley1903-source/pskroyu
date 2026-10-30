local RESOURCE = 'hitman_players'
local C = Config.Contracts
local T = Config.Tracker

local Presence = { byChar = {}, bySrc = {} } -- who is online, refreshed every few seconds
local OnDuty = {}          -- [charId] = true
local LastCall = {}        -- [src] = { [key] = ms }
local PlaceCooldown = {}   -- [charId] = unix time
local AbandonUntil = {}    -- [charId] = unix time
local CreditRetry = {}     -- [charId] = unix time before which a stuck credit is not retried

local protectedJobs = {}
for _, job in ipairs(C.protectedJobs or {}) do protectedJobs[job] = true end

Store.Load()

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

local function clamp(value, lo, hi)
    return math.max(lo, math.min(hi, value))
end

-- trims, removes control characters and caps the length (by characters)
local function sanitizeText(text, maxLen)
    text = tostring(text or '')
    if not utf8.len(text) then text = text:gsub('[\128-\255]', '?') end
    text = text:gsub('%c', ' ')
    text = text:gsub('%s+', ' ')
    text = text:match('^%s*(.-)%s*$')
    local length = utf8.len(text) or #text
    if length > maxLen then
        text = text:sub(1, utf8.offset(text, maxLen + 1) - 1)
    end
    return text
end

local function say(src, kind, key, ...)
    Bridge.Notify(src, L(key, ...), kind)
end

local function isAllowedAccount(account)
    for _, a in ipairs(C.accounts) do
        if a == account then return true end
    end
    return false
end

local function canWork(src)
    if not Config.RequireJob then return true end
    return Bridge.GetJob(src) == Config.JobName
end

local function atTerminal(src)
    if not Config.RequireTerminal then return true end
    local ped = GetPlayerPed(src)
    if ped == 0 then return false end
    local pos = GetEntityCoords(ped)
    for _, terminal in ipairs(Config.Terminals) do
        if #(pos - terminal.coords) <= (terminal.radius or 2.0) + 3.0 then return true end
    end
    return false
end

local function payoutFor(reward)
    return math.floor(reward * (100 - C.brokerCut) / 100)
end

--------------------------------------------------------------------------
-- money: hand it over now, or keep it as a credit for when the owner is back
--------------------------------------------------------------------------
local function payCharacter(charId, account, amount, reason)
    amount = math.floor(amount)
    if amount <= 0 then return 'none' end
    local src = Presence.byChar[charId]
    if src and Bridge.AddMoney(src, account, amount, reason) then return 'paid' end
    Store.AddCredit(charId, amount, account, reason)
    return 'credited'
end

local function claimCredits(src, charId)
    if not Store.HasCredits(charId) then return end
    local total, failed = 0, {}
    for _, credit in ipairs(Store.TakeCredits(charId)) do
        if Bridge.AddMoney(src, credit.account, credit.amount, credit.reason) then
            total = total + credit.amount
        else
            failed[#failed + 1] = credit
        end
    end
    for _, credit in ipairs(failed) do
        Store.AddCredit(charId, credit.amount, credit.account, credit.reason)
    end
    Store.Save()
    if total > 0 then say(src, 'success', 'credit_paid', Money(total)) end
end

--------------------------------------------------------------------------
-- queries
--------------------------------------------------------------------------
local function contractOnTarget(targetId)
    for _, c in ipairs(Store.Data().contracts) do
        if c.targetId == targetId then return c end
    end
    return nil
end

local function countPlacedBy(charId)
    local n = 0
    for _, c in ipairs(Store.Data().contracts) do
        if c.clientId == charId then n = n + 1 end
    end
    return n
end

local function claimedBy(charId)
    for _, c in ipairs(Store.Data().contracts) do
        if c.status == 'claimed' and c.hitmanId == charId then return c end
    end
    return nil
end

--------------------------------------------------------------------------
-- state sent to the board
--------------------------------------------------------------------------
local function activeInfo(c, t)
    return {
        id = c.id,
        target = c.targetName,
        description = c.description,
        payout = payoutFor(c.reward),
        remaining = math.max(0, c.claimExpiresAt - t),
        interval = T.interval,
    }
end

local function buildState(src)
    local charId = Bridge.GetCharId(src)
    local t = now()
    local duty = charId ~= nil and OnDuty[charId] == true
    local worker = canWork(src)

    local stats = charId and Store.GetStats(charId) or { kills = 0, earned = 0, placed = 0, fulfilled = 0 }
    local balances = {}
    for _, account in ipairs(C.accounts) do balances[account] = Bridge.GetMoney(src, account) end

    local state = {
        currency = Config.Currency,
        canWork = worker,
        duty = duty,
        balances = balances,
        stats = { kills = stats.kills, earned = stats.earned, placed = stats.placed, fulfilled = stats.fulfilled },
        limits = {
            minReward = C.minReward,
            maxReward = C.maxReward,
            maxDescription = C.maxDescription,
            brokerCut = C.brokerCut,
            cancelFee = C.cancelFee,
            maxPerClient = C.maxPerClient,
            accounts = C.accounts,
            selection = C.targetSelection,
        },
        cooldowns = {
            place = charId and math.max(0, (PlaceCooldown[charId] or 0) - t) or 0,
            abandon = charId and math.max(0, (AbandonUntil[charId] or 0) - t) or 0,
        },
        open = {},
        placed = {},
        active = nil,
    }
    if not charId then return state end

    for _, c in ipairs(Store.Data().contracts) do
        if c.clientId == charId then
            state.placed[#state.placed + 1] = {
                id = c.id,
                target = c.targetName,
                reward = c.reward,
                status = c.status,
                expiresIn = math.max(0, c.expiresAt - t),
                refund = c.reward - math.floor(c.reward * C.cancelFee / 100),
            }
        end
        if c.status == 'claimed' and c.hitmanId == charId then
            state.active = activeInfo(c, t)
        elseif c.status == 'open' and duty and worker and c.clientId ~= charId and c.targetId ~= charId then
            state.open[#state.open + 1] = {
                id = c.id,
                target = c.targetName,
                description = c.description,
                payout = payoutFor(c.reward),
                expiresIn = math.max(0, c.expiresAt - t),
                targetOnline = Presence.byChar[c.targetId] ~= nil,
            }
        end
    end
    table.sort(state.open, function(a, b) return a.payout > b.payout end)
    table.sort(state.placed, function(a, b) return a.id > b.id end)
    return state
end

local function respond(src, ok, key, ...)
    TriggerClientEvent('hitman_players:client:state', src, buildState(src), { ok = ok, text = L(key, ...) })
end

--------------------------------------------------------------------------
-- tracker / hunted flags
--------------------------------------------------------------------------
local function sendHunted(targetId, state)
    local src = Presence.byChar[targetId]
    if src then TriggerClientEvent('hitman_players:client:hunted', src, state) end
end

local function sendTrack(c)
    if c.hitmanSrc then
        TriggerClientEvent('hitman_players:client:track', c.hitmanSrc, activeInfo(c, now()))
    end
end

local function sendPing(c)
    c.nextPing = now() + T.interval
    local hitmanSrc = c.hitmanSrc
    if not hitmanSrc then return end

    local targetSrc = Presence.byChar[c.targetId]
    local targetPed = targetSrc and GetPlayerPed(targetSrc) or 0
    local hitmanPed = GetPlayerPed(hitmanSrc)
    if targetPed == 0 or hitmanPed == 0 then
        TriggerClientEvent('hitman_players:client:ping', hitmanSrc, { id = c.id, lost = true })
        return
    end

    local targetPos, hitmanPos = GetEntityCoords(targetPed), GetEntityCoords(hitmanPed)
    local radius = clamp(#(targetPos - hitmanPos) * T.distanceFactor, T.minRadius, T.maxRadius)
    -- the area is centred off the target so it cannot simply be walked to
    local angle = math.random() * 2.0 * math.pi
    local offset = math.random() * radius * 0.6
    TriggerClientEvent('hitman_players:client:ping', hitmanSrc, {
        id = c.id,
        x = targetPos.x + math.cos(angle) * offset,
        y = targetPos.y + math.sin(angle) * offset,
        radius = radius,
        interval = T.interval,
        first = c.pinged ~= true,
    })
    c.pinged = true
end

--------------------------------------------------------------------------
-- contract life cycle
--------------------------------------------------------------------------
local function releaseClaim(c, reason)
    local hitmanSrc, hitmanId = c.hitmanSrc, c.hitmanId
    c.status = 'open'
    c.hitmanId, c.hitmanName, c.hitmanSrc = nil, nil, nil
    c.claimedAt, c.claimExpiresAt, c.dropAt, c.nextPing, c.pinged = nil, nil, nil, nil, nil
    Store.Save()

    sendHunted(c.targetId, false)
    if hitmanSrc then
        TriggerClientEvent('hitman_players:client:track', hitmanSrc, nil)
        if reason == 'timeout' then say(hitmanSrc, 'error', 'claim_timeout', c.targetName) end
    end
    if reason == 'timeout' and hitmanId then
        AbandonUntil[hitmanId] = now() + C.abandonCooldown
    end
    Log('Claim released', ('#%d %s (%s)'):format(c.id, c.targetName, reason))
end

local function expireContract(c)
    Store.Remove(c.id)
    payCharacter(c.clientId, c.account, c.reward, 'hitman-contract-refund')
    Store.Save()

    local clientSrc = Presence.byChar[c.clientId]
    if clientSrc then
        say(clientSrc, 'info', 'contract_expired', c.targetName, Money(c.reward))
    end
    Log('Contract expired', ('#%d %s - refunded %s to %s'):format(
        c.id, c.targetName, Money(c.reward), c.clientId))
end

local function fulfilContract(c)
    local payout = payoutFor(c.reward)
    local hitmanSrc, hitmanId = c.hitmanSrc, c.hitmanId

    Store.Remove(c.id)
    Store.Data().immunity[c.targetId] = now() + C.immunity * 60
    payCharacter(hitmanId, C.payoutAccount, payout, 'hitman-contract-payout')
    Store.Save()

    local hitmanStats = Store.GetStats(hitmanId)
    hitmanStats.kills = hitmanStats.kills + 1
    hitmanStats.earned = hitmanStats.earned + payout
    Store.SaveStats(hitmanId)

    local clientStats = Store.GetStats(c.clientId)
    clientStats.fulfilled = clientStats.fulfilled + 1
    Store.SaveStats(c.clientId)

    sendHunted(c.targetId, false)
    if hitmanSrc then
        TriggerClientEvent('hitman_players:client:track', hitmanSrc, nil)
        say(hitmanSrc, 'success', 'contract_fulfilled_hitman', Money(payout))
    end
    local clientSrc = Presence.byChar[c.clientId]
    if clientSrc then say(clientSrc, 'success', 'contract_fulfilled_client', c.targetName) end

    Log('Contract fulfilled', ('#%d %s killed by %s - %s paid %s (reward %s, client %s)'):format(
        c.id, c.targetName, c.hitmanName or hitmanId, hitmanId, Money(payout), Money(c.reward), c.clientId))
end

-- returns ok, locale key, args...
local function placeContract(src, payload)
    if type(payload) ~= 'table' then return false, 'err_bad_request' end
    if not Bridge.ready then return false, 'err_not_ready' end
    local charId = Bridge.GetCharId(src)
    if not charId then return false, 'err_no_char' end
    if not atTerminal(src) then return false, 'err_terminal' end

    -- target
    local targetSrc
    if C.targetSelection == 'list' then
        targetSrc = tonumber(payload.targetId)
        if not targetSrc or not GetPlayerName(targetSrc) then return false, 'err_target_offline' end
    else
        local query = tostring(payload.target or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
        if query == '' then return false, 'err_target_unknown' end
        if tonumber(query) then
            targetSrc = tonumber(query)
            if not GetPlayerName(targetSrc) then return false, 'err_target_unknown' end
        else
            for _, id in ipairs(GetPlayers()) do
                local pid = tonumber(id)
                if (Bridge.GetName(pid) or ''):lower() == query then
                    if targetSrc then return false, 'err_target_ambiguous' end
                    targetSrc = pid
                end
            end
            if not targetSrc then return false, 'err_target_unknown' end
        end
    end

    local targetId = Bridge.GetCharId(targetSrc)
    if not targetId then return false, 'err_target_offline' end
    if targetSrc == src or targetId == charId then return false, 'err_target_self' end
    local targetJob = Bridge.GetJob(targetSrc)
    if targetJob and protectedJobs[targetJob] then return false, 'err_target_protected' end
    if (Store.Data().immunity[targetId] or 0) > now() then return false, 'err_target_immune' end
    if contractOnTarget(targetId) then return false, 'err_target_has_contract' end

    -- terms
    local reward = math.floor(tonumber(payload.reward) or 0)
    if reward < C.minReward or reward > C.maxReward then
        return false, 'err_reward_range', Money(C.minReward), Money(C.maxReward)
    end
    local account = tostring(payload.account or '')
    if not isAllowedAccount(account) then account = C.accounts[1] end

    if countPlacedBy(charId) >= C.maxPerClient then return false, 'err_max_placed', C.maxPerClient end
    local wait = (PlaceCooldown[charId] or 0) - now()
    if wait > 0 then return false, 'err_place_cooldown', Duration(wait) end

    -- build the whole contract first, so nothing can fail while the money is out
    local t = now()
    local c = {
        clientId = charId,
        clientName = Bridge.GetName(src),
        targetId = targetId,
        targetName = Bridge.GetName(targetSrc),
        description = sanitizeText(payload.description, C.maxDescription),
        reward = reward,
        account = account,
        createdAt = t,
        expiresAt = t + C.expireAfter * 60,
        status = 'open',
    }

    -- escrow, then book the contract immediately
    if not Bridge.RemoveMoney(src, account, reward, 'hitman-contract-escrow') then
        return false, 'err_money'
    end
    c.id = Store.NextId()
    Store.Add(c)
    Store.Save()
    PlaceCooldown[charId] = t + C.placeCooldown

    local stats = Store.GetStats(charId)
    stats.placed = stats.placed + 1
    Store.SaveStats(charId)

    if C.warnTarget == 'placed' then say(targetSrc, 'error', 'target_warned_placed') end
    if C.notifyHitmen then
        for dutyChar in pairs(OnDuty) do
            local hitmanSrc = Presence.byChar[dutyChar]
            if hitmanSrc and hitmanSrc ~= src and hitmanSrc ~= targetSrc then
                say(hitmanSrc, 'info', 'new_contract', Money(payoutFor(reward)))
            end
        end
    end
    Log('Contract placed', ('#%d on %s for %s by %s (%s)'):format(
        c.id, c.targetName, Money(reward), c.clientName, charId))
    return true, 'placed', c.targetName, Money(reward)
end

local function cancelContract(src, id)
    local charId = Bridge.GetCharId(src)
    if not charId then return false, 'err_no_char' end
    if not atTerminal(src) then return false, 'err_terminal' end
    local c = Store.Find(tonumber(id))
    if not c or c.clientId ~= charId then return false, 'err_gone' end
    if c.status ~= 'open' then return false, 'err_cancel_claimed' end

    local fee = math.floor(c.reward * C.cancelFee / 100)
    local refund = c.reward - fee
    Store.Remove(c.id)
    payCharacter(charId, c.account, refund, 'hitman-contract-cancel')
    Store.Save()
    Log('Contract cancelled', ('#%d by client - refunded %s, fee %s'):format(c.id, Money(refund), Money(fee)))
    return true, 'cancelled', Money(refund), Money(fee)
end

local function claimContract(src, id)
    if not Bridge.ready then return false, 'err_not_ready' end
    local charId = Bridge.GetCharId(src)
    if not charId then return false, 'err_no_char' end
    if not canWork(src) then return false, 'err_job' end
    if not OnDuty[charId] then return false, 'err_duty' end
    if not atTerminal(src) then return false, 'err_terminal' end

    local c = Store.Find(tonumber(id))
    if not c or c.status ~= 'open' then return false, 'err_gone' end
    if c.clientId == charId then return false, 'err_own' end
    if c.targetId == charId then return false, 'err_self' end
    if claimedBy(charId) then return false, 'err_have_active' end
    local wait = (AbandonUntil[charId] or 0) - now()
    if wait > 0 then return false, 'err_abandon_cooldown', Duration(wait) end

    local targetSrc = Presence.byChar[c.targetId]
    if not targetSrc then return false, 'err_target_offline' end

    local t = now()
    c.status = 'claimed'
    c.hitmanId = charId
    c.hitmanName = Bridge.GetName(src)
    c.hitmanSrc = src
    c.claimedAt = t
    c.claimExpiresAt = t + C.claimTime * 60
    c.nextPing = 0
    c.dropAt = nil
    c.pinged = nil
    Store.Save()

    sendHunted(c.targetId, true)
    if C.warnTarget == 'claimed' then say(targetSrc, 'error', 'target_warned_claimed') end
    sendTrack(c)
    Log('Contract claimed', ('#%d on %s by %s (%s)'):format(c.id, c.targetName, c.hitmanName, charId))
    return true, 'claimed', c.targetName
end

local function abandonContract(src)
    local charId = Bridge.GetCharId(src)
    if not charId then return false, 'err_no_char' end
    if not atTerminal(src) then return false, 'err_terminal' end
    local c = claimedBy(charId)
    if not c then return false, 'err_no_active' end
    releaseClaim(c, 'abandoned')
    AbandonUntil[charId] = now() + C.abandonCooldown
    return true, 'abandoned', Duration(C.abandonCooldown)
end

-- admin: remove a contract in any state and refund the client in full
local function adminCancel(c)
    local hitmanSrc = c.hitmanSrc
    Store.Remove(c.id)
    payCharacter(c.clientId, c.account, c.reward, 'hitman-contract-admin-refund')
    Store.Save()
    sendHunted(c.targetId, false)
    if hitmanSrc then
        TriggerClientEvent('hitman_players:client:track', hitmanSrc, nil)
        say(hitmanSrc, 'info', 'admin_cancelled_hitman', c.targetName)
    end
    local clientSrc = Presence.byChar[c.clientId]
    if clientSrc then say(clientSrc, 'info', 'admin_cancelled_client', c.targetName, Money(c.reward)) end
    Log('Contract removed by admin', ('#%d on %s - refunded %s'):format(c.id, c.targetName, Money(c.reward)))
end

--------------------------------------------------------------------------
-- presence
--------------------------------------------------------------------------
local function onCharacterAppeared(src, charId)
    claimCredits(src, charId)
    for _, c in ipairs(Store.Data().contracts) do
        if c.status == 'claimed' then
            if c.hitmanId == charId then
                c.hitmanSrc = src
                c.dropAt = nil
                c.nextPing = 0
                sendTrack(c)
            elseif c.targetId == charId then
                TriggerClientEvent('hitman_players:client:hunted', src, true)
            end
        end
    end
end

local function refreshPresence()
    if not Bridge.ready then return end
    local byChar, bySrc = {}, {}
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local charId = src and Bridge.GetCharId(src)
        if charId then
            byChar[charId] = src
            bySrc[src] = charId
        end
    end
    local previous = Presence.byChar
    Presence.byChar, Presence.bySrc = byChar, bySrc

    for charId in pairs(OnDuty) do
        if not byChar[charId] then OnDuty[charId] = nil end
    end
    -- a hitman whose character left (logout / character switch) loses his live link
    for _, c in ipairs(Store.Data().contracts) do
        if c.status == 'claimed' and c.hitmanSrc and byChar[c.hitmanId] ~= c.hitmanSrc then
            c.hitmanSrc = nil
            c.dropAt = now()
        end
    end
    for charId, src in pairs(byChar) do
        if previous[charId] ~= src then
            onCharacterAppeared(src, charId)
        elseif Store.HasCredits(charId) and (CreditRetry[charId] or 0) <= now() then
            -- a payout that failed earlier (framework error): try again now and then
            CreditRetry[charId] = now() + 60
            claimCredits(src, charId)
        end
    end
end

--------------------------------------------------------------------------
-- net events (all UI actions answer with a fresh state)
--------------------------------------------------------------------------
RegisterNetEvent('hitman_players:server:open', function()
    local src = source
    if not rateLimit(src, 'open', 700) then return end
    if not Bridge.ready then return say(src, 'error', 'err_not_ready') end
    local charId = Bridge.GetCharId(src)
    if not charId then return say(src, 'error', 'err_no_char') end
    if not atTerminal(src) then return say(src, 'error', 'err_terminal') end
    claimCredits(src, charId)
    TriggerClientEvent('hitman_players:client:state', src, buildState(src), nil)
end)

RegisterNetEvent('hitman_players:server:refresh', function()
    local src = source
    if not rateLimit(src, 'refresh', 1500) then return end
    if not Bridge.GetCharId(src) or not atTerminal(src) then return end
    TriggerClientEvent('hitman_players:client:state', src, buildState(src), nil)
end)

RegisterNetEvent('hitman_players:server:players', function()
    local src = source
    if not rateLimit(src, 'players', 1500) then return end
    if C.targetSelection ~= 'list' or not Bridge.GetCharId(src) or not atTerminal(src) then return end

    local list, seen = {}, {}
    for _, otherSrc in pairs(Presence.byChar) do
        if otherSrc ~= src then
            local job = Bridge.GetJob(otherSrc)
            if not (job and protectedJobs[job]) then
                local name = Bridge.GetName(otherSrc)
                seen[name] = (seen[name] or 0) + 1
                list[#list + 1] = { id = otherSrc, name = name }
            end
        end
    end
    for _, entry in ipairs(list) do
        if seen[entry.name] > 1 then entry.name = ('%s #%d'):format(entry.name, entry.id) end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    TriggerClientEvent('hitman_players:client:players', src, list)
end)

RegisterNetEvent('hitman_players:server:duty', function(on)
    local src = source
    if not rateLimit(src, 'duty', 800) then return end
    local charId = Bridge.GetCharId(src)
    if not charId then return end
    if not atTerminal(src) then return respond(src, false, 'err_terminal') end

    local want
    if on == nil then want = not OnDuty[charId] else want = on == true end
    if want and not canWork(src) then return respond(src, false, 'err_job') end

    OnDuty[charId] = want or nil
    respond(src, true, want and 'duty_on' or 'duty_off')
end)

RegisterNetEvent('hitman_players:server:place', function(payload)
    local src = source
    if not rateLimit(src, 'place', 1500) then return end
    respond(src, placeContract(src, payload))
end)

RegisterNetEvent('hitman_players:server:cancel', function(id)
    local src = source
    if not rateLimit(src, 'cancel', 1000) then return end
    respond(src, cancelContract(src, id))
end)

RegisterNetEvent('hitman_players:server:claim', function(id)
    local src = source
    if not rateLimit(src, 'claim', 1000) then return end
    respond(src, claimContract(src, id))
end)

RegisterNetEvent('hitman_players:server:abandon', function()
    local src = source
    if not rateLimit(src, 'abandon', 1000) then return end
    respond(src, abandonContract(src))
end)

-- Sent by the target's own client when it dies while a hitman is hunting it.
-- Money only moves from the client's escrow to the hitman, so a forged report
-- gains nothing; the checks below stop remote or third party claims.
RegisterNetEvent('hitman_players:server:reportDeath', function(killerId)
    local src = source
    if not rateLimit(src, 'death', 2000) then return end
    killerId = tonumber(killerId)
    if not killerId or killerId == src then return end

    local charId = Bridge.GetCharId(src)
    local c = charId and contractOnTarget(charId)
    if not c or c.status ~= 'claimed' or c.hitmanSrc ~= killerId then return end

    local victimPed, killerPed = GetPlayerPed(src), GetPlayerPed(killerId)
    if victimPed ~= 0 and killerPed ~= 0
        and #(GetEntityCoords(victimPed) - GetEntityCoords(killerPed)) > C.maxKillDistance then
        debugLog('death report rejected: too far apart', c.id)
        return
    end
    fulfilContract(c)
end)

--------------------------------------------------------------------------
-- background work
--------------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait(1000)
        local t = now()
        for _, c in ipairs(Store.Snapshot()) do
            if c.status == 'open' then
                if t >= c.expiresAt then expireContract(c) end
            elseif c.status == 'claimed' then
                if not c.hitmanSrc then
                    if c.dropAt and t - c.dropAt >= C.disconnectGrace then
                        releaseClaim(c, 'disconnect')
                    end
                elseif t >= c.claimExpiresAt then
                    releaseClaim(c, 'timeout')
                elseif t >= (c.nextPing or 0) then
                    sendPing(c)
                end
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(3000)
        refreshPresence()
    end
end)

CreateThread(function()
    Wait(1000)
    local oneSync = GetConvar('onesync', 'off')
    if oneSync == 'off' and GetConvar('onesync_enabled', 'false') ~= 'true' then
        print(('^1[%s] OneSync is disabled. Player positions are unavailable, so the tracker cannot work. Enable it with: set onesync on^7'):format(RESOURCE))
    end
    if Config.RequireTerminal and #Config.Terminals == 0 then
        print(('^3[%s] Config.RequireTerminal is on but Config.Terminals is empty - nobody can use the board.^7'):format(RESOURCE))
    end
    print(('^2[%s]^7 started with %d stored contract(s)'):format(RESOURCE, #Store.Data().contracts))
end)

AddEventHandler('playerDropped', function()
    local src = source
    local charId = Presence.bySrc[src]
    if charId then
        OnDuty[charId] = nil
        for _, c in ipairs(Store.Data().contracts) do
            if c.status == 'claimed' and c.hitmanSrc == src then
                c.hitmanSrc = nil
                c.dropAt = now()
            end
        end
        Presence.byChar[charId] = nil
    end
    Presence.bySrc[src] = nil
    LastCall[src] = nil
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then Store.Save() end
end)

--------------------------------------------------------------------------
-- admin command (needs: add_ace group.admin command.<name> allow)
--------------------------------------------------------------------------
RegisterCommand(Config.Commands.admin, function(source, args)
    local function reply(message)
        if source == 0 then print(message) else Bridge.Notify(source, message, 'info') end
    end
    local usage = ('usage: /%s list | cancel <id> | clear | give <id> <amount>'):format(Config.Commands.admin)
    local sub = args[1]

    if sub == 'list' then
        local contracts = Store.Data().contracts
        if #contracts == 0 then return reply('no contracts') end
        for i, c in ipairs(contracts) do
            if i > 15 then
                reply(('... and %d more'):format(#contracts - 15))
                break
            end
            reply(('#%d %s on %s %s [%s]'):format(c.id, Money(c.reward), c.targetName, c.hitmanName and ('hunted by ' .. c.hitmanName) or '', c.status))
        end
    elseif sub == 'cancel' then
        local c = Store.Find(tonumber(args[2]))
        if not c then return reply('contract not found') end
        adminCancel(c)
        reply(('contract #%d removed and refunded'):format(c.id))
    elseif sub == 'clear' then
        local n = 0
        for _, c in ipairs(Store.Snapshot()) do
            adminCancel(c)
            n = n + 1
        end
        reply(('%d contract(s) removed and refunded'):format(n))
    elseif sub == 'give' then
        local target, amount = tonumber(args[2]), tonumber(args[3])
        if not target or not amount or not GetPlayerName(target) then return reply(usage) end
        local ok = Bridge.AddMoney(target, 'cash', amount, 'hitman-players-admin')
        reply(ok and ('gave %s to player %d'):format(Money(amount), target) or 'could not add money')
    else
        reply(usage)
    end
end, true)
