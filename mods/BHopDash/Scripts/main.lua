-- BHopDash — auto-bhop dash for FarFarWest.
--
-- Behavior: while the dash key (LeftShift) is held AND the player is on
-- ground, F_Dash fires every game tick (~60 Hz cap). Cooldown is refilled
-- before each call so the game never blocks the dash. No keybinds, no UI,
-- no toggle — always on, no collisions with Speedometer / DPSMeter.
--
-- Hot path runs on the player's ReceiveTick. Player-relative refs
-- (PlayerController, CharacterMovement) are cached and re-resolved only
-- when their wrappers go invalid (level change, pawn respawn), so per-tick
-- cost is one IsValid + two property reads + one pcall.
--
-- MP correctness (v1.2.0): ReceiveTick on BP_Player_C fires for EVERY
-- BP_Player instance in the world — yours, every coop teammate, every
-- AI/NPC that inherits BP_Player_C. Per-pawn IsLocallyControlled is
-- unreliable (returns non-false for remote pawn proxies under UE4SS),
-- so cachedPC/cachedCM used to thrash between local + remote pawns,
-- making IsInputKeyDown query the WRONG controller — dash silently
-- no-ops while friend is in the lobby.
--
-- Fix: cache the local PlayerController ONCE at module level via
-- FindAllOf("PlayerController") + IsLocalController filter. Each tick,
-- gate on `pawn:GetController() == localPC`. Mismatch = not our pawn = bail.

----------------------------------------------------------------- config
local MOD_VERSION    = "1.2.0-mp-fix"
local PLAYER_ASSET   = "/Game/Player/BP_Player.BP_Player_C"
local TICK_FN        = PLAYER_ASSET .. ":ReceiveTick"
local DASH_KEY_NAME  = "LeftShift"
local RETRY_MS       = 500
local DASH_INTERVAL  = 0       -- seconds between cooldown nukes (0 = no throttle, fully snappy; >0 = max ~1 dash per DASH_INTERVAL seconds)
local LOCAL_PC_REFRESH_MS = 2000  -- min ms between local PC re-resolve attempts (cheap-but-not-free FindAllOf)
local DEBUG_MP       = false   -- set true to log MP edge events (skip-noOurPawn / pc-resolve / skip-airborne)
local DEBUG_SAMPLE_S = 2.0

----------------------------------------------------------------- locals
local pcall    = pcall
local print    = print
local tostring = tostring
local ipairs   = ipairs

----------------------------------------------------------------- state
local dashKey         = nil    -- cached FName-wrapped key struct
local cachedLocalPC   = nil    -- the local-machine PlayerController, MP-safe
local cachedCM        = nil    -- our pawn's CharacterMovement
local lastNuke        = 0.0
local lastLocalPCSeek = 0.0    -- os.clock() of last FindAllOf attempt
local dbgLast         = {}

----------------------------------------------------------------- helpers
local function log(m) print("[BHopDash] " .. m) end

local function dbg(key, msg)
    if not DEBUG_MP then return end
    local now = os.clock()
    if (now - (dbgLast[key] or 0)) < DEBUG_SAMPLE_S then return end
    dbgLast[key] = now
    print("[BHopDash][dbg:" .. key .. "] " .. msg)
end

local function buildDashKey()
    local k = {}
    k.KeyName = FName(DASH_KEY_NAME)
    return k
end

-- Resolve the local PlayerController (the one with IsLocalController()==true).
-- FindAllOf is the only reliable way; FindFirstOf in MP often returns a
-- remote PC proxy. Throttle the scan because each call walks UObjects.
local function resolveLocalPC()
    local now = os.clock()
    if cachedLocalPC and cachedLocalPC:IsValid() then return cachedLocalPC end
    if (now - lastLocalPCSeek) * 1000 < LOCAL_PC_REFRESH_MS then return nil end
    lastLocalPCSeek = now

    local pcs = nil
    pcall(function() pcs = FindAllOf("PlayerController") end)
    if not pcs then return nil end
    for _, pc in ipairs(pcs) do
        local ok, isLocal = pcall(function() return pc:IsLocalController() end)
        if ok and isLocal then
            cachedLocalPC = pc
            dbg("pc-resolve", "localPC found: " .. tostring(pc))
            return pc
        end
    end
    return nil
end

----------------------------------------------------------------- hot path
local function onTick(ctx)
    local p = ctx
    if ctx and ctx.get then
        local ok, val = pcall(ctx.get, ctx)
        if ok then p = val end
    end
    if not p or not p:IsValid() then return end

    -- MP gate: confirm THIS pawn's controller is OUR local PC. In MP,
    -- ReceiveTick fires for every BP_Player_C in the world, so we must
    -- filter or we'll thrash caches across teammates' pawns.
    local localPC = resolveLocalPC()
    if not localPC then return end

    local pawnCtrl = nil
    pcall(function() pawnCtrl = p:GetController() end)
    if not pawnCtrl or pawnCtrl ~= localPC then
        dbg("skip-notOurs", "tick on non-local pawn (controller mismatch)")
        return
    end

    -- Refresh CM if invalidated (level change, respawn, weapon swap, etc).
    if not cachedCM or not cachedCM:IsValid() then
        cachedCM = p.CharacterMovement
        dbg("cm-refresh", "cachedCM re-resolved: " .. tostring(cachedCM))
    end
    if not cachedCM or not cachedCM:IsValid() then
        dbg("ref-fail", "no CM after refresh")
        return
    end

    local heldOk, held = pcall(localPC.IsInputKeyDown, localPC, dashKey)
    if not heldOk or held ~= true then return end

    local groundOk, ground = pcall(cachedCM.IsMovingOnGround, cachedCM)
    if not groundOk or ground ~= true then
        if held == true then dbg("skip-airborne", "held=true but not on ground") end
        return
    end

    -- F_Dash is POLLED every tick — that's where the snappy feel comes from.
    -- DASH_INTERVAL = period between cooldown nukes (NOT a gate on F_Dash):
    --   DASH_INTERVAL <= 0   → nuke every tick → continuous dash spam
    --   DASH_INTERVAL = 0.2  → nuke every 0.2s → 1 dash per 0.2s max
    local now = os.clock()
    local nukeNow = (DASH_INTERVAL <= 0) or (now - lastNuke) >= DASH_INTERVAL

    if nukeNow then
        pcall(function()
            p.isDashOnCooldown = false
            local mx = p.maxDash
            if mx and mx > 0 then p.currentDashLeft = mx end
            p.dashCooldown = 0.0
            p.dashedTimes  = 0
        end)
    end

    pcall(p.F_Dash, p)

    if nukeNow then
        pcall(p.F_DashCooldown, p)
        pcall(p.F_ResetAndUpdateDash, p)
        lastNuke = now
    end
end

----------------------------------------------------------------- registration
-- Global flag survives Lua reload; UE4SS keeps the C++ hook registered
-- across Ctrl+R, so re-registering double-binds ReceiveTick = freeze.
_G.__BHopDash_hooked = _G.__BHopDash_hooked or false
_G.__BHopDash_onTick = onTick  -- always point latest closure

-- On Lua reload, invalidate caches so new closure resolves fresh state.
cachedLocalPC = nil
cachedCM      = nil

LoopAsync(RETRY_MS, function()
    if _G.__BHopDash_hooked then
        log("ready (reused hook)")
        return true
    end
    if pcall(RegisterHook, TICK_FN, function(ctx) return _G.__BHopDash_onTick(ctx) end) then
        _G.__BHopDash_hooked = true
        log("ready")
        return true
    end
    return false
end)

dashKey = buildDashKey()
log("loaded v" .. MOD_VERSION .. " — hold " .. DASH_KEY_NAME .. " on ground to bhop (DEBUG_MP=" .. tostring(DEBUG_MP) .. ")")
