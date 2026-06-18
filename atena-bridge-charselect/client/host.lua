-- atena-bridge-charselect — CLIENT: the HOST for the character-select NUI. Headless doctrine: std-charselect
-- ships the selection MACHINE (no UI); THIS bridge owns the screen. The conductor (server) pushes the roster
-- (cards = id+name) + free-slot count at preSpawn; the host takes focus, drops the held-spawn loading screen so
-- the screen is visible, hands the CEF the cards, and forwards the player's pick / create-new as INTENTS to
-- std-charselect (op:pick / op:createNew — the NUI never decides, nui.md §1). Focus is balanced: released on
-- close AND on onResourceStop (nui.md §2). Bridge = EXEMPT from vouch anti-bias (calling the std intents is its
-- nature). The CEF (ui_page) is mounted at resource start, so a push after a net event lands with no mount race.

local open = false

-- Release the screen + its focus. Idempotent (a no-op if nothing is open), so the explicit server hide and the
-- client's own self-close on intent can both fire without double-toggling the focus.
local function closeSelect()
    if not open then return end
    open = false
    SetNuiFocus(false, false)
    SendNUIMessage({ type = 'close' })
    -- NB: do NOT fade in here. The screen is held BLACK from open() through the (gated, hidden) spawn until atena
    -- fires the reveal — so the world is never visible between the NUI closing and the new ped being ready.
end

-- The conductor pushes the live roster + free-slot count. Take focus and drop the loading screen the held spawn
-- left up (otherwise the select screen renders behind it), then hand the CEF the cards to render.
RegisterNetEvent('atena-bridge-charselect:openSelect')
AddEventHandler('atena-bridge-charselect:openSelect', function(cards, slotsFree)
    open = true
    DoScreenFadeOut(0)             -- black the WORLD behind the NUI FIRST: no peek now, and none when the NUI closes
    ShutdownLoadingScreen()        -- leave the spawn-hold loading state…
    ShutdownLoadingScreenNui()     -- …and tear down its NUI, so the (black) screen + NUI are the only thing on top
    SetNuiFocus(true, true)
    SendNUIMessage({ type = 'open', payload = { cards = cards or {}, slotsFree = slotsFree or 0 } })
end)

-- Explicit server hide (after a pick resolves to a spawn, or createNew hands off to entry). Belt-and-braces:
-- the client already closes itself the instant it forwards an intent (below) — this covers a server-driven close.
RegisterNetEvent('atena-bridge-charselect:closeSelect')
AddEventHandler('atena-bridge-charselect:closeSelect', closeSelect)

-- Player clicked a character card → forward the pick INTENT (std-charselect re-validates it against what the
-- server presented; the client's claim never decides validity) and release focus at once. Empty id = no-op.
RegisterNUICallback('pick', function(data, cb)
    local id = data and data.id
    if type(id) == 'string' and id ~= '' then
        if GetResourceState('std-charselect') == 'started' then
            TriggerServerEvent('std-charselect:op:pick', id)
        end
        closeSelect()
    end
    cb('ok')
end)

-- Player chose "new character" (a free slot) → forward the create-new INTENT and release focus. The conductor
-- routes it into the entry cinematic, which takes the screen from here.
RegisterNUICallback('createNew', function(_, cb)
    if GetResourceState('std-charselect') == 'started' then
        TriggerServerEvent('std-charselect:op:createNew')
    end
    closeSelect()
    cb('ok')
end)

-- Never leave the mouse captured if the bridge stops with the screen open (nui.md §2).
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    local wasOpen = open
    closeSelect()
    if wasOpen then DoScreenFadeIn(300) end   -- we blacked the screen for the select → don't strand it black if the bridge dies mid-select
end)
