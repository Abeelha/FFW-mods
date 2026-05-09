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
local PLAYER_ASSET  = "/Game/Player/BP_Player.BP_Player_C"
local TICK_FN       = PLAYER_ASSET .. ":ReceiveTick"
local DASH_KEY_NAME = "LeftShift"
local RETRY_MS      = 500

----------------------------------------------------------------- locals
local pcall    = pcall
local print    = print
local tostring = tostring

----------------------------------------------------------------- state
local hooked   = false
local dashKey  = nil   -- cached FName-wrapped key struct
local cachedPC = nil
local cachedCM = nil

----------------------------------------------------------------- helpers
local function log(m) print("[BHopDash] " .. m) end

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

    -- Multiplayer: only act on the locally controlled pawn.
    local okl, locally = pcall(p.IsLocallyControlled, p)
    if okl and locally == false then return end

    -- Refresh cached refs if invalidated (level change, respawn).
    if not cachedPC or not cachedPC:IsValid() then
        cachedPC = p:GetController()
    end
    if not cachedCM or not cachedCM:IsValid() then
        cachedCM = p.CharacterMovement
    end
    if not cachedPC or not cachedPC:IsValid()
       or not cachedCM or not cachedCM:IsValid() then
        return
    end

    -- Both checks before any state mutation: bail fast on the common case.
    local heldOk, held = pcall(cachedPC.IsInputKeyDown, cachedPC, dashKey)
    if not heldOk or held ~= true then return end

    local groundOk, ground = pcall(cachedCM.IsMovingOnGround, cachedCM)
    if not groundOk or ground ~= true then return end

    -- Refill cooldown so F_Dash can never be gated, then dash.
    pcall(function()
        p.isDashOnCooldown = false
        local mx = p.maxDash
        if mx and mx > 0 then p.currentDashLeft = mx end
    end)
    pcall(p.F_Dash, p)
end

----------------------------------------------------------------- registration
LoopAsync(RETRY_MS, function()
    if hooked then return true end
    if pcall(RegisterHook, TICK_FN, onTick) then
        hooked = true
        log("ready")
        return true
    end
    return false
end)

dashKey = buildDashKey()
log("loaded — hold " .. DASH_KEY_NAME .. " on ground to bhop")
