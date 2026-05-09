-- AutoGrabberPro v2 — smart auto-pickup, Lua reimplementation.
--
-- Property paths and signatures verified from FModel JSON exports:
--   tools/Output/Exports/FarFarWest/Content/Player/BP_Player.json
--   tools/Output/Exports/FarFarWest/Content/Player/BP_PlayerState.json
--   tools/Output/Exports/FarFarWest/Content/Player/SaveGames/S_PlayerRuntimeStats.json

----------------------------------------------------------------- config
local CONFIG = {
  AMMO_RATIO_THRESHOLD = 0.25,   -- skip ammo if BOTH weapons have reserve >= 25%
  UTILITY_BLOCK_AT     = 1,      -- skip utility if grenades >= this
  GRAB_RADIUS_UU       = 500.0,
  TICK_INTERVAL_MS     = 200,
  VERBOSE              = true,   -- log liberally while we debug
}

------------------------------------------ hardcoded BP property paths
-- PlayerState ─ playerRuntimeStats (struct) ─ datasWepA (S_ItemDatas) ─ currentMagazineAmmos / maxMagazineAmmos
--                                                                    ─ currentTotalAmmos    / maxTotalAmmos
--                                         ╰ datasWepB (S_ItemDatas) ─ same fields
--                                         ╰ amountGrenades (int)
local P_RUNTIME_STATS  = "playerRuntimeStats"
local P_WEP_A          = "datasWepA_24_C099A0F04138D662182F8D9C94DCA8C6"
local P_WEP_B          = "datasWepB_25_EE50A5DA4381738DA8C10CB8353016D9"
local P_CUR_MAG        = "currentMagazineAmmos_10_76E089514907BA2E4DDB1CA16CEC4B6B"
local P_MAX_MAG        = "maxMagazineAmmos_8_E1B199D345F51D5DF152DBBB0371E153"
local P_CUR_TOTAL      = "currentTotalAmmos_17_DDF8963D42826C9B6D9A9E92E9563632"
local P_MAX_TOTAL      = "maxTotalAmmos_18_2EACEDBD42C653C7490D2F999719144E"
local P_GRENADES       = "amountGrenades_26_E0AD04BF4A4DB7E8E4C0DA8931601223"

----------------------------------------------------------------- state
local pcall, ipairs, tostring, type = pcall, ipairs, tostring, type
local string_format = string.format

local cachedPS    = nil
local grabbed     = {}
local tickN       = 0
local logSampled  = {}   -- once-only logging per category

------------------------------------------------------------------ utils
local function logf(fmt, ...)
  local ok, s = pcall(string_format, fmt, ...)
  if not ok then s = fmt end
  pcall(print, "[AGP] " .. s)
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
  if not o then return "?" end
  local s = "?"
  pcall(function() if o.GetFullName then s = o:GetFullName() end end)
  return s
end

----------------------------------------------------------- discovery
local function getPlayerController()
  local pc = nil
  pcall(function() pc = FindFirstOf("PlayerController") end)
  if isValid(pc) then return pc end
  pcall(function() pc = FindFirstOf("BP_PlayerController_C") end)
  return isValid(pc) and pc or nil
end

local function getPlayer()
  local pc = getPlayerController()
  if isValid(pc) then
    local p = nil
    pcall(function() p = pc.Pawn end)
    if isValid(p) then return p end
  end
  local p = nil
  pcall(function() p = FindFirstOf("BP_Player_C") end)
  return isValid(p) and p or nil
end

local function getPlayerState()
  if isValid(cachedPS) then return cachedPS end
  cachedPS = nil
  local pc = getPlayerController()
  if isValid(pc) then
    local ps = nil
    pcall(function() ps = pc.PlayerState end)
    if isValid(ps) then cachedPS = ps; return ps end
  end
  local ps = nil
  pcall(function() ps = FindFirstOf("BP_PlayerState_C") end)
  if isValid(ps) then cachedPS = ps; return ps end
  return nil
end

----------------------------------------------------- nested prop reads
local function readNested(root, path)
  -- path is array of names; returns last value or nil with reason.
  local cur = root
  for i, name in ipairs(path) do
    if cur == nil then return nil, "nil before " .. name end
    local nxt = nil
    local ok, err = pcall(function() nxt = cur[name] end)
    if not ok then return nil, "err at " .. name .. ": " .. tostring(err) end
    if nxt == nil then return nil, "missing " .. name end
    cur = nxt
  end
  return cur, nil
end

local function readWeapon(ps, slotName)
  local s = readNested(ps, { P_RUNTIME_STATS, slotName })
  if not s then return 0, 0, 0, 0 end
  local curMag   = readNested(s, { P_CUR_MAG })   or 0
  local maxMag   = readNested(s, { P_MAX_MAG })   or 0
  local curTotal = readNested(s, { P_CUR_TOTAL }) or 0
  local maxTotal = readNested(s, { P_MAX_TOTAL }) or 0
  if type(curMag)   ~= "number" then curMag   = 0 end
  if type(maxMag)   ~= "number" then maxMag   = 0 end
  if type(curTotal) ~= "number" then curTotal = 0 end
  if type(maxTotal) ~= "number" then maxTotal = 0 end
  return curMag, maxMag, curTotal, maxTotal
end

local function readPlayerStats()
  local ps = getPlayerState()
  if not ps then
    once("no-ps", function() logf("no PlayerState yet") end)
    return nil
  end
  local cMagA, mMagA, cTotA, mTotA = readWeapon(ps, P_WEP_A)
  local cMagB, mMagB, cTotB, mTotB = readWeapon(ps, P_WEP_B)
  local gren = readNested(ps, { P_RUNTIME_STATS, P_GRENADES })
  if type(gren) ~= "number" then
    once("gren-bad", function() logf("grenades unreadable; got %s", type(gren)) end)
    return nil
  end
  return {
    A = { mag = cMagA, magMax = mMagA, total = cTotA, totalMax = mTotA },
    B = { mag = cMagB, magMax = mMagB, total = cTotB, totalMax = mTotB },
    grenades = gren,
  }
end

------------------------------------------------------------- decisions
-- Weapon "needs ammo" if any of its ammo pools (mag or reserve) is below
-- the threshold ratio. Mag-only weapons (e.g. Sheriff Stars / shurikens
-- with maxTotal == 0) fall back to the mag check. Total-only weapons fall
-- back to the total check. Either path triggers grab eligibility.
local function weaponNeedsAmmo(w, threshold)
  local needTotal = (w.totalMax > 0) and ((w.total / w.totalMax) < threshold)
  local needMag   = (w.magMax   > 0) and ((w.mag   / w.magMax)   < threshold)
  return needTotal or needMag
end

local function shouldSkipAmmo(stats)
  -- Grab if EITHER weapon needs ammo (any pool below threshold). The user
  -- doesn't need the active weapon equipped — both slots count.
  return not (weaponNeedsAmmo(stats.A, CONFIG.AMMO_RATIO_THRESHOLD)
           or weaponNeedsAmmo(stats.B, CONFIG.AMMO_RATIO_THRESHOLD))
end

local function shouldSkipUtility(grenades)
  return grenades >= CONFIG.UTILITY_BLOCK_AT
end

------------------------------------------------------------ geometry
local function actorLoc(a)
  local v = nil
  pcall(function() v = a:K2_GetActorLocation() end)
  return v
end

local function distSq(a, b)
  if not a or not b then return math.huge end
  local dx = (a.X or 0) - (b.X or 0)
  local dy = (a.Y or 0) - (b.Y or 0)
  local dz = (a.Z or 0) - (b.Z or 0)
  return dx * dx + dy * dy + dz * dz
end

----------------------------------------------------- pickup invocation
-- Pickup boxes use overlap-triggered logic (bGenerateOverlapEvents=true,
-- CollisionCylinder, F_StartInteract → wait → F_Interact pipeline). Direct
-- function calls (F_Interact, F_Activate, F_InstantInteract) don't fire
-- the pipeline because they bypass the BeginOverlap event the box's own
-- BP listens for.
--
-- The natural-overlap approach: teleport the box ONTO the player. The
-- box's BeginOverlap fires, the box's BP runs the same code path as if
-- the player walked over it, and the box self-destructs after the normal
-- pickup. K2_SetActorLocation with bSweep=true forces overlap events to
-- fire during the move.
--
-- Falls back to F_Activate / F_Interact if teleport doesn't despawn the
-- box (we'll see in the log which path actually does the work).

local STRATEGIES = {
  -- Strategy 1: THE canonical pattern AutoGrabber uses — set the player's
  -- `interactableObject` (an ObjectProperty<Actor> on BP_Player_C, verified
  -- in BP_Player.json line 1144), then call F_InstantInteract with no args.
  -- F_InstantInteract reads interactableObject internally to know what to
  -- pick up. This is what the original Mod_2_C BP does.
  { name = "SetInteractable+F_InstantInteract", fn = function(player, box, ploc)
      player.interactableObject = box
      player:F_InstantInteract()
    end },
  -- Strategy 2 fallback: teleport box to player so natural overlap fires.
  { name = "Teleport_Sweep", fn = function(player, box, ploc)
      box:K2_SetActorLocation(ploc, true, {}, false)
    end },
  -- Strategy 3 fallback: F_Activate.
  { name = "F_Activate", fn = function(player, box, ploc)
      player:F_Activate(0, 0.0, box)
    end },
}

local strategyIndex = {}  -- [boxFullName] = next strategy idx to try

local function callPickup(player, box, ploc, label)
  local id = fname(box)
  local idx = strategyIndex[id] or 1
  if idx > #STRATEGIES then return nil end  -- exhausted
  local strat = STRATEGIES[idx]
  local ok, err = pcall(function() strat.fn(player, box, ploc) end)
  strategyIndex[id] = idx + 1
  if not ok then
    once("strat-err-" .. strat.name .. "-" .. label, function()
      logf("%s strategy %s errored on %s: %s", label, strat.name, id, tostring(err))
    end)
  end
  return strat.name
end

----------------------------------------------------- pickup processing
-- We call F_Activate at most once per box per RECHECK_MS — boxes have
-- pickup animations / server-replication round-trips, calling more often
-- can spam or cancel itself.
local RECHECK_MS = 1000
local lastAttempt = {}  -- [boxFullName] = ms timestamp of last attempt

local function nowMs()
  -- Use os.clock(); good enough for rate-limit purposes (returns seconds).
  return math.floor(os.clock() * 1000)
end

local function processClass(player, playerLoc, className, allowed, label)
  local boxes = nil
  pcall(function() boxes = FindAllOf(className) end)
  if not boxes then
    once("no-class-" .. className, function() logf("FindAllOf(%s) returned nil", className) end)
    return 0
  end

  local count = 0
  pcall(function() count = #boxes end)
  once("first-class-" .. className, function() logf("FindAllOf(%s) found %d", className, count) end)

  if not allowed then return count end
  if count == 0 then return 0 end

  local now = nowMs()
  local rSq = CONFIG.GRAB_RADIUS_UU * CONFIG.GRAB_RADIUS_UU

  for _, box in ipairs(boxes) do
    if isValid(box) then
      local id = fname(box)
      local lastMs = lastAttempt[id] or 0
      if not grabbed[id] and (now - lastMs) >= RECHECK_MS then
        local bl = actorLoc(box)
        if bl then
          local d2 = distSq(playerLoc, bl)
          if d2 <= rSq then
            local stratName = callPickup(player, box, playerLoc, label)
            if stratName then
              once("first-attempt-" .. label .. "-" .. stratName, function()
                logf("%s attempt via %s on %s (dist^2=%.0f thresh=%.0f)",
                  label, stratName, id, d2, rSq)
              end)
            end
            lastAttempt[id] = now
          end
        end
      end
    elseif not grabbed[fname(box) or "?"] then
      -- Box just got destroyed (was valid, now isn't) -> success.
      local id = fname(box) or "?"
      grabbed[id] = true
      local lastStrat = (strategyIndex[id] and STRATEGIES[strategyIndex[id] - 1]) or nil
      once("first-success-" .. label, function()
        logf("%s GRAB WORKED on %s via %s", label, id,
             lastStrat and lastStrat.name or "?")
      end)
    end
  end
  return count
end

----------------------------------------------------------------- main
local function tick()
  local player = getPlayer()
  if not player then
    once("no-player", function() logf("no player yet") end)
    return
  end

  local stats = readPlayerStats()
  if not stats then return end

  local skipAmmo = shouldSkipAmmo(stats)
  local skipUtil = shouldSkipUtility(stats.grenades)

  if CONFIG.VERBOSE then
    tickN = tickN + 1
    if tickN >= 25 then  -- every ~5s at 200ms
      tickN = 0
      logf("A mag=%d/%d total=%d/%d  B mag=%d/%d total=%d/%d  gren=%d  skipAmmo=%s skipUtil=%s",
        stats.A.mag, stats.A.magMax, stats.A.total, stats.A.totalMax,
        stats.B.mag, stats.B.magMax, stats.B.total, stats.B.totalMax,
        stats.grenades,
        tostring(skipAmmo), tostring(skipUtil))
    end
  end

  local ploc = actorLoc(player)
  if not ploc then return end

  processClass(player, ploc, "BP_AmmoBox_C",         not skipAmmo, "ammo")
  processClass(player, ploc, "BP_AmmoBox_Utility_C", not skipUtil, "util")
end

----------------------------------------------------------- level reset
LoopAsync(5000, function()
  if not isValid(cachedPS) then
    cachedPS = nil
    grabbed = {}
    -- keep logSampled so we don't re-spam debug lines
  end
  return false
end)

----------------------------------------------------------------- driver
ExecuteWithDelay(2000, function()
  LoopAsync(CONFIG.TICK_INTERVAL_MS, function()
    pcall(tick)
    return false
  end)
  logf("v2 ready. ammoRatio=%.2f utilityBlockAt=%d radius=%.0f",
    CONFIG.AMMO_RATIO_THRESHOLD, CONFIG.UTILITY_BLOCK_AT, CONFIG.GRAB_RADIUS_UU)
end)
