Config = {}

--------------------------------------------------------------------------
-- GENERAL
--------------------------------------------------------------------------
Config.Locale    = 'en'
Config.Framework = 'auto'      -- 'auto' | 'qbcore' | 'qbox' | 'esx' | 'standalone'
Config.Debug     = false       -- verbose server console output
Config.Currency  = '$'

--------------------------------------------------------------------------
-- HOW PLAYERS OPEN THE BOARD
--------------------------------------------------------------------------
Config.Commands = {
    board  = 'hitlist',         -- opens the board (set to false to disable the command)
    duty   = 'hitduty',         -- toggles "available for contracts"
    coords = 'terminalcoords',  -- prints your position as a vec3 (for placing terminals)
    admin  = 'hitmanadmin',     -- /hitmanadmin list | cancel <id> | clear | give <id> <amount>
                                -- needs: add_ace group.admin command.hitmanadmin allow
}
Config.OpenKey = ''             -- default key for the board, '' = unbound (players can bind it in settings)

-- Optional physical terminals. With RequireTerminal = true the board only
-- works next to one of them. Stand where you want one and run /terminalcoords.
Config.RequireTerminal = false
Config.Terminals = {
    -- { label = 'Darknet Terminal', coords = vec3(0.0, 0.0, 0.0), radius = 2.0, blip = false },
}
Config.InteractKey = 38         -- control used at a terminal (38 = E)

--------------------------------------------------------------------------
-- WHO MAY HUNT
--------------------------------------------------------------------------
Config.RequireJob = false       -- true = only players whose framework job is Config.JobName
Config.JobName    = 'hitman'

--------------------------------------------------------------------------
-- CONTRACT RULES
--------------------------------------------------------------------------
Config.Contracts = {
    minReward       = 5000,
    maxReward       = 250000,
    maxDescription  = 140,
    accounts        = { 'cash', 'bank' },  -- accounts a client may pay from
    payoutAccount   = 'cash',              -- where the hitman is paid

    brokerCut       = 10,    -- % of the reward the broker keeps when a contract is fulfilled
    cancelFee       = 10,    -- % kept when the client cancels a contract nobody took yet
    maxPerClient    = 2,     -- open/running contracts one person may have posted
    placeCooldown   = 300,   -- seconds between two contracts by the same person

    expireAfter     = 180,   -- minutes until an unclaimed contract is refunded in full
    claimTime       = 60,    -- minutes a hitman has to finish once he took a contract
    abandonCooldown = 300,   -- seconds a hitman has to wait after dropping/timing out a contract
    disconnectGrace = 120,   -- seconds a hitman may be offline before his claim is released
    immunity        = 30,    -- minutes a target is safe after being killed on contract

    maxKillDistance = 600.0, -- killer and victim must be this close when the death is reported

    targetSelection = 'list',        -- 'list'  = pick from online players
                                     -- 'input' = type a server id or the exact character name
    protectedJobs   = { 'police', 'ambulance' },  -- these jobs cannot be targeted
    warnTarget      = 'claimed',     -- 'claimed' | 'placed' | 'never' - vague warning to the target
    notifyHitmen    = true,          -- tell hitmen on duty when a new contract is posted
}

--------------------------------------------------------------------------
-- TRACKER: the hitman sees a search area, not the exact position
--------------------------------------------------------------------------
Config.Tracker = {
    interval       = 30,      -- seconds between area updates
    minRadius      = 60.0,    -- smallest search area (when you are close)
    maxRadius      = 350.0,   -- largest search area (when you are far)
    distanceFactor = 0.5,     -- radius = distance * factor, clamped to the limits above
    setWaypoint    = true,    -- put a waypoint on the first area
    blipColour     = 1,
    blipAlpha      = 90,
}

--------------------------------------------------------------------------
-- DISCORD LOG (optional)
--------------------------------------------------------------------------
Config.Webhook = {
    url  = '',
    name = 'Hitman Contracts',
}
