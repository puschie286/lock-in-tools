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

- **Setup and persistence:** Check first-login setup, real key copy/paste and saved settings after reload, relog and character changes. Use a disposable newer-schema profile to check saved data remains untouched.
- **Native interface:** Check Content/Settings navigation, tooltips, focus, Escape/Alt+Z and dragging at different UI scales. Check minimap controls and any installed DataBroker display.
- **Chat and data:** On two clients sharing an internal realm and faction, exchange chat and group data across zones/instances. Check data works with human chat off, reconnects after loading or connection loss, and old channels stop carrying traffic after a group switch. Test native password and ownership behavior when changing chat.
- **Overview and party actions:** Check live discovery and XP updates with chat and positions off, then exercise invitations and join requests through native confirmations. Check scrolling and stale-state display with real peers.
- **Map positions:** Keep the sender's position sharing off during login, then enable it and confirm its first map pin already has the correct class icon; no coordinates should appear before enabling. With sharing enabled on both clients, check movement, zone/map projection, overlapping-player tooltips, stale pins and the world-map filter. Confirm pins remain in place when a status refresh carries the position, and a later unavailable report retains the last location's age. With a shared player in Orgrimmar, switch between the Orgrimmar, Durotar and Kalimdor maps and confirm the marker stays at the corresponding location; repeat with a retained last-known position. Check disabling sharing and reconnecting through loading screens.
- **Ranking:** Check live updates, overflow/own-row layout, dragging, click-through and readability with long names at different UI scales.
- **RestedXP:** With two clients, follow a publisher and complete a real guide transfer/import using recipient-local personalization. Check paste handling, import completion, combat/busy-importer deferral and reconnect/group-switch behavior during a transfer; observe actual throughput. Confirm publication keeps compressed guide bytes opaque, damaged content fails native validation, and extra local guides do not cause repeated updates after refresh or reload.
- **RestedXP summary:** Confirm Settings shows one guide status and one row per player even when that player shares several packs. Follow a player with multiple packs and check all currently offered packs are selected, including any not previously followed. Check summary progress, failed imports, offline followed publishers (also before any pack was downloaded), and installation/sharing details on hover. Check publisher scrolling, long player names and status readability at different UI scales.
- **RestedXP peer test:** On the receiver, run `/lit rxp test [player] [pack-id]` with an online group publisher; no publisher command is needed. `/lit rxp test random` chooses a random publisher, then one of their packs. It always downloads and re-imports one pack, including matching installed versions. Check discovery, transfer and native-confirmation timings plus sent/observed traffic in the report and `/lit rxp stats`; diagnostic reporting must add no messages beyond ordinary sharing traffic. Test concurrent downloads and a publisher with a full LIT cache. If no bytes arrive, inspect the publisher's request counters, local guide identities and last request status. Check `/lit rxp test cancel`, and use `/lit rxp test local` for metadata-only timing.

Report the offline verification command/result separately from in-game checks performed and any client/server behavior left unverified.
