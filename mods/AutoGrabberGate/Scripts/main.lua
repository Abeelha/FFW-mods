-- AutoGrabberGate — wraps GoldBl4d3's AutoGrabber pak (mods/2 of his),
-- skipping pickups the player doesn't currently need.
--
-- How: AutoGrabber's BP keeps a `PastInteractions` array of actors it has
-- already grabbed. Before grabbing anything new it does a Contains() check
-- against that array. If we pre-add a pickup actor to PastInteractions,
-- the grabber treats it as already-handled and skips it — no hooking, no
-- blocking required.
--
-- Behavior:
--   - Primary ammo (BP_AmmoBox_C):    skip pickup if reserveCur/reserveMax > AMMO_RATIO
--   - Utility   (BP_AmmoBox_Utility): skip pickup if grenadeCount >= UTILITY_BLOCK_AT
--
-- Each tick we re-evaluate every nearby box. We also remove our own
-- entries from PastInteractions when conditions flip back, so dropping
-- below the threshold re-enables grabbing without a restart.

------------------------------------------------------------------ config
local AMMO_RATIO            = 0.50    -- skip ammo if reserve fraction > this
local UTILITY_BLOCK_AT      = 1       -- skip utility if count >= this  (0 means: only allow when count == 0)
local TICK_HZ               = 0.2     -- 5 Hz, matches GoldBl4d3's grabber TickInterval
local READ_ONLY_DEBUG       = true    -- TRUE: log values, don't gate. Flip after sanity check.
local LOG_EVERY_N_TICKS     = 25      -- 25 * 0.2s = ~5s log cadence in debug mode

----------------------------------------------------------------- locals
local pcall, ipairs, tostring = pcall, ipairs, tostring
local string_find = string.find
local string_lower = string.lower

----------------------------------------------------------------- state
local resolved        = false
local nameCurAmmo     = nil   -- e.g. "currentTotalAmmos_17_DDF8...."
local nameMaxAmmo     = nil
local nameGrenades    = nil
local cachedPS        = nil
local cachedPSCls     = nil
local ourBlocked      = {}    -- [fullName]=true, only entries WE put into PastInteractions
local debugTickCount  = 0

------------------------------------------------------------------ utils
local function logf(fmt, ...)
  pcall(function() print("[AutoGrabberGate] " .. string.format(fmt, ...)) end)
end

local function safeFullName(o)
  local s = "?"
  pcall(function() if o and o.GetFullName then s = o:GetFullName() end end)
  return s
end

local function looksLikeFName(propClass)
  -- propClass e.g. "IntProperty", "DoubleProperty", "FloatProperty", "StructProperty"
  return propClass == "IntProperty" or propClass == "FloatProperty"
      or propClass == "DoubleProperty" or propClass == "ByteProperty"
end

-- Find the full hashed name of a property whose serialized name starts with `prefix`,
-- by iterating the class's properties via UE4SS reflection.
local function findPropName(cls, prefix)
  if not cls or not cls:IsValid() then return nil end
  local found = nil
  pcall(function()
    cls:ForEachProperty(function(prop)
      local n = prop:GetFName():ToString()
      if string_find(n, prefix, 1, true) == 1 then  -- starts with
        found = n
        return true  -- stop iteration if supported; harmless if not
      end
    end)
  end)
  return found
end

local function resolvePropertyNames(playerState)
  if not playerState or not playerState:IsValid() then return false end
  local cls = playerState:GetClass()
  cachedPSCls = cls

  nameCurAmmo  = findPropName(cls, "currentTotalAmmos")
  nameMaxAmmo  = findPropName(cls, "maxTotalAmmos")
  nameGrenades = findPropName(cls, "amountGrenades")

  if nameCurAmmo and nameMaxAmmo and nameGrenades then
    logf("resolved props: cur=%s  max=%s  gren=%s", nameCurAmmo, nameMaxAmmo, nameGrenades)
    return true
  end
  logf("WARN unresolved: cur=%s max=%s gren=%s", tostring(nameCurAmmo), tostring(nameMaxAmmo), tostring(nameGrenades))
  return false
end

local function getPlayerState()
  if cachedPS and cachedPS:IsValid() then return cachedPS end
  -- Try via PlayerController -> PlayerState
  local pc = nil
  pcall(function() pc = UEHelpers and UEHelpers.GetPlayerController and UEHelpers.GetPlayerController() end)
  if pc and pc:IsValid() then
    local ps = nil
    pcall(function() ps = pc.PlayerState end)
    if ps and ps:IsValid() then cachedPS = ps; return ps end
  end
  -- Fallback: FindFirstOf BP_PlayerState_C
  local ps = nil
  pcall(function() ps = FindFirstOf("BP_PlayerState_C") end)
  if ps and ps:IsValid() then cachedPS = ps; return ps end
  return nil
end

local function readPlayerStats()
  local ps = getPlayerState()
  if not ps then return nil end
  if not resolved then
    resolved = resolvePropertyNames(ps)
    if not resolved then return nil end
  end
  local cur, max, gren
  pcall(function() cur  = ps[nameCurAmmo]  end)
  pcall(function() max  = ps[nameMaxAmmo]  end)
  pcall(function() gren = ps[nameGrenades] end)
  if type(cur) ~= "number" or type(max) ~= "number" or type(gren) ~= "number" then return nil end
  return cur, max, gren
end

------------------------------------------------------------- decisions
local function shouldSkipAmmo(curAmmo, maxAmmo)
  if maxAmmo <= 0 then return false end  -- avoid div-by-zero, allow grab
  return (curAmmo / maxAmmo) > AMMO_RATIO
end

local function shouldSkipUtility(grenades)
  return grenades >= UTILITY_BLOCK_AT
end

----------------------------------------------------------- past-interactions
local function paContains(grabber, actor)
  local pi = grabber.PastInteractions
  if not pi then return false end
  local n = 0
  pcall(function() n = #pi end)
  for i = 1, n do
    local ok, entry = pcall(function() return pi[i] end)
    if ok and entry and entry == actor then return true, i end
  end
  return false
end

local function paAdd(grabber, actor)
  local ok = pcall(function() grabber.PastInteractions[#grabber.PastInteractions + 1] = actor end)
  return ok
end

local function paRemove(grabber, actor)
  local has, idx = paContains(grabber, actor)
  if not has then return false end
  -- TArray remove: shift down. Easier: nil the slot via :RemoveIndex if available.
  local ok = pcall(function()
    if grabber.PastInteractions.RemoveIndex then
      grabber.PastInteractions:RemoveIndex(idx - 1)  -- 0-based
    elseif grabber.PastInteractions.Remove then
      grabber.PastInteractions:Remove(actor)
    else
      -- last-resort manual shift
      local pi = grabber.PastInteractions
      local n = #pi
      for j = idx, n - 1 do pi[j] = pi[j + 1] end
      pi[n] = nil
    end
  end)
  return ok
end

-------------------------------------------------------------- main pass
local function evaluate()
  local cur, max, gren = readPlayerStats()
  if not cur then return end  -- not in a game / not resolved yet

  local grabber = FindFirstOf("Mod_2_C")
  if not grabber or not grabber:IsValid() then return end

  if READ_ONLY_DEBUG then
    debugTickCount = debugTickCount + 1
    if debugTickCount >= LOG_EVERY_N_TICKS then
      debugTickCount = 0
      local ratio = (max > 0) and (cur / max) or 0
      logf("DEBUG ammo=%d/%d (%.0f%%)  grenades=%d  -> skipAmmo=%s  skipUtil=%s",
        cur, max, ratio * 100, gren,
        tostring(shouldSkipAmmo(cur, max)),
        tostring(shouldSkipUtility(gren)))
    end
    return
  end

  local skipAmmo  = shouldSkipAmmo(cur, max)
  local skipUtil  = shouldSkipUtility(gren)

  local function process(className, shouldSkip)
    local boxes = nil
    pcall(function() boxes = FindAllOf(className) end)
    if not boxes then return end
    for _, box in ipairs(boxes) do
      if box and box:IsValid() then
        local key = safeFullName(box)
        local ours = ourBlocked[key] == true
        local has  = paContains(grabber, box)
        if shouldSkip then
          if not has then
            if paAdd(grabber, box) then ourBlocked[key] = true end
          else
            -- already in PastInteractions; mark as ours if grabber put it there too. Conservative: don't claim.
          end
        else
          if has and ours then
            if paRemove(grabber, box) then ourBlocked[key] = nil end
          end
        end
      end
    end
  end

  process("BP_AmmoBox_C", skipAmmo)
  process("BP_AmmoBox_Utility_C", skipUtil)
end

----------------------------------------------------------------- driver
local function startTimer()
  LoopAsync(math.floor(TICK_HZ * 1000), function()
    pcall(evaluate)
    return false  -- never stop
  end)
end

ExecuteWithDelay(1000, function()
  startTimer()
  logf("ready (READ_ONLY_DEBUG=%s, AMMO_RATIO=%.2f, UTILITY_BLOCK_AT=%d)",
       tostring(READ_ONLY_DEBUG), AMMO_RATIO, UTILITY_BLOCK_AT)
end)
