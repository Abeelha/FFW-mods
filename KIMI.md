# FFW-mods — Kimi project notes

Consolidation repo for all my Far Far West (UE 5.7 Shipping) mods. Two pipelines live side by side:

1. **UE4SS Lua mods** — runtime-loaded Lua under `mods/<ModName>/Scripts/main.lua`. Fast iteration, no rebuild.
2. **`.pak` Blueprint mods** — cooked content patches loaded from `Content/Paks/Mods/`. Required when behavior lives in a BP that Lua can't reach (or when the mod is third-party and we don't have source).

## Repo layout

```
FFW-mods/
├── mods/                 # UE4SS Lua mods (source of truth, version controlled)
│   ├── BHopDash/         # auto-bhop on hold-LeftShift, no keybinds
│   └── FFW_Cheats/       # INSERT spawns native UI_CheatMenu_C
├── docs/
│   └── asset-editing.md  # Wr4Th_0f_D0g's pak-modding cheat sheet (Fmodel/retoc/UAssetGUI + AES key)
├── mods.txt              # UE4SS load list (mirrors game folder)
└── mods-zips.zip         # third-party packaged mods archive
```

**Live target:** `C:\Program Files (x86)\Steam\steamapps\common\FarFarWest\FarFarWest\Binaries\Win64\ue4ss\Mods\`
**Pak target:** `C:\Program Files (x86)\Steam\steamapps\common\FarFarWest\FarFarWest\Content\Paks\Mods\`

Manual sync. Edit here → copy → reload.

## Installed paks (third-party)

- `AutoGrabber_P.pak` — GoldBl4d3. https://www.nexusmods.com/farfarwest/mods/34
- `ModHub_P.pak` — GoldBl4d3, **dependency** for RogueHub-registered pak mods. https://www.nexusmods.com/farfarwest/mods/16
- `PurpleUtilityPickup_P.pak` / `WhitePrimaryPickup_P.pak` — visual reskins.

Modify via Lua hook (preferred) or pak rebuild.

## Nexus / credits

| Mod | Author | Nexus |
|-----|--------|-------|
| BHopDash | Abeelha | https://www.nexusmods.com/farfarwest/mods/39 |
| BHopMod (original) | Unconscious66 | https://www.nexusmods.com/farfarwest/mods/15 |
| AutoGrabber | GoldBl4d3 | https://www.nexusmods.com/farfarwest/mods/34 |
| ModHub | GoldBl4d3 | https://www.nexusmods.com/farfarwest/mods/16 |

## Pak modding stack

Tools: Fmodel, retoc, UAssetGUI experimental.
AES key: `0xDD5543BCC9C387A03DEADD72473D6A2EAF491AF88FC47365EE963F8AFE16B2D9`.
See `docs/asset-editing.md`.

## UE4SS Lua load-bearing quirks

- No `cls.Children` walk (TArray OOR). Use `Reflection:GetFunctions()`.
- No `CPPHooking` for BP overrides. Use `RegisterHook` with string path.
- Wrap hook registration in 500ms retry.
- `pcall` everything.
- `ExecuteInGameThread` for game-thread work.
- Filter `IsDefaultObject()` from `FindAllOf`.

## Keybind registry

| Key | Mod |
|-----|-----|
| F6/F7/F8 | Speedometer (+ F7 DPSMeter) |
| INS | FFW_Cheats |

Free: F1–F5, F9–F12. BHopDash keybind-free.

## Preferences

- Terse, action-first. Caveman OK.
- On failure: iterate, don't ask.
- No AI co-author commit trailers.
- Verify API signatures against working code.

## AI sync rule

`CLAUDE.md`, `GEMINI.md`, `KIMI.md` must stay synced.

## Active work

AutoGrabber threshold gate — `mods/AutoGrabberGate/` (when started).
