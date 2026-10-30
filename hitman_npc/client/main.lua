local RESOURCE = GetCurrentResourceName()

local brokerPed = nil
local brokerBlip = nil
local uiOpen = false
local awaitingUntil = 0    -- we asked the server for the board and wait for the answer
local lastRequest = 0

--------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------
local function showHelp(text)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

local function brokerOrigin()
    local c = Config.Broker.coords
    return vec3(c.x, c.y, c.z)
end

--------------------------------------------------------------------------
-- broker blip + ped
--------------------------------------------------------------------------
local function createBrokerBlip()
    local cfg = Config.Broker.blip
    if not cfg or not cfg.enabled or brokerBlip then return end
    local c = Config.Broker.coords
    brokerBlip = AddBlipForCoord(c.x, c.y, c.z)
    SetBlipSprite(brokerBlip, cfg.sprite)
    SetBlipColour(brokerBlip, cfg.color)
    SetBlipScale(brokerBlip, cfg.scale)
    SetBlipAsShortRange(brokerBlip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(L('blip_broker'))
    EndTextCommandSetBlipName(brokerBlip)
end

local function spawnBroker()
    local cfg = Config.Broker
    local hash = LoadModel(cfg.model)
    if not hash then return end

    local c = cfg.coords
    local z = c.z
    for _ = 1, 10 do
        RequestCollisionAtCoord(c.x, c.y, c.z)
        local found, groundZ = GetGroundZFor_3dCoord(c.x, c.y, c.z + 2.0, false)
        if found and math.abs(groundZ - c.z) < 6.0 then
            z = groundZ
            break
        end
        Wait(50)
    end

    local ped = CreatePed(4, hash, c.x, c.y, z, c.w, false, true)
    SetModelAsNoLongerNeeded(hash)
    if not ped or ped == 0 then return end

    SetEntityAsMissionEntity(ped, true, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedCanRagdoll(ped, false)
    FreezeEntityPosition(ped, true)
    if cfg.scenario then TaskStartScenarioInPlace(ped, cfg.scenario, 0, true) end
    brokerPed = ped
end

local function removeBroker()
    if brokerPed and DoesEntityExist(brokerPed) then DeleteEntity(brokerPed) end
    brokerPed = nil
end

--------------------------------------------------------------------------
-- contract board (NUI)
--------------------------------------------------------------------------
local function requestBoard()
    local t = GetGameTimer()
    if t - lastRequest < 700 then return end
    lastRequest = t
    awaitingUntil = t + 3000
    TriggerServerEvent('hitman_npc:server:openBoard')
end

local function openBoard(data)
    if not uiOpen and GetGameTimer() >= awaitingUntil then return end
    awaitingUntil = 0
    if not uiOpen then
        uiOpen = true
        SetNuiFocus(true, true)
    end
    SendNUIMessage({ action = 'board', data = data, strings = GetUIStrings() })
end

local function closeBoard()
    awaitingUntil = 0
    if not uiOpen then return end
    uiOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'closeBoard' })
end

RegisterNetEvent('hitman_npc:client:board', openBoard)

RegisterNUICallback('close', function(_, cb)
    closeBoard()
    cb({})
end)

RegisterNUICallback('accept', function(data, cb)
    local id = type(data) == 'table' and tonumber(data.id)
    if id then TriggerServerEvent('hitman_npc:server:accept', id) end
    cb({})
end)

RegisterNUICallback('abandon', function(_, cb)
    TriggerServerEvent('hitman_npc:server:cancel')
    closeBoard()
    cb({})
end)

--------------------------------------------------------------------------
-- contract events from the server
--------------------------------------------------------------------------
RegisterNetEvent('hitman_npc:client:start', function(contract)
    closeBoard()
    Mission.Start(contract)
end)

RegisterNetEvent('hitman_npc:client:finish', function(reason)
    Mission.Stop(reason == 'completed')
end)

--------------------------------------------------------------------------
-- broker interaction loop
--------------------------------------------------------------------------
CreateThread(function()
    createBrokerBlip()

    local cfg = Config.Broker
    while true do
        local sleep = 1000
        local alive = brokerPed and DoesEntityExist(brokerPed)
        local origin = alive and GetEntityCoords(brokerPed) or brokerOrigin()
        local distance = #(GetEntityCoords(PlayerPedId()) - origin)

        if distance <= cfg.spawnDistance then
            sleep = 500
            if not alive then
                brokerPed = nil
                spawnBroker()
            end
            if distance <= cfg.interactDistance and not uiOpen then
                sleep = 0
                showHelp(L('prompt_broker'))
                if IsControlJustReleased(0, Config.InteractKey) then requestBoard() end
            end
        elseif brokerPed then
            removeBroker()
        end

        Wait(sleep)
    end
end)

--------------------------------------------------------------------------
-- commands
--------------------------------------------------------------------------
RegisterCommand(Config.Commands.cancel, function()
    -- the server owns the contract and answers "no active contract" itself
    TriggerServerEvent('hitman_npc:server:cancel')
end, false)

RegisterCommand(Config.Commands.coords, function()
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    local text = ('vec4(%.2f, %.2f, %.2f, %.2f)'):format(c.x, c.y, c.z, GetEntityHeading(ped))
    print(text)
    Bridge.Notify(L('coords_copied', text), 'info')
end, false)

--------------------------------------------------------------------------
-- cleanup
--------------------------------------------------------------------------
AddEventHandler('onResourceStop', function(resource)
    if resource ~= RESOURCE then return end
    if uiOpen then SetNuiFocus(false, false) end
    Mission.Stop()
    removeBroker()
    if brokerBlip and DoesBlipExist(brokerBlip) then RemoveBlip(brokerBlip) end
end)
