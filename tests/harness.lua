-- A small fake FiveM: virtual clock, coroutine scheduler, event routing between
-- one server and many clients, KVP storage, a few framework mocks and the
-- natives the two resources use. The real script files run unmodified.

local H = {}

local TESTS_DIR = (debug.getinfo(1, 'S').source:match('^@(.*)/[^/]*$')) or '.'

--------------------------------------------------------------------------
-- vectors (FiveM: vec3 / vec4, `#v` is the length)
--------------------------------------------------------------------------
local Vec = {}
Vec.__index = Vec
Vec.__isvec = true

local function mkvec(x, y, z, w)
    return setmetatable({ x = x + 0.0, y = y + 0.0, z = (z or 0) + 0.0, w = w and (w + 0.0) or nil }, Vec)
end
function Vec.__add(a, b) return mkvec(a.x + b.x, a.y + b.y, a.z + b.z) end
function Vec.__sub(a, b) return mkvec(a.x - b.x, a.y - b.y, a.z - b.z) end
function Vec.__mul(a, b)
    if type(a) == 'number' then a, b = b, a end
    return mkvec(a.x * b, a.y * b, a.z * b)
end
function Vec.__unm(a) return mkvec(-a.x, -a.y, -a.z) end
function Vec.__len(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
function Vec.__eq(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
function Vec.__tostring(a) return ('vec(%.2f, %.2f, %.2f)'):format(a.x, a.y, a.z) end

H.vec3 = function(x, y, z) return mkvec(x, y, z) end
H.vec4 = function(x, y, z, w) return mkvec(x, y, z, w) end

--------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------
local function joaat(s)
    s = tostring(s):lower()
    local h = 0
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = h ~ (h >> 6)
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = h ~ (h >> 11)
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h
end

-- what survives a trip over the network (msgpack): data only, no functions
local function wire(v)
    if type(v) ~= 'table' then
        assert(type(v) ~= 'function', 'functions cannot be sent over events')
        return v
    end
    if getmetatable(v) == Vec then return v end
    local out = {}
    for k, x in pairs(v) do out[wire(k)] = wire(x) end
    return out
end

local function listFiles(dir, pattern)
    if not pattern:find('*', 1, true) then return { pattern } end
    local files = {}
    local p = io.popen(('ls -1 %s/%s 2>/dev/null'):format(dir, pattern))
    for line in p:lines() do files[#files + 1] = line:sub(#dir + 2) end
    p:close()
    table.sort(files)
    return files
end

-- the real FiveM json implementation (dkjson), loaded outside the game
function H.loadJson()
    local source = assert(io.open(TESTS_DIR .. '/vendor/json.lua')):read('a')
    local jenv = setmetatable({}, { __index = _G })
    jenv._G = jenv
    jenv.require = function(modname)
        if modname == 'debug' then return debug end
        error('module not available: ' .. modname)
    end
    return assert(load(source, '@json.lua', 't', jenv))()
end

H.joaat = joaat

--------------------------------------------------------------------------
-- world
--------------------------------------------------------------------------
local World = {}
World.__index = World

function H.world(opts)
    opts = opts or {}
    math.randomseed(opts.seed or 1234)
    local w = setmetatable({
        ms = 0,
        unix = opts.unix or 1700000000,
        threads = {},
        queue = {},
        kvp = {},                  -- [resource][key] = string
        players = {},              -- [src] = player record
        entities = {},             -- [handle] = entity record (shared by server and clients)
        nextEntity = 5000,
        nextNet = 100,
        blips = {},
        nextBlip = 1,
        envs = { server = {}, client = {} },
        clients = {},              -- [src] = client env of the player
        clientEvents = {},         -- everything the server sent: { name, target, args }
        serverEvents = {},         -- everything clients sent: { name, src, args }
        http = {},
        printed = {},
        convars = { onesync = 'on' },
        resourceStates = {},
        exportsRegistry = {},
        notifyLog = {},            -- every framework notification shown to a player
        verbose = opts.verbose,
    }, World)
    return w
end

-- scheduler ---------------------------------------------------------------
function World:step(thread, ...)
    local ok, wait = coroutine.resume(thread.co, ...)
    if not ok then error(debug.traceback(thread.co, tostring(wait)), 0) end
    if coroutine.status(thread.co) == 'dead' then
        thread.dead = true
    else
        wait = tonumber(wait) or 0
        thread.wake = self.ms + (wait < 1 and 16 or wait)
    end
end

function World:spawn(fn, delay, owner)
    local thread = { co = coroutine.create(fn), wake = self.ms + (delay or 0), owner = owner }
    self.threads[#self.threads + 1] = thread
    return thread
end

-- run handler code right now (events start synchronously, like FiveM)
function World:runNow(fn, ...)
    local thread = { co = coroutine.create(fn), wake = self.ms }
    self.threads[#self.threads + 1] = thread
    self:step(thread, ...)
end

function World:pump()
    if self.pumping then return end
    self.pumping = true
    while #self.queue > 0 do
        local item = table.remove(self.queue, 1)
        item()
    end
    self.pumping = false
end

function World:advance(ms)
    local target = self.ms + ms
    self:pump()
    while true do
        local nextThread
        for _, t in ipairs(self.threads) do
            if not t.dead and t.wake <= target and (not nextThread or t.wake < nextThread.wake) then
                nextThread = t
            end
        end
        if not nextThread then break end
        self.ms = math.max(self.ms, nextThread.wake)
        self:step(nextThread)
        self:pump()
        -- drop finished threads now and then
        if #self.threads > 200 then
            local alive = {}
            for _, t in ipairs(self.threads) do if not t.dead then alive[#alive + 1] = t end end
            self.threads = alive
        end
    end
    self.ms = target
end

function World:seconds(n) self:advance(n * 1000) end

-- players / entities -------------------------------------------------------
function World:newEntity(props)
    self.nextEntity = self.nextEntity + 1
    local e = props or {}
    e.handle = self.nextEntity
    e.type = e.type or 1
    e.coords = e.coords or mkvec(0, 0, 0)
    e.health = e.health or 200
    self.entities[e.handle] = e
    return e
end

function World:netId(entity)
    if not entity.netId then
        self.nextNet = self.nextNet + 1
        entity.netId = self.nextNet
    end
    return entity.netId
end

function World:addPlayer(src, opts)
    opts = opts or {}
    local ped = self:newEntity({
        type = 1,
        coords = opts.coords or mkvec(0, 0, 30),
        isPlayer = true,
        playerIndex = src,
        owner = src,
    })
    local p = {
        src = src,
        name = opts.name or ('Player' .. src),
        char = opts.char or ('CHAR' .. src),
        first = opts.first or ('First' .. src),
        last = opts.last or ('Last' .. src),
        job = opts.job or 'unemployed',
        cash = opts.cash or 0,
        bank = opts.bank or 0,
        black = opts.black or 0,
        ped = ped.handle,
        loaded = opts.loaded ~= false,
    }
    ped.player = p
    self.players[src] = p
    return p
end

function World:dropPlayer(src)
    local p = self.players[src]
    if not p then return end
    for _, env in ipairs(self.envs.server) do
        env:dispatch('playerDropped', src, 'quit')
    end
    -- the player's game is gone: so are the scripts running in it
    local client = self.clients[src]
    if client then
        for _, t in ipairs(self.threads) do
            if t.owner == client then t.dead = true end
        end
        self:unload(client)
    end
    self.entities[p.ped] = nil
    self.players[src] = nil
    self:pump()
end

function World:clientOut(name, target)
    local list = {}
    for _, ev in ipairs(self.clientEvents) do
        if ev.name == name and (target == nil or ev.target == target) then list[#list + 1] = ev end
    end
    return list
end

function World:lastClientOut(name, target)
    local list = self:clientOut(name, target)
    return list[#list]
end

function World:clearOut()
    self.clientEvents = {}
    self.serverEvents = {}
end

--------------------------------------------------------------------------
-- resource environments
--------------------------------------------------------------------------
local Env = {}
Env.__index = Env

function Env:dispatch(name, src, ...)
    local handlers = self.handlers[name]
    if not handlers then return end
    local args = table.pack(...)
    for _, fn in ipairs(handlers) do
        -- `source` is only reliable until the handler first yields; clear it
        -- afterwards so code that reads it late fails loudly in the tests
        self.G.source = src
        self.world:runNow(function()
            local ok, err = xpcall(fn, debug.traceback, table.unpack(args, 1, args.n))
            if not ok then error(err, 0) end
        end)
        self.G.source = nil
    end
end

-- act as player `src` sending a server event
function Env:fire(name, src, ...)
    local args = wire(table.pack(...))
    self.world.serverEvents[#self.world.serverEvents + 1] = { name = name, src = src, args = args }
    self:dispatch(name, src, table.unpack(args, 1, args.n))
    self.world:pump()
end

-- act as the server sending a client event
function Env:fireClient(name, ...)
    local args = wire(table.pack(...))
    self:dispatch(name, nil, table.unpack(args, 1, args.n))
    self.world:pump()
end

function Env:command(name, src, args)
    local cmd = self.commands[name]
    assert(cmd, 'command not registered: ' .. tostring(name))
    self.world:runNow(function() cmd.fn(src, args or {}, name) end)
    self.world:pump()
    return cmd
end

function Env:nui(name, data)
    local fn = self.nuiCallbacks[name]
    assert(fn, 'NUI callback not registered: ' .. tostring(name))
    local result
    fn(wire(data or {}), function(r) result = r end)
    self.world:pump()
    return result
end

function Env:lastNui(action)
    for i = #self.nuiMessages, 1, -1 do
        if not action or self.nuiMessages[i].action == action then return self.nuiMessages[i] end
    end
end

function Env:notifications()
    return self.notified
end

local function baseGlobals(w, env, side, resource)
    local G = env.G
    G.vec3, G.vector3, G.vec4, G.vector4 = H.vec3, H.vec3, H.vec4, H.vec4
    G.joaat, G.GetHashKey = joaat, joaat
    G.GetCurrentResourceName = function() return resource end
    G.GetGameTimer = function() return w.ms end
    G.GetResourceState = function(name) return w.resourceStates[name] or 'missing' end
    G.GetConvar = function(name, default) return w.convars[name] or default end
    G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local line = table.concat(parts, ' ')
        w.printed[#w.printed + 1] = line
        if w.verbose then io.write(line, '\n') end
    end
    G.os = setmetatable({
        time = function(t)
            if t then return os.time(t) end
            return w.unix + w.ms // 1000
        end,
    }, { __index = os })

    -- scheduler
    G.CreateThread = function(fn) w:spawn(fn, 0, env) end
    G.SetTimeout = function(ms, fn) w:spawn(fn, ms, env) end
    G.Wait = function(ms) return coroutine.yield(ms) end

    -- events
    local function addHandler(name, fn)
        env.handlers[name] = env.handlers[name] or {}
        table.insert(env.handlers[name], fn)
    end
    G.AddEventHandler = addHandler
    G.RegisterNetEvent = function(name, fn)
        env.netEvents[name] = true
        if fn then addHandler(name, fn) end
    end
    G.RegisterServerEvent = G.RegisterNetEvent
    G.TriggerEvent = function(name, ...)
        for _, e in ipairs(w.envs[side]) do e:dispatch(name, nil, ...) end
    end
    G.RegisterCommand = function(name, fn, restricted)
        env.commands[name] = { fn = fn, restricted = restricted }
    end

    -- exports: exports['res']:Fn(...) and exports.res:Fn(...)
    G.exports = setmetatable({}, {
        __index = function(_, res)
            return setmetatable({}, {
                __index = function(_, fnName)
                    return function(_, ...)
                        local reg = w.exportsRegistry[res]
                        assert(reg and reg[fnName], ('export not found: %s:%s'):format(res, fnName))
                        return reg[fnName](...)
                    end
                end,
            })
        end,
    })
    G.PerformHttpRequest = function(url, cb, method, data, headers)
        w.http[#w.http + 1] = { url = url, method = method, data = data, headers = headers }
    end

    G.json = H.loadJson()
end

local function serverGlobals(w, env)
    local G = env.G

    G.TriggerClientEvent = function(name, target, ...)
        local args = wire(table.pack(...))
        w.clientEvents[#w.clientEvents + 1] = { name = name, target = target, args = args }
        local targets = {}
        if target == -1 then
            for src in pairs(w.clients) do targets[#targets + 1] = src end
        else
            targets[1] = target
        end
        for _, src in ipairs(targets) do
            local client = w.clients[src]
            if client then
                w.queue[#w.queue + 1] = function()
                    client:dispatch(name, nil, table.unpack(args, 1, args.n))
                end
            end
        end
    end

    G.GetPlayers = function()
        local ids = {}
        for src in pairs(w.players) do ids[#ids + 1] = src end
        table.sort(ids)
        for i, id in ipairs(ids) do ids[i] = tostring(id) end
        return ids
    end
    G.GetPlayerName = function(src)
        local p = w.players[tonumber(src)]
        return p and p.name or nil
    end
    G.GetPlayerPed = function(src)
        local p = w.players[tonumber(src)]
        return p and p.ped or 0
    end
    G.GetPlayerIdentifierByType = function(src, kind)
        local p = w.players[tonumber(src)]
        if not p then return nil end
        if kind == 'license' then return 'license:' .. p.char:lower() end
        return nil
    end
    G.GetPlayerIdentifiers = function(src)
        local p = w.players[tonumber(src)]
        return p and { 'license:' .. p.char:lower() } or {}
    end

    -- entities (server view)
    G.DoesEntityExist = function(e) return w.entities[e] ~= nil end
    G.GetEntityCoords = function(e)
        local ent = w.entities[e]
        return ent and ent.coords or mkvec(0, 0, 0)
    end
    G.GetEntityHealth = function(e)
        local ent = w.entities[e]
        return ent and ent.health or 0
    end
    G.GetEntityType = function(e)
        local ent = w.entities[e]
        return ent and ent.type or 0
    end
    G.DeleteEntity = function(e) w.entities[e] = nil end
    G.NetworkGetEntityFromNetworkId = function(netId)
        for handle, ent in pairs(w.entities) do
            if ent.netId == netId then return handle end
        end
        return 0
    end
    G.GetPedSourceOfDeath = function(e)
        local ent = w.entities[e]
        return ent and ent.killer or 0
    end
    G.GetVehiclePedIsIn = function(e)
        local ent = w.entities[e]
        return ent and ent.vehicle or 0
    end

    G.IsPlayerAceAllowed = function() return true end
end

-- frameworks ---------------------------------------------------------------
local function installFrameworks(w)
    local function accountKey(account)
        if account == 'cash' or account == 'money' then return 'cash' end
        return account
    end

    -- QBCore / Qbox style player object
    local function qbPlayer(src)
        local p = w.players[src]
        if not p or not p.loaded then return nil end
        return {
            PlayerData = {
                citizenid = p.char,
                charinfo = { firstname = p.first, lastname = p.last },
                job = { name = p.job },
                money = { cash = p.cash, bank = p.bank },
            },
            Functions = {
                GetMoney = function(account)
                    local k = accountKey(account)
                    if k ~= 'cash' and k ~= 'bank' then return false end
                    return p[k]
                end,
                AddMoney = function(account, amount)
                    if p.failAdd then error('framework exploded in AddMoney') end
                    local k = accountKey(account)
                    if k ~= 'cash' and k ~= 'bank' then return false end
                    p[k] = p[k] + amount
                    return true
                end,
                RemoveMoney = function(account, amount)
                    if p.failRemove then error('framework exploded in RemoveMoney') end
                    local k = accountKey(account)
                    if (k ~= 'cash' and k ~= 'bank') or p[k] < amount then return false end
                    p[k] = p[k] - amount
                    return true
                end,
            },
        }
    end

    local function esxPlayer(src)
        local p = w.players[src]
        if not p or not p.loaded then return nil end
        local x = { identifier = p.char, job = { name = p.job } }
        function x.getName() return p.first .. ' ' .. p.last end
        function x.getJob() return x.job end
        function x.getAccount(name)
            if name == 'money' then return { money = p.cash } end
            if name == 'bank' then return { money = p.bank } end
            if name == 'black_money' then return { money = p.black } end
            return nil
        end
        function x.addMoney(n) p.cash = p.cash + n end
        function x.removeMoney(n) p.cash = p.cash - n end
        function x.addAccountMoney(name, n)
            if name == 'bank' then p.bank = p.bank + n
            elseif name == 'black_money' then p.black = p.black + n
            else error('no such account ' .. tostring(name)) end
        end
        function x.removeAccountMoney(name, n)
            if name == 'bank' then p.bank = p.bank - n
            elseif name == 'black_money' then p.black = p.black - n
            else error('no such account ' .. tostring(name)) end
        end
        return x
    end

    local function shown(message) w.notifyLog[#w.notifyLog + 1] = message end
    w.exportsRegistry['qb-core'] = {
        GetCoreObject = function()
            return { Functions = { GetPlayer = qbPlayer, Notify = shown } }
        end,
    }
    w.exportsRegistry['qbx_core'] = { GetPlayer = qbPlayer, Notify = shown }
    w.exportsRegistry['es_extended'] = {
        getSharedObject = function()
            return { GetPlayerFromId = esxPlayer, ShowNotification = shown }
        end,
    }
end

function H.useFramework(w, name)
    installFrameworks(w)
    w.resourceStates = {}
    if name == 'qbcore' then w.resourceStates['qb-core'] = 'started' end
    if name == 'qbox' then w.resourceStates['qbx_core'] = 'started' end
    if name == 'esx' then w.resourceStates['es_extended'] = 'started' end
end

-- client natives ---------------------------------------------------------------
local function clientGlobals(w, env, src)
    local G = env.G
    local state = { pressed = {}, shooting = false, silenced = false, waypoint = nil, wanted = nil, nuiFocus = false }
    env.state = state

    G.TriggerServerEvent = function(name, ...)
        local args = wire(table.pack(...))
        w.serverEvents[#w.serverEvents + 1] = { name = name, src = src, args = args }
        w.queue[#w.queue + 1] = function()
            for _, server in ipairs(w.envs.server) do
                server:dispatch(name, src, table.unpack(args, 1, args.n))
            end
        end
    end
    G.RegisterNUICallback = function(name, fn) env.nuiCallbacks[name] = fn end
    G.SendNUIMessage = function(msg)
        env.nuiMessages[#env.nuiMessages + 1] = wire(msg)
        return true
    end
    G.SetNuiFocus = function(focus) state.nuiFocus = focus end
    G.RegisterKeyMapping = function(command, description, kind, key)
        env.keyMappings[command] = { description = description, kind = kind, key = key }
    end

    -- player / entities
    G.PlayerPedId = function() return w.players[src].ped end
    G.PlayerId = function() return src end
    G.GetPlayerServerId = function(index) return index end
    G.GetEntityCoords = function(e)
        local ent = w.entities[e]
        return ent and ent.coords or mkvec(0, 0, 0)
    end
    G.GetEntityHeading = function() return 90.0 end
    G.DoesEntityExist = function(e) return e ~= nil and w.entities[e] ~= nil end
    G.IsEntityDead = function(e)
        local ent = w.entities[e]
        return ent == nil or ent.health <= 0
    end
    G.IsPedFatallyInjured = G.IsEntityDead
    G.GetEntityHealth = function(e)
        local ent = w.entities[e]
        return ent and ent.health or 0
    end
    G.SetEntityHealth = function(e, h) if w.entities[e] then w.entities[e].health = h end end
    G.DeleteEntity = function(e) w.entities[e] = nil end
    G.IsEntityAVehicle = function(e) return w.entities[e] ~= nil and w.entities[e].type == 2 end
    G.IsEntityAPed = function(e) return w.entities[e] ~= nil and w.entities[e].type == 1 end
    G.IsPedAPlayer = function(e) return w.entities[e] ~= nil and w.entities[e].isPlayer == true end
    G.NetworkGetPlayerIndexFromPed = function(e)
        local ent = w.entities[e]
        return ent and ent.playerIndex or -1
    end
    G.GetPedInVehicleSeat = function(vehicle)
        local ent = w.entities[vehicle]
        return ent and ent.driver or 0
    end
    G.GetPedSourceOfDeath = function(e)
        local ent = w.entities[e]
        return ent and ent.killer or 0
    end
    G.NetworkGetEntityKillerOfPlayer = function()
        local ent = w.entities[w.players[src].ped]
        return ent and ent.killer or 0, 0
    end
    G.GetPedCauseOfDeath = function(e)
        local ent = w.entities[e]
        return ent and ent.cause or 0
    end
    G.GetWeapontypeGroup = function(hash) return hash == 1 and joaat('GROUP_MELEE') or joaat('GROUP_PISTOL') end
    G.GetPedLastDamageBone = function(e)
        local ent = w.entities[e]
        return (ent and ent.lastBone) ~= nil, ent and ent.lastBone or 0
    end
    G.IsPedShooting = function() return state.shooting end
    G.IsPedCurrentWeaponSilenced = function() return state.silenced end
    G.IsControlJustReleased = function(_, key)
        if state.pressed[key] then
            state.pressed[key] = nil
            return true
        end
        return false
    end

    -- models / spawning
    G.IsModelInCdimage = function() return true end
    G.IsModelValid = function() return true end
    G.RequestModel = function() end
    G.HasModelLoaded = function() return true end
    G.SetModelAsNoLongerNeeded = function() end
    G.RequestCollisionAtCoord = function() end
    G.GetSafeCoordForPed = function(x, y, z) return true, mkvec(x, y, z) end
    G.GetGroundZFor_3dCoord = function(_, _, z) return true, z - 25.0 end
    G.CreatePed = function(_, hash, x, y, z, _, isNetwork)
        local ped = w:newEntity({ type = 1, coords = mkvec(x, y, z), model = hash, health = 200, owner = src })
        if isNetwork then w:netId(ped) end
        return ped.handle
    end
    G.NetworkGetNetworkIdFromEntity = function(e)
        local ent = w.entities[e]
        return ent and w:netId(ent) or 0
    end
    G.SetNetworkIdExistsOnAllMachines = function() end

    -- ped behaviour (recorded so tests can look at it)
    local function record(field)
        return function(e, ...)
            local ent = w.entities[e]
            if ent then
                ent[field] = table.pack(...)
            end
        end
    end
    G.TaskCombatPed = function(e) if w.entities[e] then w.entities[e].task = 'combat' end end
    G.TaskSmartFleePed = function(e) if w.entities[e] then w.entities[e].task = 'flee' end end
    G.TaskStartScenarioInPlace = function(e) if w.entities[e] then w.entities[e].task = 'scenario' end end
    G.TaskGuardCurrentPosition = function(e) if w.entities[e] then w.entities[e].task = 'guard' end end
    G.ClearPedTasks = function(e) if w.entities[e] then w.entities[e].task = nil end end
    G.GiveWeaponToPed = function(e, weapon) if w.entities[e] then w.entities[e].weapon = weapon end end
    G.SetPedArmour = record('armour')
    G.SetEntityMaxHealth = record('maxHealth')
    G.SetPedRelationshipGroupHash = record('group')
    G.SetBlockingOfNonTemporaryEvents = record('blocking')
    for _, name in ipairs({
        'SetEntityAsMissionEntity', 'SetPedRandomComponentVariation', 'SetPedDropsWeaponsWhenDead',
        'SetPedFleeAttributes', 'SetPedCombatAttributes', 'SetPedCombatAbility', 'SetPedAccuracy',
        'SetPedCombatRange', 'SetPedCombatMovement', 'SetPedSeeingRange', 'SetPedHearingRange',
        'SetPedAlertness', 'SetPedKeepTask', 'SetPedCanRagdoll', 'SetEntityInvincible',
        'FreezeEntityPosition', 'AddRelationshipGroup', 'SetRelationshipBetweenGroups',
        'DrawMarker', 'BeginTextCommandDisplayHelp',
        'EndTextCommandDisplayHelp', 'BeginTextCommandSetBlipName', 'EndTextCommandSetBlipName',
        'SetBlipColour', 'SetBlipScale', 'SetBlipAlpha', 'SetBlipSprite', 'SetBlipAsShortRange',
        'SetPlayerWantedLevelNow',
    }) do
        G[name] = function() end
    end
    env.texts = {}
    G.AddTextComponentSubstringPlayerName = function(text) env.texts[#env.texts + 1] = text end
    G.BeginTextCommandThefeedPost = function() end
    G.EndTextCommandThefeedPostTicker = function() end
    G.SetNewWaypoint = function(x, y) state.waypoint = { x = x, y = y } end
    G.SetPlayerWantedLevel = function(_, level) state.wanted = level end

    -- blips
    local function newBlip(kind)
        return function(a, b, c, d)
            local id = w.nextBlip
            w.nextBlip = id + 1
            w.blips[id] = { kind = kind, a = a, b = b, c = c, d = d, owner = src }
            return id
        end
    end
    G.AddBlipForRadius = newBlip('radius')
    G.AddBlipForCoord = newBlip('coord')
    G.AddBlipForEntity = newBlip('entity')
    G.DoesBlipExist = function(id) return w.blips[id] ~= nil end
    G.RemoveBlip = function(id) w.blips[id] = nil end
end

--------------------------------------------------------------------------
-- loading a resource (reads the real fxmanifest.lua)
--------------------------------------------------------------------------
-- opts.config(Config)      called right after config.lua ran
-- opts.src                 player id (client side)
function World:load(dir, side, opts)
    opts = opts or {}
    local resource = dir:match('([^/]+)/?$')

    -- manifest
    local manifest = {}
    local menv = setmetatable({}, { __index = function(_, key)
        return function(value) manifest[key] = value end
    end })
    local mchunk = assert(loadfile(dir .. '/fxmanifest.lua', 't', menv))
    mchunk()

    local env = setmetatable({
        world = self, side = side, resource = resource,
        handlers = {}, netEvents = {}, commands = {},
        nuiCallbacks = {}, nuiMessages = {}, keyMappings = {}, notified = {},
        G = {},
    }, Env)
    local G = env.G
    setmetatable(G, { __index = _G })
    G._G = G

    baseGlobals(self, env, side, resource)
    if side == 'server' then
        serverGlobals(self, env)
    else
        clientGlobals(self, env, opts.src)
    end

    local scripts = {}
    for _, list in ipairs({ manifest.shared_scripts or {}, manifest[side .. '_scripts'] or {} }) do
        for _, pattern in ipairs(list) do
            for _, file in ipairs(listFiles(dir, pattern)) do scripts[#scripts + 1] = file end
        end
    end

    self.envs[side][#self.envs[side] + 1] = env
    if side == 'client' then self.clients[opts.src] = env end

    -- KVP is per resource
    self.kvp[resource] = self.kvp[resource] or {}
    local kvp = self.kvp[resource]
    G.SetResourceKvp = function(key, value) kvp[key] = tostring(value) end
    G.GetResourceKvpString = function(key) return kvp[key] end
    G.DeleteResourceKvp = function(key) kvp[key] = nil end

    for _, file in ipairs(scripts) do
        local chunk, err = loadfile(dir .. '/' .. file, 't', G)
        assert(chunk, err)
        local ok, runErr = xpcall(chunk, debug.traceback)
        if not ok then error(('error in %s/%s: %s'):format(resource, file, runErr), 0) end
        if file == 'config.lua' and opts.config then opts.config(G.Config) end
    end
    self:pump()
    return env
end

function World:unload(env)
    for i, e in ipairs(self.envs[env.side]) do
        if e == env then table.remove(self.envs[env.side], i) break end
    end
    for src, c in pairs(self.clients) do
        if c == env then self.clients[src] = nil end
    end
end

--------------------------------------------------------------------------
-- tiny assertion kit
--------------------------------------------------------------------------
local T = { passed = 0, failed = 0, failures = {}, current = '' }
H.T = T

local function show(v)
    if type(v) == 'table' and getmetatable(v) ~= Vec then
        local parts = {}
        for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. '=' .. show(x) end
        table.sort(parts)
        return '{' .. table.concat(parts, ', ') .. '}'
    end
    return tostring(v)
end

local function fail(msg)
    T.failed = T.failed + 1
    T.failures[#T.failures + 1] = ('[%s] %s'):format(T.current, msg)
    if H.stopOnFail then error(msg, 0) end
end

function T.ok(cond, msg)
    if cond then T.passed = T.passed + 1 else fail(msg or 'expected truthy') end
end

function T.eq(actual, expected, msg)
    if actual == expected then
        T.passed = T.passed + 1
    else
        fail(('%s: expected %s, got %s'):format(msg or 'eq', show(expected), show(actual)))
    end
end

function T.near(actual, expected, tolerance, msg)
    if type(actual) == 'number' and math.abs(actual - expected) <= (tolerance or 0.001) then
        T.passed = T.passed + 1
    else
        fail(('%s: expected %s ± %s, got %s'):format(msg or 'near', expected, tolerance, show(actual)))
    end
end

function T.contains(text, needle, msg)
    if type(text) == 'string' and text:find(needle, 1, true) then
        T.passed = T.passed + 1
    else
        fail(('%s: %q does not contain %q'):format(msg or 'contains', show(text), needle))
    end
end

function H.test(name, fn)
    T.current = name
    local before = T.failed
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then
        T.failed = T.failed + 1
        T.failures[#T.failures + 1] = ('[%s] raised: %s'):format(name, err)
        io.write('E')
    elseif T.failed > before then
        io.write('F')
    else
        io.write('.')
    end
    io.flush()
end

return H
