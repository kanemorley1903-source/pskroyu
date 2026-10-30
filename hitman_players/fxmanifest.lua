fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'hitman_players'
author 'pskroyu'
description 'Hitman job - players post contracts on other players, hitmen hunt them down'
version '1.0.0'

shared_scripts {
    'config.lua',
    'shared/locale.lua',
    'locales/*.lua',
}

server_scripts {
    'server/bridge.lua',
    'server/store.lua',
    'server/main.lua',
}

client_scripts {
    'client/bridge.lua',
    'client/main.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
}
