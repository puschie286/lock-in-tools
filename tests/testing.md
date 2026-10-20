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
2. Parse every root-level addon Lua file and every Lua file under `Libs/` and `tests/` with `luac -p`, without producing bytecode files. Parse root-level and bundled-library XML files for XML syntax.
3. Run every top-level `tests/*.lua` suite in a separate Lua process. New suites are discovered automatically.

| Suite | Main coverage |
| --- | --- |
| `smoke.lua` | Initialization, migrations, commands, reload and saved-data preservation. |
| `group.lua` | Crypto reference vectors, friendly/legacy keys, generation, validation and group lifecycle. |
| `startup-data.lua` | Production startup, independent data connections, routing, preferences and recovery. |
| `chat.lua` | Native chat joins, labels, retries, channel cleanup and group switching. |
| `minimap.lua` | Real DataBroker/DBIcon registration and callbacks, navigation, tooltips, dragging, placement migration and read-only persistence. |
| `options.lua` | Group-key callbacks, confirmation, privacy, immediate preferences and help. |
| `welcome.lua` | Initial Content setup, saved-key stability, generation failures and damaged/read-only profiles. |
| `interface.lua` | Shared-window navigation, lazy views, remembered Settings pages and saved placement. |
| `overview-ui.lua` | Scrolling, sorting, party actions, progress bars and tooltips. |
| `ranking.lua` | Exact level/XP ordering, shared ranks, saved offline standings, stale/missing reports, disconnects, account-wide settings and read-only preservation. |
| `ranking-ui.lua` | Independent overlay and Settings controls, top-five/own rows, stale markers and explanatory help, visible refreshes, saved header dragging, click-through and native styling. |
| `theme.lua` | Native styling for windows, controls, text and progress bars, including lazy views. |
| `notifications.lua` | Real AceEvent native/message dispatch, independent owners, isolated failures and batched group cleanup. |
| `restedxp-codec.lua` | Independent export/cipher fixtures, canonical hashes, metadata, malformed input, bounded inflation and cooperative processing. |
| `restedxp-adapter.lua` | RestedXP detection, installed versions, local personalization, verified asynchronous imports and safe cancellation. |
| `restedxp-ui.lua` | RestedXP Settings navigation, installed guides, publisher selection, update actions and import-draft cleanup. |
| `restedxp.lua` | Late discovery, selected sources, unchanged-version updates, missing-chunk recovery, failed imports and group isolation. |
| `data.lua` | Shared transport, native lifecycle, request/response dispatch and status protocol. |
| `position.lua` | Position preferences, sampling, freshness, retention and class discovery. |
| `position-map.lua` | Native map providers, projection, pins, interpolation and filters. |
| `overview.lua` | Presence, level/XP/party metadata, freshness and native action eligibility. |

The production suites share native API fixtures in `tests/support/addon.lua` and widget fixtures in `tests/support/ui.lua`. Fixtures load the real bundled libraries in isolated environments; native API and widget mocks supply their client-facing surfaces. These helpers are syntax-checked recursively but are not standalone suites or addon files. Keep strict mocks for native visibility, events, focus and widget callbacks in these helpers.

For a focused run, invoke a suite from the repository root:

```powershell
.\tools\lua\lua5.1.exe tests/options.lua
```

Replace `tests/options.lua` with another suite path as needed. A focused run does not replace the full verification required before handoff.

`tests/position.lua` checks opt-in settings, two-second sampling, unchanged-coordinate suppression without an idle heartbeat, latest-sample retries, unavailable positions, ordering, 60-second offline detection, retained-location persistence with restored peers offline, suppression resets and read-only data. Class checks cover one request per connection/enable cycle, bounded failed-send retries, multi-client class exchange without periodic announcements, independent ordering, retained classes, legacy position compatibility and group cleanup without extending position freshness. `tests/position-map.lua` checks native map-provider callbacks, lazy loading, class-colored dots, unknown-class fallback, hollow stale markers, hover-only names and shared overlap tooltips during movement and zoom, pooled state resets, parent-map projection, overlapping city/region conversion, unavailable/off-map conversion results and cleanup. Native rendering and hover behavior remain in-game checks.

`tests/data.lua` checks data-channel credential separation, shared feature routing, framing/packet budget, failure isolation and position integration. Native-channel mocks cover prefix registration, independent login joins, retries capped at 30 seconds, automatic reconnection, the 15-second membership check, immediate retry commands, native routing, channel renumbering and operation failures. Group-switch checks cover paused traffic, deferred cleanup, waiting for both old memberships, failed-leave recovery, the latest pending destination, late obsolete joins and fresh status sessions. The production checks in `tests/startup-data.lua` also exercise coordinated chat/data departure, persisted peer ownership and logout. Native receives do not depend on channel metadata. Production uses CHANNEL broadcasts without roster discovery or whisper fallback; mocks establish behavior, not server delivery.

Native channel membership and lifecycle live in `DataChannel.lua`; `Data.lua` owns message transport, routing and request/response exchange. `DataStatus.lua` owns shared-status synchronization and its wire protocol. Native API availability is checked once during initialization. Tests distinguish missing support, which requires reloading after the APIs become available, from recoverable registration, join and send failures. Data sends and receives use only native WoW channels. Fixtures mock membership, native send results and queued addon events while the addon validates its protocol.

Request/response checks in `tests/data.lua` exercise generic snapshot registrations, multi-peer replies, correlation and requester filtering, self-echo/duplicate suppression, expiry, packet limits, callback/send failures and cleanup across transport/group changes. These mocks establish dispatch behavior, not native delivery.

Shared-status checks in `tests/data.lua` cover permanent numeric wire IDs with readable Lua fields, five-second change detection with full reports, thirty-second full refreshes, initial snapshot exchange, latest-state retries, fresh sessions, ordering, packet limits and lifecycle cleanup. Position attachments cover opt-in privacy, stationary refreshes, initial discovery and ordering against separate movement packets without making movement trigger status changes. A missed report needs no recovery request because the next full report supplies the current state. `tests/overview.lua` covers consolidated level/XP/party metadata, unavailable and maximum-level states, level-up consistency, activity expiry and persisted player status, including XP and flags for peers and the local character. Restored or reconnected peer values remain stale until fresh status arrives; legacy entries without XP remain unavailable, and cached flags cannot authorize party actions. `tests/overview-ui.lua` checks progress bars, exact-XP tooltips, retained state, reused rows, regions without ages and **Active** or elapsed-only contact labels. Opening Overview must not request another snapshot; unchanged refreshes preserve the XP report age, while a new sender session or resumed contact establishes a fresh sample. Invalid player data leaves the last good values visibly stale until a valid report arrives.

Status protocol 3 uses full reports and the permanent field registry in `DataStatus.lua`. Add an explicit unused ID for a new field; never renumber or reuse existing IDs, including retired fields. Providers keep readable field names. Field 9 is an optional position attachment with its own timestamp; it is excluded from status change detection and same-revision comparisons and is not exposed to status providers. Unknown numeric IDs are validated and ignored by consumers; tests cover their presence or absence in independent reports, duplicate or malformed identifiers, unsupported message kinds and rejection of older status versions. Adding an ID does not require changing the protocol version.

Position-map interpolation checks cover two-second linear movement, retargeting, metadata refreshes, endpoint clamping without prediction when updates are delayed, projected coordinates, immediate placement on map/presence/zone changes or large jumps, and animation cleanup on pooled pins.

Chat and position options checks in `tests/options.lua` cover clickable checkbox labels, independent immediate changes, retained chat membership when autojoin is disabled, compact status with full tooltip details, read-only label controls and tooltip dismissal across page/window changes. Native hover areas, label clicks and tooltip placement still require in-game checks.

Player-icon filter checks cover a default-on account-wide preference, persistence, rejected invalid/read-only/uninitialized changes, and continued sampling, receiving, discovery and retention while hidden. Map checks cover native filter registration, immediate pin removal/restoration, current locations when shown again and lazy map loading; actual dropdown placement and rendering remain in-game checks.

Minimap-button checks in `tests/minimap.lua` exercise the actual bundled LibDataBroker and LibDBIcon, including broker discovery and attribute callbacks, login creation, reused controls, left/right navigation, tooltips, scaled round/square dragging, saved placement, legacy-angle migration, invalid values and detached read-only settings. Actual icon rendering, external broker displays and mouse behavior remain part of the [interface in-game checks](../feature/interface.md#limits-and-in-game-checks).

Window-position checks in `tests/interface.lua` cover account-wide saving, unchanged placement across Content/Settings view changes, restoration after reinitialization, centered defaults for missing or malformed values, and temporary movement without writes on read-only profiles. Group keys, privacy and feature preferences must remain unchanged. Actual placement after reload, login or character changes requires the interface in-game checks.

`tests/overview.lua` checks presence with position sharing disabled, sender identity, level/party updates, last-contact expiry, retained metadata, group isolation and read-only data. Roster, position and production startup regressions cover legacy bare names restored before realm information is available, different current realms, repeated reloads and retained offline Overview rows. Position checks preserve coordinate age through unavailable/class updates and reload. `tests/interface.lua` covers direct command and Content/Overview navigation and key cleanup. `tests/overview-ui.lua` covers pooled scrolling rows, sorting with unknown values last, region-only labels and Actions dropdown callbacks and cleanup. Native party eligibility is rechecked on click; mocks cover self, stale/same-party targets, permission, capacity and unsupported APIs. Perform the [overview in-game checks](../feature/overview.md#in-game-checks) for real native target eligibility, delivery and rendering.

Any failed check stops verification with a nonzero exit code. Fix the cause and rerun. Add regression coverage to the relevant suite when behavior changes can be meaningfully exercised by the mocks. Put new suites directly under `tests/` and reusable helpers under `tests/support/`; verification discovers them automatically. Keep test files out of `LockInTools.toc`.

Verification also runs `tests/link-wow.ps1` on Windows. It uses temporary client folders to check junction creation and removal, dry runs, reruns, repository preservation and refusal to change conflicting folders, files or broken links. It does not change an installed WoW client; addon discovery still needs an in-game check after linking.

## In-game verification

Mocks verify callbacks and state transitions. Rendering, actual clipboard/focus behavior, client event ordering and server channels require in-game checks. Record addon version and client build with `/lit status`, plus realm and faction. Use an isolated test profile or preserved SavedVariables fixture for fresh-install and schema scenarios.

1. With no saved group and initial login display enabled, confirm Content opens once without key fields, a new key is saved and chat begins joining when autojoin is enabled. Check different UI scales. Existing groups must retain their key.
2. Open Settings → Group. Use **Select key** and Ctrl+C, then paste elsewhere to check the complete key. Typing into the saved-key display must leave it unchanged. Both key fields must be readable, with no reveal button. Blank drafts must disable **Use key**. **Generate key** must leave the current group active until applied. Check the **Group info** and action tooltips, their dismissal when navigating or closing, and matching public group IDs on two clients. Invalid replacement keys must preserve the group. Case/whitespace variants of the current key must require no switch confirmation.
3. Require **Use key**, then confirmation, before using a different key. Editing must reset confirmation. Check the displayed key updates, both old group channels are left and removed from all chat-window settings, unrelated channels remain and asynchronous notices preserve unfinished input. Repeat with an old pending join completing after the switch or group leave, and with obsolete addon channels restored after reload/relog.
4. Close with the title-bar close button and Escape. A focused edit box may consume the first Escape. Hide and restore the interface with Alt+Z. Leaving Group, switching to Content or hiding the window must clear key fields and drafts; reopening Group restores the saved key and resets confirmation. The **Settings** and **Content** header buttons must switch views within the same window.
5. Move the window, then reload, relog and switch characters. Content and Settings must restore the same saved position; the account-wide key, fingerprint and preferences must persist. Configured groups must not reopen Content automatically. Check `/lit`, `/lit content`, `/lit overview`, the legacy `/lit welcome` alias, `/lit options` and `/lit welcome off` on an unconfigured profile.
6. With chat autojoin disabled, initial setup and importing a key in Settings → Group must save without a human-chat join request; the independent group-data connection should still join. Exchange human messages using `/lit chat` and check leave/reconnect, rejected joins, bounded retries and ownership/password behavior with the [shared-chat guide](../feature/shared-chat.md). Check readable chat/data labels in messages/notices, the composer header and addon status; clickable labels and `/number` must still target the current channel after reload and a group switch, with normal message text and unrelated channel labels preserved.
7. With a disposable newer-schema fixture, editing must be blocked, initial setup must not create a key and saved data must remain intact. An invalid saved key must survive opening Content or Settings until explicitly replaced.
8. With chat autojoin and position sharing off, confirm group data connects and automatically reconnects after `/lit data leave` or a native channel leave without saving settings. Check silent loss recovery within about 15 seconds, continuing retries with delays capped at 30 seconds after rejected joins, immediate retry with `/lit data join` and channel renumbering. Existing connections and pending joins must continue without duplication. Group switching/leaving, logout and read-only settings must stop old transport/retries without affecting human chat or unrelated channels. Enable positions on two clients sharing an internal realm and faction; check movement, idle/unavailable updates, self-echo exclusion, offline/retention behavior, reconnection and map rendering using the [position guide](../feature/position-sharing.md#in-game-checks). Toggle **LockInTools → Show player icons** in the world map filter; check immediate hide/show, updates and expiry while hidden, and the saved choice after reload or a character switch. Repeat zone/loading recovery and capacity checks with 6–10 clients; no production whisper fallback should run.
9. Follow the [interface checks](../feature/interface.md#limits-and-in-game-checks). Content contains Overview; Settings contains Group, Shared chat and Shared positions. The first `/lit options` opens Settings/Group; later calls restore its page, including from Content. `/lit overview` opens Content/Overview. Check header navigation, retained Settings pages, immediate preference effects and persistence, and Group-key cleanup when switching pages or views. Overview should show eight rows with fixed sortable headers, wheel and scrollbar navigation, region names without coordinates and an Actions dropdown. Repeated opens must reuse the window and its views. Check native styling across views, UI scale, moving, Escape/close, key copying/clearing and read-only controls. Minimap left-click opens Content, right-click opens Settings, and dragging still saves its position.

See [groups](../feature/group.md) and [shared chat](../feature/shared-chat.md) for further checks. Report the verification command and result with each change, separately from actual in-game validation and any client/server behavior left unverified.
