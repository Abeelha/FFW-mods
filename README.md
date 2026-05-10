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
Lua dash-based bhop. **Hold `LeftShift` while moving on ground → `F_Dash` polls every game tick**, chaining naturally. No keybind, no toggle, always on. Coexists cleanly with Speedometer (F6/F7/F8) and DPSMeter (F7).

- Hooks `BP_Player_C:ReceiveTick`, polls `IsInputKeyDown(LeftShift)` + `CharacterMovement:IsMovingOnGround()`. F_Dash itself is called every tick; `DASH_INTERVAL` gates the COOLDOWN-NUKE pair (`F_DashCooldown` + `F_ResetAndUpdateDash`), not F_Dash, so the snappy feel is preserved while still letting users throttle.
- Config: `DASH_INTERVAL = 0` for spammy original feel; raise to cap dash rate.
- Resilient: 500 ms retry loop re-registers the hook until the player BP is loaded.
- Nexus release: https://www.nexusmods.com/farfarwest/mods/39 (by me, Abeelha)
- Inspired by Unconscious66's original jump-based **BHopMod**: https://www.nexusmods.com/farfarwest/mods/15

### `mods/AutoGrabberGate/` — smart-pickup gate for GoldBl4d3's AutoGrabber
Wraps the third-party `AutoGrabber_P.pak` so it skips pickups you don't need. Primary/secondary ammo boxes stay in world above 50 %; utility (grenade) boxes stay above 0. Implementation toggles per-box `CollisionEnabled` between `QueryAndPhysics` (grabbable) and `PhysicsOnly` (falls/physics but invisible to AutoGrabber's sphere trace). Settle window (3 s) + velocity gate (5 u/s) ensures boxes physics-settle before any decision.

- Source-of-truth: hardcoded BP property hashes against `tools/Output/Exports/FarFarWest/Content/Player/BP_PlayerState.json` (rotate on game patch).
- `FindAllOf("BP_AmmoBox_C")` filtered by exact `classNameOf(box) == className` to prevent subclass double-processing (Spell, Utility, Throw subclasses leak into parent passes and crashed the engine with 5 Hz collision flip-flop).

### `mods/WispElec/` — auto-supercharge Fire Wisp on spawn
Hooks `BP_FireWisp_C:ReceiveBeginPlay`, waits 250 ms for replication, then sets `wisp.isSupercharged = true` + manually invokes `OnRep_isSupercharged()`. Game's own VFX + damage-tier logic flips on frame 1. No need to cast an Elec spell at the wisp's target. Idempotent — skips already-supercharged wisps (e.g. user did the manual combo).

### `mods/AcidElec/` — auto-electrify Acid Rain on spawn
Mirror of WispElec architecture. `BP_Rain_Acid_C` exposes replicated bool `isElec` (RepNotify `OnRep_isElec`). On `ReceiveBeginPlay` → 250 ms grace → `rain.isElec = true` + `rain:OnRep_isElec()`. Lightning auto-strikes inside the rain zone + Niagara swaps to `NS_AcidRain_Elec`. No need to cast a Thunder Strike into the rain.

### `mods/ThrowerCombo/` — auto-imbue Fire + Elec on Acid Thrower targets
Acid Thrower normally needs the target pre-debuffed with Fire OR Elec to trigger combo micro-explosions. This mod removes the prereq by applying both debuffs on every acid tick, so the combo handler in `UO_Buff_Acid` tick bytecode spawns BOTH fire and elec explosions automatically.

- Hooks `UO_Buff_Acid_C:F_StartBuff_Everyone` (fires ~5 Hz per target during spray).
- Calls `target:F_ReceiveBuff(owner, location, UO_Buff_Fire_C)` + same for `UO_Buff_Elec_C`. **Critical:** `F_ReceiveBuff` is the only buff-apply path that registers with the target's buff list. Raw `StaticConstructObject + F_StartBuff_Everyone()` creates orphan UObjects that the combo check misses.
- Per-target throttle (0.4 s) via `__mode = "k"` weak-keyed table — released targets GC freely.

## Third-party paks installed

Located under `<game>/Content/Paks/Mods/`:
- `AutoGrabber_P.pak` — by **GoldBl4d3**, auto-loots nearby pickups. Adds `_Mods/Mod_2/Mod_2` (BP) + `PGE_AutoGrab_Info` (config DataAsset). https://www.nexusmods.com/farfarwest/mods/34
- `ModHub_P.pak` — by **GoldBl4d3**, in-game mod manager UI. **Required dependency for any pak mod that registers itself via the `RogueHub` system** (AutoGrabber depends on it). https://www.nexusmods.com/farfarwest/mods/16
- `WhitePrimaryPickup_P.pak` — visual reskin of `GPE/BP_AmmoBox` (primary ammo) for higher visibility.
- `PurpleUtilityPickup_P.pak` — visual reskin of `GPE/BP_AmmoBox_Utility`.

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
│   ├── AcidElec/Scripts/main.lua
│   ├── AutoGrabberGate/Scripts/main.lua
│   ├── BHopDash/Scripts/main.lua
│   ├── FFW_Cheats/Scripts/main.lua
│   ├── ThrowerCombo/Scripts/main.lua
│   └── WispElec/Scripts/main.lua
├── my-mods/                          # Nexus-ready release bundles + zips
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
