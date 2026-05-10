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
-- Notes:
--   * Hook by full UFunction path (BP overrides don't bind via CPP).
--   * Weak-keyed tracker; despawned rains GC freely.
--   * Single startup log line, no per-rain spam.

----------------------------------------------------------------- config
local CONFIG = {
  IMBUE_DELAY_MS = 250,   -- post-BeginPlay grace for replication settle
}

----------------------------------------------------------------- locals
local pcall = pcall

local HOOK_BEGINPLAY =
  "/Game/Spells/Assets/Acid/BP_Rain_Acid.BP_Rain_Acid_C:ReceiveBeginPlay"

local imbued = setmetatable({}, { __mode = "k" })

----------------------------------------------------------------- imbue
local function imbue(rain)
  if not rain or imbued[rain] then return end

  local alive = false
  pcall(function() alive = rain:IsValid() end)
  if not alive then return end

  local already = false
  pcall(function() already = rain.isElec end)
  if already then imbued[rain] = true; return end

  local ok = pcall(function()
    rain.isElec = true
    rain:OnRep_isElec()
  end)
  if ok then imbued[rain] = true end
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
