-- FFW_Dump — temporary recon mod for AutoGrabberGate.
-- F9: dump BP_Player_C + nearest BP_AmmoBox_C / BP_AmmoBox_Utility_C
--     + Mod_2_C (AutoGrabber) properties to UE4SS.log.
-- After we have property names, this mod gets removed.

local AMMO_HINTS = {
  "ammo", "mag", "clip", "reserve", "bullet", "magazine",
  "utility", "grenade", "throwable", "charge", "use", "consum",
  "reload", "primary", "secondary", "weapon", "current", "max",
  "count", "amount", "stack", "qty",
}

local function lower(s) return string.lower(s or "") end

local function looksInteresting(name)
  local n = lower(name)
  for _, hint in ipairs(AMMO_HINTS) do
    if string.find(n, hint, 1, true) then return true end
  end
  return false
end

local function safeFullName(o)
  local s = "?"
  pcall(function() s = o:GetFullName() end)
  return s
end

local function readVal(obj, name)
  local val = "<unread>"
  pcall(function()
    local v = obj[name]
    local t = type(v)
    if t == "number" or t == "boolean" then
      val = tostring(v)
    elseif t == "string" then
      val = v
    elseif t == "userdata" then
      if v.IsValid and v:IsValid() then
        val = "<obj " .. safeFullName(v) .. ">"
      else
        val = "<userdata>"
      end
    elseif t == "nil" then
      val = "nil"
    else
      val = "<" .. t .. ">"
    end
  end)
  return val
end

local function dumpProps(obj, label, onlyInteresting)
  if not obj or not obj:IsValid() then
    print("[FFW_Dump] " .. label .. ": invalid/missing")
    return
  end
  local cls = obj:GetClass()
  print("[FFW_Dump] === " .. label .. " :: " .. safeFullName(cls) .. " ===")

  local total, shown = 0, 0
  local ok = pcall(function()
    cls:ForEachProperty(function(prop)
      total = total + 1
      local name = prop:GetFName():ToString()
      local typeName = prop:GetClass():GetFName():ToString()
      if (not onlyInteresting) or looksInteresting(name) then
        shown = shown + 1
        print("[FFW_Dump]   " .. typeName .. "  " .. name .. " = " .. readVal(obj, name))
      end
    end)
  end)
  if not ok then
    print("[FFW_Dump]   ForEachProperty failed on " .. label)
  end
  print("[FFW_Dump]   (" .. shown .. "/" .. total .. " properties shown)")
end

local function dumpFunctions(obj, label, filter)
  if not obj or not obj:IsValid() then return end
  local cls = obj:GetClass()
  print("[FFW_Dump] --- " .. label .. " functions matching '" .. (filter or "*") .. "' ---")
  pcall(function()
    cls:ForEachFunction(function(fn)
      local n = fn:GetFName():ToString()
      if (not filter) or string.find(lower(n), lower(filter), 1, true) then
        print("[FFW_Dump]   fn " .. n)
      end
    end)
  end)
end

local function dumpAll()
  ExecuteInGameThread(function()
    print("[FFW_Dump] ====== begin dump ======")

    local p = FindFirstOf("BP_Player_C")
    dumpProps(p, "BP_Player_C (filtered)", true)
    dumpFunctions(p, "BP_Player_C", "ammo")
    dumpFunctions(p, "BP_Player_C", "util")
    dumpFunctions(p, "BP_Player_C", "interact")
    dumpFunctions(p, "BP_Player_C", "consum")

    local boxes = FindAllOf("BP_AmmoBox_C")
    if boxes and boxes[1] then
      dumpProps(boxes[1], "BP_AmmoBox_C[0]", false)
    else
      print("[FFW_Dump] no BP_AmmoBox_C in world")
    end

    local utilBoxes = FindAllOf("BP_AmmoBox_Utility_C")
    if utilBoxes and utilBoxes[1] then
      dumpProps(utilBoxes[1], "BP_AmmoBox_Utility_C[0]", false)
    else
      print("[FFW_Dump] no BP_AmmoBox_Utility_C in world")
    end

    local grabber = FindFirstOf("Mod_2_C")
    if grabber and grabber:IsValid() then
      dumpProps(grabber, "Mod_2_C (AutoGrabber)", false)
      local pi = grabber.PastInteractions
      if pi then
        local n = 0
        pcall(function() n = #pi end)
        print("[FFW_Dump]   PastInteractions length = " .. n)
      end
    else
      print("[FFW_Dump] no Mod_2_C (AutoGrabber not loaded?)")
    end

    print("[FFW_Dump] ====== end dump ======")
  end)
end

RegisterKeyBind(Key.F9, dumpAll)

print("[FFW_Dump] ready. Press F9 in-game (with player + a pickup nearby) to dump.")
