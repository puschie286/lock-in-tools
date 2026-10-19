# Verification process

Keep addon code compatible with Lua 5.1. Run offline checks after changes and verify relevant client behavior in WoW.

## Local setup

Install the native Windows x64 Lua 5.1.5 runtime once from the repository root:

```powershell
.\tools\setup-lua.ps1
```

The script downloads a pinned archive from the [LuaBinaries release files](https://sourceforge.net/projects/luabinaries/files/5.1.5/Tools%20Executables/), verifies its SHA-256 before extraction, and checks the interpreter and compiler. Executables, dependencies and the archive stay in ignored `tools/lua/`; no global installation or PATH change is needed. Running setup again reuses an existing installation.

## After changes

```powershell
.\tools\verify.ps1
```

Run after changing addon Lua, tests or verification tooling, and before handoff or committing. Both scripts locate the repository themselves and work from another directory when invoked by full path. Verification uses only the installed local runtime and performs no downloads.

1. Require Lua 5.1, matching the addon's syntax target.
2. Parse every root-level addon Lua file, every Lua file under `tests/`, and the standalone position probe source with `luac -p`, without producing bytecode files. Parse `PositionPins.xml` for XML syntax.
3. Run `tests/group.lua` for crypto reference vectors, friendly/legacy keys, generation failures, validation, credential derivation, feature separation and group lifecycle.
4. Run `tests/smoke.lua` for initialization, migrations, commands, asynchronous chat joins/retries, group switching, options and welcome callbacks against mocked WoW APIs. Production startup checks connect data independently of chat/position preferences, route position packets and exercise data leave/rejoin and group switching. Welcome checks include saved-key stability, copying, friend import and confirmation, draft preservation, hide cleanup, disabled autojoin, generation failure and damaged/newer-schema data. Interface checks cover native styling, optional EllesmereUI skin selection, style changes, lazy window creation, category tabs, preference drafts across tabs, key cleanup when leaving Group, reused settings and mutually exclusive welcome/settings navigation.
5. Run `tests/position-probe.lua` for the separate diagnostic's startup, channel and whisper modes, explicit-peer whispers, native-name self matching, independent receipt/order/traffic accounting, changing channel numbers, five-second cadence, roster targeting up to nine recipients, missing coordinates and shutdown. Diagnostic whisper modes do not enable a production fallback. These mocks do not prove in-game delivery or 6–10-player performance; follow the [position-sharing checks](../feature/position-sharing.md#in-game-checks).
6. Run `tests/position.lua` for opt-in settings, two-second sampling, unchanged-coordinate suppression, the 15-second heartbeat threshold with a normal 16-second cadence, latest-sample retries, unavailable positions, ordering, 60-second offline detection, retained-location persistence with restored peers offline, suppression resets and read-only data. Run `tests/position-map.lua` for native map-provider callbacks, lazy loading, active/offline pin labels and colors, parent-map projection and cleanup. Native rendering remains an in-game check.
7. Run `tests/data.lua` for data-channel credential separation, shared feature routing, framing/packet budget, failure isolation and position integration. Native-channel mocks cover prefix registration, login joins independent of chat/position preferences, bounded asynchronous retries, explicit data leave/rejoin, current-route filtering, channel renumbering, unavailable APIs/send errors, disconnect recovery and group switches. Production uses CHANNEL broadcasts without roster discovery or whisper fallback; mocks establish behavior, not server delivery.

Any failed check stops verification with a nonzero exit code. Fix the cause and rerun. Add regression coverage to the existing suites when behavior changes can be meaningfully exercised by the mocks; register new suites in `tools/verify.ps1` when needed. Keep test files out of `LockInTools.toc`.

## In-game verification

Mocks verify callbacks and state transitions. Rendering, actual clipboard/focus behavior, client event ordering and server channels require in-game checks. Record addon version and client build with `/lit status`, plus realm and faction. Use an isolated test profile or preserved SavedVariables fixture for fresh-install and schema scenarios.

1. With no saved group and welcome enabled, confirm welcome opens once with a saved key and chat begins joining when autojoin is enabled. Check different UI scales. Existing groups must retain their key.
2. Use **Select key** and Ctrl+C, then paste elsewhere to check the complete key. Typing into **Your secret key** must leave it unchanged. Blank/invalid friend keys must preserve the group. Case/whitespace variants of the current key must require no switch confirmation.
3. Require **Join friend**, then **Confirm switch**, before using a different key. Editing must reset confirmation. Check the displayed key updates, both old group channels are left and removed from all chat-window settings, unrelated channels remain and asynchronous notices preserve unfinished input. Repeat with an old pending join completing after the switch or group leave, and with obsolete addon channels restored after reload/relog.
4. Close with **Done**, the title-bar close button and Escape. A focused edit box may consume the first Escape. Hide and restore the interface with Alt+Z. Hidden fields must clear; reopening restores the saved key and resets drafts/confirmation. **More options** must open settings.
5. Reload, relog and switch characters. The account-wide key, fingerprint and preferences must persist. Configured groups must not reopen welcome automatically. Check `/lit`, `/lit welcome`, `/lit options` and `/lit welcome off` on an unconfigured profile.
6. With chat autojoin disabled, opening welcome and importing a friend key must save without a human-chat join request; the independent group-data connection should still join. Exchange human messages using `/lit chat` and check leave/reconnect, rejected joins, bounded retries and ownership/password behavior with the [shared-chat guide](../feature/shared-chat.md). Check readable chat/data labels in messages/notices, the composer header and addon status; clickable labels and `/number` must still target the current channel after reload and a group switch, with normal message text and unrelated channel labels preserved.
7. With a disposable newer-schema fixture, editing must be blocked, initial setup must not create a key and saved data must remain intact. An invalid saved key must survive opening welcome until explicitly replaced.
8. Confirm automatic group-data joins with position sharing off, `/lit data leave` remaining paused until `/lit data join`, native disconnect recovery, changing channel numbers and group switching without affecting human chat or unrelated channels. Enable positions on two clients sharing an internal realm and faction; check movement, idle/unavailable updates, self-echo exclusion, offline/retention behavior and map rendering using the [position guide](../feature/position-sharing.md#in-game-checks). Repeat zone/loading recovery and capacity checks with 6–10 clients; no production whisper fallback should run.
9. Follow the [interface checks](../feature/interface.md#limits-and-in-game-checks) with EllesmereUI absent, its LockInTools skin disabled and enabled. Check all tabs, default Group selection, preference drafts across tabs, Group-key cleanup and bidirectional navigation with one visible window. Repeated slash opens must reuse settings and preserve its selected tab. Check live accent/font updates, windows created after a style change, UI scale, moving, Escape/close, key copying/clearing and read-only controls.

See [groups](../feature/group.md) and [shared chat](../feature/shared-chat.md) for further checks. Report the verification command and result with each change, separately from actual in-game validation and any client/server behavior left unverified.
