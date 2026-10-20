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

Extend the relevant suite for meaningful behavior regressions. New suites belong in `tests/*.lua`, shared fixtures in `tests/support/`. Suites are discovered automatically; keep tests out of `LockInTools.toc`.

## In-game verification

Run the checks relevant to the change. Offline mocks cannot establish native rendering, client event ordering, server delivery or third-party compatibility.

Use `/reload` for existing Lua edits; restart WoW after manifest additions. Record addon version and client build from `/lit status`, plus realm and faction. Use an isolated profile or preserved SavedVariables for fresh-install and schema checks.

- **Setup and persistence:** With the login message enabled, use `/reload` and confirm it shows the installed addon version from `/lit status`. Check first-login setup, real key copy/paste and saved settings after reload, relog and character changes. Use a disposable newer-schema profile to check saved data remains untouched.
- **Native interface:** Check Content/Settings navigation, tooltips, focus, Escape/Alt+Z and dragging at different UI scales. Check minimap controls and any installed DataBroker display.
- **Chat and data:** On two clients sharing an internal realm and faction, exchange chat and group data across zones/instances. Check data works with human chat off, reconnects after loading or connection loss, and old channels stop carrying traffic after a group switch. Test native password and ownership behavior when changing chat.
- **Overview and party actions:** Check live discovery and XP updates with chat and positions off, then exercise invitations and join requests through native confirmations. Check scrolling and stale-state display with real peers.
- **Map positions:** Keep the sender's position sharing off during login, then enable it and confirm its first map pin already has the correct class icon; no coordinates should appear before enabling. With sharing enabled on both clients, check movement, zone/map projection, overlapping-player tooltips, stale pins and the world-map filter. Confirm pins remain in place when a status refresh carries the position, and a later unavailable report retains the last location's age. With a shared player in Orgrimmar, switch between the Orgrimmar, Durotar and Kalimdor maps and confirm the marker stays at the corresponding location; repeat with a retained last-known position. Check disabling sharing and reconnecting through loading screens.
- **Ranking:** Check live updates, overflow/own-row layout, dragging, click-through and readability with long names at different UI scales.
- **RestedXP import helper:** Open `/lit rxp` without a group, paste an import string and enter its original owner's BattleTag. Check local conversion and handoff to RestedXP, including missing/disabled RestedXP, invalid input and large pasted strings. Errors should retain the draft; leaving the tab or closing the window must clear temporary guide input. Enter or edit the source BattleTag without importing and confirm it is prefilled on reopening the helper and after `/reload`, including partial input and when RestedXP is unavailable. Failed conversions and rejected imports must retain the latest entry. Clear the field and confirm it stays empty after reopening and reload. Confirm the helper sends no group messages, never saves guide strings and reports completion only when RestedXP confirms success. With preserved legacy settings, check `/lit rxp cleanup` followed by `/reload` removes LIT's old RestedXP cache and remembered source while retaining other settings and RestedXP's own guides.
- **RestedXP import progress:** Compare LIT's guide count with RestedXP's importer while importing. Import must stay disabled through native processing and show an explicit completed, failed or cancelled result. Close and reopen LIT during import to check the current status remains visible. Try an incorrect source BattleTag, cancel in RestedXP and start a replacement native import; none should report the original import as completed. Check a second successful import even if RestedXP already contains its previous success message.
- **RestedXP paste stability:** In `/lit rxp`, click **Paste export** and press Ctrl+V with a small export, then a real large single-line export up to 2 MiB. Confirm the button prompts for Ctrl+V while focused, only the loaded byte count appears after capture, and no guide text is ever visible; Import must use the entire export. Clicking Paste export without pasting must retain the loaded export. Also try newline-heavy text and literal `|` sequences, replacing a draft with another paste, and pasting more than 2 MiB (an explicit size error with Import disabled). **Clear** must remove pending or loaded guide input and size errors without changing the source BattleTag. Clicking the BattleTag field or pressing Escape immediately after pasting should finish capture and retain the draft. Switching tabs or closing the window during paste must clear all temporary input; reopening must not restore a partial or previous export. Confirm Paste export and Clear respect busy/read-only state, and the client stays responsive while pasting and after repeated replacements at different UI scales. These native clipboard and rendering checks require the actual client; offline tests cannot establish that the reported crash is resolved.
- **RestedXP paste performance:** Compare Ctrl+V to the loaded-byte-count time for the same real export before and after the change, especially near 2 MiB and after repeated pastes. Record approximate pause duration and export byte count separately from the time after clicking Import. Watch for stuttering when entering the BattleTag, switching tabs, or closing after a large paste. The transparent capture field stays shown to receive native clipboard input and is limited to one byte throughout; removing the previous 150-character preview removes its rendering work, but leaves character-by-character capture unchanged. Offline regression tests deliver characters individually and check bounded widget work and exact import bytes; their timings do not measure WoW's native clipboard delivery or rendering.

Report the offline verification command/result separately from in-game checks performed and any client/server behavior left unverified.
