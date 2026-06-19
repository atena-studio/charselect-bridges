-- atena-bridge-charselect — SERVER: the CONDUCTOR of the join flow. This bridge is the SINGLE owner of the
-- pre-spawn decision: at atena:player:preSpawn it holds the spawn, resolves the account, queries the roster
-- (std-pila), and routes to ENTRY (0 characters → create the first) or CHARACTER SELECT (≥1 → choose). On a
-- pick it resolves the body (std-custodia) and binds it (bridge-custodia) before releasing the spawn; on
-- createNew it kicks off the entry cinematic to author a new character. NO permanent bail at load
-- (bridge-registration §5a): bind every handler ALWAYS, gate each cross-resource call at call-time, re-arm on
-- (re)start of the deps. pcall around the cross-resource touches: a transient (resource mid-restart / player
-- gone) must never crash the conductor and strand a held spawn. Bridge = EXEMPT from vouch anti-bias (§6c).
Bridge = Bridge or {}

local HOLD = 'charselect'   -- the named spawn-hold this conductor places at preSpawn (atena Players.holdSpawn)
local ROUTE_TIMEOUT_MS = 30000   -- bounded wait for std-pila + the target dep (charselect/entry) to (re)start
                                 -- before routing; past this we cede to atena's pre-spawn failsafe (no infinite hold)
local FORGE_TIMEOUT_MS = 10000   -- bounded wait for the account + pila/custodia bridges before a forge-on-demand
                                 -- (the player just finished authoring → deps are normally warm; this only covers
                                 -- the case where the join-time forge missed a still-cold dep)
local BIND_TIMEOUT_MS = 5000     -- bounded wait for std-custodia on a PICK before falling back to a plain spawn —
                                 -- a transient custodia restart must not drop a returning player onto the default ped

-- Narrate the join/spawn flow into atena's log (the standalones stay headless — the bridge is the only layer
-- that logs). Gated at call-time; a transient (atena mid-restart) just drops the line. tag groups it in docker.
local function logFlow(level, msg)
    if GetResourceState('atena') == 'started' then pcall(function() exports.atena:log(level, 'charselect', msg) end) end
end

local function atenaUp()      return GetResourceState('atena') == 'started' end
local function pilaUp()        return GetResourceState('std-pila') == 'started' end
local function pilaBridgeUp()  return GetResourceState('atena-bridge-pila') == 'started' end
local function charselectUp() return GetResourceState('std-charselect') == 'started' end
local function custodiaUp()   return GetResourceState('std-custodia') == 'started' end
local function custodiaBridgeUp() return GetResourceState('atena-bridge-custodia') == 'started' end
local function entryUp()      return GetResourceState('std-entry') == 'started' end

-- pendingCreate[src] = custodiaId of the body authored for a brand-new character whose entry cinematic is
-- mid-flight. Set at startCreate (pila+custodia pair forged), consumed at resleeveComplete (persist + bind),
-- cleared on any teardown (sceneEnded / spawned / drop). Keyed by src: one pending create per player at a time.
local pendingCreate = {}

-- Claim spawn delegation: while this conductor owns the join, atena must NOT auto-spawn anyone — the spawn is
-- released explicitly (spawnPlayer) once select/entry resolves. Re-armed on every (re)start so the policy
-- follows the live resource (atena resets the flag on restart). pcall: a re-arm can fire mid-restart.
local function arm()
    if not atenaUp() then return end
    pcall(function() exports.atena:setSpawnDelegated(true) end)
end

-- The CANONICAL account key for ALL identity rows (pila.account / custodia.owner): the account's numeric id
-- (the license-keyed primary key the pila/custodia rows are stored under). STRICT — no license fallback: a
-- pila row is keyed by account.id, so routing/forging on the license (when the account hasn't loaded yet)
-- would read an EMPTY roster for a returning player and forge a DUPLICATE character. nil = account not
-- resolved yet (DB slow) or the session is gone; the conductor WAITS for it before routing, never guesses.
local function accountIdOf(src)
    local p
    pcall(function() p = exports.atena:getPlayer(src) end)
    return (p and p.account and p.account.id) or nil
end

-- The player's atena session stage, or nil if the session is gone. A deferred route reads this to abort if the
-- player left, or if atena's pre-spawn failsafe already spawned them (don't open a select/cinematic behind an
-- already-spawned player).
local function sessionStage(src)
    local p
    pcall(function() p = exports.atena:getPlayer(src) end)
    return p and p.stage or nil
end

-- ── the three routes (create / select / pick) ─────────────────────────────────────────────────────────

-- RELATION MODEL (the SSOT for the pila↔custodia↔account links, kept consistent here — the conductor owns
-- the pair lifecycle). A character is THREE things bound into one whole: a pila (identity row, std-pila), a
-- custodia (body row, std-custodia), and the pila SLEEVED into the body's locked `stack` slot. The link is
-- CANONICAL in the inventory engine (the pila's item location = container:custodia/stack), MIRRORED onto
-- custodia_bodies.pila_id because std-custodia is headless and can't read the engine (returning-pick resolves
-- the body from that mirror via custodiaForPila). account-ref keys both rows (pila.account / custodia.owner =
-- the account id). The engine's I.destroy cascades items but fires NO event, so the rows are dropped by the
-- bridges — which means EVERY write path must keep the relation whole or roll it back. That invariant is
-- enforced here (atomic forge) and in pilaRemove (clears the mirror on destroy).

-- Best-effort teardown of one forged side, to roll back a partial forge so a failed create never strands an
-- orphan row. Gated at call-time; a transient just leaves the row (a future reconcile/boot sweep can reap it).
local function dropPila(id)     if id and pilaBridgeUp()     then pcall(function() exports['atena-bridge-pila']:pilaRemove(id) end) end end
local function dropCustodia(id) if id and custodiaBridgeUp() then pcall(function() exports['atena-bridge-custodia']:custodiaRemove(id) end) end end

-- Forge the durable pair behind a brand-new character: a pila (identity) + a custodia (body), with the pila
-- SLEEVED into the body's locked stack. ATOMIC: returns the custodiaId only for a WHOLE, sleeved pair; on any
-- failure (a dep nil, or the sleeve rejected) it rolls back BOTH sides and returns nil + reason — never a
-- half-forged orphan. The pila gets a default name (GetPlayerName) — authored names are a future slice.
local function forgePair(src, accountRef)
    if accountRef == nil then return nil, 'no-account' end
    if not pilaBridgeUp() then return nil, 'pila-bridge-down' end
    if not custodiaBridgeUp() then return nil, 'custodia-bridge-down' end
    local pilaId, custodiaId
    pcall(function()
        local name = GetPlayerName(src) or 'Character'   -- default name; naming UI is a future slice
        pilaId     = exports['atena-bridge-pila']:pilaSpawn(accountRef, name)
        custodiaId = exports['atena-bridge-custodia']:custodiaSpawn(accountRef)   -- body owned by the account
    end)
    -- A half-forged pair (one side nil, or the pcall threw mid-spawn) isn't a character — tear down whatever
    -- did land so no orphan pila/custodia row survives.
    if not (pilaId and custodiaId) then
        dropPila(pilaId); dropCustodia(custodiaId)
        return nil, (not pilaId) and 'pila-spawn-nil' or 'custodia-spawn-nil'
    end
    -- Sleeve locks the pila into the body's stack AND sets the body-row mirror. If it's rejected, the pair is
    -- not whole (returning-pick would never resolve the body) → roll back both. pila-first: pilaRemove drops
    -- the engine item + identity row + clears the (just-set-or-not) mirror, so custodiaRemove cascades clean.
    local sleeved, err
    pcall(function() sleeved, err = exports['atena-bridge-pila']:pilaSleeve(pilaId, custodiaId) end)
    if not sleeved then
        dropPila(pilaId); dropCustodia(custodiaId)
        return nil, 'sleeve-failed:' .. tostring(err or 'nil')
    end
    return custodiaId, nil
end

-- Write the authored appearance onto the forged body and bind it to the session (so the spawn re-applies it
-- from the body, and a relog re-reads it). The single durable-persist path, shared by the happy path and the
-- forge-on-demand recovery below. custodiaSetAppearance lands in custodia_bodies via the DB persistence swap.
local function persistCreate(src, custodiaId, blob)
    if custodiaUp() then
        pcall(function() exports['std-custodia']:custodiaSetAppearance(custodiaId, blob) end)
    end
    if custodiaBridgeUp() then
        pcall(function() exports['atena-bridge-custodia']:bindBody(src, custodiaId) end)
    end
    logFlow('info', ('create persisted for src %d (custodia %s)'):format(src, tostring(custodiaId)))
end

-- CREATE: a new character (no characters yet, or a free slot was chosen). Forge the pila+custodia pair, drop
-- into a private bucket, and run the entry cinematic. The appearance authored in entry is PERSISTED onto the
-- body at resleeveComplete (below) and bound to the session, so it survives a relog/restart; entry itself also
-- applies the look client-side (setModel + applySleeve) — complementary, that's the immediate paint, this is
-- the durable write. entry's preSpawn auto-begin is suppressed when this conductor is up, so begin() is driven
-- here. `skippable` is a forward hook (spec §3: 1st intro mandatory, later ones skippable); with maxPile=1 the
-- create is always the 1st → never skippable yet. The real per-character skip is a future slice; default false.
local function startCreate(src, skippable)   -- luacheck: ignore skippable
    if not atenaUp() or not entryUp() then return end
    local accountRef = accountIdOf(src)
    pendingCreate[src] = forgePair(src, accountRef)   -- remember the body to persist the look onto (nil if a dep is down)
    pcall(function()
        exports.atena:bucketAcquire(src)        -- isolated dimension for the per-player cinematic
        exports['std-entry']:begin(src)         -- entry plays; bridge-entry releases the spawn at sceneEnded
    end)
end

-- SELECT: ≥1 character → open the selection machine with the live roster + free-slot count, AND push the
-- screen to the host CEF. The machine (std-charselect) only holds the server-side pilaIds it validates picks
-- against; the NUI needs the NAMES to render — so we build cards (id+name) from the pila rows and send them
-- straight to the client. slotsFree = cap − roster size (≥0) drives whether "new character" is offered.
local function startSelect(src, roster)
    if not charselectUp() then return end
    local options = {}   -- pilaId list the machine validates eligibility against (#6)
    local cards   = {}   -- { id, name } the host CEF renders — pila rows carry the name, the machine does not
    for _, row in ipairs(roster) do
        local id = (type(row) == 'table') and row.id or row   -- pila rows are { id, account, name, blocked }
        if id ~= nil then
            options[#options + 1] = id
            cards[#cards + 1] = { id = id, name = (type(row) == 'table' and row.name) or 'Character' }
        end
    end
    local slotsFree = math.max(0, (Bridge.maxPile or 1) - #options)
    pcall(function() exports['std-charselect']:open(src, options, slotsFree) end)
    -- Push cards + free-slot count to the host. The ui_page is mounted at resource start, so this lands with
    -- no mount race (nui.md §7 governs boot-time provider pushes, not a per-event push after mount).
    TriggerClientEvent('atena-bridge-charselect:openSelect', src, cards, slotsFree)
end

-- Hide the select screen on the host (release focus). The client also closes itself the instant it forwards
-- a pick/createNew intent, so this is belt-and-braces for a close the conductor drives (a resolved pick about
-- to spawn, or createNew handing the screen to the entry cinematic). Idempotent client-side.
local function hideSelect(src) TriggerClientEvent('atena-bridge-charselect:closeSelect', src) end

-- ── the conductor: the SINGLE owner of the pre-spawn decision ──────────────────────────────────────────
-- preSpawn fires synchronously during atena's prepare(); place the hold NOW so the (delegated) spawn waits,
-- resolve the account, query the roster, route. holdSpawn is ALWAYS placed first (even if a dep is down) so a
-- transient never lets a player slip into the world unrouted; the route then resolves once deps are up.
local function conduct(src)
    if not atenaUp() then return end
    pcall(function() exports.atena:holdSpawn(src, HOLD) end)   -- place the hold synchronously (recorded before prepare returns)

    -- Resolve the route on a BOUNDED poll, not once at preSpawn: std-pila (the roster source) and the dep that
    -- takes the screen (charselect/entry) may be mid-(re)start, and routing that instant would strand the player
    -- with no retry. Wait for pila FIRST so a returning player is never misrouted into entry on an empty roster
    -- read (which would forge a duplicate character). Past the deadline we cede to atena's pre-spawn failsafe.
    CreateThread(function()
        local deadline = GetGameTimer() + ROUTE_TIMEOUT_MS
        while not pilaUp() and GetGameTimer() < deadline do Wait(250) end

        local stage = sessionStage(src)
        if stage == nil then return end                              -- player left while we waited
        if stage ~= 'preparing' and stage ~= 'ready' then return end -- already spawned (failsafe/other) → no route

        -- The route (create vs select) hinges on the ROSTER, which is keyed by account.id. WAIT for the account
        -- to resolve before deciding — routing on an unresolved account reads an empty roster for a returning
        -- player and forges a DUPLICATE character. If it never resolves (DB stalled past the deadline) we do NOT
        -- forge: cede to atena's pre-spawn failsafe (a plain spawn, no character). A degraded spawn is
        -- recoverable on relog; a duplicate character is data corruption.
        while accountIdOf(src) == nil and GetGameTimer() < deadline do
            if sessionStage(src) == nil then return end
            Wait(250)
        end
        local accountId = accountIdOf(src)
        if accountId == nil then
            logFlow('warn', ('route src %d: account unresolved past deadline — ceding to failsafe (no forge, avoids duplicate character)'):format(src))
            return
        end

        local roster = {}
        if pilaUp() then
            pcall(function() roster = exports['std-pila']:pilaListForAccount(accountId) or {} end)
        end

        if #roster == 0 then
            logFlow('info', ('route src %d -> create (empty roster)'):format(src))
            while not entryUp() and GetGameTimer() < deadline do Wait(250) end
            startCreate(src)            -- new player (or roster unavailable) → entry authors character #1
        else
            logFlow('info', ('route src %d -> select (%d characters)'):format(src, #roster))
            while not charselectUp() and GetGameTimer() < deadline do Wait(250) end
            startSelect(src, roster)    -- returning player → character select over the live roster
        end
    end)
end
AddEventHandler('atena:player:preSpawn', conduct)

-- PICK: the player selected an existing character. Resolve its body, bind it to the session (applies
-- appearance/state to the ped), then release the spawn at the select-spawn point. spawnPlayer clears all
-- pending holds, so the held spawn is released by this single call. custodiaForPila (std-custodia) is the
-- direct resolution; bindBody (bridge-custodia) is the 59.4 mechanism (find-or-create lived there earlier,
-- here it's a straight bind of an existing pair). pcall so a transient never strands the held spawn.
AddEventHandler('std-charselect:picked', function(src, pilaId)
    hideSelect(src)   -- the choice is made → drop the screen + its focus before we spawn the player in
    if not atenaUp() then return end
    -- Resolve + bind the body on a BOUNDED poll, then release the spawn. If custodia is transiently down
    -- (mid-restart) WAIT for it rather than drop a RETURNING player onto the default ped — only fall back to a
    -- plain spawn if it never comes. When custodia is already up the loop doesn't wait (no added latency).
    CreateThread(function()
        local deadline = GetGameTimer() + BIND_TIMEOUT_MS
        while (not custodiaUp() or not custodiaBridgeUp()) and GetGameTimer() < deadline do
            if sessionStage(src) == nil then return end   -- player left while we waited
            Wait(250)
        end
        local custodiaId, bound
        if custodiaUp() then
            pcall(function() custodiaId = exports['std-custodia']:custodiaForPila(pilaId) end)
        end
        if custodiaId then
            pcall(function() bound = exports['atena-bridge-custodia']:bindBody(src, custodiaId) end)
        end
        -- GATE ONLY WHEN A BODY IS BOUND: a gated spawn lands HIDDEN (black) until the bound body paints →
        -- applied → revealPlayer. With nothing bound nothing signals applied → spawn PLAIN (visible at once,
        -- default ped — better than a black wait to the 8s backstop). A gated bind hides the base-ped swap +
        -- wrong spawn point until the saved look is on. pcall: a transient must not strand the held spawn.
        local gate = bound == true or nil
        logFlow('info', ('pick src %d -> %s spawn (custodia %s)'):format(src, gate and 'gated' or 'plain', tostring(custodiaId)))
        pcall(function() exports.atena:spawnPlayer(src, Bridge.spawn, gate) end)
    end)
end)

-- CREATE-NEW from the select screen (a free slot was chosen) → drop the screen, then the same create route
-- as a fresh account (the entry cinematic takes the screen from here).
AddEventHandler('std-charselect:createNew', function(src) hideSelect(src); startCreate(src) end)

-- PERSIST the authored look onto the new character's body. entry fires resleeveComplete once the player has
-- finished authoring (gender + appearance blob); bridge-entry ALSO listens to this same event (setModel +
-- client paint) — that handler stays, it's the immediate client apply. THIS handler is the durable half: for
-- a pending create, write the appearance jsonb onto the custodia body (the only sanctioned appearance store —
-- it lands in custodia_bodies via the DB persistence swap) and bind the body to the session so the spawn
-- re-applies it from the body (59.4). After binding, the create is no longer pending — clear it.
AddEventHandler('std-entry:resleeveComplete', function(src, _gender, blob)
    local custodiaId = pendingCreate[src]
    pendingCreate[src] = nil   -- consumed (happy path) or about to be forged on demand (recovery below)
    if custodiaId then
        persistCreate(src, custodiaId, blob)   -- happy path: the join-time forge landed → persist synchronously
        return
    end
    -- FORGE-ON-DEMAND recovery: the join-time forge missed (a dep — account / pila-bridge / custodia-bridge —
    -- was still cold at join, so forgePair returned nil and the look would NEVER persist → relog = default body,
    -- the "created character not saved" bug, hit by a second player joining mid-session). Forge now, behind a
    -- bounded wait for those deps (warm by now), then persist. Every failure path is logged with its reason.
    CreateThread(function()
        local deadline = GetGameTimer() + FORGE_TIMEOUT_MS
        while GetGameTimer() < deadline do
            if sessionStage(src) == nil then return end   -- player left mid-wait → stop (no orphan write, no lingering 10s)
            if accountIdOf(src) ~= nil and pilaBridgeUp() and custodiaBridgeUp() then break end
            Wait(250)
        end
        local id, reason = forgePair(src, accountIdOf(src))
        if not id then
            logFlow('warn', ('create NOT persisted for src %d: %s (look lost on relog)'):format(src, reason or 'unknown'))
            return
        end
        logFlow('info', ('forge-on-demand recovered the create for src %d'):format(src))
        persistCreate(src, id, blob)
    end)
end)

-- Clean up the selection state when the player leaves (idempotent close; safe if nothing was open). Also drop
-- any pending create (the entry flow ended/aborted with the player) so the map never leaks a stale body id.
AddEventHandler('playerDropped', function()
    local src = source
    pendingCreate[src] = nil
    if charselectUp() then pcall(function() exports['std-charselect']:close(src) end) end
end)

-- Belt-and-braces cleanup of the pending create on the normal scene teardown / real spawn: by then the persist
-- has already run at resleeveComplete (which clears it), so these are no-ops on the happy path — they guard the
-- case where resleeveComplete never fired (scene skipped/aborted) so a stale body id can't linger for the src.
AddEventHandler('std-entry:sceneEnded', function(src) pendingCreate[src] = nil end)
AddEventHandler('atena:player:spawned', function(src) pendingCreate[src] = nil end)

arm()
AddEventHandler('onResourceStart', function(res) if res == 'atena' then arm() end end)
