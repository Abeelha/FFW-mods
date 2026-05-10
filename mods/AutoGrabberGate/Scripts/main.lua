-- AutoGrabberGate — gate ammo box pickup by ammo % via collision profile.
--
-- Mechanism: each box's CollisionEnabled mode is toggled.
--   PhysicsOnly       → physics works (gravity, ground block, falling),
--                       but traces and overlaps return nothing. Both
--                       AutoGrabber's SphereTraceMulti and player
--                       overlap pickup stop seeing the box.
--   QueryAndPhysics   → normal grabbable state.
--
-- Per-box lifecycle:
--   1. ReceiveBeginPlay → instantly set PhysicsOnly. Box exists in
--      world, simulates physics normally, invisible to grab queries
--      from frame zero — no race window.
--   2. Tick (5 Hz) re-evaluates:
--        - not settled (age < SETTLE_DELAY_MS or velocity > threshold)
--          → keep PhysicsOnly
--        - settled + skip (player full)              → keep PhysicsOnly
--        - settled + needs ammo                      → QueryAndPhysics
--   3. Mid-fight stat changes flip individual boxes between modes.
--
-- Why not pause Mod_2 / mutate InteractClasses / null F_Interact params:
--   Each of those was tried and hit a UE limitation (BP body always
--   runs after pre-hooks; TArray writes risk crashes; null Owner doesn't
--   stop the unconditional F_DestroyActor_Server call). Per-box
--   collision profile sidesteps all of it: the box is simply absent
--   from any grab query, so no grab path is ever entered.
--
-- Pickup → stat mapping (verified via uasset string dumps):
--   BP_AmmoBox_C / *_Throw_C        → datasWepA   (primary)
--   BP_AmmoBox_Spell_C / *_Throw_C  → datasWepB   (secondary)
--   BP_AmmoBox_Utility_C            → grenades

----------------------------------------------------------------- config
local CONFIG = {
  AMMO_RATIO         = 0.50,
  UTILITY_BLOCK_AT   = 1,
  TICK_INTERVAL_MS   = 200,    -- 5 Hz
  HEARTBEAT_MS       = 5000,
  SETTLE_DELAY_MS    = 3000,
  SETTLE_VELOCITY    = 5.0,    -- u/s; box at-rest threshold
  GC_INTERVAL_TICKS  = 25,     -- prune dead box keys every N ticks (~5s)
  VERBOSE            = true,
}

----------------------------------------------- UE ECollisionEnabled
local CE_PHYSICS_ONLY      = 2  -- physics yes, queries no
local CE_QUERY_AND_PHYSICS = 3  -- normal

------------------------------------- BP property prefixes
-- Hashed property names (e.g. "datasWepA_24_C099A0F0...") may change on
-- game patches. We resolve by prefix on first read and cache the result.
local PREFIX_RUNTIME_STATS = "playerRuntimeStats"
local PREFIX_WEP_A         = "datasWepA"
local PREFIX_WEP_B         = "datasWepB"
local PREFIX_CUR_TOTAL     = "currentTotalAmmos"
local PREFIX_MAX_TOTAL     = "maxTotalAmmos"
local PREFIX_GRENADES      = "amountGrenades"

local TARGET_CLASSES = {
  primary   = "BP_AmmoBox_C",
  secondary = "BP_AmmoBox_Spell_C",
  utility   = "BP_AmmoBox_Utility_C",
}

local BEGIN_PLAY_HOOKS = {
  "/Game/GPE/BP_AmmoBox.BP_AmmoBox_C:ReceiveBeginPlay",
  "/Game/GPE/BP_AmmoBox_Spell.BP_AmmoBox_Spell_C:ReceiveBeginPlay",
  "/Game/GPE/BP_AmmoBox_Utility.BP_AmmoBox_Utility_C:ReceiveBeginPlay",
}

----------------------------------------------------------------- locals
local pcall, ipairs, type, pairs = pcall, ipairs, type, pairs
local string_find, string_format, string_sub = string.find, string.format, string.sub
local sqrt, floor = math.sqrt, math.floor

----------------------------------------------------------------- state
-- Per-box state. Keys are box GetFullName() strings. Both tables are
-- pruned each GC sweep so dead-box keys don't accumulate.
local firstSeenAt   = {}  -- key -> ms when first observed
local appliedMode   = {}  -- key -> last applied CE_* mode (skip no-op writes)

-- Resolved BP property names (set once on first successful PS read).
local pName = {
  runtimeStats = nil, wepA = nil, wepB = nil,
  curTotal = nil, maxTotal = nil, grenades = nil,
}

-- Misc
local logSampled    = {}
local lastHeartbeat = 0
local tickCount     = 0
-- Aggregated transition counts since last heartbeat; emitted in heartbeat.
local txCounts = {
  blocked   = {},
  unblocked = {},
}

----------------------------------------------------------------- utils
local function logf(fmt, ...)
  local ok, s = pcall(string_format, fmt, ...)
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

local function nowMs() return floor(os.clock() * 1000) end

local function unwrapCtx(ctx)
  if ctx and ctx.get then
    local ok, val = pcall(ctx.get, ctx)
    if ok then return val end
  end
  return ctx
end

------------------------------------------------ property name resolver
-- Iterate object properties, return name starting with prefix. UE4SS
-- exposes ForEachProperty on UClass.
local function findPropName(cls, prefix)
  if not isValid(cls) then return nil end
  local found = nil
  pcall(function()
    cls:ForEachProperty(function(prop)
      local n = prop:GetFName():ToString()
      if string_find(n, prefix, 1, true) == 1 then
        found = n
        return true  -- stop iteration when supported
      end
    end)
  end)
  return found
end

local function resolveStructPropOnce(structSample, key, prefix)
  if pName[key] then return pName[key] end
  if not isValid(structSample) then return nil end
  local cls = nil
  pcall(function() cls = structSample:GetClass() end)
  local resolved = findPropName(cls, prefix)
  if resolved then pName[key] = resolved end
  return resolved
end

------------------------------------------------------ player state read
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

local function getRuntimeStats(ps)
  if not pName.runtimeStats then
    -- Try class-resolved first; PS class typically has the prop named
    -- exactly "playerRuntimeStats" (no hash) or hashed.
    local cls = nil
    pcall(function() cls = ps:GetClass() end)
    local n = findPropName(cls, PREFIX_RUNTIME_STATS) or PREFIX_RUNTIME_STATS
    pName.runtimeStats = n
  end
  local rs = nil
  pcall(function() rs = ps[pName.runtimeStats] end)
  return rs
end

local function readSlot(rs, slotPrefix, slotKey)
  if not pName[slotKey] then
    local cls = nil
    pcall(function() cls = rs:GetClass() end)
    pName[slotKey] = findPropName(cls, slotPrefix)
  end
  if not pName[slotKey] then return 0, 0 end
  local s = nil
  pcall(function() s = rs[pName[slotKey]] end)
  if not s then return 0, 0 end
  -- Resolve per-slot field names once using one slot as a sample.
  local curName = resolveStructPropOnce(s, "curTotal",  PREFIX_CUR_TOTAL)
  local maxName = resolveStructPropOnce(s, "maxTotal",  PREFIX_MAX_TOTAL)
  local cur, max = 0, 0
  if curName then pcall(function() cur = s[curName] or 0 end) end
  if maxName then pcall(function() max = s[maxName] or 0 end) end
  if type(cur) ~= "number" then cur = 0 end
  if type(max) ~= "number" then max = 0 end
  return cur, max
end

local function readPlayerStats()
  local ps = getPlayerState()
  if not ps then return nil end
  local rs = getRuntimeStats(ps)
  if not rs then
    once("no-rs", function() logf("playerRuntimeStats unreadable") end)
    return nil
  end
  local cA, mA = readSlot(rs, PREFIX_WEP_A, "wepA")
  local cB, mB = readSlot(rs, PREFIX_WEP_B, "wepB")

  if not pName.grenades then
    local cls = nil
    pcall(function() cls = rs:GetClass() end)
    pName.grenades = findPropName(cls, PREFIX_GRENADES)
  end
  local gren = 0
  if pName.grenades then
    pcall(function() gren = rs[pName.grenades] or 0 end)
  end
  if type(gren) ~= "number" then gren = 0 end

  return {
    A    = { cur = cA, max = mA },
    B    = { cur = cB, max = mB },
    gren = gren,
  }
end

----------------------------------------------------------- decisions
local function slotFull(w, ratio)
  -- max == 0 means the player has no weapon equipped for this slot.
  -- Don't block: leave the box grabbable. The game itself no-ops or
  -- stores the ammo internally; not our job to second-guess that.
  -- (Earlier returned true for "mag-only weapons" but those actually
  -- have a non-zero max in the runtime stats — e.g. shurikens are 15/15,
  -- not 0/0 — so this case is purely "no slot equipped".)
  if w.max <= 0 then return false end
  return (w.cur / w.max) >= ratio
end

local function shouldSkipForCategory(category, stats)
  if category == "primary"   then return slotFull(stats.A, CONFIG.AMMO_RATIO) end
  if category == "secondary" then return slotFull(stats.B, CONFIG.AMMO_RATIO) end
  if category == "utility"   then return stats.gren >= CONFIG.UTILITY_BLOCK_AT end
  return false
end

----------------------------------------------------- collision-mode set
local function applyMode(box, mode)
  return pcall(function()
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
end

local function setBoxBlocked(box, key, blocked)
  local mode = blocked and CE_PHYSICS_ONLY or CE_QUERY_AND_PHYSICS
  if appliedMode[key] == mode then return false end
  if applyMode(box, mode) then
    appliedMode[key] = mode
    return true
  end
  return false
end

----------------------------------------------------- settle detection
local function isBoxSettled(box, key, now)
  local age = now - (firstSeenAt[key] or now)
  if age < CONFIG.SETTLE_DELAY_MS then return false end
  local v = nil
  pcall(function() v = box:GetVelocity() end)
  if not v then return true end  -- can't read = trust age alone
  local sx, sy, sz = (v.X or 0), (v.Y or 0), (v.Z or 0)
  local speed = sqrt(sx*sx + sy*sy + sz*sz)
  return speed < CONFIG.SETTLE_VELOCITY
end

----------------------------------------------------- per-class processor
-- `seen` collects keys observed this tick, used to GC stale entries.
local function processClass(category, className, shouldSkip, now, seen)
  local boxes = nil
  pcall(function() boxes = FindAllOf(className) end)
  if not boxes then return 0, 0 end
  local nBlocked, nUnblocked = 0, 0
  for _, box in ipairs(boxes) do
    if isValid(box) then
      local key = fname(box)
      seen[key] = true
      if not firstSeenAt[key] then firstSeenAt[key] = now end

      local desired
      if not isBoxSettled(box, key, now) then
        desired = true   -- always block while settling
      else
        desired = shouldSkip
      end

      if setBoxBlocked(box, key, desired) then
        if desired then nBlocked = nBlocked + 1
        else            nUnblocked = nUnblocked + 1 end
      end
    end
  end
  return nBlocked, nUnblocked
end

----------------------------------------------------- spawn-time block
local function onBoxBeginPlay(ctx)
  local box = unwrapCtx(ctx)
  if not isValid(box) then return end
  local key = fname(box)
  if not firstSeenAt[key] then firstSeenAt[key] = nowMs() end
  setBoxBlocked(box, key, true)
end

----------------------------------------------------- GC of stale state
-- Called periodically (every GC_INTERVAL_TICKS). Drops box keys that
-- weren't seen in the most recent FindAllOf sweeps, preventing the
-- two state tables from growing without bound.
local function gcDeadKeys(seen)
  for key in pairs(firstSeenAt) do
    if not seen[key] then firstSeenAt[key] = nil end
  end
  for key in pairs(appliedMode) do
    if not seen[key] then appliedMode[key] = nil end
  end
end

----------------------------------------------------------------- main
local function tick()
  local stats = readPlayerStats()
  if not stats then
    once("no-ps", function() logf("no PlayerState yet") end)
    return
  end

  local now = nowMs()
  local seen = {}

  local skipPrimary   = shouldSkipForCategory("primary",   stats)
  local skipSecondary = shouldSkipForCategory("secondary", stats)
  local skipUtility   = shouldSkipForCategory("utility",   stats)

  local pB, pU = processClass("primary",   TARGET_CLASSES.primary,   skipPrimary,   now, seen)
  local sB, sU = processClass("secondary", TARGET_CLASSES.secondary, skipSecondary, now, seen)
  local uB, uU = processClass("utility",   TARGET_CLASSES.utility,   skipUtility,   now, seen)

  -- Periodic GC of stale entries (boxes destroyed since last sweep).
  tickCount = tickCount + 1
  if tickCount >= CONFIG.GC_INTERVAL_TICKS then
    tickCount = 0
    gcDeadKeys(seen)
  end

  if CONFIG.VERBOSE and (now - lastHeartbeat) >= CONFIG.HEARTBEAT_MS then
    lastHeartbeat = now
    local rA = (stats.A.max > 0) and (stats.A.cur / stats.A.max * 100) or 0
    local rB = (stats.B.max > 0) and (stats.B.cur / stats.B.max * 100) or 0
    logf("primary %d/%d (%.0f%%) skip=%s | secondary %d/%d (%.0f%%) skip=%s | gren=%d skip=%s",
      stats.A.cur, stats.A.max, rA, tostring(skipPrimary),
      stats.B.cur, stats.B.max, rB, tostring(skipSecondary),
      stats.gren, tostring(skipUtility))
    local b, u = txCounts.blocked, txCounts.unblocked
    local bSum = (b.primary or 0) + (b.secondary or 0) + (b.utility or 0)
    local uSum = (u.primary or 0) + (u.secondary or 0) + (u.utility or 0)
    if bSum + uSum > 0 then
      logf("transitions since last: blocked p=%d s=%d u=%d | unblocked p=%d s=%d u=%d",
        b.primary or 0, b.secondary or 0, b.utility or 0,
        u.primary or 0, u.secondary or 0, u.utility or 0)
    end
    txCounts.blocked   = {}
    txCounts.unblocked = {}
  end

  -- Roll up transition counts into the heartbeat to keep log clean.
  -- Per-tick spam was masking real signal (e.g. lobby spawners cycle
  -- 24 boxes/tick which produced log floods).
  txCounts.blocked.primary   = (txCounts.blocked.primary   or 0) + pB
  txCounts.blocked.secondary = (txCounts.blocked.secondary or 0) + sB
  txCounts.blocked.utility   = (txCounts.blocked.utility   or 0) + uB
  txCounts.unblocked.primary   = (txCounts.unblocked.primary   or 0) + pU
  txCounts.unblocked.secondary = (txCounts.unblocked.secondary or 0) + sU
  txCounts.unblocked.utility   = (txCounts.unblocked.utility   or 0) + uU
end

----------------------------------------------------------------- driver
-- Globals survive Lua reload (Ctrl+R); UE4SS keeps native hooks bound,
-- so re-registering double-fires. The forwarder closure picks up the
-- newly-loaded callback each time the script reloads.
_G.__AGGate_started     = _G.__AGGate_started or false
_G.__AGGate_hooks       = _G.__AGGate_hooks or {}
_G.__AGGate_tick        = tick
_G.__AGGate_onBeginPlay = onBoxBeginPlay

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
    logf("ready  ammoRatio=%.2f  utilityBlockAt=%d  tick=%dms",
      CONFIG.AMMO_RATIO, CONFIG.UTILITY_BLOCK_AT, CONFIG.TICK_INTERVAL_MS)
  end)
else
  logf("ready (Lua reload)")
end
