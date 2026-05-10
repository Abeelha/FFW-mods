-- AutoGrabberGate — gate ammo box pickups by ammo % via collision profile.
--
-- Mechanism: each box has its CollisionEnabled mode toggled.
--   PhysicsOnly       → physics works (falls, lands), but traces/overlaps
--                       ignored. AutoGrabber's SphereTraceMulti returns
--                       nothing; manual pickup overlap doesn't fire.
--   QueryAndPhysics   → normal grabbable state.
--
-- Lifecycle of a box:
--   1. BeginPlay: immediately set PhysicsOnly. Box exists in world,
--      simulates physics normally, but is invisible to grab queries.
--   2. After settle (age ≥ 3s AND |velocity| < 5 u/s): re-evaluate based
--      on player stats. If skip → stay PhysicsOnly. If grab needed →
--      revert to QueryAndPhysics.
--   3. On player stat change (mid-fight ammo drop): tick re-evaluates
--      and toggles individual box collision modes.
--
-- Why this is the right design:
--   * No Mod_2 mutation → AutoGrabber's other behaviors (crate opening,
--     soul/gold pickup, etc) keep working untouched.
--   * Physics intact at all times → no fall-through, no mid-air freeze.
--   * Per-box state, not global → newly-spawned boxes don't affect
--     existing boxes' grab state.
--   * Manual pickup also gated (intended — user wants box to stay in
--     world when full, regardless of pickup source).
--
-- Pickup → stat mapping (verified via uasset string dumps):
--   BP_AmmoBox_C / *_Throw_C          → datasWepA  (primary)
--   BP_AmmoBox_Spell_C / *_Throw_C    → datasWepB  (secondary)
--   BP_AmmoBox_Utility_C              → grenades   (utility)

----------------------------------------------------------------- config
local CONFIG = {
  AMMO_RATIO         = 0.50,
  UTILITY_BLOCK_AT   = 1,
  TICK_INTERVAL_MS   = 200,
  HEARTBEAT_MS       = 5000,
  SETTLE_DELAY_MS    = 3000,
  SETTLE_VELOCITY    = 5.0,    -- u/s; below this = at rest
  VERBOSE            = true,
}

------------------------------------------ UE collision-mode constants
-- ECollisionEnabled enum (UE source):
--   0 NoCollision, 1 QueryOnly, 2 PhysicsOnly, 3 QueryAndPhysics,
--   4 ProbeOnly,   5 QueryAndProbe
local CE_PHYSICS_ONLY      = 2
local CE_QUERY_AND_PHYSICS = 3

------------------------------------------ BP property paths (verified)
local P_RUNTIME_STATS = "playerRuntimeStats"
local P_WEP_A         = "datasWepA_24_C099A0F04138D662182F8D9C94DCA8C6"
local P_WEP_B         = "datasWepB_25_EE50A5DA4381738DA8C10CB8353016D9"
local P_CUR_TOTAL     = "currentTotalAmmos_17_DDF8963D42826C9B6D9A9E92E9563632"
local P_MAX_TOTAL     = "maxTotalAmmos_18_2EACEDBD42C653C7490D2F999719144E"
local P_GRENADES      = "amountGrenades_26_E0AD04BF4A4DB7E8E4C0DA8931601223"

----------------------------------------------------------------- state
local logSampled    = {}
local lastHeartbeat = 0
local firstSeenAt   = {}      -- box fullName -> ms when first observed
local appliedMode   = {}      -- box fullName -> last applied CE_* mode
local pcall, ipairs, type = pcall, ipairs, type
local string_find = string.find
local sqrt = math.sqrt

----------------------------------------------------------------- utils
local function logf(fmt, ...)
  local ok, s = pcall(string.format, fmt, ...)
  if not ok then s = fmt end
  pcall(print, "[AGGate] " .. s)
end

local function once(key, fn)
  if logSampled[key] then return end
  logSampled[key] = true
  fn()
end

local function isValid(o)
  if not o then return false end
  local v = false
  pcall(function() v = o.IsValid and o:IsValid() or false end)
  return v
end

local function fname(o)
  local s = "?"
  pcall(function() if o and o.GetFullName then s = o:GetFullName() end end)
  return s
end

local function classNameOf(o)
  local s = nil
  pcall(function()
    local c = o:GetClass()
    if c then s = c:GetFName():ToString() end
  end)
  return s
end

local function nowMs()
  return math.floor(os.clock() * 1000)
end

local function unwrapCtx(ctx)
  if ctx and ctx.get then
    local ok, val = pcall(ctx.get, ctx)
    if ok then return val end
  end
  return ctx
end

------------------------------------------------------- player state read
local function readNested(root, path)
  local cur = root
  for _, name in ipairs(path) do
    if cur == nil then return nil end
    local nxt = nil
    local ok = pcall(function() nxt = cur[name] end)
    if not ok or nxt == nil then return nil end
    cur = nxt
  end
  return cur
end

local function readWepReserve(ps, slotName)
  local s = readNested(ps, { P_RUNTIME_STATS, slotName })
  if not s then return 0, 0 end
  local cur = readNested(s, { P_CUR_TOTAL }) or 0
  local max = readNested(s, { P_MAX_TOTAL }) or 0
  if type(cur) ~= "number" then cur = 0 end
  if type(max) ~= "number" then max = 0 end
  return cur, max
end

local function getPlayerState()
  local pc = nil
  pcall(function() pc = FindFirstOf("PlayerController") end)
  if isValid(pc) then
    local ps = nil
    pcall(function() ps = pc.PlayerState end)
    if isValid(ps) then return ps end
  end
  local ps = nil
  pcall(function() ps = FindFirstOf("BP_PlayerState_C") end)
  return isValid(ps) and ps or nil
end

local function readPlayerStats()
  local ps = getPlayerState()
  if not ps then return nil end
  local cA, mA = readWepReserve(ps, P_WEP_A)
  local cB, mB = readWepReserve(ps, P_WEP_B)
  local gren = readNested(ps, { P_RUNTIME_STATS, P_GRENADES })
  if type(gren) ~= "number" then return nil end
  return {
    A    = { cur = cA, max = mA },
    B    = { cur = cB, max = mB },
    gren = gren,
  }
end

------------------------------------------------------------- decisions
local function slotFull(w, ratio)
  if w.max <= 0 then return true end
  return (w.cur / w.max) >= ratio
end

local function shouldSkipForClass(cls, stats)
  if not cls then return false end
  if string_find(cls, "BP_AmmoBox_Utility", 1, true) then
    return stats.gren >= CONFIG.UTILITY_BLOCK_AT
  elseif string_find(cls, "BP_AmmoBox_Spell", 1, true) then
    return slotFull(stats.B, CONFIG.AMMO_RATIO)
  elseif string_find(cls, "BP_AmmoBox", 1, true) then
    return slotFull(stats.A, CONFIG.AMMO_RATIO)
  end
  return false
end

------------------------------------------------------- collision-mode set
-- Apply a CollisionEnabled mode to the box's root component AND every
-- subcomponent (BP_AmmoBox typically has a StaticMesh + CollisionCylinder
-- trigger; both need the same mode).
local function applyMode(box, mode)
  if not isValid(box) then return false end
  local ok = pcall(function()
    if box.RootComponent and box.RootComponent.SetCollisionEnabled then
      box.RootComponent:SetCollisionEnabled(mode)
    end
    if box.GetComponents then
      local comps = nil
      pcall(function() comps = box:GetComponents() end)
      if comps then
        for _, c in ipairs(comps) do
          pcall(function()
            if c.SetCollisionEnabled then c:SetCollisionEnabled(mode) end
          end)
        end
      end
    end
  end)
  return ok
end

local function setBoxBlocked(box, blocked)
  local mode = blocked and CE_PHYSICS_ONLY or CE_QUERY_AND_PHYSICS
  local key = fname(box)
  if appliedMode[key] == mode then return false end  -- no-op if already set
  if applyMode(box, mode) then
    appliedMode[key] = mode
    return true
  end
  return false
end

------------------------------------------------------- settle detection
local function isBoxSettled(box, key, now)
  local age = now - (firstSeenAt[key] or now)
  if age < CONFIG.SETTLE_DELAY_MS then return false end
  local v = nil
  pcall(function() v = box:GetVelocity() end)
  if not v then return true end  -- velocity unreadable; trust age alone
  local sx, sy, sz = (v.X or 0), (v.Y or 0), (v.Z or 0)
  local speed = sqrt(sx*sx + sy*sy + sz*sz)
  return speed < CONFIG.SETTLE_VELOCITY
end

----------------------------------------------------- per-class processor
local function processClass(className, shouldSkip)
  local boxes = nil
  pcall(function() boxes = FindAllOf(className) end)
  if not boxes then return 0, 0 end
  local nBlocked, nUnblocked = 0, 0
  local now = nowMs()
  for _, box in ipairs(boxes) do
    if isValid(box) then
      local key = fname(box)
      if not firstSeenAt[key] then firstSeenAt[key] = now end

      local settled = isBoxSettled(box, key, now)
      -- During settle (or if velocity check failed weirdly), keep box
      -- in PhysicsOnly so it physics-falls but isn't grabbable. After
      -- settle, decide based on shouldSkip.
      local desired
      if not settled then
        desired = true   -- block during settle
      else
        desired = shouldSkip
      end

      if setBoxBlocked(box, desired) then
        if desired then nBlocked = nBlocked + 1
        else nUnblocked = nUnblocked + 1 end
      end
    end
  end
  return nBlocked, nUnblocked
end

----------------------------------------------------- spawn-time block
-- BeginPlay: apply PhysicsOnly the moment the box exists. Closes the
-- race window where AutoGrabber would otherwise grab between spawn and
-- our first tick.
local function onBoxBeginPlay(ctx)
  local box = unwrapCtx(ctx)
  if not isValid(box) then return end
  local key = fname(box)
  if not firstSeenAt[key] then firstSeenAt[key] = nowMs() end
  setBoxBlocked(box, true)
end

----------------------------------------------------------------- main
local function tick()
  local stats = readPlayerStats()
  if not stats then
    once("no-ps", function() logf("no PlayerState yet") end)
    return
  end

  local skipPrimary   = slotFull(stats.A, CONFIG.AMMO_RATIO)
  local skipSecondary = slotFull(stats.B, CONFIG.AMMO_RATIO)
  local skipUtility   = stats.gren >= CONFIG.UTILITY_BLOCK_AT

  local pB, pU = processClass("BP_AmmoBox_C",         skipPrimary)
  local sB, sU = processClass("BP_AmmoBox_Spell_C",   skipSecondary)
  local uB, uU = processClass("BP_AmmoBox_Utility_C", skipUtility)

  local now = nowMs()
  if CONFIG.VERBOSE and (now - lastHeartbeat) >= CONFIG.HEARTBEAT_MS then
    lastHeartbeat = now
    local rA = (stats.A.max > 0) and (stats.A.cur / stats.A.max * 100) or 0
    local rB = (stats.B.max > 0) and (stats.B.cur / stats.B.max * 100) or 0
    logf("primary %d/%d (%.0f%%) skip=%s | secondary %d/%d (%.0f%%) skip=%s | gren=%d skip=%s",
      stats.A.cur, stats.A.max, rA, tostring(skipPrimary),
      stats.B.cur, stats.B.max, rB, tostring(skipSecondary),
      stats.gren, tostring(skipUtility))
  end

  if (pB + sB + uB) > 0 then
    logf("blocked: primary=%d secondary=%d utility=%d", pB, sB, uB)
  end
  if (pU + sU + uU) > 0 then
    logf("unblocked: primary=%d secondary=%d utility=%d", pU, sU, uU)
  end
end

----------------------------------------------------------------- driver
local BEGIN_PLAY_HOOKS = {
  "/Game/GPE/BP_AmmoBox.BP_AmmoBox_C:ReceiveBeginPlay",
  "/Game/GPE/BP_AmmoBox_Spell.BP_AmmoBox_Spell_C:ReceiveBeginPlay",
  "/Game/GPE/BP_AmmoBox_Utility.BP_AmmoBox_Utility_C:ReceiveBeginPlay",
}

_G.__AGGate_started      = _G.__AGGate_started or false
_G.__AGGate_hooks        = _G.__AGGate_hooks or {}
_G.__AGGate_tick         = tick
_G.__AGGate_onBeginPlay  = onBoxBeginPlay

LoopAsync(1000, function()
  local allDone = true
  for _, path in ipairs(BEGIN_PLAY_HOOKS) do
    if not _G.__AGGate_hooks[path] then
      local ok = pcall(RegisterHook, path, function(c)
        _G.__AGGate_onBeginPlay(c)
      end)
      if ok then
        _G.__AGGate_hooks[path] = true
        logf("hooked %s", path)
      else
        allDone = false
      end
    end
  end
  return allDone
end)

if not _G.__AGGate_started then
  _G.__AGGate_started = true
  ExecuteWithDelay(2000, function()
    LoopAsync(CONFIG.TICK_INTERVAL_MS, function()
      pcall(_G.__AGGate_tick)
      return false
    end)
    logf("ready  ammoRatio=%.2f  utilityBlockAt=%d  tick=%dms  (PhysicsOnly gating)",
      CONFIG.AMMO_RATIO, CONFIG.UTILITY_BLOCK_AT, CONFIG.TICK_INTERVAL_MS)
  end)
else
  logf("ready (Lua reload)")
end
