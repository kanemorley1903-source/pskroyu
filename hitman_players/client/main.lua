local RESOURCE = GetCurrentResourceName()
local T = Config.Tracker

local uiOpen = false
local awaitingUntil = 0       -- we asked the server to open the board and wait for the answer
local lastRequest = 0

local hunted = false          -- a hitman is after us (set by the server)
local monitorRunning = false

local areaBlip = nil          -- search area of the contract we are working on
local terminalBlips = {}

--------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------
local function showHelp(text)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

local function clearAreaBlip()
    if areaBlip and DoesBlipExist(areaBlip) then RemoveBlip(areaBlip) end
    areaBlip = nil
end

--------------------------------------------------------------------------
-- board (NUI)
--------------------------------------------------------------------------
local function requestOpen()
    local t = GetGameTimer()
    if t - lastRequest < 700 then return end
    lastRequest = t
    awaitingUntil = t + 3000
    TriggerServerEvent('hitman_players:server:open')
end

local function closeUi()
    awaitingUntil = 0
    if not uiOpen then return end
    uiOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

RegisterNetEvent('hitman_players:client:state', function(state, toast)
    if uiOpen then
        SendNUIMessage({ action = 'state', state = state, toast = toast })
    elseif GetGameTimer() < awaitingUntil then
        awaitingUntil = 0
        uiOpen = true
        SetNuiFocus(true, true)
        SendNUIMessage({ action = 'open', strings = GetUIStrings(), state = state, toast = toast })
    elseif toast and toast.text then
        Bridge.Notify(toast.text, toast.ok and 'success' or 'error')
    end
end)

RegisterNetEvent('hitman_players:client:players', function(list)
    if uiOpen then SendNUIMessage({ action = 'players', list = list }) end
end)

RegisterNUICallback('close', function(_, cb)
    closeUi()
    cb({})
end)

RegisterNUICallback('refresh', function(_, cb)
    TriggerServerEvent('hitman_players:server:refresh')
    cb({})
end)

RegisterNUICallback('players', function(_, cb)
    TriggerServerEvent('hitman_players:server:players')
    cb({})
end)

RegisterNUICallback('duty', function(data, cb)
    local on = nil
    if type(data) == 'table' and type(data.on) == 'boolean' then on = data.on end
    TriggerServerEvent('hitman_players:server:duty', on)
    cb({})
end)

RegisterNUICallback('place', function(data, cb)
    if type(data) == 'table' then
        TriggerServerEvent('hitman_players:server:place', {
            targetId = tonumber(data.targetId),
            target = tostring(data.target or ''),
            reward = tonumber(data.reward),
            account = tostring(data.account or ''),
            description = tostring(data.description or ''),
        })
    end
    cb({})
end)

RegisterNUICallback('cancel', function(data, cb)
    local id = type(data) == 'table' and tonumber(data.id)
    if id then TriggerServerEvent('hitman_players:server:cancel', id) end
    cb({})
end)

RegisterNUICallback('claim', function(data, cb)
    local id = type(data) == 'table' and tonumber(data.id)
    if id then TriggerServerEvent('hitman_players:server:claim', id) end
    cb({})
end)

RegisterNUICallback('abandon', function(_, cb)
    TriggerServerEvent('hitman_players:server:abandon')
    cb({})
end)

-- keep an open board fresh
CreateThread(function()
    while true do
        Wait(12000)
        if uiOpen then TriggerServerEvent('hitman_players:server:refresh') end
    end
end)

--------------------------------------------------------------------------
-- commands and key
--------------------------------------------------------------------------
if Config.Commands.board then
    RegisterCommand(Config.Commands.board, requestOpen, false)
    RegisterKeyMapping(Config.Commands.board, 'Open the hitman contract board', 'keyboard', Config.OpenKey or '')
end

if Config.Commands.duty then
    RegisterCommand(Config.Commands.duty, function()
        TriggerServerEvent('hitman_players:server:duty', nil)
    end, false)
end

if Config.Commands.coords then
    RegisterCommand(Config.Commands.coords, function()
        local c = GetEntityCoords(PlayerPedId())
        local text = ('vec3(%.2f, %.2f, %.2f)'):format(c.x, c.y, c.z)
        print(text)
        Bridge.Notify(L('coords_copied', text), 'info')
    end, false)
end

--------------------------------------------------------------------------
-- terminals
--------------------------------------------------------------------------
CreateThread(function()
    if #Config.Terminals == 0 then return end

    for _, terminal in ipairs(Config.Terminals) do
        if terminal.blip then
            local blip = AddBlipForCoord(terminal.coords.x, terminal.coords.y, terminal.coords.z)
            SetBlipSprite(blip, 303)
            SetBlipColour(blip, 1)
            SetBlipScale(blip, 0.7)
            SetBlipAsShortRange(blip, true)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(terminal.label or L('blip_terminal'))
            EndTextCommandSetBlipName(blip)
            terminalBlips[#terminalBlips + 1] = blip
        end
    end

    while true do
        local sleep = 1000
        local pos = GetEntityCoords(PlayerPedId())
        for _, terminal in ipairs(Config.Terminals) do
            local distance = #(pos - terminal.coords)
            if distance < 20.0 then
                sleep = 0
                DrawMarker(27, terminal.coords.x, terminal.coords.y, terminal.coords.z - 0.95,
                    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.2, 1.2, 1.0,
                    214, 52, 62, 150, false, false, 2, false, nil, nil, false)
                if distance <= (terminal.radius or 2.0) and not uiOpen then
                    showHelp(L('prompt_terminal'))
                    if IsControlJustReleased(0, Config.InteractKey) then requestOpen() end
                end
            end
        end
        Wait(sleep)
    end
end)

--------------------------------------------------------------------------
-- hitman side: tracker area + hud
--------------------------------------------------------------------------
RegisterNetEvent('hitman_players:client:track', function(info)
    if not info then
        clearAreaBlip()
        SendNUIMessage({ action = 'hud', visible = false })
        return
    end
    SendNUIMessage({
        action = 'hud',
        visible = true,
        strings = GetUIStrings(),
        info = info,
    })
end)

RegisterNetEvent('hitman_players:client:ping', function(ping)
    clearAreaBlip()
    if ping.lost then
        Bridge.Notify(L('tracker_lost'), 'error')
        SendNUIMessage({ action = 'hudSignal', signal = 'lost' })
        return
    end

    areaBlip = AddBlipForRadius(ping.x, ping.y, 0.0, ping.radius)
    SetBlipColour(areaBlip, T.blipColour)
    SetBlipAlpha(areaBlip, T.blipAlpha)
    SendNUIMessage({ action = 'hudSignal', signal = 'ok' })

    if ping.first then
        Bridge.Notify(L('tracker_ping'), 'info')
        if T.setWaypoint then SetNewWaypoint(ping.x, ping.y) end
    end
end)

--------------------------------------------------------------------------
-- target side: report our own death while a hitman is hunting us
--------------------------------------------------------------------------
local function resolveKiller(ped)
    local killer = NetworkGetEntityKillerOfPlayer(PlayerId())
    if not killer or killer == 0 or killer == ped then killer = GetPedSourceOfDeath(ped) end
    if not killer or killer == 0 or not DoesEntityExist(killer) then return nil end
    if IsEntityAVehicle(killer) then
        killer = GetPedInVehicleSeat(killer, -1)
        if not killer or killer == 0 then return nil end
    end
    if IsEntityAPed(killer) and IsPedAPlayer(killer) then
        local index = NetworkGetPlayerIndexFromPed(killer)
        if index and index ~= -1 then return GetPlayerServerId(index) end
    end
    return nil
end

-- Checked every frame (like FiveM's own baseevents): frameworks revive a dead
-- player into a "downed" state within about 100 ms, so slower polling misses deaths.
local function startMonitor()
    if monitorRunning then return end
    monitorRunning = true
    CreateThread(function()
        local reported = false
        while hunted do
            local ped = PlayerPedId()
            if IsPedFatallyInjured(ped) or IsEntityDead(ped) then
                if not reported then
                    reported = true
                    -- the killer may take a few frames to become known
                    local killer = resolveKiller(ped)
                    for _ = 1, 10 do
                        if killer then break end
                        Wait(0)
                        killer = resolveKiller(ped)
                    end
                    if killer then
                        TriggerServerEvent('hitman_players:server:reportDeath', killer)
                    end
                end
            else
                reported = false
            end
            Wait(0)
        end
        monitorRunning = false
    end)
end

RegisterNetEvent('hitman_players:client:hunted', function(state)
    hunted = state and true or false
    if hunted then startMonitor() end
end)

--------------------------------------------------------------------------
-- cleanup
--------------------------------------------------------------------------
AddEventHandler('onResourceStop', function(resource)
    if resource ~= RESOURCE then return end
    if uiOpen then SetNuiFocus(false, false) end
    clearAreaBlip()
    for _, blip in ipairs(terminalBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
end)
