-- Runs the active contract on the client: map blips, spawning the target and
-- guards, alert behaviour and kill detection. The server owns the contract,
-- verifies the kill and pays; this file only drives the mission in the world.

Mission = { active = false }

local S = nil -- current mission state, nil = no mission

local HOSTILE_GROUP = 'HITMAN_NPC_HOSTILE'
local hostileHash = joaat(HOSTILE_GROUP)
local MELEE_GROUP = joaat('GROUP_MELEE')
local UNARMED_GROUP = joaat('GROUP_UNARMED')
local BONE_HEAD = 31086
local RETRY_MS = 6000
local MAX_REPORTS = 5
local groupsReady = false

local function dbg(...)
    if Config.Debug then print('[hitman_npc]', ...) end
end

local function pick(list)
    return list[math.random(#list)]
end

local function sameHash(a, b)
    a, b = math.tointeger(a), math.tointeger(b)
    if not a or not b then return false end
    return (a & 0xFFFFFFFF) == (b & 0xFFFFFFFF)
end

--------------------------------------------------------------------------
-- streaming / placement helpers
--------------------------------------------------------------------------
function LoadModel(model)
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local deadline = GetGameTimer() + 8000
    while not HasModelLoaded(hash) do
        if GetGameTimer() > deadline then return nil end
        Wait(10)
    end
    return hash
end

local function groundZ(x, y, z)
    for _ = 1, 8 do
        RequestCollisionAtCoord(x, y, z)
        local found, gz = GetGroundZFor_3dCoord(x, y, z + 25.0, false)
        if found and gz > z - 30.0 and gz < z + 30.0 then return gz end
        Wait(40)
    end
    return z
end

-- A walkable spot near (cx, cy, cz). Falls back to a plain ground probe.
local function findSpot(cx, cy, cz, scatter)
    for attempt = 1, 8 do
        local angle = math.random() * math.pi * 2.0
        local dist = math.random() * scatter
        local x, y = cx + math.cos(angle) * dist, cy + math.sin(angle) * dist
        RequestCollisionAtCoord(x, y, cz)
        local flags = (attempt <= 5) and 12 or 0 -- first: no interiors, no water
        local ok, safe = GetSafeCoordForPed(x, y, cz, false, flags)
        if ok and safe then return safe.x, safe.y, safe.z end
        Wait(30)
    end
    return cx, cy, groundZ(cx, cy, cz)
end

-- Creates a networked ped, trying the listed models in random order.
local function createPed(models, x, y, z, heading)
    local order = {}
    for i = 1, #models do order[i] = models[i] end
    for i = #order, 2, -1 do
        local j = math.random(i)
        order[i], order[j] = order[j], order[i]
    end
    for _, name in ipairs(order) do
        local hash = LoadModel(name)
        if hash then
            local ped = CreatePed(4, hash, x, y, z, heading, true, true)
            SetModelAsNoLongerNeeded(hash)
            if ped and ped ~= 0 and DoesEntityExist(ped) then return ped end
        else
            dbg('model unavailable', name)
        end
    end
    return nil
end

local function removeBlip(blip)
    if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
end

local function nameBlip(blip, label)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(blip)
end

local function setupGroups()
    if groupsReady then return end
    AddRelationshipGroup(HOSTILE_GROUP)
    SetRelationshipBetweenGroups(0, hostileHash, hostileHash)
    SetRelationshipBetweenGroups(5, hostileHash, joaat('PLAYER'))
    SetRelationshipBetweenGroups(5, joaat('PLAYER'), hostileHash)
    groupsReady = true
end

--------------------------------------------------------------------------
-- ped setup
--------------------------------------------------------------------------
local function prepareCommon(ped)
    SetEntityAsMissionEntity(ped, true, true)
    SetPedRandomComponentVariation(ped, 0)
    SetPedDropsWeaponsWhenDead(ped, false)
end

local function setupTarget(ped, def, scenario)
    prepareCommon(ped)
    SetEntityMaxHealth(ped, def.targetHealth)
    SetEntityHealth(ped, def.targetHealth)
    SetPedArmour(ped, def.targetArmour or 0)

    if def.targetBehavior == 'fight' then
        SetPedRelationshipGroupHash(ped, hostileHash)
        SetPedFleeAttributes(ped, 0, false)
        SetPedCombatAttributes(ped, 5, true)
        SetPedCombatAttributes(ped, 46, true)
        SetPedCombatAbility(ped, 1)
        SetPedAccuracy(ped, def.guardAccuracy or 30)
    end
    if def.targetWeapon then
        GiveWeaponToPed(ped, joaat(def.targetWeapon), 250, false, false)
    end

    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedKeepTask(ped, true)
    TaskStartScenarioInPlace(ped, scenario, 0, true)
end

local function setupGuard(ped, def)
    prepareCommon(ped)
    SetPedRelationshipGroupHash(ped, hostileHash)
    GiveWeaponToPed(ped, joaat(pick(def.guardWeapons)), 500, false, true)
    SetPedArmour(ped, def.guardArmour or 0)
    SetPedAccuracy(ped, def.guardAccuracy or 30)
    SetPedCombatAbility(ped, 2)
    SetPedCombatRange(ped, 2)
    SetPedCombatMovement(ped, 2)
    SetPedCombatAttributes(ped, 0, true)
    SetPedCombatAttributes(ped, 5, true)
    SetPedCombatAttributes(ped, 46, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedSeeingRange(ped, 45.0)
    SetPedHearingRange(ped, 30.0)
    SetPedAlertness(ped, 1)
    TaskGuardCurrentPosition(ped, 15.0, 10.0, true)
end

--------------------------------------------------------------------------
-- blips
--------------------------------------------------------------------------
local function addAreaBlip(m)
    -- shift the circle so the target is not dead centre (it always stays inside)
    local angle = math.random() * math.pi * 2.0
    local offset = math.random() * m.def.areaRadius * 0.4
    local cx = m.center.x + math.cos(angle) * offset
    local cy = m.center.y + math.sin(angle) * offset

    m.areaBlip = AddBlipForRadius(cx, cy, m.center.z, m.def.areaRadius)
    SetBlipColour(m.areaBlip, 1)
    SetBlipAlpha(m.areaBlip, 110)

    m.centerBlip = AddBlipForCoord(cx, cy, m.center.z)
    SetBlipSprite(m.centerBlip, 303)
    SetBlipColour(m.centerBlip, 1)
    SetBlipScale(m.centerBlip, 0.8)
    SetBlipAsShortRange(m.centerBlip, false)
    nameBlip(m.centerBlip, L('blip_area'))

    if Config.AutoWaypoint then SetNewWaypoint(cx, cy) end
end

local function updateTargetBlip(m, distance)
    local mode = m.def.targetBlip
    local want = mode == 'always' or (mode == 'near' and distance <= Config.NearBlipDistance)
    if want and not m.targetBlip then
        m.targetBlip = AddBlipForEntity(m.target)
        SetBlipColour(m.targetBlip, 1)
        SetBlipScale(m.targetBlip, 0.9)
        nameBlip(m.targetBlip, L('blip_target'))
        if not m.spotted then
            m.spotted = true
            Bridge.Notify(L('target_spotted'), 'info')
        end
    elseif not want and m.targetBlip then
        removeBlip(m.targetBlip)
        m.targetBlip = nil
    end
end

--------------------------------------------------------------------------
-- spawning
--------------------------------------------------------------------------
local function abandoned(m)
    return S ~= m
end

-- returns true when target (and guards) exist
local function spawnPeds(m)
    local loc, def = m.loc, m.def
    local pool = Config.Targets[m.contract.gender] or Config.Targets.male

    local x, y, z = findSpot(loc.coords.x, loc.coords.y, loc.coords.z, loc.scatter or 20.0)
    if abandoned(m) then return false end

    local target = createPed(pool.models, x, y, z, math.random() * 360.0)
    if not target then return false end
    if abandoned(m) then
        DeleteEntity(target)
        return false
    end
    m.target = target
    setupTarget(target, def, pick(Config.Targets.scenarios))
    m.targetHealth0 = GetEntityHealth(target)

    for _ = 1, m.contract.guards do
        local gx, gy, gz = findSpot(x, y, z, 9.0)
        if abandoned(m) then return false end
        local guard = createPed(Config.GuardModels, gx, gy, gz, math.random() * 360.0)
        if guard then
            if abandoned(m) then
                DeleteEntity(guard)
                return false
            end
            m.guards[#m.guards + 1] = guard
            setupGuard(guard, def)
            m.guardHealth0[guard] = GetEntityHealth(guard)
        end
    end
    return true
end

local function registerWithServer(m)
    local guardIds = {}
    for _, guard in ipairs(m.guards) do
        guardIds[#guardIds + 1] = NetworkGetNetworkIdFromEntity(guard)
    end
    local targetId = NetworkGetNetworkIdFromEntity(m.target)
    SetNetworkIdExistsOnAllMachines(targetId, true)
    TriggerServerEvent('hitman_npc:server:register', m.contract.id, targetId, guardIds)
end

--------------------------------------------------------------------------
-- behaviour
--------------------------------------------------------------------------
local function alertAll(m, player)
    m.alerted = true
    ClearPedTasks(m.target)
    SetBlockingOfNonTemporaryEvents(m.target, false)
    if m.def.targetBehavior == 'fight' then
        TaskCombatPed(m.target, player, 0, 16)
    else
        TaskSmartFleePed(m.target, player, 600.0, -1, false, false)
    end
    for _, guard in ipairs(m.guards) do
        if DoesEntityExist(guard) and not IsEntityDead(guard) then
            TaskCombatPed(guard, player, 0, 16)
        end
    end
end

local function shouldAlert(m, player, distance)
    if distance <= Config.AlertDistance then return true end
    if GetEntityHealth(m.target) < m.targetHealth0 then return true end
    for _, guard in ipairs(m.guards) do
        if DoesEntityExist(guard) then
            if IsEntityDead(guard) or GetEntityHealth(guard) < (m.guardHealth0[guard] or 0) then
                return true
            end
        end
    end
    if distance <= Config.GunfireAlertDistance and IsPedShooting(player)
        and not IsPedCurrentWeaponSilenced(player) then
        return true
    end
    return false
end

local function applyHeat(coords)
    local heat = Config.Heat
    if not heat then return end
    if heat.wantedLevel and heat.wantedLevel > 0 then
        SetPlayerWantedLevel(PlayerId(), heat.wantedLevel, false)
        SetPlayerWantedLevelNow(PlayerId(), false)
    end
    if heat.alert and math.random() < (heat.chance or 0) then
        pcall(heat.alert, coords)
    end
end

local function reportKill(m, player)
    local target = m.target
    local gotBone, bone = GetPedLastDamageBone(target)
    local cause = GetPedCauseOfDeath(target)
    local group = (cause and cause ~= 0) and GetWeapontypeGroup(cause) or 0

    m.report = {
        headshot = (gotBone and bone == BONE_HEAD) and true or false,
        silent = (IsPedCurrentWeaponSilenced(player)
            or sameHash(group, MELEE_GROUP)
            or sameHash(group, UNARMED_GROUP)) and true or false,
    }
    m.killReported = true
    m.killReportedAt = GetGameTimer()
    m.killReports = 1
    TriggerServerEvent('hitman_npc:server:complete', m.contract.id, m.report)
    SendNUIMessage({ action = 'hudStatus', status = 'done' })
    applyHeat(GetEntityCoords(target))
end

--------------------------------------------------------------------------
-- main loop
--------------------------------------------------------------------------
local function loop(m)
    while S == m do
        local player = PlayerPedId()
        local pos = GetEntityCoords(player)
        local sleep = 400

        if not m.spawned then
            if #(pos - m.center) <= Config.SpawnRadius then
                local ok = spawnPeds(m)
                if abandoned(m) then return end
                if ok then
                    m.spawned = true
                    registerWithServer(m)
                    SendNUIMessage({ action = 'hudStatus', status = 'engage' })
                else
                    TriggerServerEvent('hitman_npc:server:fail', m.contract.id, 'spawn_failed')
                    Mission.Stop()
                    return
                end
            end
        else
            sleep = 200
            if m.killReported then
                -- waiting for the server; resend if the answer is slow
                if GetGameTimer() - m.killReportedAt > RETRY_MS then
                    if m.killReports >= MAX_REPORTS then
                        TriggerServerEvent('hitman_npc:server:fail', m.contract.id, 'lost')
                        Mission.Stop()
                        return
                    end
                    m.killReports = m.killReports + 1
                    m.killReportedAt = GetGameTimer()
                    TriggerServerEvent('hitman_npc:server:complete', m.contract.id, m.report)
                end
            elseif not DoesEntityExist(m.target) then
                TriggerServerEvent('hitman_npc:server:fail', m.contract.id, 'lost')
                Mission.Stop()
                return
            else
                local targetPos = GetEntityCoords(m.target)
                local distance = #(pos - targetPos)
                updateTargetBlip(m, distance)

                if IsEntityDead(m.target) or IsPedFatallyInjured(m.target) then
                    reportKill(m, player)
                elseif not m.alerted and shouldAlert(m, player, distance) then
                    alertAll(m, player)
                end
            end
        end

        Wait(sleep)
    end
end

-- Every frame: frameworks revive a dead player into a "downed" state within
-- about 100 ms, so the slower mission loop could miss the moment of death.
local function watchDeath(m)
    while S == m do
        local ped = PlayerPedId()
        if IsPedFatallyInjured(ped) or IsEntityDead(ped) then
            TriggerServerEvent('hitman_npc:server:fail', m.contract.id, 'died')
            Mission.Stop()
            return
        end
        Wait(0)
    end
end

--------------------------------------------------------------------------
-- public api
--------------------------------------------------------------------------
function Mission.Start(contract)
    if S then Mission.Stop() end

    local loc = Config.Locations[contract.locationIndex]
    local def = Config.Tiers[contract.tier]
    if not loc or not def then return end

    setupGroups()

    local m = {
        contract = contract,
        loc = loc,
        def = def,
        center = vec3(loc.coords.x, loc.coords.y, loc.coords.z),
        guards = {},
        guardHealth0 = {},
        spawned = false,
        alerted = false,
        killReported = false,
    }
    S = m
    Mission.active = true

    addAreaBlip(m)
    SendNUIMessage({
        action = 'hud',
        visible = true,
        strings = GetUIStrings(),
        target = contract.target,
        location = contract.location,
        remaining = contract.remaining,
        bonuses = contract.bonuses,
        status = 'travel',
    })
    Bridge.Notify(L('target_here', contract.target), 'info')

    CreateThread(function() loop(m) end)
    if Config.FailOnDeath then
        CreateThread(function() watchDeath(m) end)
    end
end

-- keepBodies: leave the dead for a while (a finished job), otherwise delete now
function Mission.Stop(keepBodies)
    local m = S
    if not m then return end
    S = nil
    Mission.active = false

    removeBlip(m.areaBlip)
    removeBlip(m.centerBlip)
    removeBlip(m.targetBlip)

    local peds = {}
    if m.target then peds[#peds + 1] = m.target end
    for _, guard in ipairs(m.guards) do peds[#peds + 1] = guard end

    local function cleanup()
        for _, ped in ipairs(peds) do
            if DoesEntityExist(ped) then
                SetEntityAsMissionEntity(ped, true, true)
                DeleteEntity(ped)
            end
        end
    end
    if keepBodies and Config.CleanupDelay > 0 then
        SetTimeout(Config.CleanupDelay * 1000, cleanup)
    else
        cleanup()
    end

    SendNUIMessage({ action = 'hud', visible = false })
end
