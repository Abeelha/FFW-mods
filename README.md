# FFW-mods

Personal mod collection for **Far Far West** (UE 5.7 Shipping). Compilation of stuff I'm modifying from existing mods + new ones I'm making. Two pipelines:

1. **UE4SS Lua mods** — runtime-loaded scripts under `mods/`. Hot-reload via `Ctrl+R` in the UE4SS console.
2. **`.pak` Blueprint mods** — cooked Blueprint patches. Build/edit with `tools/retoc.exe` + `tools/UAssetGUI.exe` and drop into `Content/Paks/Mods/`.

## My mods

### `mods/FFW_Cheats/` — native cheat menu spawner
Press **INSERT** in-game to toggle the developer `UI_CheatMenu_C` widget that ships in the cooked build but is never instantiated in retail. Free instant access to godmode / give-item / teleport / etc. without rebuilding any UI.

- Companion required: `CheatManagerEnablerMod : 1` in `mods.txt` (otherwise the widget's buttons no-op).
- No keybind collisions: only uses `INSERT`.

### `mods/BHopDash/` — auto-bunnyhop dash
Lua dash-based bhop. **Hold `LeftShift` while moving on ground → `F_Dash` fires every game tick**, chaining naturally. No keybind, no toggle, always on. Coexists cleanly with Speedometer (F6/F7/F8) and DPSMeter (F7).

- Hooks `BP_Player_C:ReceiveTick`, polls `IsInputKeyDown(LeftShift)` + `CharacterMovement:IsMovingOnGround()`, refills cooldown every tick so the game can't gate the dash.
- Resilient: 500 ms retry loop re-registers the hook until the player BP is loaded.
- Nexus release: https://www.nexusmods.com/farfarwest/mods/39 (by me, Abeelha)
- Inspired by Unconscious66's original jump-based **BHopMod**: https://www.nexusmods.com/farfarwest/mods/15

## Third-party paks installed

Located under `<game>/Content/Paks/Mods/`:
- `AutoGrabber_P.pak` — by **GoldBl4d3**, auto-loots nearby pickups. Adds `_Mods/Mod_2/Mod_2` (BP) + `PGE_AutoGrab_Info` (config DataAsset). https://www.nexusmods.com/farfarwest/mods/34
- `ModHub_P.pak` — by **GoldBl4d3**, in-game mod manager UI. **Required dependency for any pak mod that registers itself via the `RogueHub` system** (AutoGrabber depends on it). https://www.nexusmods.com/farfarwest/mods/16
- `WhitePrimaryPickup_P.pak` — visual reskin of `GPE/BP_AmmoBox` (primary ammo) for higher visibility.
- `PurpleUtilityPickup_P.pak` — visual reskin of `GPE/BP_AmmoBox_Utility`.

## In progress — AutoGrabberGate

Make AutoGrabber smart: only pick up ammo when current ≤ 50 % of max, only pick up utility when current count = 0 (max 3). Avoids wasting pickups during boss fights. Blueprint inspection in `extracted/AutoGrabber/` and `extracted/Pickups/`. Likely shipped as a Lua hook, not a pak rebuild.

## Tooling (`tools/`)

| Tool | Purpose |
|------|---------|
| `retoc.exe` | Convert iostore (`.ucas`/`.utoc`) ↔ legacy `.pak`. UE 5.7 support. |
| `UAssetGUI.exe` | Edit legacy `.uasset`/`.uexp` Blueprint files. |
| `FModel.exe` | Browse pak contents visually. |
| `FarFarWest.usmap` | Mappings file required for proper deserialization in Fmodel/UAssetGUI. |

**AES key:** `0xDD5543BCC9C387A03DEADD72473D6A2EAF491AF88FC47365EE963F8AFE16B2D9`

Reference command (extract a pak to legacy assets):
```powershell
.\tools\retoc.exe -a 0xDD5543BCC9C387A03DEADD72473D6A2EAF491AF88FC47365EE963F8AFE16B2D9 `
  to-legacy --version UE5_7 `
  "<staging dir with global.utoc + target_P.utoc>" `
  "<output legacy dir>"
```
**Important:** retoc needs `global.utoc` (base game script objects) co-located with the target pak. Stage both in a temp dir, then point retoc at that dir. Pointing at the live `Paks/Mods/` alone fails with `ScriptObjects not found`.

## Repo layout

```
FFW-mods/
├── CLAUDE.md / GEMINI.md / KIMI.md   # AI agent project context (kept in sync)
├── README.md
├── mods/                             # UE4SS Lua mods (source of truth)
│   ├── BHopDash/Scripts/main.lua
│   └── FFW_Cheats/Scripts/main.lua
├── docs/asset-editing.md             # pak modding cheat sheet
├── tools/                            # retoc, UAssetGUI, FModel, mappings
├── extracted/                        # working dir for pak inspection
├── mods.txt                          # UE4SS load list (mirrors game folder)
└── mods-zips.zip
```

## Live target paths

UE4SS reads from the game folder, not this repo. Edits here must be synced:
- Lua: `<game>\Binaries\Win64\ue4ss\Mods\<ModName>\Scripts\main.lua`
- Pak: `<game>\Content\Paks\Mods\<ModName>_P.pak` (+ `.ucas` / `.utoc`)

## Keybinds claimed (don't double-bind)

| Key | Mod | Action |
|-----|-----|--------|
| F6 | Speedometer | cycle layout |
| F7 | Speedometer / DPSMeter | toggle (shared, accepted) |
| F8 | Speedometer | cycle units |
| INS | FFW_Cheats | toggle native cheat menu |

Free F-keys: F1–F5, F9–F12. BHopDash deliberately uses no keybinds.

## Credits

| Mod | Author | Nexus |
|-----|--------|-------|
| BHopDash (this repo, dash-based) | Abeelha (me) | https://www.nexusmods.com/farfarwest/mods/39 |
| BHopMod (original jump-based, predecessor) | Unconscious66 | https://www.nexusmods.com/farfarwest/mods/15 |
| AutoGrabber | GoldBl4d3 | https://www.nexusmods.com/farfarwest/mods/34 |
| ModHub (pak-mod loader/manager) | GoldBl4d3 | https://www.nexusmods.com/farfarwest/mods/16 |

Thanks to `Wr4Th_0f_D0g` for the asset-editing notes (`docs/asset-editing.md`) and to the wider FFW modding Discord.

## Resources

- UE4SS for FFW (Nexus): https://www.nexusmods.com/farfarwest/mods/2
- UE4SS AOB sigs (UE 5.7): https://github.com/anro772/ue4ss-far-far-west
- FModel: https://fmodel.app/
- retoc: https://github.com/trumank/retoc/releases
- UAssetGUI: https://github.com/atenfyr/UAssetGUI/releases
