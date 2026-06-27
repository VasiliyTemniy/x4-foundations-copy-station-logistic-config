# Copy Station Logistic Config

Copies one player station's full logistic configuration onto another in a
single right-click. For every ware the source handles, the target station
inherits the same storage allocation, buy/sell offers, prices, trade rules
and (optionally) the drone-pool configuration.

## Why

Tuning a single station's logistics by hand is grim. A medium production
station typically touches **10–20 wares**, and each ware has up to
**9 independently configurable settings**:

- Manual storage allocation (m³)
- Automatic-allocation toggle
- Buy offer on/off
- Buy amount (manual)
- Buy price (manual)
- Sell offer on/off
- Sell amount (manual)
- Sell price (manual)
- Per-ware trade-rule overrides (buy + sell)

A fully tuned station is easily **150–400 clicks** to configure from scratch,
and three of every nine settings are numbers you must remember exactly. If
you want a second station configured identically, the vanilla UI gives you
nothing — you alt-tab to a notepad, scribble values, switch back, open the
source, forget a number, switch back to read it, switch again, lose your
place... I have done this. You probably have too. It is the worst part of
running a station empire.

This mod skips all of that. Configure one station the way you want it.
Right-click it, pick **Set as Logistic Copy Source**. Right-click each
target station, pick **Apply Logistic Config from <X>**, untick the wares
you don't want copied (or keep the default "all"), confirm. Done.

## Game version compatibility

- 9.00 release - **supported**
- 9.00 betas and release candidates - **supported**
- 8.00 release - **supported**

## Requirements

- **SirNukes Mod Support APIs** ([link](https://www.nexusmods.com/x4foundations/mods/503)) — hard
  dependency. Provides Lua loader, Interact Menu API and Simple Menu API.

## How to use

The mod adds three actions to the right-click menu on player-owned stations
(visible only on stations, never on build-storage).

1. **Set as Logistic Copy Source** — appears on every player station. Marks
   that station as the source. A notification confirms the selection.
2. **Apply Logistic Config from <SourceName>** — appears on every player
   station *except* the source, once a source is set. Opens a picker:
   - One checkbox per ware the source handles, defaulting to all selected.
   - **All wares** master toggle at the top.
   - **Copy drone config** checkbox (off by default; see below).
   - **Select / deselect all wares** — flips every ware checkbox.
   - **Select only target station wares** — narrows selection to wares the
     target itself handles, useful when you don't want to push new tradewares
     onto the target.
   - **Confirm** runs the copy. **Cancel** closes the picker.
3. **Clear Logistic Copy Source** — appears once a source is set, on any
   station. Drops the source so it doesn't linger.

The source persists across map opens and saves; a **game-load wipes it**,
since the component reference could be stale and a half-finished copy
shouldn't survive a session boundary.

## What gets copied

Per ware (for every ware the source handles **and** the target has storage
for — wares the target can't physically hold are silently skipped):

- **Storage allocation override** (manual m³, or "automatic" if the source
  is on auto). If the target's remaining storage can't fit the source's
  allocation, the override is written as 0 and the player is expected to
  adjust manually once storage modules finish building.
- **Buy offer existence + amount + price** (with their auto/manual toggles).
- **Sell offer existence + amount + price** (with their auto/manual toggles).
- **Per-ware trade-rule overrides** (both buy and sell).
- For wares the target doesn't already render in its Logical Station
  Overview, the ware is registered as a tradeware so the UI exposes it.

When **Copy drone config** is checked, the station's shared drone pool also
gets copied:

- For each drone unit type (transport, defence, repair), the source's
  manual/auto mode and per-macro target counts are mirrored.
- The shared pool capacity is respected — already-built drones on the
  target are never destroyed; the inbound order delta is the only thing
  that gets adjusted.
- The station-wide "Trade Rule for Supplies" (the single rule that governs
  both drones and missile resupply) is also copied.

Target-side per-macro overrides for drones the source doesn't have are
left intact (the player's existing orders survive).

## What does NOT get copied

- Non-drone supply overrides.
- Anything outside the Logistic Station Overview (e.g. construction plans,
  module loadouts).

## Cross-station compatibility notes

- The source and target don't need to be the same module layout. The copy
  is per-ware, capacity-clamped per transport type.
- Copying onto an under-construction station works for any ware the planned
  modules will eventually accept. Wares not in the plan are skipped.
- If the source has a ware the target physically can't hold (no storage of
  the right transport type), that ware's override is written as 0.

## Tips

- **Use "Select only target station wares"** when applying onto a station
  with a much narrower production scope than the source. Avoids pushing
  irrelevant tradewares onto the target. Unless you want to copy config to
  a new similar station that is still in construction.
- The Apply action does **not** wipe the target's existing settings — it
  only overwrites the wares you selected. Wares you unchecked retain their
  current target-side configuration.
- The source remains set after Apply, so you can copy onto several stations
  in succession without re-marking the source each time.

## Caveats

- **No undo.** Pick carefully; or re-apply with corrected settings.
- **Debug logging is off by default.** Enable it from Extension Options if you
  need troubleshooting output. This enables both the MD-side `debug_to_file`
  logs (file: `VAS_CopyStationLogistic/copy_station_logistic.txt`) and the Lua
  `DebugError` blocks in the in-game debug log window.

## Credits

- Inspired by **HJ Copy Behaviour** (which does the equivalent for ship
  default orders).
- Built on **SirNukes Mod Support APIs** (Lua loader, Interact Menu API,
  Simple Menu API).
- By VasiliyTemniy.

## Source

https://github.com/VasiliyTemniy/x4-foundations-copy-station-logistic-config
