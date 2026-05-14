-- AcidElec — auto-electrify Acid Rain on spawn.
--
-- BP_Rain_Acid_C exposes replicated bool `isElec` (RepNotify OnRep_isElec).
-- Game's normal flow: cast Acid Rain → cast Elec spell (ThunderStrike)
-- into rain area → game flips isElec=true → lightning strikes spawn in
-- rain zone, Niagara swaps to NS_AcidRain_Elec. We skip the middleman.
--
-- Recon: F_ReceiveBuff is NOT the elec imbue path (same as wisp). The
-- setter lives in BP graph bytecode, mirrored from Lua via direct
-- property write + manual OnRep invoke.
--
-- Multiplayer rules (added after coop testing 2026-05-10):
--   * `isElec` is server-authoritative (replicated, RepNotify). A client
--     write is wiped on next replication tick. Therefore: imbue ONLY
--     when local machine has authority over the rain (i.e. host).
--   * Imbue ONLY rains owned by the local player. Otherwise host imbues
--     teammates' rains, which:
--       - changes a non-consenting player's spell behavior;
--       - desyncs combo state for teammates;
--       - was reported as "teammate's rain bugs mine".
--   * As pure-client: silently no-op (no server-side mirror without an
--     RPC; out of reach from UE4SS Lua).
--
-- Notes:
--   * Hook by full UFunction path (BP overrides don't bind via CPP).
--   * Weak-keyed tracker; despawned rains GC freely.
--   * Single startup log line, no per-rain spam.

----------------------------------------------------------------- config
local CONFIG = {
  IMBUE_DELAY_MS = 250,   -- post-BeginPlay grace for replication settle
}

----------------------------------------------------------------- locals
local pcall, ipairs = pcall, ipairs

local HOOK_BEGINPLAY =
  "/Game/Spells/Assets/Acid/BP_Rain_Acid.BP_Rain_Acid_C:ReceiveBeginPlay"

local imbued = setmetatable({}, { __mode = "k" })

----------------------------------------------------------------- helpers
local function logf(fmt, ...)
  local ok, s = pcall(string.format, fmt, ...)
  if not ok then s = fmt end
  pcall(print, "[AcidElec] " .. s)
end

local function isValid(o)
  if not o then return false end
  local v = false
  pcall(function() v = o.IsValid and o:IsValid() or false end)
  return v
end

-- Local PlayerController (the one IsLocalController()==true on this
-- machine). In MP, FindFirstOf("PlayerController") can return a remote
-- PC proxy, which is the entire MP-bug root cause for owner checks.
local function getLocalPC()
  local pcs = nil
  pcall(function() pcs = FindAllOf("PlayerController") end)
  if not pcs then return nil end
  for _, pc in ipairs(pcs) do
    local ok, isLocal = pcall(function() return pc:IsLocalController() end)
    if ok and isLocal then return pc end
  end
  return nil
end

local function getLocalPawn()
  local pc = getLocalPC()
  if not isValid(pc) then return nil end
  local pawn = nil
  pcall(function() pawn = pc.Pawn end)
  return isValid(pawn) and pawn or nil
end

local function isOwnedByLocal(rain)
  local localPC   = getLocalPC()
  local localPawn = getLocalPawn()
  if not (localPC or localPawn) then return false end
  local owner = nil
  pcall(function() owner = rain.owner end)
  local instigator = nil
  pcall(function() instigator = rain.Instigator end)
  if owner and (owner == localPC or owner == localPawn) then return true end
  if instigator and (instigator == localPawn or instigator == localPC) then
    return true
  end
  return false
end

local function hasAuthority(rain)
  local ok, has = pcall(function() return rain:HasAuthority() end)
  return ok and has or false
end

----------------------------------------------------------------- imbue
local function describeRain(rain)
  local s = "?"
  pcall(function() if rain and rain.GetFullName then s = rain:GetFullName() end end)
  return s
end

local function imbue(rain)
  if not rain or imbued[rain] then return end
  if not isValid(rain) then return end

  local name = describeRain(rain)
  local auth = hasAuthority(rain)
  local owned = isOwnedByLocal(rain)
  local owner = nil; pcall(function() owner = rain.owner end)
  local instigator = nil; pcall(function() instigator = rain.Instigator end)
  local localPC = getLocalPC()
  local localPawn = getLocalPawn()
  logf("[hook] rain=%s auth=%s owned=%s owner=%s instig=%s localPC=%s localPawn=%s",
    name, tostring(auth), tostring(owned),
    tostring(owner), tostring(instigator),
    tostring(localPC), tostring(localPawn))

  -- MP gate 1: only the authoritative machine can flip a replicated bool.
  -- As pure-client this is a no-op (server overrides on next tick).
  if not auth then
    logf("[skip] no authority (client) — server-authoritative property")
    return
  end

  -- MP gate 2: only act on rains the local player cast. Skip teammates'.
  if not owned then
    logf("[skip] not owned by local player")
    return
  end

  local already = false
  pcall(function() already = rain.isElec end)
  if already then
    imbued[rain] = true
    logf("[skip] already elec")
    return
  end

  local ok, err = pcall(function()
    rain.isElec = true
    rain:OnRep_isElec()
  end)
  if ok then
    imbued[rain] = true
    logf("[apply] imbued %s", name)
  else
    logf("[error] imbue failed: %s", tostring(err))
  end
end

----------------------------------------------------------------- bootstrap
_G.__AcidElec_started = _G.__AcidElec_started or false
_G.__AcidElec_bound   = _G.__AcidElec_bound   or false

local function bindHook()
  if _G.__AcidElec_bound then return true end
  local ok = pcall(function()
    RegisterHook(HOOK_BEGINPLAY, function(self)
      local s = self:get()
      ExecuteWithDelay(CONFIG.IMBUE_DELAY_MS, function()
        ExecuteInGameThread(function() imbue(s) end)
      end)
    end)
  end)
  if ok then
    _G.__AcidElec_bound = true
    pcall(print, "[AcidElec] ready")
    return true
  end
  return false
end

if not _G.__AcidElec_started then
  _G.__AcidElec_started = true
  ExecuteWithDelay(1000, function()
    local tries = 0
    LoopAsync(500, function()
      tries = tries + 1
      if bindHook() then return true end
      if tries > 60 then
        pcall(print, "[AcidElec] hook bind failed after 30s")
        return true
      end
      return false
    end)
  end)
end
