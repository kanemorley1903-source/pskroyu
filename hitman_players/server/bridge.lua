-- Framework bridge: QBCore, Qbox, ESX or a built-in standalone wallet.
-- The rest of the resource only talks to `Bridge`.

Bridge = { framework = 'standalone', ready = false }

local EVENT_PREFIX = 'hitman_players'
local FRAMEWORK_RESOURCE = { qbcore = 'qb-core', qbox = 'qbx_core', esx = 'es_extended' }

local QBCore, ESX

local function detect()
    local want = Config.Framework
    if want and want ~= 'auto' then return want end
    if GetResourceState('qbx_core') == 'started' then return 'qbox' end
    if GetResourceState('qb-core') == 'started' then return 'qbcore' end
    if GetResourceState('es_extended') == 'started' then return 'esx' end
    return nil
end

local function init(name)
    if name ~= 'qbcore' and name ~= 'qbox' and name ~= 'esx' and name ~= 'standalone' then
        print(('^3[%s]^7 unknown Config.Framework "%s", falling back to standalone'):format(EVENT_PREFIX, tostring(name)))
        name = 'standalone'
    end
    if name == 'qbcore' then
        QBCore = exports['qb-core']:GetCoreObject()
    elseif name == 'esx' then
        ESX = exports['es_extended']:getSharedObject()
    end
    Bridge.framework = name
    Bridge.ready = true
    print(('^2[%s]^7 framework: %s'):format(EVENT_PREFIX, name))
end

CreateThread(function()
    local name = detect()
    local waited = 0
    if Config.Framework == 'auto' then
        -- give the framework time to start when this resource is ensured first
        while not name and waited < 15000 do
            Wait(500)
            waited = waited + 500
            name = detect()
        end
        name = name or 'standalone'
    else
        local res = FRAMEWORK_RESOURCE[name]
        while res and GetResourceState(res) ~= 'started' and waited < 30000 do
            Wait(250)
            waited = waited + 250
        end
    end
    init(name)
end)

--------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------
local function getPlayer(src)
    local fw = Bridge.framework
    if fw == 'qbcore' then
        return QBCore.Functions.GetPlayer(src)
    elseif fw == 'qbox' then
        return exports.qbx_core:GetPlayer(src)
    elseif fw == 'esx' then
        return ESX.GetPlayerFromId(src)
    end
    return nil
end

local function getLicense(src)
    local id = GetPlayerIdentifierByType(src, 'license')
    if id then return id end
    for _, v in ipairs(GetPlayerIdentifiers(src)) do
        if v:sub(1, 8) == 'license:' then return v end
    end
    return nil
end

local function normalizeAccount(account)
    if account == nil or account == 'money' or account == 'cash' then return 'cash' end
    return account
end

--------------------------------------------------------------------------
-- standalone wallet (only used when no framework is running)
--------------------------------------------------------------------------
local WALLET_KEY = EVENT_PREFIX .. ':wallet:'

local function walletGet(charId)
    if not charId then return 0 end
    return tonumber(GetResourceKvpString(WALLET_KEY .. charId)) or 0
end

local function walletSet(charId, amount)
    SetResourceKvp(WALLET_KEY .. charId, tostring(math.floor(amount)))
end

--------------------------------------------------------------------------
-- public api
--------------------------------------------------------------------------

-- Stable id of the active character (not the connection). nil = not loaded.
function Bridge.GetCharId(src)
    local fw = Bridge.framework
    if fw == 'qbcore' or fw == 'qbox' then
        local p = getPlayer(src)
        return p and p.PlayerData and p.PlayerData.citizenid or nil
    elseif fw == 'esx' then
        local p = getPlayer(src)
        return p and p.identifier or nil
    end
    if not GetPlayerName(src) then return nil end
    return getLicense(src) or ('src:' .. tostring(src))
end

function Bridge.GetName(src)
    local fw = Bridge.framework
    if fw == 'qbcore' or fw == 'qbox' then
        local p = getPlayer(src)
        local ci = p and p.PlayerData and p.PlayerData.charinfo
        if ci and ci.firstname then
            return ('%s %s'):format(ci.firstname, ci.lastname or '')
        end
    elseif fw == 'esx' then
        local p = getPlayer(src)
        if p and p.getName then return p.getName() end
    end
    return GetPlayerName(src) or 'Unknown'
end

function Bridge.GetJob(src)
    local fw = Bridge.framework
    if fw == 'qbcore' or fw == 'qbox' then
        local p = getPlayer(src)
        local job = p and p.PlayerData and p.PlayerData.job
        return job and job.name or nil
    elseif fw == 'esx' then
        local p = getPlayer(src)
        if not p then return nil end
        if p.job and p.job.name then return p.job.name end
        if p.getJob then
            local job = p.getJob()
            return job and job.name or nil
        end
    end
    return nil
end

function Bridge.GetMoney(src, account)
    account = normalizeAccount(account)
    local fw = Bridge.framework
    if fw == 'qbcore' or fw == 'qbox' then
        local p = getPlayer(src)
        if not p then return 0 end
        return p.Functions.GetMoney(account) or 0
    elseif fw == 'esx' then
        local p = getPlayer(src)
        if not p then return 0 end
        local acc = p.getAccount(account == 'cash' and 'money' or account)
        return acc and acc.money or 0
    end
    return walletGet(Bridge.GetCharId(src))
end

local function addMoney(src, account, amount, reason)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return false end
    account = normalizeAccount(account)
    local fw = Bridge.framework
    if fw == 'qbcore' or fw == 'qbox' then
        local p = getPlayer(src)
        if not p then return false end
        if account ~= 'cash' and account ~= 'bank' and account ~= 'crypto' then account = 'cash' end
        return p.Functions.AddMoney(account, amount, reason or EVENT_PREFIX) == true
    elseif fw == 'esx' then
        local p = getPlayer(src)
        if not p then return false end
        local ok = pcall(function()
            if account == 'cash' then
                p.addMoney(amount, reason)
            else
                p.addAccountMoney(account, amount, reason)
            end
        end)
        return ok
    end
    local charId = Bridge.GetCharId(src)
    if not charId then return false end
    walletSet(charId, walletGet(charId) + amount)
    return true
end

local function removeMoney(src, account, amount, reason)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return false end
    account = normalizeAccount(account)
    if Bridge.GetMoney(src, account) < amount then return false end
    local fw = Bridge.framework
    if fw == 'qbcore' or fw == 'qbox' then
        local p = getPlayer(src)
        if not p then return false end
        return p.Functions.RemoveMoney(account, amount, reason or EVENT_PREFIX) == true
    elseif fw == 'esx' then
        local p = getPlayer(src)
        if not p then return false end
        local ok = pcall(function()
            if account == 'cash' then
                p.removeMoney(amount, reason)
            else
                p.removeAccountMoney(account, amount, reason)
            end
        end)
        return ok
    end
    local charId = Bridge.GetCharId(src)
    if not charId then return false end
    walletSet(charId, walletGet(charId) - amount)
    return true
end

-- A framework error must never escape between taking money and booking it:
-- callers get `false` and decide what to do (usually: keep it as a credit).
local function guarded(name, fn)
    return function(...)
        local ok, result = pcall(fn, ...)
        if not ok then
            print(('^1[%s] %s failed: %s^7'):format(EVENT_PREFIX, name, tostring(result)))
            return false
        end
        return result
    end
end

Bridge.AddMoney = guarded('AddMoney', addMoney)
Bridge.RemoveMoney = guarded('RemoveMoney', removeMoney)

function Bridge.Notify(src, message, kind)
    TriggerClientEvent(EVENT_PREFIX .. ':client:notify', src, message, kind or 'info')
end
