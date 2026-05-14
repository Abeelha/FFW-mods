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

----------------------------------------------------------------- config
local MOD_VERSION   = "1.1.0-mp-debug"
local PLAYER_ASSET  = "/Game/Player/BP_Player.BP_Player_C"
local TICK_FN       = PLAYER_ASSET .. ":ReceiveTick"
local DASH_KEY_NAME = "LeftShift"
local RETRY_MS      = 500
local DASH_INTERVAL = 0  -- seconds between cooldown nukes (0 = no throttle, fully snappy; >0 = max ~1 dash per DASH_INTERVAL seconds)
local DEBUG_MP      = true   -- sampled MP-edge logging (pawn changes, skip reasons)
local DEBUG_SAMPLE_S = 2.0   -- min seconds between same-key debug lines

----------------------------------------------------------------- locals
local pcall    = pcall
local print    = print
local tostring = tostring

----------------------------------------------------------------- state
local hooked       = false
local dashKey      = nil   -- cached FName-wrapped key struct
local cachedPC     = nil
local cachedCM     = nil
local lastNuke     = 0.0   -- os.clock() of last cooldown-nuke pass
local lastPawnRepr = nil   -- tostring(pawn) tracking; logs on change
local dbgLast      = {}    -- key -> os.clock() of last sampled-debug line

----------------------------------------------------------------- helpers
local function log(m) print("[BHopDash] " .. m) end

local function dbg(key, msg)
    if not DEBUG_MP then return end
    local now = os.clock()
    local prev = dbgLast[key] or 0
    if (now - prev) < DEBUG_SAMPLE_S then return end
    dbgLast[key] = now
    print("[BHopDash][dbg:" .. key .. "] " .. msg)
end

local function buildDashKey()
    local k = {}
    k.KeyName = FName(DASH_KEY_NAME)
    return k
end

----------------------------------------------------------------- hot path
local function onTick(ctx)
    local p = ctx
    if ctx and ctx.get then
        local ok, val = pcall(ctx.get, ctx)
        if ok then p = val end
    end
    if not p or not p:IsValid() then return end

    -- Pawn identity tracker: in MP, join/leave/respawn can swap the pawn
    -- pointer. UE4SS wrappers stay IsValid()==true past the underlying
    -- destroy in some cases, so identity-by-tostring catches swaps the
    -- IsValid check misses.
    if DEBUG_MP then
        local repr = tostring(p)
        if repr ~= lastPawnRepr then
            local prev = lastPawnRepr or "<nil>"
            lastPawnRepr = repr
            local lOk, locFlag = pcall(p.IsLocallyControlled, p)
            print(string.format(
              "[BHopDash][dbg:pawn] pawn changed: %s -> %s | locally=%s",
              prev, repr, tostring(lOk and locFlag)))
            -- Force cache refresh on pawn swap so we don't keep stale
            -- PC/CM wrappers from the previous pawn life.
            cachedPC = nil
            cachedCM = nil
        end
    end

    -- Multiplayer: only act on the locally controlled pawn.
    local okl, locally = pcall(p.IsLocallyControlled, p)
    if okl and locally == false then
        dbg("skip-remote", "skipping remote pawn (IsLocallyControlled=false)")
        return
    end

    -- Refresh cached refs if invalidated (level change, respawn).
    if not cachedPC or not cachedPC:IsValid() then
        cachedPC = p:GetController()
        dbg("pc-refresh", "cachedPC re-resolved: " .. tostring(cachedPC))
    end
    if not cachedCM or not cachedCM:IsValid() then
        cachedCM = p.CharacterMovement
        dbg("cm-refresh", "cachedCM re-resolved: " .. tostring(cachedCM))
    end
    if not cachedPC or not cachedPC:IsValid()
       or not cachedCM or not cachedCM:IsValid() then
        dbg("ref-fail", string.format("ref fail PC=%s CM=%s",
            tostring(cachedPC), tostring(cachedCM)))
        return
    end

    -- Both checks before any state mutation: bail fast on the common case.
    local heldOk, held = pcall(cachedPC.IsInputKeyDown, cachedPC, dashKey)
    if not heldOk then
        dbg("held-pcall-fail", "IsInputKeyDown pcall failed")
        return
    end
    if held ~= true then return end

    -- Past here: dash key IS held. Anything that skips now is interesting.
    local groundOk, ground = pcall(cachedCM.IsMovingOnGround, cachedCM)
    if not groundOk then
        dbg("ground-pcall-fail", "IsMovingOnGround pcall failed (held=true)")
        return
    end
    if ground ~= true then
        dbg("skip-airborne", "held=true but airborne (IsMovingOnGround=false)")
        return
    end

    -- F_Dash is POLLED every tick — that's where the snappy feel comes
    -- from. The game has a 1-second natural cooldown (p.dashCooldown
    -- default = 1.0); without us nuking that cooldown, F_Dash would
    -- only fire once per second.
    --
    -- DASH_INTERVAL is the PERIOD BETWEEN COOLDOWN NUKES, not a gate on
    -- F_Dash itself. F_Dash still polls at 60 Hz, so the moment the
    -- game says "dash ready," it fires. The user's DASH_INTERVAL just
    -- decides how often we tell the game "dash ready":
    --   * DASH_INTERVAL <= 0   → nuke every tick → continuous dash spam
    --   * DASH_INTERVAL = 0.2  → nuke every 0.2s → 1 dash per 0.2s max
    -- Between nukes, the game's own cooldown blocks F_Dash naturally,
    -- giving the user's tunable safety floor with zero feel-cost.
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
