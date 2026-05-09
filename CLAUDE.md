# FFW-mods — Claude project notes

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

Manual sync. No symlink set up. Edit here → copy → reload (Ctrl+R in UE4SS console or game restart).

## Currently installed paks (third-party)

- `AutoGrabber_P.pak` — GoldBl4d3, auto-loots nearby pickups.
- `PurpleUtilityPickup_P.pak` / `WhitePrimaryPickup_P.pak` — tier filters paired with AutoGrabber.
- `ModHub_P.pak` — mod manager UI.

We don't have source for these. To modify behavior we either (a) extract & rebuild the pak, or (b) write a Lua mod that hooks/intercepts the BP's pickup function. Prefer (b) — reversible, no UAssetGUI loop.

## Pak modding stack (per `docs/asset-editing.md`)

| Tool | Purpose |
|------|---------|
| Fmodel | Browse pak contents (`fmodel.app`) |
| retoc | Convert iostore (`.ucas`/`.utoc`) ↔ legacy `.pak` (`github.com/trumank/retoc/releases`) |
| UAssetGUI (experimental) | Edit legacy uasset/uexp |
| AES key | `0xDD5543BCC9C387A03DEADD72473D6A2EAF491AF88FC47365EE963F8AFE16B2D9` |
| Mappings | Required for proper deserialization (Drive link in docs) |

Reference template:
```
retoc.exe --aes-key 0xDD5543BCC9C387A03DEADD72473D6A2EAF491AF88FC47365EE963F8AFE16B2D9 to-legacy -f Progress \
  "C:\Program Files (x86)\Steam\steamapps\common\FarFarWest\FarFarWest\Content\Paks" \
  "<output legacy dir>"
```

## UE4SS Lua quirks (load-bearing)

- **Don't walk `cls.Children`** — TArray index out of range. Use `Reflection:GetFunctions()`.
- **Don't use `CPPHooking` for BP-overridden events** (e.g. `OnLanded`). Use `RegisterHook` with full UFunction string path.
- **Hooks don't always bind on script load** — wrap registration in a 500ms retry loop until success.
- **Always `pcall` UE calls** — `GetVisibility`, `IsValid`, etc. crash unwrapped on edge states.
- **Always `ExecuteInGameThread(...)`** for widget create / viewport / pawn writes when triggered from input thread.
- **Filter `IsDefaultObject()`** when iterating `FindAllOf` results.

## Keybind registry (don't double-bind)

| Key | Mod | Action |
|-----|-----|--------|
| F6 | Speedometer | Cycle layout |
| F7 | Speedometer + DPSMeter | Toggle (known shared collision, accepted) |
| F8 | Speedometer | Cycle units |
| INS | FFW_Cheats | Toggle native cheat menu |

Free F-keys: F1–F5, F9–F12. **BHopDash is keybind-free** (always-on, hold-LeftShift trigger). Don't reintroduce toggle keys.

## `mods.txt` load order (must match game folder)

`CheatManagerEnablerMod` must be `1` for FFW_Cheats to be useful. `Keybinds` stays last.

## Personal preferences

- Terse, action-first responses. No pleasantries / no recap-of-what-just-happened.
- Caveman mode is fine and frequently active.
- When something fails: propose next iteration, don't ask whether to continue.
- Commit messages: no AI co-author trailers.
- No worktrees for solo single-branch PR work.
- Verify exact UE/Lua API signatures against existing working code before writing new calls. Don't guess function names.

## AI sync rule

This project must keep `CLAUDE.md`, `GEMINI.md`, `KIMI.md` in sync. When updating one, update all three.

## Auto-memory

`.claude` memory under `C:\Users\Abeelha\.claude\projects\C--Users-Abeelha-Documents-github-FFW-mods\memory\`. Index is `MEMORY.md`. Append new project/feedback/reference memos on milestones, surprising fixes, or non-obvious facts.

## Active work

**AutoGrabber threshold gate** — wrap the third-party AutoGrabber so it skips ammo pickups above N% of max and skips utility pickups when count > 0. See `mods/AutoGrabberGate/` (when started).

---
*This file is auto-maintained. Update on every: new mod added, new keybind claimed, new third-party pak installed, new project-wide convention.*
