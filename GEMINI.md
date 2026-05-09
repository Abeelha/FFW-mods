# FFW-mods — Gemini project notes

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

**Live target (UE4SS reads from here, not the repo):**
`C:\Program Files (x86)\Steam\steamapps\common\FarFarWest\FarFarWest\Binaries\Win64\ue4ss\Mods\`

**Pak target:**
`C:\Program Files (x86)\Steam\steamapps\common\FarFarWest\FarFarWest\Content\Paks\Mods\`

Manual sync. No symlink set up. Edit here → copy → reload.

## Currently installed paks (third-party)

- `AutoGrabber_P.pak` — GoldBl4d3, auto-loots nearby pickups.
- `PurpleUtilityPickup_P.pak` / `WhitePrimaryPickup_P.pak` — tier filters paired with AutoGrabber.
- `ModHub_P.pak` — mod manager UI.

No source. Modify via (a) pak rebuild, or (b) Lua hook intercepting the BP function. Prefer (b).

## Pak modding stack (per `docs/asset-editing.md`)

| Tool | Purpose |
|------|---------|
| Fmodel | Browse pak contents |
| retoc | Convert iostore ↔ legacy pak |
| UAssetGUI experimental | Edit legacy uasset/uexp |
| AES key | `0xDD5543BCC9C387A03DEADD72473D6A2EAF491AF88FC47365EE963F8AFE16B2D9` |

## UE4SS Lua quirks (load-bearing)

- Don't walk `cls.Children` — TArray OOR. Use `Reflection:GetFunctions()`.
- Don't `CPPHooking` BP-overridden events. Use `RegisterHook` with full UFunction path.
- Hooks may not bind on script load — wrap in 500ms retry loop.
- Always `pcall` UE calls.
- `ExecuteInGameThread` for widget/viewport/pawn writes triggered from input thread.
- Filter `IsDefaultObject()` when iterating `FindAllOf`.

## Keybind registry

| Key | Mod | Action |
|-----|-----|--------|
| F6 | Speedometer | Cycle layout |
| F7 | Speedometer + DPSMeter | Toggle (shared, accepted) |
| F8 | Speedometer | Cycle units |
| INS | FFW_Cheats | Toggle native cheat menu |

Free F-keys: F1–F5, F9–F12. BHopDash is keybind-free.

## Preferences

- Terse, action-first. No pleasantries.
- Caveman mode often active.
- On failure: propose next iteration, don't ask permission.
- No AI co-author trailers in commits.
- Verify UE/Lua API signatures against existing working code before writing new calls.

## AI sync rule

`CLAUDE.md`, `GEMINI.md`, `KIMI.md` must stay synced. Update all three together.

## Active work

AutoGrabber threshold gate — see `mods/AutoGrabberGate/` (when started).
