# Verification process

## Offline verification

From the repository root, install the local Lua 5.1 runtime once:

```powershell
.\tools\setup-lua.ps1
```

The runtime stays in ignored `tools/lua/`; no global installation is needed.

After changing Lua, tests or verification tooling, run the full check before handoff or committing:

```powershell
.\tools\verify.ps1
```

This checks Lua/XML syntax, runs all offline Lua suites and checks the Windows addon-link tool. Verification uses the installed runtime without downloads. Fix failures and rerun.

For a focused run while working:

```powershell
.\tools\lua\lua5.1.exe tests/options.lua
```

Replace the suite path as needed. A focused run does not replace full verification.

Keep offline tests focused on core behavior and distinct regressions; avoid duplicate scenarios and assertions about labels, colors or exact widget layout. New suites belong in `tests/*.lua`, shared fixtures in `tests/support/`. Suites are discovered automatically; keep tests out of `LockInTools.toc`.

## In-game verification

Run the checks relevant to the change. Offline mocks cannot establish native rendering, client event ordering, server delivery or third-party compatibility.

Use `/reload` for existing Lua edits; restart WoW after manifest additions. Record addon version and client build from `/lit status`, plus realm and faction. Use an isolated profile or preserved SavedVariables for fresh-install and schema checks.

- **Setup and persistence:** Check first-login setup, key copy/paste and saved settings across reload, relog and character changes. Use a disposable newer-schema profile to confirm saved data stays untouched.
- **Native interface:** Check Content/Settings navigation, tooltips, focus, Escape/Alt+Z, window placement and dragging at different UI scales. Exercise minimap controls and any installed DataBroker display. Check the 64×64 addon texture in the AddOns list, window title, minimap and DataBroker display for clarity, correct orientation and clean edges at different UI scales.
- **Chat and data:** On two clients sharing a realm and faction, exchange chat and group data across zones/instances. Confirm data works with chat off, reconnects after loading or connection loss, and old channels stop carrying traffic after a group switch. Exercise native password and ownership behavior.
- **Overview and party actions:** Check discovery and XP updates with chat and positions off, invitations and join requests through native confirmations, scrolling and stale peers. Check the narrower Name column with long names and the extra room for Region; offline regions show just the region name without `Last:`. Percentages sit beside their level values on the same horizontal line with consistent right alignment and no `~` prefix; offline values remain dimmed. Confirm local, live and saved player names remain readable without a `(you)` suffix, the local player's Actions button is disabled, and party actions address the intended active player.
- **Map positions:** Enable sharing after login and confirm the first pin has its class icon, with no coordinates sent beforehand. Check movement, zone/map projection, overlapping-player tooltips, stale pins and the map filter. Pins use the ranking overlay's compact tooltip: rank/name, level and XP needed unless at maximum level, then location with contact age only offline. Overlapping pins list each player's compact entry. Compare ranks and XP with the overlay, including saved/offline players and players beyond the top five; check XP updates while hovered and position-only players awaiting XP. Confirm sharing preferences hide cached locations. Status refreshes must preserve pin location and age; unavailable reports retain the last location's age. With a player in Orgrimmar, switch between Orgrimmar, Durotar and Kalimdor and repeat with a retained position. Check disabling sharing and reconnecting after loading screens.
- **Ranking:** Check live XP ordering, ties, saved/offline standings, overflow and own-row placement. Confirm names have no `(you)` suffix and each XP bar sits directly below its player's name without a blank line. Percentages and MAX sit immediately left of the level on the same horizontal line, with room for long names and no `~` prefix; offline values remain dimmed. Shift-drag the header or a row, including your own row, and confirm placement survives reload and character changes. Double-left-click the title to open Overview from a closed main window or Settings while keeping the overlay visible; single clicks, right double clicks and Shift-dragging must not open it. Hover players: line 1 is `#Rank - Name`; line 2 is `Lv Level - Missing% (Missing XP)` and disappears at max level; the final line shows location, with contact age appended only for offline players. Missing progress shows **Awaiting XP**. Check location privacy with either side's sharing off. Confirm your own row still shows its tooltip but cannot open an action menu; exercise Invite/Request to join for other players, including stale peers. Keep an action menu open through rank changes, contact expiry and group switching: it must never target a replacement player. Check Escape, outside clicks, closing/dragging and clicks through unused space.
- **Tooltip placement:** Check Settings help (including checkboxes, labels, disabled controls and RestedXP input), Overview level cells, Invite/Request help, map pins, the minimap launcher, ranking player rows, your own row and close-button help with default tooltip placement and any installed global tooltip positioning customization. Keep players hovered during live updates and map pin rebuilds; placement must continue following global behavior. Repeat near different screen edges and at different UI scales. Confirm leaving, tab changes, closing and dragging dismiss owned tooltips, minimap dragging suppresses its tooltip, and external DataBroker displays retain control of their own tooltip placement.
- **RestedXP import:** Open the helper without a group and import using the original owner's BattleTag. Check missing/disabled RestedXP, invalid input and large exports. Failures retain the draft; leaving the tab or closing clears guide input. Editing the source BattleTag must persist across reopening and reload, including partial input and clearing it. Confirm no group traffic or saved guide strings. Run `/lit rxp cleanup` against legacy settings and reload; only LIT's old RestedXP cache and remembered source should disappear.
- **RestedXP progress:** Compare LIT's guide count with the native importer. Import stays disabled during native processing and reports completion only after confirmed success. Close/reopen during import, then try an incorrect source, cancellation, a replacement native import and a second success when an old success message already exists.
- **RestedXP paste:** Paste small, newline-heavy and real single-line exports up to 2 MiB, including literal `|` characters. Only the byte count should appear; importing must receive the entire export. Replacing a paste, clicking Paste without pasting, moving focus and pressing Escape must retain the right draft. More than 2 MiB produces an explicit error and disables Import. Clear removes guide input and errors while retaining the BattleTag; tab/window changes clear all temporary guide input. Check busy/read-only controls and responsiveness at different UI scales.
- **RestedXP performance:** Compare paste-to-byte-count time for the same real export before/after changes, especially near 2 MiB and after repeated pastes. Record export size and pause duration separately from import time; watch for stuttering while editing the BattleTag or closing. Offline byte-integrity and bounded-widget-work checks cannot establish native clipboard performance or resolution of the reported client crash.

Report the offline verification command/result separately from in-game checks performed and any client/server behavior left unverified.
