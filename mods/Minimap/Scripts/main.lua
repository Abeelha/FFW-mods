-- Minimap — round HUD minimap with POI markers (gold, minerals, camps, etc).
--
-- v0.1 SCANNER PHASE: log POI counts every 5s to verify class-name guesses
-- against the live game world. Once classes are confirmed, we'll add the
-- actual HUD render layer (player at center, POIs as colored dots, rotates
-- with heading).
--
-- POI candidates inferred from FModel JSON exports — names not yet
-- empirically validated. Numbers in heartbeat = live FindAllOf hit count.

----------------------------------------------------------------- config
local CONFIG = {
  TICK_INTERVAL_MS = 1000,  -- POI scan cadence
  HEARTBEAT_MS     = 5000,  -- log every N ms
  VERBOSE          = true,
}

----------------------------------------------------------------- POI registry
-- group: logical category for the minimap legend
-- color: future render hint (R,G,B 0..1) — gold/cyan/red/etc
-- classes: UE class names (FindAllOf includes subclasses)
local POI_GROUPS = {
  {
    group   = "gold-veins",        -- mineable rocks = gold source
    color   = { 1.0, 0.84, 0.0 },  -- gold
    classes = {
      "BP_MineableRocks_C",
    },
  },
  {
    group   = "skull-spawners",    -- enemy camps with skulls; killing skulls drops souls
    color   = { 1.0, 0.3, 0.3 },   -- red
    classes = {
      "BP_Camp_Cryptic_A_C",
      "BP_Camp_Cryptic_B_C",
      "BP_Camp_Cryptic_C_C",
      "BP_Camp_Cryptic_D_C",
      "BP_Camp_Cryptic_E_C",
      "BP_Camp_Cryptic_F_C",
    },
  },
  {
    group   = "skulls",            -- destructible skulls that drop souls on kill
    color   = { 0.9, 0.5, 0.9 },   -- pink/violet
    classes = {
      "BP_PhysicObject_Skull_Cryptic_C",
      "BP_PhysicObject_Skull_Cryptic_Lit_C",
    },
  },
  {
    group   = "souls",             -- dropped soul pickups (after skull/camp killed)
    color   = { 0.7, 0.4, 1.0 },   -- purple
    classes = {
      "BP_PickUpSoul_C",           -- guess; verify in log
      "SC_PickUpSoul_C",           -- alt path seen in JSON
    },
  },
  {
    group   = "objectives",
    color   = { 1.0, 1.0, 0.4 },   -- yellow
    classes = {
      "BP_CrypticTotem_C",
      "BP_CryptincInvocationRing_Ring_C",
      "BP_Area_GoldMagnet_C",
      "BP_Area_KwartCareer_C",
      "BP_Area_Cryptic_Totem_C",
    },
  },
}

----------------------------------------------------------------- locals
local pcall, ipairs = pcall, ipairs

----------------------------------------------------------------- state
local lastHeartbeat = 0
local logSampled    = {}

----------------------------------------------------------------- utils
local function logf(fmt, ...)
  local ok, s = pcall(string.format, fmt, ...)
  if not ok then s = fmt end
  pcall(print, "[Minimap] " .. s)
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

local function nowMs()
  return math.floor(os.clock() * 1000)
end

local function actorLoc(a)
  local v = nil
  pcall(function() v = a:K2_GetActorLocation() end)
  return v
end

----------------------------------------------------------------- player
local function getPlayer()
  local pc = nil
  pcall(function() pc = FindFirstOf("PlayerController") end)
  if isValid(pc) then
    local p = nil
    pcall(function() p = pc.Pawn end)
    if isValid(p) then return p end
  end
  local p = nil
  pcall(function() p = FindFirstOf("BP_Player_C") end)
  return isValid(p) and p or nil
end

----------------------------------------------------------------- scan
local function scanGroup(group)
  local total = 0
  local perClass = {}
  for _, cls in ipairs(group.classes) do
    local n = 0
    local boxes = nil
    pcall(function() boxes = FindAllOf(cls) end)
    if boxes then
      pcall(function() n = #boxes end)
      -- Subtract default objects (CDOs) which FindAllOf includes.
      if boxes and n > 0 then
        local count = 0
        for _, o in ipairs(boxes) do
          local isDefault = false
          pcall(function() isDefault = o:IsDefaultObject() end)
          if isValid(o) and not isDefault then count = count + 1 end
        end
        n = count
      end
    end
    perClass[cls] = n
    total = total + n
  end
  return total, perClass
end

local function tick()
  local now = nowMs()
  if (now - lastHeartbeat) < CONFIG.HEARTBEAT_MS then return end
  lastHeartbeat = now

  local player = getPlayer()
  local hasPlayer = isValid(player)

  if not CONFIG.VERBOSE then return end

  local lines = {}
  for _, g in ipairs(POI_GROUPS) do
    local total, perClass = scanGroup(g)
    if total > 0 then
      table.insert(lines, string.format("%s=%d", g.group, total))
    end
    -- Log per-class breakdown once when first seen non-zero, so we know
    -- which classes are actually live in the world.
    for cls, n in pairs(perClass) do
      if n > 0 then
        once("first-" .. cls, function()
          logf("first-seen class %s in world (count=%d)", cls, n)
        end)
      end
    end
  end

  if #lines == 0 then
    once("empty", function() logf("no POIs found yet (or class names wrong)") end)
  else
    logf("POIs: %s | player=%s", table.concat(lines, "  "), tostring(hasPlayer))
  end
end

----------------------------------------------------------------- driver
_G.__Minimap_started = _G.__Minimap_started or false
_G.__Minimap_tick    = tick

if not _G.__Minimap_started then
  _G.__Minimap_started = true
  ExecuteWithDelay(2000, function()
    LoopAsync(CONFIG.TICK_INTERVAL_MS, function()
      pcall(_G.__Minimap_tick)
      return false
    end)
    logf("scanner ready — heartbeat every %dms", CONFIG.HEARTBEAT_MS)
  end)
else
  logf("scanner ready (Lua reload)")
end
