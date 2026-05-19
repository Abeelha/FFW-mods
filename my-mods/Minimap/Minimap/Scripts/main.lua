-- Minimap — corner mirror of the game's native UI_Map widget.
--
-- Approach: do NOT construct a second UI_Map_C — that crashes because the
-- widget's BP construction script registers itself globally as "the
-- active map" and a second instance corrupts state.
--
-- Instead: find the EXISTING UI_Map_C the game already creates (normally
-- shown only when TAB is held), and push it to a corner with a small
-- render scale on every tick. The game's own TAB handler can override
-- our values back to fullscreen when the user opens it. When TAB is
-- released the game restores its hidden/closed state — we re-assert
-- corner-mini next tick.
--
-- Lobby is excluded by checking the world / context: UI_Map has no map
-- data in the home town and reading it crashes. We only act once a
-- mission UI_Player_C panel exists in the engine.

----------------------------------------------------------------- config
local CONFIG = {
  TICK_INTERVAL_MS = 200,
  HEARTBEAT_MS     = 5000,

  ANCHOR_X         = 1660,
  ANCHOR_Y         = 60,
  RENDER_SCALE     = 0.30,

  VERBOSE          = true,
}

----------------------------------------------------------------- locals
local pcall, ipairs = pcall, ipairs
local string_format, string_find = string.format, string.find
local floor = math.floor

----------------------------------------------------------------- state
local logSampled    = {}
local lastHeartbeat = 0

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

------------------------------------------------- mission detection
-- Only operate while a mission HUD panel exists in the engine. Lobby
-- has UI_PlayerLobby_C only — the map widget there has no data.
local function inMission()
  local panels = nil
  pcall(function() panels = FindAllOf("CanvasPanel") end)
  if not panels then return false end
  for _, p in ipairs(panels) do
    if isValid(p) then
      local nm = nil
      pcall(function() nm = p:GetFullName() end)
      if nm
         and string_find(nm, "UI_Player_C")
         and not string_find(nm, "UI_PlayerLobby_C")
         and string_find(nm, "/Engine/Transient") then
        return true
      end
    end
  end
  return false
end

------------------------------------------------- find existing UI_Map
local function findGameMap()
  local maps = nil
  pcall(function() maps = FindAllOf("UI_Map_C") end)
  if not maps then return nil end
  for _, m in ipairs(maps) do
    if isValid(m) then
      local isDefault = false
      pcall(function() isDefault = m:IsDefaultObject() end)
      if not isDefault then
        return m
      end
    end
  end
  return nil
end

------------------------------------------------- apply mini transform
-- Push the existing map widget into a corner-sized mini. The game's TAB
-- handler can flip these per-frame when the user opens the map.
--
-- AddToViewport is required: a UMG widget that isn't in the viewport
-- doesn't render even if Visibility is set. We add at a low Z-order so
-- when the user presses TAB the game can re-add at fullscreen Z above us.
local addedToViewport = false
local function applyMini(m)
  if not addedToViewport then
    local ok = pcall(function() m:AddToViewport(50) end)
    if ok then
      addedToViewport = true
      logf("AddToViewport ok")
    end
  end
  pcall(function() m:SetVisibility(0) end)  -- Visible

  -- Pivot top-right of widget so render-scale shrinks toward that corner.
  pcall(function()
    m:SetRenderTransformPivot({ X = 1.0, Y = 0.0 })
  end)
  pcall(function()
    m:SetRenderScale({ X = CONFIG.RENDER_SCALE, Y = CONFIG.RENDER_SCALE })
  end)
  -- Anchor widget's slot to top-right of viewport, then offset inward.
  pcall(function()
    m:SetAnchorsInViewport({
      Minimum = { X = 1.0, Y = 0.0 },
      Maximum = { X = 1.0, Y = 0.0 },
    })
  end)
  pcall(function()
    m:SetAlignmentInViewport({ X = 1.0, Y = 0.0 })
  end)
  pcall(function()
    m:SetPositionInViewport({ X = -10, Y = 10 }, false)
  end)
end

----------------------------------------------------------------- driver
_G.__Minimap_started = _G.__Minimap_started or false

local function tick()
  if not inMission() then return end
  local m = findGameMap()
  if not isValid(m) then
    once("no-map", function() logf("UI_Map_C not present yet") end)
    return
  end
  applyMini(m)

  if CONFIG.VERBOSE then
    local now = nowMs()
    if (now - lastHeartbeat) >= CONFIG.HEARTBEAT_MS then
      lastHeartbeat = now
      logf("mini active (scale=%.2f anchor=%d,%d)",
        CONFIG.RENDER_SCALE, CONFIG.ANCHOR_X, CONFIG.ANCHOR_Y)
    end
  end
end
_G.__Minimap_tick = tick

if not _G.__Minimap_started then
  _G.__Minimap_started = true
  ExecuteWithDelay(2000, function()
    LoopAsync(CONFIG.TICK_INTERVAL_MS, function()
      pcall(_G.__Minimap_tick)
      return false
    end)
    logf("ready — anchor=(%d,%d) scale=%.2f (mission-only, hijack-existing)",
      CONFIG.ANCHOR_X, CONFIG.ANCHOR_Y, CONFIG.RENDER_SCALE)
  end)
else
  logf("ready (Lua reload)")
end
