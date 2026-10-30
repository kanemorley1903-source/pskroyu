-- Client side framework bridge. Only used for notifications.

Bridge = {}

local EVENT_PREFIX = 'hitman_players'

local function detect()
    local want = Config.Framework
    if want and want ~= 'auto' then return want end
    if GetResourceState('qbx_core') == 'started' then return 'qbox' end
    if GetResourceState('qb-core') == 'started' then return 'qbcore' end
    if GetResourceState('es_extended') == 'started' then return 'esx' end
    return 'standalone'
end

local function nativeNotify(message)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandThefeedPostTicker(false, true)
end

local QB_KIND = { info = 'primary', success = 'success', error = 'error', warning = 'primary' }
local QBOX_KIND = { info = 'inform', success = 'success', error = 'error', warning = 'warning' }

function Bridge.Notify(message, kind)
    kind = kind or 'info'
    local framework = detect()
    local ok = false

    if framework == 'qbcore' then
        ok = pcall(function()
            exports['qb-core']:GetCoreObject().Functions.Notify(message, QB_KIND[kind] or 'primary', 6000)
        end)
    elseif framework == 'qbox' then
        ok = pcall(function()
            exports.qbx_core:Notify(message, QBOX_KIND[kind] or 'inform', 6000)
        end)
    elseif framework == 'esx' then
        ok = pcall(function()
            exports['es_extended']:getSharedObject().ShowNotification(message, kind, 6000)
        end)
    end

    if not ok then nativeNotify(message) end
end

RegisterNetEvent(EVENT_PREFIX .. ':client:notify', function(message, kind)
    Bridge.Notify(message, kind)
end)
