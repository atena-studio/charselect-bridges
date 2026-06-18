-- atena-bridge-charselect — PRESENTATION/POLICY config (bridge-owned tunables; standalone-resource.md §2.1).
-- The conductor of the join flow lives in server/main.lua; this is the handful of values it reads. std-charselect
-- ships the selection MACHINE (headless); the deployment-time choices (where a selected character spawns, how
-- many characters an account may hold) live here, in the bridge, never in the standalone.
Bridge = Bridge or {}

-- Where a SELECTED existing character is dropped into the world (atena spawnPlayer point; overrides atena's
-- configured default). Re-uses the entry clinic exit so first-character (entry) and returning-character (select)
-- land in the same place — re-point both once the clinic exit set is blocked in. PLACEHOLDER central-LS coords.
Bridge.spawn = { x = 215.0, y = -810.0, z = 30.7, heading = 145.0 }

-- maxPile = how many characters (pile) one account may hold. The selection machine is N-ready; this cap drives
-- the free-slot count handed to the select screen (and whether "new character" is offered). Default 1 (the spec's
-- v1 cap). MIRRORED here (not read from std-charselect): the cap is a DEPLOYMENT policy the conductor owns — the
-- standalone only enforces the slotsFree count it is HANDED, it has no opinion on the cap itself. Raise to allow
-- multiple characters with zero code change. Kept as the single source the conductor reads (Config.maxPile or 1).
Bridge.maxPile = 1
