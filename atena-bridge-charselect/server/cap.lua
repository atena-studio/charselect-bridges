-- atena-bridge-charselect — SERVER: PER-ACCOUNT character-slot cap (override of the global default).
--
-- The conductor (server/main.lua) gates character creation on a cap. By default that cap is the global
-- Bridge.maxPile (shared/config.lua); this file lets a deployment give an INDIVIDUAL account its own cap,
-- set live by an admin and persisted in the bridge's OWN table (atena owns the DB; the schema ships with the
-- bridge — atena-database §8.1). The read path is SYNCHRONOUS (a per-src cache) so the conductor can read the
-- cap inline on every route — including the non-threaded createNew path, where an async DB read would be
-- illegal (a Citizen.Await outside a coroutine). Bridge = EXEMPT from vouch anti-bias (atena-framework §6c).
Bridge = Bridge or {}

local function atenaUp() return GetResourceState('atena') == 'started' end
-- The stable account key. Raw native (frag-verified; same usage as atena accounts) so the KEY needs no atena.
local function licenseOf(src) return GetPlayerIdentifierByType(src, 'license') end

-- Narrate into atena's log (the bridge is the only layer that logs; gated at call-time, a transient drops it).
local function clog(level, msg)
    if atenaUp() then pcall(function() exports.atena:log(level, 'charselect', 'cap: ' .. msg) end) end
end

-- Bridge-owned table: license -> cap. Keyed by LICENSE (not account.id) so a cap can be set for an OFFLINE
-- account by its license string, and resolved synchronously at create-time from the connected src. No FK to
-- atena's accounts (migrations run per-resource, order-independent — the link is by license, app-side).
local SCHEMA = { { v = 1, stmts = {
    'create table if not exists charselect_account_caps ('
        .. 'license text primary key, '
        .. 'cap integer not null check (cap > 0))',
} } }

local function migrate()
    if not atenaUp() then return end
    pcall(function() exports.atena:dbMigrate('atena-bridge-charselect', SCHEMA) end)   -- idempotent + versioned
end

-- Per-src cache of the resolved cap. Populated once when the player joins (license is known then) via a
-- CALLBACK-form DB read (no coroutine needed), so Bridge.capFor stays synchronous everywhere. A miss (cache
-- not filled yet, atena/DB down, or no override row) falls back to the global default — benign: a real
-- over-cap account is a RETURNING player (routed to select, roster >= 1), giving the read ample time to land.
local capCache = {}

local function loadCap(src)
    if not atenaUp() then return end
    local license = licenseOf(src)
    if not license then return end
    pcall(function()
        exports.atena:dbSingle('select cap from charselect_account_caps where license = $1', { license },
            function(row) if row and row.cap then capCache[src] = row.cap end end)   -- row is the row | nil | false(err)
    end)
end

-- The cap for this player's account: a per-account override if one is set, else the global Bridge.maxPile.
-- SYNCHRONOUS by design (reads the cache) — safe from both the threaded (conduct) and non-threaded (createNew)
-- routes. The conductor's lock + check-then-commit are unchanged; only the SOURCE of the number lives here.
function Bridge.capFor(src)
    return capCache[src] or (Bridge.maxPile or 1)
end

AddEventHandler('playerJoining', function() loadCap(source) end)   -- earliest point the license is valid
AddEventHandler('playerDropped', function() capCache[source] = nil end)

-- Schema on boot (race-proof one-shot) + re-apply on an atena restart (idempotent). bridge-registration §2.
CreateThread(function() while not atenaUp() do Wait(250) end; migrate() end)
AddEventHandler('onResourceStart', function(res) if res == 'atena' then migrate() end end)

-- ── admin set-path ─────────────────────────────────────────────────────────────────────────────────────
-- /pilecap <playerId|license> <n> — set (or reset) an account's character-slot cap. Admin-gated via atena's
-- deny-by-default perm seam (console, src 0, is always allowed). n >= 1 upserts the override; n <= 0 deletes
-- the row (the account falls back to the global default). Values go into parameterized SQL ($1/$2) — no
-- injection — but inputs are still validated/bounded (n a small positive integer; license length capped).
-- A live change applies to the cap enforce immediately (capFor reads the cache); the select-screen free-slot
-- count refreshes on the player's next route/relog. ponytail: dev knob — feedback via atena log + console.
local MAX_CAP = 50   -- sanity bound: a cap above this is almost certainly a typo, not a real intent

-- dbExecute REQUIRES a callback (the driver logs "missing callback" otherwise) — pass one that surfaces errors.
local function execDone(res, err)
    if res == false then clog('warn', 'db write failed: ' .. tostring(err)) end
end

local function feedback(src, msg)
    if src == 0 then print('[pilecap] ' .. msg) end   -- console invoker sees it directly; log covers in-game
    clog('info', msg)
end

RegisterCommand('pilecap', function(src, args)
    if src ~= 0 then                                   -- a player typed it → must hold 'admin' (deny-by-default)
        local ok = false
        if atenaUp() then pcall(function() ok = exports.atena:can(src, 'admin') end) end
        if not ok then feedback(src, ('denied for src %d'):format(src)); return end
    end

    local target, raw = args[1], args[2]
    local n = tonumber(raw)
    if not target or not n or n ~= math.floor(n) then
        feedback(src, 'usage: pilecap <playerId|license> <n>   (n<=0 resets to default)'); return
    end
    if n > MAX_CAP then feedback(src, ('cap %d exceeds max %d'):format(n, MAX_CAP)); return end

    -- Resolve the target license: a connected player id, else the arg taken as a license string (length-bounded).
    local license, onlineSrc
    local asId = tonumber(target)
    if asId and GetPlayerName(asId) then
        license, onlineSrc = licenseOf(asId), asId
    elseif #target <= 100 then
        license = target
    end
    if not license then feedback(src, ('cannot resolve account from %q'):format(tostring(target))); return end

    if not atenaUp() then feedback(src, 'atena down - cannot persist'); return end
    if n <= 0 then
        pcall(function() exports.atena:dbExecute('delete from charselect_account_caps where license = $1',
            { license }, execDone) end)
        if onlineSrc then capCache[onlineSrc] = nil end
        feedback(src, ('reset %s to default (%d)'):format(license, Bridge.maxPile or 1))
    else
        pcall(function() exports.atena:dbExecute('insert into charselect_account_caps (license, cap) '
            .. 'values ($1, $2) on conflict (license) do update set cap = excluded.cap', { license, n }, execDone) end)
        if onlineSrc then capCache[onlineSrc] = n end
        feedback(src, ('set %s = %d'):format(license, n))
    end
end, false)   -- restricted=false: gated by the atena perm seam (not an ACE) — any player CAN invoke, denied unless 'admin'
