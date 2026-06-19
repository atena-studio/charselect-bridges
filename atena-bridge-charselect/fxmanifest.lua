-- atena-bridge-charselect — the CONDUCTOR of the join flow: glue between std-charselect / std-pila /
-- std-custodia / std-entry and atena's player lifecycle. SINGLE owner of atena:player:preSpawn — it decides
-- entry-vs-select, holds the spawn until select/entry resolves, and routes the player into the world. Inert
-- unless atena is up (runtime-detection, no hard deps). atena-framework §6 — a bridge is EXEMPT from vouch
-- anti-bias (calling exports['std-*'] / exports.atena:* / exports['atena-bridge-*'] is its nature).

fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'atena-bridge-charselect'
author 'SirTheo'
description 'Bridge: join-flow conductor (preSpawn → roster → entry-vs-select → bind → spawn)'
version '0.1.0'

shared_scripts {
    'shared/config.lua',        -- select-spawn point + maxPile cap (bridge-owned deployment policy)
}

server_scripts {
    'server/cap.lua',           -- per-account slot-cap override (Bridge.capFor) + /pilecap admin command + schema
    'server/main.lua',          -- the conductor: owns preSpawn, routes create/select/pick, binds + spawns
}

client_scripts {
    'client/host.lua',          -- NUI host: focus + push roster cards to the CEF + forward pick/createNew intents
}

-- This bridge OWNS the character-select CEF (headless doctrine: std-charselect ships no UI). React/shadcn/Vite
-- source lives in fivem/std-charselect/web/; the compiled output is built into nui/ (build-nui.ps1 charselect).
ui_page 'nui/index.html'

files {
    'nui/index.html',
    'nui/assets/*',             -- Vite bundle (js/css + bundled fonts) — flat assetsDir
}
