local UEHelpers = require("UEHelpers")

local _spawnedCheatMenu = nil

local function printSafe(msg)
    pcall(function() print(msg) end)
end

local function ToggleNativeCheatMenu()
    ExecuteInGameThread(function()
        local menu = nil
        if _spawnedCheatMenu and _spawnedCheatMenu:IsValid() then
            menu = _spawnedCheatMenu
        else
            local widgets = FindAllOf("UI_CheatMenu_C")
            if widgets then
                for _, w in ipairs(widgets) do
                    local isDef = false
                    pcall(function() isDef = w:IsDefaultObject() end)
                    if w:IsValid() and not isDef then
                        menu = w
                        break
                    end
                end
            end
        end
        
        local pc = UEHelpers.GetPlayerController()
        
        if not menu then
            local WidgetClass = StaticFindObject("/Game/Interfaces/UI_CheatMenu.UI_CheatMenu_C")
            if not WidgetClass or not WidgetClass:IsValid() then
                printSafe("[FFW] Class UI_CheatMenu_C not found in memory. You must be in-game.")
                return
            end
            
            local WidgetLib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
            if not WidgetLib or not pc or not pc:IsValid() then
                printSafe("[FFW] Cannot spawn widget: Missing PlayerController or WidgetBlueprintLibrary.")
                return
            end
            
            local ok, newWidget = pcall(function()
                return WidgetLib:Create(pc, WidgetClass, pc)
            end)
            
            if ok and newWidget and newWidget:IsValid() then
                menu = newWidget
                _spawnedCheatMenu = newWidget
                printSafe("[FFW] Successfully spawned UI_CheatMenu_C instance.")
            else
                printSafe("[FFW] Failed to spawn UI_CheatMenu_C: " .. tostring(newWidget))
                return
            end
        end
        
        local vis = 2
        pcall(function() vis = menu:GetVisibility() end)
        
        if vis == 0 then
            pcall(function() menu:SetVisibility(2) end)
            printSafe("[FFW] Native Cheat Menu Hidden.")
            if pc and pc:IsValid() then
                pc.bShowMouseCursor = false
            end
        else
            pcall(function()
                if not menu:IsInViewport() then
                    menu:AddToViewport(9999)
                end
            end)
            pcall(function() menu:SetVisibility(0) end)
            printSafe("[FFW] Native Cheat Menu Shown.")
            if pc and pc:IsValid() then
                pc.bShowMouseCursor = true
            end
        end
    end)
end

RegisterKeyBind(Key.INS, ToggleNativeCheatMenu)

print("[FFW_Cheats] Native Cheat Menu Spawner Ready. Press INSERT.")
