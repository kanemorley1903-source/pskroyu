local H, root = ...
local T = H.T
local DIR = root .. '/hitman_players'

local NS = 'hitman_players:server:'
local CS = 'hitman_players:client:'

--------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------
local function newWorld(configure, framework)
    framework = framework or 'qbcore'
    local w = H.world()
    H.useFramework(w, framework)
    local server = w:load(DIR, 'server', {
        config = function(C)
            C.Framework = framework
            C.Contracts.placeCooldown = 0
            if configure then configure(C) end
        end,
    })
    return w, server
end

-- Alice (client), Bob (target), Charlie (hitman), all close to each other
local function populate(w, extra)
    extra = extra or {}
    w:addPlayer(1, { name = 'alice_rp', first = 'Alice', last = 'Archer', cash = 100000, bank = 20000, coords = H.vec3(0, 0, 30) })
    w:addPlayer(2, { name = 'bob_rp', first = 'Bob', last = 'Banks', cash = 500, coords = H.vec3(100, 0, 30), job = extra.bobJob })
    w:addPlayer(3, { name = 'charlie_rp', first = 'Charlie', last = 'Cole', cash = 1000, coords = H.vec3(200, 0, 30), job = extra.charlieJob })
    w:seconds(4) -- bridge init + presence refresh
end

local function lastState(w, src)
    local ev = w:lastClientOut(CS .. 'state', src)
    return ev and ev.args[1], ev and ev.args[2]
end

local function act(w, server, name, src, ...)
    w:seconds(2) -- stay clear of the per-event rate limits
    w:clearOut()
    server:fire(NS .. name, src, ...)
    return lastState(w, src)
end

local function place(w, server, src, target, reward, extra)
    local payload = { targetId = target, reward = reward, account = 'cash', description = 'last seen downtown' }
    for k, v in pairs(extra or {}) do payload[k] = v end
    local _, toast = act(w, server, 'place', src, payload)
    return toast
end

local function dutyOn(w, server, src)
    local state, toast = act(w, server, 'duty', src, true)
    return state, toast
end

local function contracts(server)
    return server.G.Store.Data().contracts
end

local function saved(w, server)
    return server.G.json.decode(w.kvp.hitman_players['hitman_players:data'])
end

local function cash(w, src) return w.players[src].cash end

--------------------------------------------------------------------------
H.test('place: money goes to escrow and the contract is stored', function()
    local w, server = newWorld()
    populate(w)

    local toast = place(w, server, 1, 2, 20000)
    T.ok(toast and toast.ok, 'placing works')
    T.eq(cash(w, 1), 80000, 'reward taken from cash')
    T.eq(#contracts(server), 1, 'one contract')

    local c = contracts(server)[1]
    T.eq(c.status, 'open', 'open')
    T.eq(c.reward, 20000, 'reward')
    T.eq(c.targetId, 'CHAR2', 'target is Bob')
    T.eq(c.clientId, 'CHAR1', 'client is Alice')
    T.eq(c.targetName, 'Bob Banks', 'character name is used')
    T.eq(c.expiresAt, w.unix + 4 + 2 + 180 * 60 - 0, 'expires after 180 minutes', nil)
    T.eq(saved(w, server).contracts[1].reward, 20000, 'persisted immediately')

    local state = lastState(w, 1)
    T.eq(#state.placed, 1, 'Alice sees her contract')
    T.eq(state.balances.cash, 80000, 'balance in state')
end)

H.test('place: money can come from the bank', function()
    local w, server = newWorld()
    populate(w)
    local toast = place(w, server, 1, 2, 15000, { account = 'bank' })
    T.ok(toast.ok, 'placed')
    T.eq(w.players[1].bank, 5000, 'bank charged')
    T.eq(w.players[1].cash, 100000, 'cash untouched')
    T.eq(contracts(server)[1].account, 'bank', 'remembers the account for refunds')
end)

H.test('place: invalid requests are rejected without moving money', function()
    local w, server = newWorld()
    populate(w, { bobJob = nil })

    local function rejected(reward, target, extra, why)
        local before = cash(w, 1)
        local toast = place(w, server, 1, target or 2, reward, extra)
        T.ok(toast and toast.ok == false, why .. ' is rejected')
        T.eq(cash(w, 1), before, why .. ' leaves money alone')
        T.eq(#contracts(server), 0, why .. ' creates nothing')
    end

    rejected(100, 2, nil, 'reward below minimum')
    rejected(999999, 2, nil, 'reward above maximum')
    rejected(20000, 1, nil, 'targeting yourself')
    rejected(20000, 99, nil, 'unknown player')
    rejected(20000, nil, { targetId = 'abc' }, 'non numeric target')
    rejected(500000, 2, nil, 'more than the maximum')
    rejected(-5000, 2, nil, 'negative reward')

    w.players[1].cash = 1000
    rejected(20000, 2, nil, 'not enough money')
end)

H.test('place: protected jobs, duplicates, limits and cooldown', function()
    local w, server = newWorld(function(C) C.Contracts.placeCooldown = 300 end)
    populate(w, { bobJob = 'police' })

    local toast = place(w, server, 1, 2, 20000)
    T.ok(toast.ok == false, 'police cannot be targeted')
    w.players[2].job = 'unemployed'
    w:seconds(4)

    toast = place(w, server, 1, 2, 20000)
    T.ok(toast.ok, 'civilian can be targeted')

    toast = place(w, server, 1, 3, 20000)
    T.ok(toast.ok == false, 'cooldown between contracts')
    T.eq(#contracts(server), 1, 'still one contract')

    w:seconds(301)
    toast = place(w, server, 3, 2, 20000)
    T.ok(toast.ok == false, 'only one contract per target (Charlie has no money anyway)')
    w.players[3].cash = 50000
    toast = place(w, server, 3, 2, 20000)
    T.ok(toast.ok == false, 'second contract on the same target rejected')
    T.eq(cash(w, 3), 50000, 'no escrow taken for the duplicate')

    -- max per client
    server.G.Config.Contracts.maxPerClient = 1
    w:seconds(301)
    toast = place(w, server, 1, 3, 20000)
    T.ok(toast.ok == false, 'max contracts per client')
end)

H.test('place: description is cleaned and capped by characters', function()
    local w, server = newWorld()
    populate(w)
    local nasty = 'line1\nline2\t\tx' .. string.char(7) .. ' ' .. string.rep('é', 300)
    place(w, server, 1, 2, 20000, { description = nasty })
    local d = contracts(server)[1].description
    T.ok(not d:find('[%c]'), 'no control characters')
    T.eq(utf8.len(d), 140, 'capped at 140 characters, not bytes')
    T.ok(d:sub(1, 11) == 'line1 line2', 'whitespace collapsed')
    T.ok(utf8.len(d) ~= nil, 'still valid utf-8')
end)

H.test('hunters: duty, job gate and claiming rules', function()
    local w, server = newWorld()
    populate(w)
    place(w, server, 1, 2, 20000)
    local id = contracts(server)[1].id

    -- not on duty yet
    local state, toast = act(w, server, 'claim', 3, id)
    local _
    T.ok(toast.ok == false, 'must be on duty')
    T.eq(#state.open, 0, 'board is hidden while off duty')

    state = dutyOn(w, server, 3)
    T.ok(state.duty, 'on duty')
    T.eq(#state.open, 1, 'board visible on duty')
    T.eq(state.open[1].payout, 18000, 'payout is reward minus the 10% cut')
    T.eq(state.open[1].targetOnline, true, 'target online')
    T.ok(state.open[1].clientName == nil and state.open[1].client == nil, 'client stays anonymous')

    -- Alice and Bob cannot take it
    dutyOn(w, server, 1)
    _, toast = act(w, server, 'claim', 1, id)
    T.ok(toast.ok == false, 'client cannot take own contract')
    dutyOn(w, server, 2)
    state = lastState(w, 2)
    T.eq(#state.open, 0, 'target does not see the contract on himself')
    _, toast = act(w, server, 'claim', 2, id)
    T.ok(toast.ok == false, 'target cannot take it')

    w:clearOut()
    _, toast = act(w, server, 'claim', 3, id)
    T.ok(toast.ok, 'hitman claims')
    local c = contracts(server)[1]
    T.eq(c.status, 'claimed', 'claimed')
    T.eq(c.hitmanId, 'CHAR3', 'hitman recorded')
    T.eq(c.hitmanSrc, 3, 'live link')

    T.eq(w:lastClientOut(CS .. 'hunted', 2).args[1], true, 'target is told to watch for his death')
    local track = w:lastClientOut(CS .. 'track', 3)
    T.eq(track.args[1].target, 'Bob Banks', 'hitman gets the hud info')
    T.eq(track.args[1].interval, 30, 'ping interval for the hud text')
    T.ok(#w:clientOut('hitman_players:client:notify', 2) >= 1, 'target gets a vague warning')

    -- one at a time
    w.players[1].cash = 100000
    place(w, server, 1, 3, 20000)
    w:seconds(1)
    local second
    for _, k in ipairs(contracts(server)) do if k.targetId == 'CHAR3' then second = k end end
    _, toast = act(w, server, 'claim', 3, second.id)
    T.ok(toast.ok == false, 'cannot hold two contracts')
    T.ok(second.status == 'open', 'second stays open')
end)

H.test('hunters: RequireJob keeps civilians off duty', function()
    local w, server = newWorld(function(C)
        C.RequireJob = true
        C.JobName = 'hitman'
    end)
    populate(w, { charlieJob = 'hitman' })

    local _, toast = act(w, server, 'duty', 1, true)
    T.ok(toast.ok == false, 'civilian refused')
    local state = lastState(w, 1)
    T.eq(state.canWork, false, 'state says so')

    _, toast = act(w, server, 'duty', 3, true)
    T.ok(toast.ok, 'hitman accepted')
end)

H.test('tracker: the area contains the target but is not centred on him', function()
    local w, server = newWorld()
    populate(w)
    place(w, server, 1, 2, 20000)
    dutyOn(w, server, 3)
    act(w, server, 'claim', 3, contracts(server)[1].id)

    w:clearOut()
    w:seconds(2)
    local first = w:lastClientOut(CS .. 'ping', 3)
    T.ok(first ~= nil, 'first ping arrives right after claiming')
    local p = first.args[1]
    T.eq(p.first, true, 'first ping is flagged (waypoint)')

    local target = w.entities[w.players[2].ped].coords
    local hitman = w.entities[w.players[3].ped].coords
    local distance = #(target - hitman)
    local expected = math.max(60, math.min(350, distance * 0.5))
    T.near(p.radius, expected, 0.01, 'radius follows the distance')
    local off = math.sqrt((p.x - target.x) ^ 2 + (p.y - target.y) ^ 2)
    T.ok(off <= p.radius * 0.6 + 0.001, 'target is inside the circle')

    -- keeps pinging, no waypoint the second time
    w:clearOut()
    w:seconds(31)
    local again = w:lastClientOut(CS .. 'ping', 3)
    T.ok(again ~= nil, 'pings again after the interval')
    T.eq(again.args[1].first, false, 'no waypoint on later pings')

    -- far away => bigger circle, capped
    w.entities[w.players[2].ped].coords = H.vec3(5000, 0, 30)
    w:clearOut()
    w:seconds(31)
    T.eq(w:lastClientOut(CS .. 'ping', 3).args[1].radius, 350, 'capped at the maximum radius')

    -- target gone => "lost"
    w:dropPlayer(2)
    w:clearOut()
    w:seconds(31)
    T.eq(w:lastClientOut(CS .. 'ping', 3).args[1].lost, true, 'signal lost when the target is offline')
end)

H.test('kill: the hitman is paid, the target becomes immune', function()
    local w, server = newWorld()
    populate(w)
    place(w, server, 1, 2, 20000)
    dutyOn(w, server, 3)
    act(w, server, 'claim', 3, contracts(server)[1].id)

    w:clearOut()
    w:seconds(2)
    server:fire(NS .. 'reportDeath', 2, 3)

    T.eq(cash(w, 3), 1000 + 18000, 'hitman paid 90% of the reward')
    T.eq(#contracts(server), 0, 'contract removed')
    T.eq(saved(w, server).contracts[1], nil, 'removal persisted')
    T.eq(w:lastClientOut(CS .. 'hunted', 2).args[1], false, 'target no longer hunted')
    T.eq(w:lastClientOut(CS .. 'track', 3).args[1], nil, 'hud cleared')
    T.ok(#w:clientOut(CS .. 'notify', 1) >= 1, 'client told')

    T.eq(server.G.Store.GetStats('CHAR3').kills, 1, 'kill counted')
    T.eq(server.G.Store.GetStats('CHAR3').earned, 18000, 'earnings counted')
    T.eq(server.G.Store.GetStats('CHAR1').fulfilled, 1, 'client fulfilled counter')

    -- Bob is protected for a while
    local toast = place(w, server, 1, 2, 20000)
    T.ok(toast.ok == false, 'target immune after being killed')
    w:seconds(31 * 60)
    toast = place(w, server, 1, 2, 20000)
    T.ok(toast.ok, 'immunity wears off')
end)

H.test('kill: forged or invalid death reports pay nothing', function()
    local w, server = newWorld()
    populate(w)
    w:addPlayer(4, { name = 'dave', first = 'Dave', last = 'Dunn', cash = 0, coords = H.vec3(300, 0, 30) })
    w:seconds(4)
    place(w, server, 1, 2, 20000)
    dutyOn(w, server, 3)
    act(w, server, 'claim', 3, contracts(server)[1].id)
    local hitmanCash = cash(w, 3)

    local function report(src, killer)
        w:seconds(3)
        server:fire(NS .. 'reportDeath', src, killer)
        T.eq(#contracts(server), 1, ('report from %s by %s changes nothing'):format(tostring(src), tostring(killer)))
        T.eq(cash(w, 3), hitmanCash, 'hitman not paid')
    end

    report(2, 4)        -- killed by somebody else
    report(2, 2)        -- killed himself
    report(2, nil)      -- no killer
    report(2, 'abc')    -- garbage
    report(4, 3)        -- a bystander claims the hitman killed him
    report(1, 3)        -- the client claims it
    report(3, 3)        -- the hitman reports on himself

    -- killer too far away
    w.entities[w.players[3].ped].coords = H.vec3(9000, 0, 30)
    report(2, 3)
    T.eq(#contracts(server), 1, 'still running')
end)

H.test('kill: dying before anybody claimed the contract does nothing', function()
    local w, server = newWorld()
    populate(w)
    place(w, server, 1, 2, 20000)
    w:seconds(3)
    server:fire(NS .. 'reportDeath', 2, 3)
    T.eq(#contracts(server), 1, 'open contracts are not fulfilled by a death')
    T.eq(cash(w, 3), 1000, 'no payout')
end)

H.test('cancel: open contracts refund minus the fee, claimed ones cannot be cancelled', function()
    local w, server = newWorld()
    populate(w)
    place(w, server, 1, 2, 20000)
    local id = contracts(server)[1].id

    local _, toast = act(w, server, 'cancel', 3, id)
    T.ok(toast.ok == false, 'only the client can cancel')

    _, toast = act(w, server, 'cancel', 1, id)
    T.ok(toast.ok, 'client cancels')
    T.eq(cash(w, 1), 80000 + 18000, 'refund is reward minus the 10% fee')
    T.eq(#contracts(server), 0, 'gone')

    place(w, server, 1, 2, 20000)
    id = contracts(server)[1].id
    dutyOn(w, server, 3)
    act(w, server, 'claim', 3, id)
    _, toast = act(w, server, 'cancel', 1, id)
    T.ok(toast.ok == false, 'cannot cancel once a hitman is on it')
    T.eq(#contracts(server), 1, 'still there')
end)

H.test('expiry: unclaimed contracts are refunded in full', function()
    local w, server = newWorld(function(C) C.Contracts.expireAfter = 1 end)
    populate(w)
    place(w, server, 1, 2, 20000)
    T.eq(cash(w, 1), 80000, 'escrowed')
    w:seconds(65)
    T.eq(#contracts(server), 0, 'expired')
    T.eq(cash(w, 1), 100000, 'full refund')
    T.eq(saved(w, server).contracts[1], nil, 'persisted')
end)

H.test('expiry: an offline client gets the refund when he is back', function()
    local w, server = newWorld(function(C) C.Contracts.expireAfter = 1 end)
    populate(w)
    place(w, server, 1, 2, 20000)

    w:dropPlayer(1)
    w:seconds(65)
    T.eq(#contracts(server), 0, 'expired while Alice was away')
    local credits = saved(w, server).credits.CHAR1
    T.eq(credits[1].amount, 20000, 'credit stored')
    T.eq(credits[1].account, 'cash', 'in the original account')

    -- she comes back
    w:addPlayer(1, { name = 'alice_rp', first = 'Alice', last = 'Archer', cash = 80000, bank = 20000, coords = H.vec3(0, 0, 30) })
    w:seconds(4)
    T.eq(cash(w, 1), 100000, 'refund paid on return')
    T.eq(saved(w, server).credits.CHAR1, nil, 'credit consumed')
end)

H.test('claims: timeout puts the contract back and punishes the hitman', function()
    local w, server = newWorld(function(C) C.Contracts.claimTime = 1 end)
    populate(w)
    place(w, server, 1, 2, 20000)
    dutyOn(w, server, 3)
    local id = contracts(server)[1].id
    act(w, server, 'claim', 3, id)

    w:clearOut()
    w:seconds(70)
    local c = contracts(server)[1]
    T.eq(c.status, 'open', 'back on the board')
    T.eq(c.hitmanId, nil, 'hitman cleared')
    T.eq(w:lastClientOut(CS .. 'hunted', 2).args[1], false, 'target relieved')
    T.eq(w:lastClientOut(CS .. 'track', 3).args[1], nil, 'hitman hud cleared')

    local _, toast = act(w, server, 'claim', 3, id)
    T.ok(toast.ok == false, 'cooldown after timing out')
end)

H.test('claims: abandoning has a cooldown, disconnecting does not', function()
    local w, server = newWorld()
    populate(w)
    place(w, server, 1, 2, 20000)
    dutyOn(w, server, 3)
    local id = contracts(server)[1].id
    act(w, server, 'claim', 3, id)

    local _, toast = act(w, server, 'abandon', 3)
    T.ok(toast.ok, 'abandoned')
    T.eq(contracts(server)[1].status, 'open', 'open again')
    _, toast = act(w, server, 'claim', 3, id)
    T.ok(toast.ok == false, 'cooldown after abandoning')

    -- a second hitman is not affected by Charlie's cooldown
    w:addPlayer(5, { name = 'erin', first = 'Erin', last = 'East', coords = H.vec3(120, 0, 30) })
    w:seconds(4)
    dutyOn(w, server, 5)
    _, toast = act(w, server, 'claim', 5, id)
    T.ok(toast.ok, 'another hitman takes it')

    -- Erin drops out: grace period, then released
    w:dropPlayer(5)
    w:seconds(60)
    T.eq(contracts(server)[1].status, 'claimed', 'still claimed inside the grace period')
    w:seconds(70)
    T.eq(contracts(server)[1].status, 'open', 'released after the grace period')
    -- no cooldown for disconnecting: Erin comes back and can claim immediately
    w:addPlayer(5, { name = 'erin', first = 'Erin', last = 'East', coords = H.vec3(120, 0, 30) })
    w:seconds(4)
    dutyOn(w, server, 5)
    _, toast = act(w, server, 'claim', 5, id)
    T.ok(toast.ok, 'no cooldown after a disconnect')
end)

H.test('claims: a hitman who reconnects inside the grace period keeps the contract', function()
    local w, server = newWorld()
    populate(w)
    place(w, server, 1, 2, 20000)
    dutyOn(w, server, 3)
    act(w, server, 'claim', 3, contracts(server)[1].id)

    w:dropPlayer(3)
    w:seconds(30)
    T.eq(contracts(server)[1].status, 'claimed', 'kept during grace')
    T.eq(contracts(server)[1].hitmanSrc, nil, 'no live link while offline')

    -- different server id after reconnecting
    w:addPlayer(7, { name = 'charlie_rp', char = 'CHAR3', first = 'Charlie', last = 'Cole', coords = H.vec3(210, 0, 30) })
    w:clearOut()
    w:seconds(4)
    T.eq(contracts(server)[1].hitmanSrc, 7, 'relinked to the new server id')
    T.ok(w:lastClientOut(CS .. 'track', 7) ~= nil, 'hud restored')

    server:fire(NS .. 'reportDeath', 2, 7)
    T.eq(#contracts(server), 0, 'kill still counts')
    T.eq(cash(w, 7), 18000, 'paid to the new server id')
end)

H.test('persistence: contracts and credits survive a restart', function()
    local w, server = newWorld()
    populate(w)
    place(w, server, 1, 2, 20000)
    dutyOn(w, server, 3)
    act(w, server, 'claim', 3, contracts(server)[1].id)
    server.G.Store.AddCredit('CHAR9', 777, 'bank', 'test')
    server.G.Store.Save()
    w:unload(server)

    local server2 = w:load(DIR, 'server', { config = function(C)
        C.Framework = 'qbcore'
        C.Contracts.placeCooldown = 0
    end })
    w:seconds(1)
    local list = server2.G.Store.Data().contracts
    T.eq(#list, 1, 'contract reloaded')
    T.eq(list[1].reward, 20000, 'reward intact')
    T.eq(list[1].status, 'claimed', 'claim intact')
    T.eq(list[1].hitmanSrc, nil, 'live link reset')
    T.ok(list[1].dropAt ~= nil, 'grace period started')
    T.eq(server2.G.Store.Data().credits.CHAR9[1].amount, 777, 'credit reloaded')
    T.eq(server2.G.Store.Data().nextId, 2, 'ids continue')

    -- Charlie is still online, so presence relinks him
    w:seconds(4)
    T.eq(server2.G.Store.Data().contracts[1].hitmanSrc, 3, 'relinked')
end)

H.test('input target mode: id, exact name, ambiguity', function()
    local w, server = newWorld(function(C) C.Contracts.targetSelection = 'input' end)
    populate(w)
    w:addPlayer(4, { name = 'x', first = 'Bob', last = 'Banks', coords = H.vec3(50, 0, 30), char = 'CHAR4' })
    w:seconds(4)

    local toast = place(w, server, 1, nil, 20000, { targetId = false, target = 'Charlie Cole' })
    T.ok(toast.ok, 'exact name (case insensitive) works')
    T.eq(contracts(server)[1].targetId, 'CHAR3', 'right person')

    toast = place(w, server, 1, nil, 20000, { targetId = false, target = '  bob banks ' })
    T.ok(toast.ok == false, 'two Bob Banks => ambiguous')

    toast = place(w, server, 1, nil, 20000, { targetId = false, target = '2' })
    T.ok(toast.ok, 'server id works')
    T.eq(contracts(server)[2].targetId, 'CHAR2', 'resolved id')

    toast = place(w, server, 1, nil, 20000, { targetId = false, target = 'Nobody Here' })
    T.ok(toast.ok == false, 'unknown name rejected')
end)

H.test('players list: no protected jobs, duplicates get ids, self excluded', function()
    local w, server = newWorld()
    populate(w, { bobJob = 'police' })
    w:addPlayer(4, { name = 'x', first = 'Charlie', last = 'Cole', coords = H.vec3(50, 0, 30), char = 'CHAR4' })
    w:seconds(4)
    w:clearOut()
    server:fire(NS .. 'players', 1)
    local list = w:lastClientOut(CS .. 'players', 1).args[1]
    local names = {}
    for _, e in ipairs(list) do names[#names + 1] = e.name end
    T.eq(#list, 2, 'police and self are not listed')
    T.eq(names[1], 'Charlie Cole #3', 'duplicate names are told apart')
    T.eq(names[2], 'Charlie Cole #4', 'second duplicate')
end)

H.test('terminals: the board only works next to one when required', function()
    local w, server = newWorld(function(C)
        C.RequireTerminal = true
        C.Terminals = { { label = 'T', coords = H.vec3(0, 0, 30), radius = 2.0 } }
    end)
    populate(w)

    -- Alice stands at the terminal, Charlie does not
    w:clearOut()
    server:fire(NS .. 'open', 1)
    T.ok(lastState(w, 1) ~= nil, 'opens at the terminal')
    w:seconds(2)
    w:clearOut()
    server:fire(NS .. 'open', 3)
    T.eq(lastState(w, 3), nil, 'refused away from it')

    local toast = place(w, server, 3, 2, 20000)
    T.ok(toast and toast.ok == false, 'cannot place away from it either')
    T.eq(#contracts(server), 0, 'nothing was created')
    w.players[3].cash = 50000
    w:seconds(2)
    toast = place(w, server, 1, 2, 20000)
    T.ok(toast.ok, 'placing works at the terminal')

    -- every other board action is refused away from the terminal as well
    local id = contracts(server)[1].id
    for _, action in ipairs({ 'refresh', 'players', 'duty', 'cancel', 'claim', 'abandon' }) do
        w:seconds(2)
        w:clearOut()
        server:fire(NS .. action, 3, action == 'cancel' and id or (action == 'claim' and id or true))
        local state, answer = lastState(w, 3)
        T.ok(state == nil or (answer and answer.ok == false), action .. ' does nothing away from the terminal')
        T.eq(w:lastClientOut(CS .. 'players', 3), nil, action .. ' leaks no player list')
    end
    w:seconds(2)
    local before = #w:clientOut(CS .. 'state', 3)
    server:fire(NS .. 'refresh', 3)
    T.eq(#w:clientOut(CS .. 'state', 3), before, 'the board cannot be read away from the terminal')
    T.eq(contracts(server)[1].status, 'open', 'and nothing was claimed')
end)

H.test('rate limiting: repeated events inside the window are ignored', function()
    local w, server = newWorld()
    populate(w)
    w:seconds(2)
    w:clearOut()
    server:fire(NS .. 'place', 1, { targetId = 2, reward = 6000, account = 'cash' })
    server:fire(NS .. 'place', 1, { targetId = 3, reward = 6000, account = 'cash' })
    server:fire(NS .. 'place', 1, { targetId = 3, reward = 6000, account = 'cash' })
    T.eq(#contracts(server), 1, 'only the first goes through')
end)

H.test('hostile payloads do not crash the server', function()
    local w, server = newWorld()
    populate(w)
    local junk = { nil, 'text', 5, true, {}, { reward = 'x' }, { targetId = {}, reward = {} }, { reward = 1e308, targetId = 2 } }
    for i = 1, 8 do
        w:seconds(2)
        server:fire(NS .. 'place', 1, junk[i])
        w:seconds(2)
        server:fire(NS .. 'claim', 3, junk[i])
        w:seconds(2)
        server:fire(NS .. 'cancel', 1, junk[i])
        w:seconds(2)
        server:fire(NS .. 'reportDeath', 2, junk[i])
        w:seconds(2)
        server:fire(NS .. 'duty', 3, junk[i])
    end
    T.eq(#contracts(server), 0, 'nothing created')
    T.eq(cash(w, 1), 100000, 'no money lost')
end)

H.test('admin command: list, cancel, clear and give', function()
    local w, server = newWorld()
    populate(w)
    place(w, server, 1, 2, 20000)
    w.players[1].cash = 100000
    place(w, server, 1, 3, 30000)
    T.eq(#contracts(server), 2, 'two contracts')
    w.printed = {}

    server:command('hitmanadmin', 0, { 'list' })
    T.eq(#w.printed, 2, 'lists both')
    T.contains(w.printed[1], '#1', 'first listed')

    local before = cash(w, 1)
    server:command('hitmanadmin', 0, { 'cancel', '1' })
    T.eq(#contracts(server), 1, 'cancelled')
    T.eq(cash(w, 1), before + 20000, 'client refunded in full (no fee)')

    server:command('hitmanadmin', 0, { 'clear' })
    T.eq(#contracts(server), 0, 'cleared')

    server:command('hitmanadmin', 0, { 'give', '3', '5000' })
    T.eq(cash(w, 3), 6000, 'give adds cash')
    T.ok(server.commands.hitmanadmin.restricted, 'command is ACE restricted')
end)

H.test('webhook: contract events are posted when configured', function()
    local w, server = newWorld(function(C) C.Webhook.url = 'https://example.invalid/hook' end)
    populate(w)
    place(w, server, 1, 2, 20000)
    T.ok(#w.http >= 1, 'a request was sent')
    T.eq(w.http[1].method, 'POST', 'posted')
    local body = server.G.json.decode(w.http[1].data)
    T.eq(body.embeds[1].title, 'Contract placed', 'title')
end)

--------------------------------------------------------------------------
-- frameworks
--------------------------------------------------------------------------
for _, fw in ipairs({ 'qbox', 'esx' }) do
    H.test(('framework %s: escrow, payout and names'):format(fw), function()
        local w, server = newWorld(nil, fw)
        populate(w)
        place(w, server, 1, 2, 20000)
        T.eq(cash(w, 1), 80000, 'escrow taken')
        T.eq(contracts(server)[1].targetName, 'Bob Banks', 'name from the framework')
        T.eq(contracts(server)[1].targetId, 'CHAR2', 'character id from the framework')

        dutyOn(w, server, 3)
        act(w, server, 'claim', 3, contracts(server)[1].id)
        w:seconds(2)
        server:fire(NS .. 'reportDeath', 2, 3)
        T.eq(cash(w, 3), 19000, 'payout')

        -- bank + refund
        place(w, server, 1, 3, 10000, { account = 'bank' })
        T.eq(w.players[1].bank, 10000, 'bank escrow')
        act(w, server, 'cancel', 1, contracts(server)[1].id)
        T.eq(w.players[1].bank, 19000, 'bank refund minus fee')
    end)
end

H.test('framework standalone: built-in wallet', function()
    local w, server = newWorld(nil, 'standalone')
    populate(w)
    T.eq(server.G.Bridge.framework, 'standalone', 'detected')
    T.eq(server.G.Bridge.GetMoney(1, 'cash'), 0, 'empty wallet')
    local toast = place(w, server, 1, 2, 20000)
    T.ok(toast.ok == false, 'cannot afford')

    server:command('hitmanadmin', 0, { 'give', '1', '50000' })
    T.eq(server.G.Bridge.GetMoney(1, 'cash'), 50000, 'admin funds the wallet')
    toast = place(w, server, 1, 2, 20000)
    T.ok(toast.ok, 'placed with wallet money')
    T.eq(server.G.Bridge.GetMoney(1, 'cash'), 30000, 'escrow taken')
    T.eq(contracts(server)[1].clientId, 'license:char1', 'license is the character id')
end)

H.test('framework auto-detection waits for a late framework', function()
    local w = H.world()
    local server = w:load(DIR, 'server', {})
    w:seconds(2)
    T.eq(server.G.Bridge.ready, false, 'still waiting')
    H.useFramework(w, 'qbcore')
    w:seconds(2)
    T.eq(server.G.Bridge.framework, 'qbcore', 'picked up qb-core once it started')
    T.eq(server.G.Bridge.ready, true, 'ready')

    local w2 = H.world()
    local s2 = w2:load(DIR, 'server', {})
    w2:seconds(17)
    T.eq(s2.G.Bridge.framework, 'standalone', 'falls back to standalone')
end)

H.test('source is never read after the handler yields', function()
    -- the harness clears `source` after the first yield; every handler above ran
    -- with that rule, this just documents that the handlers capture it first
    local w, server = newWorld()
    populate(w)
    T.ok(server.G.source == nil, 'source is cleared outside of handlers')
end)

H.test('framework errors never lose money: failing escrow', function()
    local w, server = newWorld()
    populate(w)
    w.players[1].failRemove = true
    local toast = place(w, server, 1, 2, 20000)
    T.ok(toast and toast.ok == false, 'rejected')
    T.eq(#contracts(server), 0, 'no contract without escrow')
    T.eq(cash(w, 1), 100000, 'money untouched')
    T.ok(#w.printed > 0, 'the error is logged')
end)

H.test('framework errors never lose money: a refund that cannot be paid waits as a credit', function()
    local w, server = newWorld(function(C) C.Contracts.expireAfter = 1 end)
    populate(w)
    place(w, server, 1, 2, 20000)
    T.eq(cash(w, 1), 80000, 'escrowed')

    w.players[1].failAdd = true            -- the framework refuses to pay out
    w:seconds(65)
    T.eq(#contracts(server), 0, 'contract expired')
    T.eq(cash(w, 1), 80000, 'nothing paid yet')
    T.eq(saved(w, server).credits.CHAR1[1].amount, 20000, 'the refund is kept as a credit, not lost')

    w.players[1].failAdd = false           -- the framework recovers; the player never left
    w:seconds(70)
    T.eq(cash(w, 1), 100000, 'credit delivered automatically')
    T.eq(saved(w, server).credits.CHAR1, nil, 'credit cleared')
end)

H.test('framework errors never lose money: a hitman payout that fails is kept', function()
    local w, server = newWorld()
    populate(w)
    place(w, server, 1, 2, 20000)
    dutyOn(w, server, 3)
    act(w, server, 'claim', 3, contracts(server)[1].id)
    w.players[3].failAdd = true
    w:seconds(2)
    server:fire(NS .. 'reportDeath', 2, 3)
    T.eq(#contracts(server), 0, 'contract done')
    T.eq(cash(w, 3), 1000, 'not paid yet')
    T.eq(saved(w, server).credits.CHAR3[1].amount, 18000, 'owed to the hitman')
    w.players[3].failAdd = false
    w:seconds(70)
    T.eq(cash(w, 3), 19000, 'paid once the framework works')
end)
