Config = {}

--------------------------------------------------------------------------
-- GENERAL
--------------------------------------------------------------------------
Config.Locale    = 'en'
Config.Framework = 'auto'      -- 'auto' | 'qbcore' | 'qbox' | 'esx' | 'standalone'
Config.Debug     = false       -- verbose server console output
Config.Currency  = '$'

Config.InteractKey = 38        -- control used to talk to the broker (38 = E)

--------------------------------------------------------------------------
-- WHO CAN WORK THE JOB
--------------------------------------------------------------------------
Config.RequireJob = false      -- true = only players whose framework job is Config.JobName
Config.JobName    = 'hitman'

Config.MinPolice  = 0          -- police that must be online before contracts are handed out
Config.PoliceJobs = { 'police', 'sheriff', 'state' }

--------------------------------------------------------------------------
-- THE BROKER (the NPC that hands out contracts)
-- Stand where you want him and run /hitmancoords to copy the position.
--------------------------------------------------------------------------
Config.Broker = {
    model            = 'g_m_m_armboss_01',
    coords           = vec4(-1851.2, -1232.0, 13.02, 330.0),
    scenario         = 'WORLD_HUMAN_SMOKING',
    spawnDistance    = 80.0,   -- ped is created when you are this close
    interactDistance = 2.2,
    blip = {
        enabled = true,
        sprite  = 303,
        color   = 1,
        scale   = 0.8,
    },
}

--------------------------------------------------------------------------
-- CONTRACT FLOW
--------------------------------------------------------------------------
Config.OfferCount    = 3       -- contracts shown on the board
Config.OfferLifetime = 600     -- seconds until the board reshuffles
Config.Cooldown      = 120     -- seconds before the next contract after finishing / abandoning one
Config.VoidCooldown  = 15      -- seconds when a contract is voided for reasons that are not your fault
Config.FailOnDeath   = true    -- dying fails the contract

Config.SpawnRadius          = 140.0   -- target and guards spawn when you get this close to the area
Config.NearBlipDistance     = 55.0    -- tiers with targetBlip = 'near' show the target this close
Config.AlertDistance        = 14.0    -- walk this close and the target notices you
Config.GunfireAlertDistance = 90.0    -- unsilenced gunfire this close alerts everyone
Config.AutoWaypoint         = true    -- set a GPS waypoint to the target area
Config.CleanupDelay         = 60      -- seconds the bodies stay after the kill

-- Server side verification of the kill. Needs OneSync (default on current servers).
Config.ServerValidation = true
Config.StrictKillCheck  = false   -- true: the server must positively identify you as the killer
Config.MaxKillDistance  = 350.0   -- you must be this close to the body when the kill is reported

--------------------------------------------------------------------------
-- PAYMENT
--------------------------------------------------------------------------
Config.Payment = {
    account    = 'cash',   -- 'cash' | 'bank' | 'black_money' (ESX only)
    multiplier = 1.0,      -- global multiplier on every reward
}

--------------------------------------------------------------------------
-- REPUTATION
--------------------------------------------------------------------------
Config.Reputation = {
    failPenalty   = 10,    -- lost for dying / running out of time
    cancelPenalty = 5,     -- lost for walking away from a contract
}

-- Higher levels pay more. A level is reached once rep >= the value below.
Config.Levels = {
    { name = 'Rookie',       rep = 0,   payMult = 1.00 },
    { name = 'Enforcer',     rep = 100, payMult = 1.10 },
    { name = 'Professional', rep = 300, payMult = 1.25 },
    { name = 'Ghost',        rep = 700, payMult = 1.40 },
}

--------------------------------------------------------------------------
-- TIERS (difficulty). A tier becomes available when rep >= unlockRep.
--   targetBehavior : 'flee' = runs when alerted, 'fight' = shoots back
--   targetBlip     : 'always' | 'near' | 'none' (blip on the target once spawned)
--------------------------------------------------------------------------
Config.Tiers = {
    [1] = {
        label          = 'Low Profile',
        unlockRep      = 0,
        reward         = { min = 2500, max = 4000 },
        timeLimit      = 15 * 60,
        repReward      = 15,
        areaRadius     = 90.0,
        guards         = { min = 0, max = 1 },
        guardWeapons   = { 'WEAPON_PISTOL' },
        guardArmour    = 0,
        guardAccuracy  = 25,
        targetBehavior = 'flee',
        targetWeapon   = nil,
        targetHealth   = 200,
        targetArmour   = 0,
        targetBlip     = 'always',
    },
    [2] = {
        label          = 'Connected',
        unlockRep      = 100,
        reward         = { min = 6000, max = 9000 },
        timeLimit      = 20 * 60,
        repReward      = 30,
        areaRadius     = 140.0,
        guards         = { min = 2, max = 3 },
        guardWeapons   = { 'WEAPON_PISTOL', 'WEAPON_COMBATPISTOL', 'WEAPON_MICROSMG' },
        guardArmour    = 25,
        guardAccuracy  = 35,
        targetBehavior = 'fight',
        targetWeapon   = 'WEAPON_PISTOL',
        targetHealth   = 250,
        targetArmour   = 25,
        targetBlip     = 'near',
    },
    [3] = {
        label          = 'High Value',
        unlockRep      = 300,
        reward         = { min = 14000, max = 22000 },
        timeLimit      = 25 * 60,
        repReward      = 60,
        areaRadius     = 200.0,
        guards         = { min = 4, max = 6 },
        guardWeapons   = { 'WEAPON_SMG', 'WEAPON_CARBINERIFLE', 'WEAPON_ASSAULTRIFLE' },
        guardArmour    = 60,
        guardAccuracy  = 45,
        targetBehavior = 'fight',
        targetWeapon   = 'WEAPON_COMBATPISTOL',
        targetHealth   = 300,
        targetArmour   = 60,
        targetBlip     = 'near',
    },
}

--------------------------------------------------------------------------
-- BONUS OBJECTIVES (percent of the base reward)
--   headshot : the killing blow hit the head
--   silent   : kill with a suppressed weapon or melee
--   fast     : finish within `fraction` of the time limit
--------------------------------------------------------------------------
Config.Bonuses = {
    headshot = { percent = 20 },
    silent   = { percent = 15 },
    fast     = { percent = 10, fraction = 0.5 },
}
Config.BonusChance = 0.6       -- chance for each bonus to be attached to a contract

--------------------------------------------------------------------------
-- TARGET POOL (names are generated, models are picked at spawn time)
--------------------------------------------------------------------------
Config.Targets = {
    femaleChance = 0.25,
    male = {
        models = {
            'a_m_m_business_01', 'a_m_y_business_01', 'a_m_y_business_02', 'a_m_y_business_03',
            'a_m_m_bevhills_01', 'a_m_m_bevhills_02', 'a_m_y_bevhills_01', 'a_m_y_bevhills_02',
            'a_m_m_prolhost_01', 'a_m_m_socenlat_01', 'a_m_y_hipster_01', 'a_m_y_vinewood_01',
        },
        names = {
            'Marcus', 'Victor', 'Dominic', 'Rafael', 'Anton', 'Lucas', 'Felix', 'Julian',
            'Roman', 'Leon', 'Damien', 'Silas', 'Theo', 'Nico', 'Gideon', 'Mateo',
        },
    },
    female = {
        models = {
            'a_f_y_business_01', 'a_f_y_business_02', 'a_f_y_bevhills_01', 'a_f_y_bevhills_02',
            'a_f_m_bevhills_01', 'a_f_m_bevhills_02', 'a_f_y_vinewood_01',
        },
        names = {
            'Elena', 'Isabel', 'Natalia', 'Camille', 'Sofia', 'Vivian', 'Lydia', 'Marta',
            'Irene', 'Daria', 'Simone', 'Helena',
        },
    },
    surnames = {
        'Webb', 'Castellan', 'Moreau', 'Vance', 'Kozlov', 'Delgado', 'Hartmann', 'Novak',
        'Ferreira', 'Blackwood', 'Okafor', 'Ricci', 'Lindqvist', 'Santoro', 'Voss', 'Duarte',
    },
    scenarios = {
        'WORLD_HUMAN_SMOKING', 'WORLD_HUMAN_STAND_MOBILE', 'WORLD_HUMAN_DRINKING',
        'WORLD_HUMAN_HANG_OUT_STREET',
    },
}

Config.GuardModels = {
    'g_m_m_armgoon_01', 'g_m_m_armlieut_01', 'g_m_y_mexgoon_01', 'g_m_y_mexgoon_02',
    'g_m_y_lost_01', 'g_m_m_chigoon_01', 'g_m_y_pologoon_01', 'g_m_y_salvagoon_01',
}

--------------------------------------------------------------------------
-- LOCATIONS
-- coords  : rough centre of the area. The exact spots are found at spawn time
--           (safe ground near the centre), so being a few metres off is fine.
-- scatter : how far from the centre the target may be placed
-- tiers   : which difficulty tiers may use this location
-- Add your own with /hitmancoords.
--------------------------------------------------------------------------
Config.Locations = {
    { label = 'Legion Square',        coords = vec3(195.2, -933.8, 30.7),    scatter = 25.0, tiers = { 1, 2 } },
    { label = 'Vespucci Beach',       coords = vec3(-1203.0, -1560.0, 4.6),  scatter = 25.0, tiers = { 1, 2 } },
    { label = 'Pink Cage Motel',      coords = vec3(326.5, -208.0, 54.1),    scatter = 20.0, tiers = { 1, 2 } },
    { label = 'Strawberry',           coords = vec3(25.7, -1347.3, 29.5),    scatter = 25.0, tiers = { 1, 2 } },
    { label = 'Mirror Park',          coords = vec3(1163.6, -323.8, 69.2),   scatter = 25.0, tiers = { 1, 2 } },
    { label = 'Chumash',              coords = vec3(-3040.0, 585.0, 7.9),    scatter = 25.0, tiers = { 1, 2 } },
    { label = 'Grove Street',         coords = vec3(117.0, -1950.0, 20.7),   scatter = 25.0, tiers = { 2, 3 } },
    { label = 'Los Santos Airport',   coords = vec3(-1037.0, -2737.0, 20.2), scatter = 35.0, tiers = { 2, 3 } },
    { label = 'Port of Los Santos',   coords = vec3(1210.0, -3115.0, 5.5),   scatter = 40.0, tiers = { 2, 3 } },
    { label = 'Sandy Shores',         coords = vec3(1975.0, 3820.0, 33.4),   scatter = 25.0, tiers = { 2, 3 } },
    { label = 'Harmony',              coords = vec3(546.0, 2672.0, 42.2),    scatter = 30.0, tiers = { 2, 3 } },
    { label = 'Banham Canyon',        coords = vec3(-1820.5, 792.8, 138.1),  scatter = 30.0, tiers = { 2, 3 } },
    { label = 'Great Chaparral',      coords = vec3(2556.0, 382.0, 108.6),   scatter = 30.0, tiers = { 2, 3 } },
    { label = 'Grapeseed',            coords = vec3(1698.0, 4924.0, 42.1),   scatter = 25.0, tiers = { 1, 2, 3 } },
    { label = 'Paleto Bay',           coords = vec3(-278.0, 6228.0, 31.7),   scatter = 25.0, tiers = { 1, 2, 3 } },
}

--------------------------------------------------------------------------
-- HEAT: what happens after you kill the target
--------------------------------------------------------------------------
Config.Heat = {
    chance      = 0.35,    -- chance the killing is reported
    wantedLevel = 0,       -- stars to give the killer (0 = none)
    -- Hook for your dispatch resource. Runs on the killer's client.
    -- Examples:
    --   exports['ps-dispatch']:SuspiciousActivity()
    --   TriggerServerEvent('police:server:policeAlert', 'Shots fired')
    alert = function(coords)
    end,
}

--------------------------------------------------------------------------
-- COMMANDS
--------------------------------------------------------------------------
Config.Commands = {
    cancel = 'cancelhit',     -- abandon your current contract
    coords = 'hitmancoords',  -- print your position as a vec4 (for setting up locations)
    admin  = 'hitmannpc',     -- /hitmannpc reset <id> | setrep <id> <rep> | give <id> <amount>
                              -- needs: add_ace group.admin command.hitmannpc allow
}

--------------------------------------------------------------------------
-- DISCORD LOG (optional)
--------------------------------------------------------------------------
Config.Webhook = {
    url  = '',
    name = 'Hitman Contracts',
}
