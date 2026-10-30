local H, root = ...
local T = H.T
local DIR = root .. '/hitman_npc'

local NS = 'hitman_npc:server:'
local CS = 'hitman_npc:client:'

--------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------
local function setup(opts)
    opts = opts or {}
    local w = H.world()
    H.useFramework(w, opts.framework or 'qbcore')
    local function configure(C)
        C.Framework = opts.framework or 'qbcore'
        C.BonusChance = opts.bonusChance or 1.0
        C.Heat.chance = 0
        if opts.config then opts.config(C) end
    end
    local server = w:load(DIR, 'server', { config = configure })
    local broker = server.G.Config.Broker.coords
    w:addPlayer(1, { name = 'hank', first = 'Hank', last = 'Hart', cash = 0, coords = H.vec3(broker.x, broker.y, broker.z) })
    local client
    if opts.client then client = w:load(DIR, 'client', { src = 1, config = configure }) end
    w:seconds(3)
    return w, server, client
end

-- `stay` = do not walk back to the broker first
local function board(w, server, stay)
    w:seconds(1)
    if not stay then
        local c = server.G.Config.Broker.coords
        w.entities[w.players[1].ped].coords = H.vec3(c.x, c.y, c.z)
    end
    w:clearOut()
    server:fire(NS .. 'openBoard', 1)
    local ev = w:lastClientOut(CS .. 'board', 1)
    return ev and ev.args[1]
end

local function accept(w, server, offerIndex, stay)
    local b = board(w, server, stay)
    if not b then return nil end
    w:seconds(1)
    w:clearOut()
    server:fire(NS .. 'accept', 1, b.offers[offerIndex or 1].id)
    local ev = w:lastClientOut(CS .. 'start', 1)
    return ev and ev.args[1], b
end

local function notifications(w)
    local list = {}
    for _, ev in ipairs(w:clientOut(CS .. 'notify', 1)) do list[#list + 1] = ev.args[1] end
    return table.concat(list, ' | ')
end

-- what the client does after the peds exist
local function spawnPeds(w, server, contract, src)
    local loc = server.G.Config.Locations[contract.locationIndex]
    local target = w:newEntity({
        type = 1, owner = 1, health = 200,
        coords = H.vec3(loc.coords.x + 4, loc.coords.y, loc.coords.z),
    })
    w:netId(target)
    w.entities[w.players[src or 1].ped].coords = H.vec3(loc.coords.x + 12, loc.coords.y, loc.coords.z)
    local guards = {}
    for i = 1, contract.guards do
        local g = w:newEntity({ type = 1, owner = 1, health = 200, coords = H.vec3(loc.coords.x + 6, loc.coords.y + i, loc.coords.z) })
        guards[i] = w:netId(g)
    end
    server:fire(NS .. 'register', 1, contract.id, target.netId, guards)
    w:seconds(1)
    return target, guards
end

local function kill(w, target, killerHandle, props)
    target.health = 0
    target.killer = killerHandle or w.players[1].ped
    for k, v in pairs(props or {}) do target[k] = v end
end

local function complete(w, server, contract, report)
    w:seconds(2)
    w:clearOut()
    server:fire(NS .. 'complete', 1, contract.id, report or {})
end

local json = H.loadJson()

-- profiles live in the resource KVP store
local function profile(w, charId)
    local raw = w.kvp.hitman_npc and w.kvp.hitman_npc['hitman_npc:profile:' .. charId]
    return raw and json.decode(raw)
end

--------------------------------------------------------------------------
-- server: board and access
--------------------------------------------------------------------------
H.test('board: three tier-1 offers for a new player', function()
    local w, server = setup()
    local b = board(w, server)
    T.ok(b ~= nil, 'board sent')
    T.eq(#b.offers, 3, 'three offers')
    T.eq(b.profile.level, 'Rookie', 'starts as a rookie')
    T.eq(b.profile.nextName, 'Enforcer', 'next level')
    T.eq(b.profile.nextRep, 100, 'next level rep')
    T.eq(b.active, nil, 'nothing active')
    T.eq(b.cooldown, 0, 'no cooldown')

    local labels = {}
    for _, o in ipairs(b.offers) do
        T.eq(o.tier, 1, 'only tier 1 for rookies')
        T.ok(o.reward >= 2500 and o.reward <= 4000, 'reward inside the tier range: ' .. o.reward)
        T.eq(o.reward % 50, 0, 'rounded to 50')
        T.ok(o.target:find('%S+ %S+') ~= nil, 'has a full name')
        T.eq(#o.bonuses, 3, 'all bonuses attached (BonusChance = 1)')
        T.ok(o.bonuses[1].label ~= nil and o.bonuses[1].percent ~= nil, 'bonus has label and percent')
        T.ok(o.location ~= nil, 'has a location label')
        labels[o.location] = true
    end
    local distinct = 0
    for _ in pairs(labels) do distinct = distinct + 1 end
    T.eq(distinct, 3, 'three different locations')

    -- asking again within the lifetime gives the same board
    local again = board(w, server)
    T.eq(again.offers[1].id, b.offers[1].id, 'board is stable')
end)

H.test('board: higher reputation unlocks tiers and pays more', function()
    local w, server = setup()
    server:command('hitmannpc', 0, { 'setrep', '1', '350' })
    local b = board(w, server)
    T.eq(b.profile.level, 'Professional', 'level from reputation')
    T.eq(b.profile.payMult, 1.25, 'multiplier')
    local tiers = {}
    for _, o in ipairs(b.offers) do tiers[o.tier] = true end
    T.ok(tiers[1] or tiers[2] or tiers[3], 'offers exist')
    for _, o in ipairs(b.offers) do
        local def = server.G.Config.Tiers[o.tier]
        T.ok(o.reward >= def.reward.min * 1.25 - 50 and o.reward <= def.reward.max * 1.25 + 50, 'reward scaled by level')
    end

    server:command('hitmannpc', 0, { 'setrep', '1', '0' })
    b = board(w, server)
    for _, o in ipairs(b.offers) do T.eq(o.tier, 1, 'back to tier 1') end
end)

H.test('access: job, police count, distance and framework readiness', function()
    local w, server = setup({ config = function(C) C.RequireJob = true; C.JobName = 'hitman' end })
    local b = board(w, server)
    T.eq(b, nil, 'civilians are turned away')
    T.ok(#w:clientOut(CS .. 'notify', 1) >= 1, 'with a message')
    w.players[1].job = 'hitman'
    T.ok(board(w, server) ~= nil, 'the right job is accepted')

    w, server = setup({ config = function(C) C.MinPolice = 2 end })
    T.eq(board(w, server), nil, 'not enough police')
    w:addPlayer(2, { first = 'P', last = 'One', job = 'police' })
    w:addPlayer(3, { first = 'P', last = 'Two', job = 'sheriff' })
    T.ok(board(w, server) ~= nil, 'police on duty, contracts available')

    w, server = setup()
    w.entities[w.players[1].ped].coords = H.vec3(0, 0, 0)
    T.eq(board(w, server, true), nil, 'must stand next to the broker')
    local b = board(w, server)
    w.entities[w.players[1].ped].coords = H.vec3(0, 0, 0)
    w:seconds(2)
    w:clearOut()
    server:fire(NS .. 'accept', 1, b.offers[1].id)
    T.eq(w:lastClientOut(CS .. 'start', 1), nil, 'cannot accept from far away either')
end)

--------------------------------------------------------------------------
-- server: contract life cycle
--------------------------------------------------------------------------
H.test('accept: one active contract, a cooldown afterwards, bad ids refused', function()
    local w, server = setup()
    local c = accept(w, server, 2)
    T.ok(c ~= nil, 'contract started')
    T.ok(c.locationIndex ~= nil and c.gender ~= nil and c.target ~= nil, 'client gets what it needs to run the mission')
    T.near(c.remaining, c.timeLimit, 1, 'time limit')

    -- second accept
    w:seconds(2)
    w:clearOut()
    server:fire(NS .. 'accept', 1, 99999)
    T.eq(w:lastClientOut(CS .. 'start', 1), nil, 'cannot start another')
    T.contains(notifications(w), 'already have', 'told why')

    -- board shows the running contract
    local b = board(w, server)
    T.ok(b.active ~= nil and b.active.id == c.id, 'active contract on the board')

    -- cancel => penalty and cooldown
    server:command('hitmannpc', 0, { 'setrep', '1', '40' })
    w:seconds(2)
    w:clearOut()
    server:fire(NS .. 'cancel', 1)
    T.eq(w:lastClientOut(CS .. 'finish', 1).args[1], 'cancelled', 'client told to clean up')
    T.eq(profile(w, 'CHAR1').rep, 35, 'cancel costs 5 reputation')
    b = board(w, server)
    T.eq(b.active, nil, 'nothing active')
    T.ok(b.cooldown > 100, 'cooldown running')
    w:clearOut()
    server:fire(NS .. 'accept', 1, b.offers[1].id)
    T.eq(w:lastClientOut(CS .. 'start', 1), nil, 'cooldown blocks the next contract')
    w:seconds(125)
    c = accept(w, server)
    T.ok(c ~= nil, 'new contract after the cooldown')
end)

H.test('accept: an offer id from another board is refused', function()
    local w, server = setup()
    local b = board(w, server)
    w:seconds(2)
    w:clearOut()
    server:fire(NS .. 'accept', 1, b.offers[1].id + 1000)
    T.eq(w:lastClientOut(CS .. 'start', 1), nil, 'unknown offer')
    T.ok(w:lastClientOut(CS .. 'board', 1) ~= nil, 'a fresh board is pushed')
end)

H.test('complete: the full job with validation, bonuses and payout', function()
    local w, server = setup({ config = function(C) C.CleanupDelay = 30 end })
    local c = accept(w, server)
    local target, guards = spawnPeds(w, server, c)
    T.eq(#guards, c.guards, 'guards registered')

    w:seconds(60)                         -- well inside half of the time limit
    kill(w, target, nil, { lastBone = 31086 })
    complete(w, server, c, { headshot = true, silent = true })

    local expected = math.floor(c.reward * (1 + (20 + 15 + 10) / 100))
    T.eq(w.players[1].cash, expected, 'base reward + headshot + silent + fast bonus')
    T.eq(w:lastClientOut(CS .. 'finish', 1).args[1], 'completed', 'client told')
    T.contains(notifications(w), 'Headshot', 'bonus announced')

    local p = profile(w, 'CHAR1')
    T.eq(p.kills, 1, 'kill counted')
    T.eq(p.rep, 15, 'tier 1 reputation')
    T.eq(p.earned, expected, 'earnings tracked')

    -- bodies are removed later
    T.ok(w.entities[target.handle] ~= nil, 'body still there')
    w:seconds(31)
    T.eq(w.entities[target.handle], nil, 'target body cleaned up by the server')
    for _, netId in ipairs(guards) do
        T.eq(server.G.NetworkGetEntityFromNetworkId(netId), 0, 'guard cleaned up')
    end

    -- a second completion report pays nothing
    w:seconds(5)
    server:fire(NS .. 'complete', 1, c.id, { headshot = true })
    T.eq(w.players[1].cash, expected, 'no double payout')
end)

H.test('complete: bonuses are only paid when earned', function()
    local w, server = setup()
    local c = accept(w, server)
    local target = spawnPeds(w, server, c)
    w:seconds(c.timeLimit * 0.7)          -- too slow for the "fast" bonus
    kill(w, target)
    complete(w, server, c, { headshot = false, silent = false })
    T.eq(w.players[1].cash, c.reward, 'base reward only')

    -- unknown report fields are ignored
    w:seconds(130)
    local c2 = accept(w, server)
    local t2 = spawnPeds(w, server, c2)
    kill(w, t2)
    complete(w, server, c2, { headshot = 'yes', silent = 1, bonus = 1e9, payout = 1e9 })
    T.eq(w.players[1].cash, c.reward + math.floor(c2.reward * 1.10), 'only fast bonus; nothing the client sends changes the amount')
end)

H.test('complete: bonuses that were not offered are never paid', function()
    local w, server = setup({ bonusChance = 0 })
    local c = accept(w, server)
    T.eq(#c.bonuses, 0, 'no bonuses on this contract')
    local target = spawnPeds(w, server, c)
    kill(w, target)
    complete(w, server, c, { headshot = true, silent = true })
    T.eq(w.players[1].cash, c.reward, 'base reward only')
end)

H.test('complete: level up message and unlocked tier', function()
    local w, server = setup()
    server:command('hitmannpc', 0, { 'setrep', '1', '90' })
    local c = accept(w, server)
    local target = spawnPeds(w, server, c)
    kill(w, target)
    complete(w, server, c, {})
    T.contains(notifications(w), 'Enforcer', 'level up announced')
    T.eq(profile(w, 'CHAR1').rep, 105, 'reputation added')
end)

H.test('anti-cheat: nothing is paid without a verified kill', function()
    local w, server = setup({ config = function(C) C.Cooldown = 5 end })

    -- 1) report completion without ever spawning anything
    local c = accept(w, server)
    complete(w, server, c, { headshot = true })
    T.eq(w.players[1].cash, 0, 'unregistered target')
    w:seconds(8)
    T.eq(w:lastClientOut(CS .. 'finish', 1), nil, 'contract still running, the client will retry')

    -- 2) target registered but alive
    local target = spawnPeds(w, server, c)
    for i = 1, 4 do
        complete(w, server, c, {})
        w:seconds(2)
    end
    T.eq(w.players[1].cash, 0, 'target is alive')
    T.eq(w:lastClientOut(CS .. 'finish', 1).args[1], 'invalid', 'voided after repeated false reports')
    T.eq(profile(w, 'CHAR1') == nil or profile(w, 'CHAR1').rep == 0, true, 'no penalty for a void contract')

    -- 3) another player killed the target
    w:seconds(20)
    w:addPlayer(2, { name = 'rival', first = 'Rita', last = 'Rival', coords = H.vec3(0, 0, 30) })
    local c2 = accept(w, server)
    local t2 = spawnPeds(w, server, c2)
    kill(w, t2, w.players[2].ped)
    complete(w, server, c2, {})
    T.eq(w.players[1].cash, 0, 'kill stolen')
    T.eq(w:lastClientOut(CS .. 'finish', 1).args[1], 'stolen', 'contract voided as stolen')
    T.contains(notifications(w), 'Somebody else', 'player told')

    -- 4) killer is the player's vehicle => accepted
    w:seconds(20)
    local c3 = accept(w, server)
    local t3 = spawnPeds(w, server, c3)
    local car = w:newEntity({ type = 2 })
    w.entities[w.players[1].ped].vehicle = car.handle
    kill(w, t3, car.handle)
    complete(w, server, c3, {})
    T.ok(w.players[1].cash > 0, 'run over with your own car counts')
end)

H.test('anti-cheat: far away reports and misplaced peds', function()
    local w, server = setup({ config = function(C) C.Cooldown = 5 end })

    -- the player is nowhere near the body
    local c = accept(w, server)
    local target = spawnPeds(w, server, c)
    kill(w, target)
    w.entities[w.players[1].ped].coords = H.vec3(5000, 5000, 30)
    for _ = 1, 4 do
        complete(w, server, c, {})
        w:seconds(2)
    end
    T.eq(w.players[1].cash, 0, 'too far from the body')
    T.eq(w:lastClientOut(CS .. 'finish', 1).args[1], 'invalid', 'voided')

    -- peds registered in the wrong place (a void contract has a 15 s cooldown)
    w:seconds(20)
    w.entities[w.players[1].ped].coords = H.vec3(-1851, -1232, 13)
    local c2 = accept(w, server)
    local loc = server.G.Config.Locations[c2.locationIndex]
    local far = w:newEntity({ type = 1, owner = 1, coords = H.vec3(loc.coords.x + 3000, loc.coords.y, 30) })
    w:netId(far)
    w:clearOut()
    server:fire(NS .. 'register', 1, c2.id, far.netId, {})
    w:seconds(5)
    T.eq(w:lastClientOut(CS .. 'finish', 1).args[1], 'invalid', 'a ped far from the area voids the contract')

    -- registering something that is not a ped
    w:seconds(20)
    local c3 = accept(w, server)
    local prop = w:newEntity({ type = 3, owner = 1, coords = H.vec3(loc.coords.x, loc.coords.y, loc.coords.z) })
    server.G.Config.Locations[c3.locationIndex].coords = server.G.Config.Locations[c3.locationIndex].coords
    local loc3 = server.G.Config.Locations[c3.locationIndex]
    prop.coords = H.vec3(loc3.coords.x, loc3.coords.y, loc3.coords.z)
    w:netId(prop)
    w:clearOut()
    server:fire(NS .. 'register', 1, c3.id, prop.netId, {})
    w:seconds(5)
    T.eq(w:lastClientOut(CS .. 'finish', 1).args[1], 'invalid', 'a non ped entity is refused')
end)

H.test('anti-cheat: hostile payloads are ignored', function()
    local w, server = setup()
    local c = accept(w, server)
    local junk = { 'x', {}, 5, true, 1e308, -1 }
    for _, j in ipairs(junk) do
        w:seconds(3)
        server:fire(NS .. 'complete', 1, j, j)
        server:fire(NS .. 'register', 1, j, j, j)
        server:fire(NS .. 'fail', 1, j, j)
        server:fire(NS .. 'accept', 1, j)
    end
    w:seconds(3)
    server:fire(NS .. 'fail', 1, c.id, 'something else')
    server:fire(NS .. 'fail', 1, c.id, { 'died' })
    local b = board(w, server)
    T.ok(b.active ~= nil, 'the contract is still running')
    T.eq(w.players[1].cash, 0, 'no money appeared')
end)

H.test('fail: death costs reputation, spawn problems do not', function()
    local w, server = setup({ config = function(C) C.Cooldown = 10 end })
    server:command('hitmannpc', 0, { 'setrep', '1', '50' })
    local c = accept(w, server)
    w:seconds(2)
    w:clearOut()
    server:fire(NS .. 'fail', 1, c.id, 'died')
    T.eq(w:lastClientOut(CS .. 'finish', 1).args[1], 'failed', 'failed')
    T.eq(profile(w, 'CHAR1').rep, 40, '-10 reputation')
    T.eq(profile(w, 'CHAR1').failed, 1, 'failure counted')

    w:seconds(20)
    c = accept(w, server)
    w:seconds(2)
    w:clearOut()
    server:fire(NS .. 'fail', 1, c.id, 'spawn_failed')
    T.eq(w:lastClientOut(CS .. 'finish', 1).args[1], 'lost', 'void')
    T.eq(profile(w, 'CHAR1').rep, 40, 'no penalty for a void')

    -- reputation never goes negative
    server:command('hitmannpc', 0, { 'setrep', '1', '3' })
    w:seconds(20)
    c = accept(w, server)
    w:seconds(2)
    server:fire(NS .. 'fail', 1, c.id, 'died')
    T.eq(profile(w, 'CHAR1').rep, 0, 'floored at zero')
end)

H.test('expiry: running out of time fails the contract', function()
    local w, server = setup()
    server:command('hitmannpc', 0, { 'setrep', '1', '20' })
    local c = accept(w, server)
    local target = spawnPeds(w, server, c)
    w:clearOut()
    w:seconds(c.timeLimit + 10)
    T.eq(w:lastClientOut(CS .. 'finish', 1).args[1], 'expired', 'expired')
    T.eq(profile(w, 'CHAR1').rep, 10, 'penalty')
    w:seconds(10)
    T.eq(w.entities[target.handle], nil, 'target removed by the server')
end)

H.test('drop: a player leaving removes his peds', function()
    local w, server = setup()
    local c = accept(w, server)
    local target, guards = spawnPeds(w, server, c)
    w:dropPlayer(1)
    T.eq(w.entities[target.handle], nil, 'target deleted')
    for _, netId in ipairs(guards) do
        T.eq(server.G.NetworkGetEntityFromNetworkId(netId), 0, 'guard deleted')
    end
end)

H.test('trust mode: without OneSync the client report is accepted', function()
    local w = H.world()
    w.convars.onesync = 'off'
    H.useFramework(w, 'qbcore')
    local server = w:load(DIR, 'server', { config = function(C) C.Framework = 'qbcore'; C.BonusChance = 0 end })
    local b = server.G.Config.Broker.coords
    w:addPlayer(1, { first = 'Hank', last = 'Hart', coords = H.vec3(b.x, b.y, b.z) })
    w:seconds(3)
    local c = accept(w, server)
    server:fire(NS .. 'register', 1, c.id, 12345, {})
    complete(w, server, c, {})
    T.eq(w.players[1].cash, c.reward, 'paid on the client report')
end)

H.test('admin command: reset, setrep, give', function()
    local w, server = setup()
    local c = accept(w, server)
    spawnPeds(w, server, c)
    w:clearOut()
    server:command('hitmannpc', 0, { 'reset', '1' })
    T.eq(w:lastClientOut(CS .. 'finish', 1).args[1], 'invalid', 'running contract voided')
    T.eq(board(w, server).cooldown, 0, 'cooldown cleared')
    server:command('hitmannpc', 0, { 'give', '1', '2500' })
    T.eq(w.players[1].cash, 2500, 'give')
    T.ok(server.commands.hitmannpc.restricted, 'restricted command')
    server:command('hitmannpc', 0, {})
    server:command('hitmannpc', 0, { 'bogus', '1' })
end)

H.test('payment accounts: bank and ESX black money', function()
    local w, server = setup({ config = function(C) C.Payment.account = 'bank'; C.BonusChance = 0 end })
    local c = accept(w, server)
    local target = spawnPeds(w, server, c)
    kill(w, target)
    complete(w, server, c, {})
    T.eq(w.players[1].bank, c.reward, 'paid into the bank')
    T.eq(w.players[1].cash, 0, 'not in cash')

    w, server = setup({ framework = 'esx', config = function(C) C.Payment.account = 'black_money'; C.BonusChance = 0 end })
    c = accept(w, server)
    target = spawnPeds(w, server, c)
    kill(w, target)
    complete(w, server, c, {})
    T.eq(w.players[1].black, c.reward, 'ESX black money account')
end)

--------------------------------------------------------------------------
-- client: the real mission code in a fake world
--------------------------------------------------------------------------
local function livePeds(w, exceptHandle)
    local list = {}
    for handle, e in pairs(w.entities) do
        if e.type == 1 and not e.isPlayer and handle ~= exceptHandle then list[#list + 1] = e end
    end
    table.sort(list, function(a, b) return a.handle < b.handle end)
    return list
end

local function pedsOfModel(w, name)
    local out = {}
    for _, e in ipairs(livePeds(w)) do
        if e.model == H.joaat(name) then out[#out + 1] = e end
    end
    return out
end

local function activeBlips(w)
    local n = 0
    for _ in pairs(w.blips) do n = n + 1 end
    return n
end

H.test('client: broker ped, prompt, board and accepting a contract', function()
    local w, server, client = setup({ client = true })
    w:seconds(3)

    T.eq(#pedsOfModel(w, 'g_m_m_armboss_01'), 1, 'broker ped spawned when close')
    T.eq(activeBlips(w), 1, 'broker blip on the map')

    client.state.pressed[38] = true
    w:seconds(2)
    local open = client:lastNui('board')
    T.ok(open ~= nil, 'board opened after pressing E')
    T.eq(client.state.nuiFocus, true, 'mouse focus given to the page')
    T.eq(#open.data.offers, 3, 'offers sent to the page')
    T.ok(open.strings.ui_title ~= nil, 'strings sent for translation')

    -- the page asks to accept
    client:nui('accept', { id = open.data.offers[1].id })
    w:seconds(2)
    T.eq(client.state.nuiFocus, false, 'focus returned to the game')
    local hud = client:lastNui('hud')
    T.ok(hud and hud.visible, 'hud shown')
    T.eq(hud.target, open.data.offers[1].target, 'hud names the target')
    T.ok(client.state.waypoint ~= nil, 'waypoint set to the area')
    T.eq(activeBlips(w), 3, 'broker + area circle + area centre')
end)

H.test('client: the target spawns on approach, the contract can be completed', function()
    local w, server, client = setup({ client = true, config = function(C) C.CleanupDelay = 20 end })
    w:seconds(3)
    client.state.pressed[38] = true
    w:seconds(2)
    local offers = client:lastNui('board').data.offers
    local chosen = offers[1]
    client:nui('accept', { id = chosen.id })
    w:seconds(2)

    local cfg = client.G.Config
    local started = w:lastClientOut(CS .. 'start', 1).args[1]
    local loc = cfg.Locations[started.locationIndex]
    local guardsPlanned = started.guards

    T.eq(#livePeds(w, w.players[1].ped) - 1, 0, 'nobody spawned yet except the broker')

    -- travel next to the area
    w.entities[w.players[1].ped].coords = H.vec3(loc.coords.x + 100, loc.coords.y, loc.coords.z)
    w:seconds(3)
    local others = livePeds(w)
    local target, guards = nil, {}
    for _, e in ipairs(others) do
        if e.model ~= H.joaat('g_m_m_armboss_01') then
            local isGuard = false
            for _, name in ipairs(cfg.GuardModels) do if e.model == H.joaat(name) then isGuard = true end end
            if isGuard then guards[#guards + 1] = e else target = e end
        end
    end
    T.ok(target ~= nil, 'target spawned')
    T.eq(#guards, guardsPlanned, 'planned number of guards spawned')
    T.eq(target.task, 'scenario', 'target idles until something happens')
    T.eq(target.blocking[1], true, 'target ignores events until alerted')
    for _, g in ipairs(guards) do
        T.eq(g.task, 'guard', 'guards stand guard')
        T.ok(g.weapon ~= nil, 'guards are armed')
    end
    local dx, dy = target.coords.x - loc.coords.x, target.coords.y - loc.coords.y
    T.ok(math.sqrt(dx * dx + dy * dy) <= loc.scatter + 1, 'target placed inside the scatter radius')

    -- the server validated the registration (a complete report would otherwise be ignored)
    local hud = client:lastNui('hudStatus')
    T.eq(hud.status, 'engage', 'hud switched to engage')

    -- walking up alerts the target
    w.entities[w.players[1].ped].coords = H.vec3(target.coords.x + 5, target.coords.y, target.coords.z)
    w:seconds(2)
    local def = cfg.Tiers[started.tier]
    T.eq(target.task, def.targetBehavior == 'fight' and 'combat' or 'flee', 'target reacts when you get close')
    for _, g in ipairs(guards) do T.eq(g.task, 'combat', 'guards attack') end

    -- kill him with a headshot from a silenced weapon
    client.state.silenced = true
    target.lastBone = 31086
    target.health = 0
    target.killer = w.players[1].ped
    w:seconds(3)

    local reportEvents = 0
    for _, ev in ipairs(w.serverEvents) do
        if ev.name == NS .. 'complete' then
            reportEvents = reportEvents + 1
            T.eq(ev.args[2].headshot, true, 'headshot reported')
            T.eq(ev.args[2].silent, true, 'silent reported')
        end
    end
    T.eq(reportEvents, 1, 'exactly one completion report')
    T.ok(w.players[1].cash >= started.reward, 'server paid at least the base reward')
    T.eq(w:lastClientOut(CS .. 'finish', 1).args[1], 'completed', 'server confirmed')
    T.eq(client:lastNui('hud').visible, false, 'hud hidden')
    T.ok(not client.G.Mission.active, 'mission finished')

    -- bodies stay for the cleanup delay, then disappear
    T.ok(w.entities[target.handle] ~= nil, 'body remains briefly')
    w:seconds(25)
    T.eq(w.entities[target.handle], nil, 'body removed')
    T.eq(activeBlips(w), 1, 'only the broker blip is left')
end)

H.test('client: dying fails the contract, /cancelhit abandons it', function()
    local w, server, client = setup({ client = true, config = function(C) C.Cooldown = 5 end })
    w:seconds(3)
    client.state.pressed[38] = true
    w:seconds(2)
    client:nui('accept', { id = client:lastNui('board').data.offers[1].id })
    w:seconds(2)
    T.ok(client.G.Mission.active, 'mission running')

    server:command('hitmannpc', 0, { 'setrep', '1', '30' })
    w.entities[w.players[1].ped].health = 0
    w:seconds(2)
    T.ok(not client.G.Mission.active, 'mission stopped on death')
    T.eq(profile(w, 'CHAR1').rep, 20, 'server applied the failure penalty')
    T.eq(activeBlips(w), 1, 'blips cleaned')

    -- abandon with the command
    w.entities[w.players[1].ped].health = 200
    w:seconds(10)
    client.state.pressed[38] = true
    w:seconds(2)
    client:nui('accept', { id = client:lastNui('board').data.offers[1].id })
    w:seconds(2)
    T.ok(client.G.Mission.active, 'second mission running')
    client:command('cancelhit', 1)
    w:seconds(2)
    T.ok(not client.G.Mission.active, 'mission stopped by /cancelhit')
    T.eq(profile(w, 'CHAR1').rep, 15, 'abandon penalty applied')

    client:command('cancelhit', 1)
    w:seconds(1)
end)

H.test('client: leaving the broker area despawns him, closing the page returns focus', function()
    local w, server, client = setup({ client = true })
    w:seconds(3)
    T.eq(#pedsOfModel(w, 'g_m_m_armboss_01'), 1, 'broker present')
    client.state.pressed[38] = true
    w:seconds(2)
    T.eq(client.state.nuiFocus, true, 'focus')
    client:nui('close')
    T.eq(client.state.nuiFocus, false, 'focus released')

    w.entities[w.players[1].ped].coords = H.vec3(0, 0, 30)
    w:seconds(3)
    T.eq(#pedsOfModel(w, 'g_m_m_armboss_01'), 0, 'broker despawned when far away')
    w.entities[w.players[1].ped].coords = H.vec3(-1851, -1232, 13)
    w:seconds(3)
    T.eq(#pedsOfModel(w, 'g_m_m_armboss_01'), 1, 'and spawns again')
end)

H.test('client: stopping the resource cleans everything up', function()
    local w, server, client = setup({ client = true })
    w:seconds(3)
    client.state.pressed[38] = true
    w:seconds(2)
    client:nui('accept', { id = client:lastNui('board').data.offers[1].id })
    w:seconds(2)
    local started = w:lastClientOut(CS .. 'start', 1).args[1]
    local loc = client.G.Config.Locations[started.locationIndex]
    w.entities[w.players[1].ped].coords = H.vec3(loc.coords.x + 50, loc.coords.y, loc.coords.z)
    w:seconds(3)
    T.ok(#livePeds(w) >= 2, 'peds exist')

    client:dispatch('onResourceStop', nil, 'hitman_npc')
    w:seconds(1)
    T.eq(#livePeds(w), 0, 'every ped removed, broker included')
    T.eq(activeBlips(w), 0, 'every blip removed')
    T.eq(client.state.nuiFocus, false, 'no stuck focus')
end)

H.test('client: /cancelhit still works after the client gave up on the mission', function()
    local w, server, client = setup({ client = true, config = function(C) C.Cooldown = 5 end })
    w:seconds(3)
    client.state.pressed[38] = true
    w:seconds(2)
    client:nui('accept', { id = client:lastNui('board').data.offers[1].id })
    w:seconds(2)
    server:command('hitmannpc', 0, { 'setrep', '1', '30' })

    client.G.Mission.Stop()                 -- the client side is gone, the server still has the contract
    T.ok(not client.G.Mission.active, 'client mission ended')
    w:clearOut()
    client:command('cancelhit', 1)
    w:seconds(2)
    T.eq(w:lastClientOut(CS .. 'finish', 1).args[1], 'cancelled', 'the server contract can still be cancelled')
    T.eq(profile(w, 'CHAR1').rep, 25, 'with the normal penalty')
end)

H.test('client: unanswered kill reports are given up cleanly and voided on the server', function()
    local w, server, client = setup({ client = true })
    w:seconds(3)
    client.state.pressed[38] = true
    w:seconds(2)
    client:nui('accept', { id = client:lastNui('board').data.offers[1].id })
    w:seconds(2)
    local started = w:lastClientOut(CS .. 'start', 1).args[1]
    local loc = client.G.Config.Locations[started.locationIndex]
    w.entities[w.players[1].ped].coords = H.vec3(loc.coords.x + 50, loc.coords.y, loc.coords.z)
    w:seconds(3)

    local target
    for _, e in pairs(w.entities) do
        if e.type == 1 and not e.isPlayer and e.model ~= H.joaat('g_m_m_armboss_01') and e.task == 'scenario' then target = e end
    end
    -- the server stops answering (e.g. it is overloaded): the kill can never be confirmed
    server.handlers[NS .. 'complete'] = nil
    target.health = 0
    target.killer = w.players[1].ped
    w:clearOut()
    w:seconds(40)

    local reports, fails = 0, {}
    for _, ev in ipairs(w.serverEvents) do
        if ev.name == NS .. 'complete' then reports = reports + 1 end
        if ev.name == NS .. 'fail' then fails[#fails + 1] = ev.args[2] end
    end
    T.eq(reports, 5, 'five attempts, then it stops')
    T.eq(fails[1], 'lost', 'and tells the server so the contract is not left hanging')
    T.ok(not client.G.Mission.active, 'client mission ended')
    T.eq(w:lastClientOut(CS .. 'finish', 1).args[1], 'lost', 'server voided it without penalty')
end)

H.test('client: "eyes on the target" is announced once, not every time the blip toggles', function()
    local w, server, client = setup({ client = true, config = function(C)
        C.Tiers[1].targetBlip = 'near'
        C.AlertDistance = 1.0
    end })
    w:seconds(3)
    client.state.pressed[38] = true
    w:seconds(2)
    client:nui('accept', { id = client:lastNui('board').data.offers[1].id })
    w:seconds(2)
    local started = w:lastClientOut(CS .. 'start', 1).args[1]
    local loc = client.G.Config.Locations[started.locationIndex]
    w.entities[w.players[1].ped].coords = H.vec3(loc.coords.x + 100, loc.coords.y, loc.coords.z)
    w:seconds(3)

    local target
    for _, e in pairs(w.entities) do
        if e.type == 1 and not e.isPlayer and e.model ~= H.joaat('g_m_m_armboss_01') and e.task == 'scenario' then target = e end
    end
    local function walk(distance)
        w.entities[w.players[1].ped].coords = H.vec3(target.coords.x + distance, target.coords.y, target.coords.z)
        w:seconds(1)
    end
    local function targetBlips()
        local n = 0
        for _, b in pairs(w.blips) do if b.kind == 'entity' then n = n + 1 end end
        return n
    end

    for _ = 1, 3 do
        walk(20)     -- inside the 55 m "near" range: the blip appears
        T.eq(targetBlips(), 1, 'blip while close')
        walk(120)    -- outside: the blip is removed again
        T.eq(targetBlips(), 0, 'no blip while far')
    end
    local announced = 0
    for _, text in ipairs(w.notifyLog) do
        if text:find('eyes on the target', 1, true) then announced = announced + 1 end
    end
    T.eq(announced, 1, 'announced a single time')
end)

H.test('framework errors: a payout that fails does not wedge the contract', function()
    local w, server = setup({ config = function(C) C.BonusChance = 0 end })
    w.players[1].failAdd = true
    local c = accept(w, server)
    local target = spawnPeds(w, server, c)
    kill(w, target)
    complete(w, server, c, {})
    T.eq(w:lastClientOut(CS .. 'finish', 1).args[1], 'completed', 'contract still completes')
    T.eq(w.players[1].cash, 0, 'nothing paid')
    local logged = false
    for _, line in ipairs(w.printed) do if line:find('PAYMENT FAILED', 1, true) then logged = true end end
    T.ok(logged, 'the unpaid amount is logged for staff')
    T.eq(board(w, server).active, nil, 'free to take the next job after the cooldown')
end)

H.test('anti-cheat: the first registered target stays the target', function()
    local w, server = setup({ config = function(C) C.Cooldown = 5 end })
    local c = accept(w, server)
    local real = spawnPeds(w, server, c)

    -- swap in a second ped (already dead) near the area and report that one
    local loc = server.G.Config.Locations[c.locationIndex]
    local decoy = w:newEntity({ type = 1, owner = 1, health = 0, killer = w.players[1].ped,
        coords = H.vec3(loc.coords.x + 2, loc.coords.y, loc.coords.z) })
    w:netId(decoy)
    w:seconds(2)
    server:fire(NS .. 'register', 1, c.id, decoy.netId, {})
    w:seconds(2)
    complete(w, server, c, {})
    T.eq(w.players[1].cash, 0, 'the decoy does not count; the real target is still alive')

    kill(w, real)
    complete(w, server, c, {})
    T.eq(w.players[1].cash, math.floor(c.reward * 1.10), 'the real kill pays (with the quick work bonus)')
end)

H.test('client: a player death that framework revives within 100 ms still fails the contract', function()
    local w, server, client = setup({ client = true })
    w:seconds(3)
    client.state.pressed[38] = true
    w:seconds(2)
    client:nui('accept', { id = client:lastNui('board').data.offers[1].id })
    w:seconds(2)
    T.ok(client.G.Mission.active, 'running')

    local ped = w.entities[w.players[1].ped]
    ped.health = 0
    w:advance(100)
    ped.health = 150            -- downed, not dead any more
    w:seconds(1)
    T.ok(not client.G.Mission.active, 'the contract failed anyway')
    T.eq(w:lastClientOut(CS .. 'finish', 1).args[1], 'failed', 'and the server knows')
end)

H.test('characters: a contract does not follow the player to another character', function()
    local w, server = setup({ config = function(C) C.Cooldown = 5 end })
    local c = accept(w, server)
    local target = spawnPeds(w, server, c)
    kill(w, target)

    -- the player logs out to character selection and loads another character, same connection
    w.players[1].char = 'CHAR_OTHER'
    complete(w, server, c, {})
    T.eq(w.players[1].cash, 0, 'the new character is not paid for the old one')
    T.eq(w:lastClientOut(CS .. 'finish', 1).args[1], 'invalid', 'the contract is voided')
    T.eq(profile(w, 'CHAR1'), nil, 'and nobody gets reputation for it')
    T.eq(profile(w, 'CHAR_OTHER'), nil, 'including the new character')

    -- the board of the new character starts clean
    w:seconds(20)
    w.players[1].char = 'CHAR1'
    local again = accept(w, server)
    w.players[1].char = 'CHAR_THIRD'
    local b = board(w, server)
    T.eq(b.active, nil, 'a third character sees no foreign contract')
    T.ok(again ~= nil, 'the first character could start a new job')
end)
