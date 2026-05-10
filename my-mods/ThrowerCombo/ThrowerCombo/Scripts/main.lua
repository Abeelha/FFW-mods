-- ThrowerCombo — auto-imbue Fire + Elec on Acid Thrower targets so
-- both combo micro-explosions trigger every Thrower tick.
--
-- Recon (logger-phase confirmed):
--   1. BUFF_ACID re-applies at ~5Hz during Thrower spray on each target.
--   2. Game's combo check (in UO_Buff_Acid tick bytecode) spawns a
--      BP_Explosion with element=fire/elec when target has ACID + FIRE
--      or ACID + ELEC at the same time.
--   3. Buffs must be REGISTERED on the target (not just constructed).
--      Game's own apply path: caller -> target:F_ReceiveBuff(owner, loc,
--      UO_Buff_<Element>_C). The actor's F_ReceiveBuff implementation
--      handles list-registration + F_StartBuff chain + replication.
--      Raw StaticConstructObject(buff) + F_StartBuff_Everyone() doesn't
--      register with the target's buff list, so the combo check misses it.
--
-- Strategy: hook UO_Buff_Acid_C:F_StartBuff_Everyone. On each fire:
--   - Read self.attachedActor (target) + self.owner (player).
--   - Throttle per-target so we don't hammer F_ReceiveBuff every tick.
--   - target:F_ReceiveBuff(owner, target.location, UO_Buff_Fire_C)
--   - target:F_ReceiveBuff(owner, target.location, UO_Buff_Elec_C)
--
-- Effect: target always has ACID + FIRE + ELEC during a Thrower cast
-- -> game's combo handler spawns BOTH element explosions every tick.

----------------------------------------------------------------- config
local CONFIG = {
  IMBUE_COOLDOWN_S = 0.4,   -- per-target throttle (sec)
}

----------------------------------------------------------------- locals
local pcall = pcall

local HOOK_ACID = "/Game/Spells/Buffs/UO_Buff_Acid.UO_Buff_Acid_C:F_StartBuff_Everyone"
local CLS_FIRE  = "/Game/Spells/Buffs/UO_Buff_Fire.UO_Buff_Fire_C"
local CLS_ELEC  = "/Game/Spells/Buffs/UO_Buff_Elec.UO_Buff_Elec_C"

local fireCls   = nil
local elecCls   = nil
local lastImbue = setmetatable({}, { __mode = "k" })

----------------------------------------------------------------- utils
local function logf(fmt, ...)
  local ok, s = pcall(string.format, fmt, ...)
  if not ok then s = fmt end
  pcall(print, "[ThrowerCombo] " .. s)
end

local function isValid(o)
  if not o then return false end
  local v = false
  pcall(function() v = o.IsValid and o:IsValid() or false end)
  return v
end

local function ensureClasses()
  if not fireCls then
    local ok, c = pcall(StaticFindObject, CLS_FIRE)
    if ok and c then fireCls = c end
  end
  if not elecCls then
    local ok, c = pcall(StaticFindObject, CLS_ELEC)
    if ok and c then elecCls = c end
  end
  return fireCls and elecCls
end

----------------------------------------------------------------- hook
local function onAcidApplied(self)
  local acid = nil
  pcall(function() acid = self:get() end)
  if not isValid(acid) then return end

  local target, owner = nil, nil
  pcall(function() target = acid.attachedActor end)
  pcall(function() owner  = acid.owner end)
  if not isValid(target) then return end

  local now = os.clock()
  local last = lastImbue[target]
  if last and (now - last) < CONFIG.IMBUE_COOLDOWN_S then return end

  if not ensureClasses() then return end
  lastImbue[target] = now

  local loc = nil
  pcall(function() loc = target:K2_GetActorLocation() end)
  if not loc then loc = { X = 0, Y = 0, Z = 0 } end

  -- Game's canonical buff-apply path. The target actor's F_ReceiveBuff
  -- implementation (from BP_Interface) registers the buff on its buff
  -- list, kicks off lifecycle, and triggers any combo checks.
  pcall(function() target:F_ReceiveBuff(owner, loc, fireCls) end)
  pcall(function() target:F_ReceiveBuff(owner, loc, elecCls) end)
end

----------------------------------------------------------------- bootstrap
_G.__ThrowerCombo_started = _G.__ThrowerCombo_started or false
_G.__ThrowerCombo_bound   = _G.__ThrowerCombo_bound   or false

local function bindHook()
  if _G.__ThrowerCombo_bound then return true end
  local ok = pcall(function() RegisterHook(HOOK_ACID, onAcidApplied) end)
  if ok then
    _G.__ThrowerCombo_bound = true
    logf("ready")
    return true
  end
  return false
end

if not _G.__ThrowerCombo_started then
  _G.__ThrowerCombo_started = true
  ExecuteWithDelay(1000, function()
    local tries = 0
    LoopAsync(500, function()
      tries = tries + 1
      if bindHook() then return true end
      if tries > 60 then
        logf("hook bind failed after 30s")
        return true
      end
      return false
    end)
  end)
end
