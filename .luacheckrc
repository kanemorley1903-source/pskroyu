-- Lint with:  luacheck .
std = 'lua54'
max_line_length = 160
exclude_files = { 'tests/vendor' }

-- globals the resources define themselves
globals = {
    'Config', 'Locales', 'Bridge', 'Mission', 'Store',
    'L', 'Money', 'Duration', 'GetUIStrings', 'LoadModel',
}

-- FiveM natives and runtime functions that are used
read_globals = dofile('tests/fivem_globals.lua')

-- fxmanifest.lua is a list of function calls
files['**/fxmanifest.lua'] = {
    read_globals = {
        'fx_version', 'game', 'lua54', 'name', 'author', 'description', 'version',
        'shared_scripts', 'server_scripts', 'client_scripts', 'ui_page', 'files',
    },
}

-- the optional dispatch hook in the NPC config documents its argument
files['hitman_npc/config.lua'] = { unused_args = false }

-- test code: loose about unused helpers
files['tests'] = {
    globals = {},
    ignore = { '21.', '31.', '41.', '43.' },
}
