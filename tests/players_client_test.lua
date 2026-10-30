local H, root = ...
local T = H.T
local DIR = root .. '/hitman_players'

local NS = 'hitman_players:server:'
local CS = 'hitman_players:client:'

--------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------
local function setup(configure)
    local w = H.world()
    H.useFramework(w, 'qbcore')
    local function cfg(C)
        C.Framework = 'qbcore'
        C.Contracts.placeCooldown = 0
        if configure then configure(C) end
    end
    local server = w:load(DIR, 'server', { config = cfg })
    w:addPlayer(1, { first = 'Alice', last = 'Archer', cash = 100000, coords = H.vec3(0, 0, 30) })
    w:addPlayer(2, { first = 'Bob', last = 'Banks', cash = 0, coords = H.vec3(100, 0, 30) })
    w:addPlayer(3, { first = 'Charlie', last = 'Cole', cash = 0, coords = H.vec3(200, 0, 30) })
    local clients = {}
    for src = 1, 3 do clients[src] = w:load(DIR, 'client', { src = src, config = cfg }) end
    w:seconds(5)
    return w, server, clients
end

local function blipCount(w, kind, owner)
    local n = 0
    for _, b in pairs(w.blips) do
        if (not kind or b.kind == kind) and (not owner or b.owner == owner) then n = n + 1 end
    end
    return n
end

local function sentToServer(w, name)
    local list = {}
    for _, ev in ipairs(w.serverEvents) do
        if ev.name == name then list[#list + 1] = ev end
    end
    return list
end

--------------------------------------------------------------------------
H.test('board: command, key binding, opening and closing', function()
    local w, server, clients = setup()
    local alice = clients[1]

    T.ok(alice.keyMappings.hitlist ~= nil, 'a key binding is registered so players can bind a key')
    T.eq(alice.keyMappings.hitlist.key, '', 'unbound by default')

    alice:command('hitlist', 1)
    w:seconds(1)
    local open = alice:lastNui('open')
    T.ok(open ~= nil, 'page opened')
    T.eq(alice.state.nuiFocus, true, 'focus')
    T.eq(open.state.balances.cash, 100000, 'balance sent')
    T.ok(open.strings.ui_title ~= nil, 'strings sent')
    T.eq(open.state.limits.selection, 'list', 'selection mode sent')

    alice:nui('close')
    T.eq(alice.state.nuiFocus, false, 'focus released')
    T.eq(alice:lastNui().action, 'close', 'page told to hide')

    -- a state pushed without a request does not pop the page open
    local before = #alice.nuiMessages
    alice:command('hitduty', 1)
    w:seconds(3)
    T.eq(#alice.nuiMessages, before, 'no ghost window after a duty toggle from the command')
    T.eq(alice.state.nuiFocus, false, 'focus untouched')

    -- ...and a stale request does not either
    w:seconds(1)
    alice:command('hitlist', 1)
    w:seconds(0.1)
end)

H.test('board: NUI actions are forwarded with cleaned payloads', function()
    local w, server, clients = setup()
    local alice = clients[1]
    alice:command('hitlist', 1)
    w:seconds(2)
    w:clearOut()

    alice:nui('place', { targetId = '2', reward = '15000', account = 'bank', description = 'hello', target = 7, evil = { 1 } })
    alice:nui('claim', { id = '5' })
    alice:nui('claim', { id = 'x' })
    alice:nui('claim', 'garbage')
    alice:nui('cancel', { id = 9 })
    alice:nui('abandon')
    alice:nui('duty', { on = true })
    alice:nui('duty', { on = 'yes' })
    alice:nui('duty')
    alice:nui('players')
    alice:nui('refresh')
    w:seconds(1)

    local place = sentToServer(w, NS .. 'place')[1]
    T.eq(place.args[1].targetId, 2, 'numbers coerced')
    T.eq(place.args[1].reward, 15000, 'reward coerced')
    T.eq(place.args[1].target, '7', 'strings coerced')
    T.eq(place.args[1].evil, nil, 'unknown fields dropped')

    local claims = sentToServer(w, NS .. 'claim')
    T.eq(#claims, 1, 'only valid ids are forwarded')
    T.eq(claims[1].args[1], 5, 'id coerced')
    T.eq(sentToServer(w, NS .. 'cancel')[1].args[1], 9, 'cancel forwarded')
    T.eq(#sentToServer(w, NS .. 'abandon'), 1, 'abandon forwarded')

    local duty = sentToServer(w, NS .. 'duty')
    T.eq(#duty, 3, 'three duty requests')
    T.eq(duty[1].args[1], true, 'explicit on')
    T.eq(duty[2].args[1], nil, 'non boolean becomes a toggle')
    T.eq(#sentToServer(w, NS .. 'players'), 1, 'player list requested')
    T.eq(#sentToServer(w, NS .. 'refresh'), 1, 'refresh requested')
end)

H.test('board: stays fresh while open, answers go to the page', function()
    local w, server, clients = setup()
    local alice = clients[1]
    alice:command('hitlist', 1)
    w:seconds(2)
    local first = #alice.nuiMessages

    w:seconds(13)
    T.ok(#alice.nuiMessages > first, 'auto refresh while open')

    -- placing a contract end to end: page -> client -> server -> client -> page
    alice:nui('place', { targetId = 2, reward = 20000, account = 'cash', description = 'x' })
    w:seconds(2)
    local msg = alice:lastNui('state')
    T.eq(msg.toast.ok, true, 'toast arrives with the new state')
    T.eq(#msg.state.placed, 1, 'new contract in the state')

    alice:nui('close')
    local count = #alice.nuiMessages
    w:seconds(30)
    T.eq(#alice.nuiMessages, count, 'no refresh traffic while closed')
end)

H.test('tracker: area blip follows the pings and disappears with the contract', function()
    local w, server, clients = setup()
    local charlie = clients[3]

    clients[1]:command('hitlist', 1)
    w:seconds(2)
    clients[1]:nui('place', { targetId = 2, reward = 20000, account = 'cash' })
    w:seconds(2)
    charlie:nui('duty', { on = true })
    w:seconds(2)
    local id = server.G.Store.Data().contracts[1].id

    charlie:nui('claim', { id = id })
    w:seconds(3)
    T.eq(blipCount(w, 'radius'), 1, 'one search area')
    T.ok(charlie.state.waypoint ~= nil, 'waypoint on the first ping')
    local hud = charlie:lastNui('hud')
    T.eq(hud.visible, true, 'hud visible')
    T.eq(hud.info.target, 'Bob Banks', 'hud names the target')
    T.eq(charlie:lastNui('hudSignal').signal, 'ok', 'signal ok')

    charlie.state.waypoint = nil
    w:seconds(31)
    T.eq(blipCount(w, 'radius'), 1, 'old area replaced, not stacked')
    T.eq(charlie.state.waypoint, nil, 'no new waypoint later')

    -- signal lost
    w:dropPlayer(2)
    w:seconds(31)
    T.eq(blipCount(w, 'radius'), 0, 'area removed when the signal is lost')
    T.eq(charlie:lastNui('hudSignal').signal, 'lost', 'hud says so')

    -- dropping the contract clears the hud
    charlie:nui('abandon')
    w:seconds(2)
    T.eq(charlie:lastNui('hud').visible, false, 'hud hidden')
    T.eq(blipCount(w, 'radius'), 0, 'no blip left')
end)

H.test('target: a hunted player reports who killed him', function()
    local w, server, clients = setup()
    local bob = clients[2]

    -- Alice hires, Charlie takes the job
    clients[1]:command('hitlist', 1)
    w:seconds(2)
    clients[1]:nui('place', { targetId = 2, reward = 20000, account = 'cash' })
    w:seconds(2)
    clients[3]:nui('duty', { on = true })
    w:seconds(2)
    clients[3]:nui('claim', { id = server.G.Store.Data().contracts[1].id })
    w:seconds(3)

    T.eq(#sentToServer(w, NS .. 'reportDeath'), 0, 'nothing reported while alive')

    -- Charlie shoots Bob
    local bobPed = w.entities[w.players[2].ped]
    bobPed.health = 0
    bobPed.killer = w.players[3].ped
    w:seconds(2)

    local reports = sentToServer(w, NS .. 'reportDeath')
    T.eq(#reports, 1, 'reported once')
    T.eq(reports[1].args[1], 3, 'with the killer server id')
    T.eq(w.players[3].cash, 18000, 'and the server paid the hitman')
    T.eq(#server.G.Store.Data().contracts, 0, 'contract completed')

    -- the monitor stops once the contract is over
    bobPed.health = 200
    w:seconds(2)
    bobPed.health = 0
    bobPed.killer = w.players[3].ped
    w:seconds(2)
    T.eq(#sentToServer(w, NS .. 'reportDeath'), 1, 'not hunted any more, nothing reported')
end)

H.test('target: vehicle kills, unknown killers and repeated deaths', function()
    local w, server, clients = setup()
    local bob = clients[2]
    bob:fireClient(CS .. 'hunted', true)
    w:seconds(1)
    local ped = w.entities[w.players[2].ped]

    -- run over by a car driven by player 3
    local car = w:newEntity({ type = 2, driver = w.players[3].ped })
    ped.health = 0
    ped.killer = car.handle
    w:seconds(2)
    local reports = sentToServer(w, NS .. 'reportDeath')
    T.eq(#reports, 1, 'vehicle death reported')
    T.eq(reports[1].args[1], 3, 'the driver is the killer')

    -- stays dead: no second report
    w:seconds(5)
    T.eq(#sentToServer(w, NS .. 'reportDeath'), 1, 'one report per death')

    -- revived, killed by an NPC: no report
    ped.health = 200
    ped.killer = 0
    w:seconds(1)
    local npc = w:newEntity({ type = 1 })
    ped.health = 0
    ped.killer = npc.handle
    w:seconds(3)
    T.eq(#sentToServer(w, NS .. 'reportDeath'), 1, 'NPC kills are not reported')

    -- revived again, killed by player 1: reported again
    ped.health = 200
    w:seconds(1)
    ped.health = 0
    ped.killer = w.players[1].ped
    w:seconds(2)
    reports = sentToServer(w, NS .. 'reportDeath')
    T.eq(#reports, 2, 'a new death is reported')
    T.eq(reports[2].args[1], 1, 'killer id')

    bob:fireClient(CS .. 'hunted', false)
    w:seconds(1)
    ped.health = 200
    w:seconds(1)
    ped.health = 0
    ped.killer = w.players[3].ped
    w:seconds(2)
    T.eq(#sentToServer(w, NS .. 'reportDeath'), 2, 'monitor stopped')
end)

H.test('terminals: marker, prompt and opening with the key', function()
    local w, server, clients = setup(function(C)
        C.Terminals = { { label = 'Back room', coords = H.vec3(0, 0, 30), radius = 2.0, blip = true } }
    end)
    T.eq(blipCount(w, 'coord', 1), 1, 'terminal blip')

    local alice = clients[1]
    alice.state.pressed[38] = true
    w:seconds(2)
    T.ok(alice:lastNui('open') ~= nil, 'E at the terminal opens the board')

    alice:nui('close')
    w.entities[w.players[1].ped].coords = H.vec3(500, 0, 30)
    alice.state.pressed[38] = true
    w:seconds(3)
    T.eq(alice:lastNui().action, 'close', 'far from the terminal nothing opens')
    alice.state.pressed[38] = nil
end)

H.test('cleanup: stopping the resource removes blips and focus', function()
    local w, server, clients = setup(function(C)
        C.Terminals = { { label = 'Back room', coords = H.vec3(0, 0, 30), radius = 2.0, blip = true } }
    end)
    clients[1]:command('hitlist', 1)
    w:seconds(2)
    clients[3]:nui('duty', { on = true })
    w:seconds(2)
    clients[1]:nui('place', { targetId = 2, reward = 20000, account = 'cash' })
    w:seconds(2)
    clients[3]:nui('claim', { id = server.G.Store.Data().contracts[1].id })
    w:seconds(3)
    T.ok(blipCount(w) >= 2, 'blips exist')

    for src = 1, 3 do clients[src]:dispatch('onResourceStop', nil, 'hitman_players') end
    T.eq(blipCount(w), 0, 'blips removed')
    T.eq(clients[1].state.nuiFocus, false, 'focus released')
end)

H.test('target: a death that framework revives within 100 ms is still reported', function()
    local w, server, clients = setup()
    local bob = clients[2]
    bob:fireClient(CS .. 'hunted', true)
    w:seconds(1)

    -- QBCore style: the ped dies for a moment, then is resurrected into a "downed" state
    local ped = w.entities[w.players[2].ped]
    ped.health = 0
    ped.killer = w.players[3].ped
    w:advance(100)
    ped.health = 150
    w:seconds(1)

    local reports = sentToServer(w, NS .. 'reportDeath')
    T.eq(#reports, 1, 'the brief death was seen')
    T.eq(reports[1].args[1], 3, 'with the killer')
end)
