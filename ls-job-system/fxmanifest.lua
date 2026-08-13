fx_version 'cerulean'
game 'gta5'

description 'Server-authoritative QBCore delivery job'
version '0.1.0'

shared_scripts {
    'shared/constants.lua',
    'config.lua'
}

client_script 'client/main.lua'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/repository.lua',
    'server/main.lua'
}

dependencies {
    '/onesync',
    'qb-core',
    'qb-target',
    'qb-vehiclekeys',
    'oxmysql'
}
