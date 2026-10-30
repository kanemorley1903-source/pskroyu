-- Persistence for contracts, pending refunds and statistics.
-- Everything lives in the resource KVP store, so no database is needed and
-- escrowed money survives restarts.

Store = {}

local RESOURCE = 'hitman_players'
local KEY_DATA = RESOURCE .. ':data'
local KEY_STATS = RESOURCE .. ':stats:'

local data = {
    nextId = 1,
    contracts = {}, -- array of contract tables
    credits = {},   -- [charId] = { { amount, account, reason, at } }
    immunity = {},  -- [charId] = unix time until the target is safe
}
local stats = {}    -- [charId] = { kills, earned, placed, fulfilled }

function Store.Data()
    return data
end

function Store.Load()
    local raw = GetResourceKvpString(KEY_DATA)
    local decoded = raw and json.decode(raw)
    if type(decoded) == 'table' then
        data.nextId = tonumber(decoded.nextId) or 1
        data.contracts = type(decoded.contracts) == 'table' and decoded.contracts or {}
        data.credits = type(decoded.credits) == 'table' and decoded.credits or {}
        data.immunity = type(decoded.immunity) == 'table' and decoded.immunity or {}
    end

    local t = os.time()
    for _, c in ipairs(data.contracts) do
        -- runtime fields never survive a restart; claimed contracts get the
        -- disconnect grace so the hitman can come back
        c.hitmanSrc = nil
        c.nextPing = 0
        c.pinged = nil
        c.dropAt = (c.status == 'claimed') and t or nil
    end
    for charId, until_ in pairs(data.immunity) do
        if tonumber(until_) == nil or until_ <= t then data.immunity[charId] = nil end
    end
end

function Store.Save()
    SetResourceKvp(KEY_DATA, json.encode(data))
end

--------------------------------------------------------------------------
-- contracts
--------------------------------------------------------------------------
function Store.NextId()
    local id = data.nextId
    data.nextId = id + 1
    return id
end

function Store.Add(contract)
    data.contracts[#data.contracts + 1] = contract
end

function Store.Find(id)
    for _, c in ipairs(data.contracts) do
        if c.id == id then return c end
    end
    return nil
end

function Store.Remove(id)
    for i, c in ipairs(data.contracts) do
        if c.id == id then
            table.remove(data.contracts, i)
            return c
        end
    end
    return nil
end

-- copy of the list so callers can remove entries while iterating
function Store.Snapshot()
    local list = {}
    for i, c in ipairs(data.contracts) do list[i] = c end
    return list
end

--------------------------------------------------------------------------
-- refunds / payouts that could not be handed over (owner offline)
--------------------------------------------------------------------------
function Store.AddCredit(charId, amount, account, reason)
    local list = data.credits[charId]
    if not list then
        list = {}
        data.credits[charId] = list
    end
    list[#list + 1] = { amount = amount, account = account, reason = reason, at = os.time() }
end

function Store.HasCredits(charId)
    local list = data.credits[charId]
    return list ~= nil and #list > 0
end

function Store.TakeCredits(charId)
    local list = data.credits[charId]
    data.credits[charId] = nil
    return list or {}
end

--------------------------------------------------------------------------
-- statistics (one KVP key per character)
--------------------------------------------------------------------------
function Store.GetStats(charId)
    local s = stats[charId]
    if s then return s end
    local raw = GetResourceKvpString(KEY_STATS .. charId)
    local decoded = raw and json.decode(raw)
    s = type(decoded) == 'table' and decoded or {}
    s.kills = tonumber(s.kills) or 0
    s.earned = tonumber(s.earned) or 0
    s.placed = tonumber(s.placed) or 0
    s.fulfilled = tonumber(s.fulfilled) or 0
    stats[charId] = s
    return s
end

function Store.SaveStats(charId)
    local s = stats[charId]
    if s then SetResourceKvp(KEY_STATS .. charId, json.encode(s)) end
end
