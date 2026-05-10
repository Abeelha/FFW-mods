-- WispElec — auto-supercharge Fire Wisp on spawn.
--
-- BP_FireWisp_C exposes a replicated bool `isSupercharged` (RepNotify
-- OnRep_isSupercharged). The game's normal flow flips it when the
-- player hits the wisp's target with an electric source. We skip the
-- middleman: on BeginPlay, set the bool and invoke OnRep so VFX +
-- damage tier flip on frame 1. Idempotent — already-supercharged
-- wisps (e.g. player still casts elec manually) are ignored.
--
-- Notes:
--   * Hook by full UFunction path (BP overrides don't bind via CPP).
--   * Weak-keyed tracker; despawned wisps GC freely.
--   * Single startup log line, no per-wisp spam.

----------------------------------------------------------------- config
local CONFIG = {
  IMBUE_DELAY_MS = 250,   -- post-BeginPlay grace for replication settle
}

----------------------------------------------------------------- locals
local pcall = pcall

local HOOK_BEGINPLAY =
  "/Game/Spells/Assets/Fire/BP_FireWisp.BP_FireWisp_C:ReceiveBeginPlay"

local imbued = setmetatable({}, { __mode = "k" })

----------------------------------------------------------------- imbue
local function imbue(wisp)
  if not wisp or imbued[wisp] then return end

  local alive = false
  pcall(function() alive = wisp:IsValid() end)
  if not alive then return end

  local already = false
  pcall(function() already = wisp.isSupercharged end)
  if already then imbued[wisp] = true; return end

  local ok = pcall(function()
    wisp.isSupercharged = true
    wisp:OnRep_isSupercharged()
  end)
  if ok then imbued[wisp] = true end
end

----------------------------------------------------------------- bootstrap
_G.__WispElec_started = _G.__WispElec_started or false
_G.__WispElec_bound   = _G.__WispElec_bound   or false

local function bindHook()
  if _G.__WispElec_bound then return true end
  local ok = pcall(function()
    RegisterHook(HOOK_BEGINPLAY, function(self)
      local s = self:get()
      ExecuteWithDelay(CONFIG.IMBUE_DELAY_MS, function()
        ExecuteInGameThread(function() imbue(s) end)
      end)
    end)
  end)
  if ok then
    _G.__WispElec_bound = true
    pcall(print, "[WispElec] ready")
    return true
  end
  return false
end

if not _G.__WispElec_started then
  _G.__WispElec_started = true
  ExecuteWithDelay(1000, function()
    local tries = 0
    LoopAsync(500, function()
      tries = tries + 1
      if bindHook() then return true end
      if tries > 60 then
        pcall(print, "[WispElec] hook bind failed after 30s")
        return true
      end
      return false
    end)
  end)
end
