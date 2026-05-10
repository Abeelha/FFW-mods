-- Minimap — round HUD minimap with POI markers (gold veins, skull spawners,
-- skulls, souls, objectives). Player at center, fixed-north orientation.
--
-- Architecture:
--   1. SCANNER: every tick, FindAllOf each POI class, collect positions.
--   2. RENDER:  spawn marker pool of TextBlocks in the game's UI canvas
--               (piggybacking UI_Player_C / UI_PlayerLobby_C, same as
--               Speedometer). Per tick, project each POI to local minimap
--               coordinates and reposition pool markers. Unused markers
--               hide (Visibility=Collapsed).
--
-- V1 simplifications (deferred to v0.3+):
--   - Mono-color markers (one shape character per group). Color requires
--     FLinearColor struct manipulation through UE4SS — punt to next pass.
--   - Fixed-north: not heading-rotated. The world axes map directly to
--     minimap X/Y. Easy to read; pure heading-rotated needs control yaw
--     which adds another reflection dance.
--   - No round mask. Square clip via range check.

----------------------------------------------------------------- config
local CONFIG = {
  TICK_INTERVAL_MS  = 100,
  HEARTBEAT_MS      = 5000,
  WORLD_RADIUS_UU   = 5000,
  MINIMAP_RADIUS_PX = 110,
  MINIMAP_CENTER_X  = 1750,
  MINIMAP_CENTER_Y  = 150,
  POOL_PER_GROUP    = 32,
  MARKER_FONT_SIZE  = 18,
  PLAYER_FONT_SIZE  = 22,
  VERBOSE           = true,
  -- Disabled: design is changing to fullscreen overlay piggybacking
  -- the game's TAB map (UI_Map_C, /Game/Interfaces/Map/UI_Map). Need to
  -- extract that widget to learn its world→map coord transform first.
  -- Until then the scanner still runs (heartbeat verifies POI counts)
  -- but no corner widgets are spawned.
  RENDER_ENABLED    = false,
}

local TAG = "MinimapMarker"  -- TextBlock name suffix for cleanup

-- POI groups with the marker glyph used for each. Glyph encodes the
-- category visually since we're not coloring v1.
local POI_GROUPS = {
  { group = "gold-veins",     glyph = "$",  classes = { "BP_MineableRocks_C" } },
  { group = "skull-spawners", glyph = "T",  classes = {
      "BP_Camp_Cryptic_A_C", "BP_Camp_Cryptic_B_C", "BP_Camp_Cryptic_C_C",
      "BP_Camp_Cryptic_D_C", "BP_Camp_Cryptic_E_C", "BP_Camp_Cryptic_F_C",
  } },
  { group = "skulls",         glyph = "x",  classes = {
      "BP_PhysicObject_Skull_Cryptic_C", "BP_PhysicObject_Skull_Cryptic_Lit_C",
  } },
  { group = "souls",          glyph = "o",  classes = {
      "BP_PickUpSoul_C", "SC_PickUpSoul_C",
  } },
  { group = "objectives",     glyph = "*",  classes = {
      "BP_CrypticTotem_C", "BP_CryptincInvocationRing_Ring_C",
      "BP_Area_GoldMagnet_C", "BP_Area_KwartCareer_C", "BP_Area_Cryptic_Totem_C",
  } },
}

local PLAYER_GLYPH = "@"

local GAMEPLAY_PANELS  = { "UI_Player_C", "UI_PlayerLobby_C" }
local PREFERRED_PANELS = { "CanvasPanel_39" }

----------------------------------------------------------------- locals
local pcall, ipairs, pairs = pcall, ipairs, pairs
local string_format, string_find = string.format, string.find
local sqrt, floor = math.sqrt, math.floor

----------------------------------------------------------------- state
local logSampled    = {}
local lastHeartbeat = 0

-- Widget state
local widgetReady     = false
local panelRef        = nil
local stylTextBlock   = nil   -- copied font/color source from game UI
local markerPool      = {}    -- group -> { textblock, slot, used }
local playerMarker    = nil
local playerSlot      = nil
local currentWidgetId = nil
local staleWidgetIds  = {}

local SETUP_RETRY_MS  = 500
local lastSetupTry    = 0

----------------------------------------------------------------- utils
local function logf(fmt, ...)
  local ok, s = pcall(string_format, fmt, ...)
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

local function nowMs() return floor(os.clock() * 1000) end

----------------------------------------------------------- player & POIs
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

local function actorLoc(a)
  local v = nil
  pcall(function() v = a:K2_GetActorLocation() end)
  return v
end

-- Collect all POIs of a group as { {x, y, z}, ... }. Filters CDOs.
local function collectGroupPOIs(group)
  local out = {}
  for _, cls in ipairs(group.classes) do
    local list = nil
    pcall(function() list = FindAllOf(cls) end)
    if list then
      for _, o in ipairs(list) do
        if isValid(o) then
          local isDefault = false
          pcall(function() isDefault = o:IsDefaultObject() end)
          if not isDefault then
            local loc = actorLoc(o)
            if loc then
              out[#out + 1] = { X = loc.X or 0, Y = loc.Y or 0, Z = loc.Z or 0 }
            end
          end
        end
      end
    end
  end
  return out
end

----------------------------------------------------- widget plumbing
-- Cleanup any old MinimapMarker TextBlocks in the world (orphaned across
-- script reloads or level transitions).
local function cleanupOldMarkers()
  local removed = 0
  pcall(function()
    local all = FindAllOf("TextBlock")
    if not all then return end
    for _, tb in ipairs(all) do
      if isValid(tb) then
        local nm = nil
        pcall(function() nm = tb:GetFullName() end)
        if nm and string_find(nm, TAG) then
          pcall(function() tb:RemoveFromParent() end)
          removed = removed + 1
        end
      end
    end
  end)
  if removed > 0 then logf("cleaned up %d old markers", removed) end
end

local function extractWidgetId(fullName)
  return string.match(fullName or "", "(UI_Player[%w_]*_C_%d+)")
end

local function findGameplayPanel()
  local panels = nil
  pcall(function() panels = FindAllOf("CanvasPanel") end)
  if not panels then return nil end
  local fallback = nil
  for _, want in ipairs(GAMEPLAY_PANELS) do
    for _, p in ipairs(panels) do
      if isValid(p) then
        local nm = nil
        pcall(function() nm = p:GetFullName() end)
        if nm and string_find(nm, want) and string_find(nm, "/Engine/Transient") then
          local id = extractWidgetId(nm)
          if not (id and staleWidgetIds[id]) then
            for _, pref in ipairs(PREFERRED_PANELS) do
              if string_find(nm, pref) then return p end
            end
            if not fallback then fallback = p end
          end
        end
      end
    end
  end
  return fallback
end

-- Find a game-side TextBlock to copy font/style from.
local function findStyleSource()
  local all = nil
  pcall(function() all = FindAllOf("TextBlock") end)
  if not all then return nil end
  for _, tb in ipairs(all) do
    if isValid(tb) then
      local nm = nil
      pcall(function() nm = tb:GetFullName() end)
      if nm and string_find(nm, "Text_PlayerHeal") and string_find(nm, "/Engine/Transient") then
        return tb
      end
    end
  end
  return nil
end

local function makeMarker(panel, name, text, fontSize)
  local cls = StaticFindObject("/Script/UMG.TextBlock")
  if not isValid(cls) then return nil end
  local tb = StaticConstructObject(cls, panel, FName(name), 0, 0, nil, false, false, nil)
  if not isValid(tb) then return nil end
  pcall(function() tb:SetText(FText(text)) end)
  pcall(function() tb:SetVisibility(2) end)  -- Collapsed by default
  -- Copy font from game style source if available, override size
  if isValid(stylTextBlock) then
    pcall(function()
      local f = stylTextBlock.Font
      if f then
        f.Size = fontSize
        tb.Font = f
      end
    end)
    pcall(function() tb.ColorAndOpacity = stylTextBlock.ColorAndOpacity end)
    pcall(function()
      tb.ShadowOffset = stylTextBlock.ShadowOffset
      tb.ShadowColorAndOpacity = stylTextBlock.ShadowColorAndOpacity
    end)
  end
  local slot = panel:AddChild(tb)
  if isValid(slot) then
    pcall(function() slot:SetAutoSize(true) end)
    pcall(function() slot:SetZOrder(1000) end)
  end
  return tb, slot
end

local function trySetupWidget()
  local ok, err = pcall(function()
    local panel = findGameplayPanel()
    if not panel then return end
    panelRef = panel
    stylTextBlock = findStyleSource()

    -- Player marker
    if not isValid(playerMarker) then
      local tb, slot = makeMarker(panel, TAG .. "_Player", PLAYER_GLYPH, CONFIG.PLAYER_FONT_SIZE)
      if not tb then return end
      playerMarker, playerSlot = tb, slot
    end

    -- POI marker pool: one set per group
    for _, g in ipairs(POI_GROUPS) do
      if not markerPool[g.group] then
        markerPool[g.group] = {}
      end
      local pool = markerPool[g.group]
      for i = #pool + 1, CONFIG.POOL_PER_GROUP do
        local nm = string_format("%s_%s_%02d", TAG, g.group, i)
        local tb, slot = makeMarker(panel, nm, g.glyph, CONFIG.MARKER_FONT_SIZE)
        if tb and slot then
          pool[i] = { tb = tb, slot = slot }
        end
      end
    end

    widgetReady = true
    currentWidgetId = extractWidgetId(panel:GetFullName())
    logf("widget ready on %s (player + %d marker pools × %d)",
      panel:GetFullName(), #POI_GROUPS, CONFIG.POOL_PER_GROUP)
  end)
  if not ok then logf("setup error: %s", tostring(err)) end
end

local function widgetAlive()
  if not widgetReady or not isValid(panelRef) or not isValid(playerMarker) then
    return false
  end
  return true
end

----------------------------------------------------- render
local function setMarkerVisible(slot, tb, visible, sx, sy)
  if visible then
    pcall(function() slot:SetPosition({ X = sx, Y = sy }) end)
    pcall(function() tb:SetVisibility(0) end)  -- Visible
  else
    pcall(function() tb:SetVisibility(2) end)  -- Collapsed
  end
end

local function renderFrame()
  local player = getPlayer()
  if not player then return end
  local ploc = actorLoc(player)
  if not ploc then return end

  -- Position the player marker at the minimap center (constant).
  if isValid(playerSlot) then
    pcall(function()
      playerSlot:SetPosition({ X = CONFIG.MINIMAP_CENTER_X, Y = CONFIG.MINIMAP_CENTER_Y })
    end)
    pcall(function() playerMarker:SetVisibility(0) end)
  end

  local r = CONFIG.WORLD_RADIUS_UU
  local rPx = CONFIG.MINIMAP_RADIUS_PX

  for _, g in ipairs(POI_GROUPS) do
    local pois = collectGroupPOIs(g)
    local pool = markerPool[g.group]
    local poolN = pool and #pool or 0
    local plotted = 0
    for _, p in ipairs(pois) do
      if plotted >= poolN then break end
      local dx = (p.X or 0) - (ploc.X or 0)
      local dy = (p.Y or 0) - (ploc.Y or 0)
      local dist = sqrt(dx*dx + dy*dy)
      if dist <= r then
        plotted = plotted + 1
        -- Project: world-X → minimap-X (east-right), world-Y → minimap-Y (north-down).
        -- UE world Y+ is east, X+ is north. Map world-X to screen-Y inverted, world-Y to screen-X.
        local sx = CONFIG.MINIMAP_CENTER_X + (dy / r) * rPx
        local sy = CONFIG.MINIMAP_CENTER_Y - (dx / r) * rPx
        local entry = pool[plotted]
        setMarkerVisible(entry.slot, entry.tb, true, sx, sy)
      end
    end
    -- Hide unused markers in this group's pool.
    for i = plotted + 1, poolN do
      local entry = pool[i]
      setMarkerVisible(entry.slot, entry.tb, false, 0, 0)
    end
  end
end

----------------------------------------------------- heartbeat
local function heartbeat()
  if not CONFIG.VERBOSE then return end
  local now = nowMs()
  if (now - lastHeartbeat) < CONFIG.HEARTBEAT_MS then return end
  lastHeartbeat = now
  local parts = {}
  for _, g in ipairs(POI_GROUPS) do
    local n = 0
    for _, cls in ipairs(g.classes) do
      local list = nil
      pcall(function() list = FindAllOf(cls) end)
      if list then
        for _, o in ipairs(list) do
          if isValid(o) then
            local isDefault = false
            pcall(function() isDefault = o:IsDefaultObject() end)
            if not isDefault then n = n + 1 end
          end
        end
      end
    end
    if n > 0 then parts[#parts + 1] = string_format("%s=%d", g.group, n) end
  end
  if #parts > 0 then
    logf("POIs: %s", table.concat(parts, "  "))
  end
end

----------------------------------------------------------------- driver
_G.__Minimap_started   = _G.__Minimap_started or false
_G.__Minimap_renderFn  = renderFrame
_G.__Minimap_heartbeat = heartbeat

local function tryFrame()
  if CONFIG.RENDER_ENABLED then
    if not widgetAlive() then
      widgetReady = false
      panelRef = nil
      playerMarker = nil
      playerSlot = nil
      markerPool = {}
      local now = nowMs()
      if now - lastSetupTry >= SETUP_RETRY_MS then
        lastSetupTry = now
        trySetupWidget()
      end
      return
    end
    pcall(_G.__Minimap_renderFn)
  end
  pcall(_G.__Minimap_heartbeat)
end
_G.__Minimap_tryFrame = tryFrame

if not _G.__Minimap_started then
  _G.__Minimap_started = true
  cleanupOldMarkers()
  ExecuteWithDelay(2000, function()
    LoopAsync(CONFIG.TICK_INTERVAL_MS, function()
      pcall(_G.__Minimap_tryFrame)
      return false
    end)
    logf("ready — radius=%d uu  center=(%d,%d)  poolPerGroup=%d",
      CONFIG.WORLD_RADIUS_UU, CONFIG.MINIMAP_CENTER_X, CONFIG.MINIMAP_CENTER_Y,
      CONFIG.POOL_PER_GROUP)
  end)
else
  logf("ready (Lua reload)")
end

-- Level transition: drop widget refs so we re-create on the new UI panel.
pcall(function()
  RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    pcall(function()
      if currentWidgetId then staleWidgetIds[currentWidgetId] = true end
      cleanupOldMarkers()
      widgetReady = false
      panelRef = nil
      playerMarker = nil
      playerSlot = nil
      markerPool = {}
      stylTextBlock = nil
      lastSetupTry = 0
    end)
  end)
end)
