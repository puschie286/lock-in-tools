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
| `ranking-ui.lua` | Independent overlay and Settings controls, top-five/own and empty rows, separate stale markers, minimal layout with contextual notices, explanatory/action tooltips and cleanup, visible refreshes, saved header dragging, click-through and native styling. |
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

Minimap-button checks in `tests/minimap.lua` exercise the actual bundled LibDataBroker and LibDBIcon, including broker discovery and attribute callbacks, login creation, reused controls, left/right navigation, tooltips, scaled round/square dragging, saved placement, legacy-angle migration, invalid values and detached read-only settings. Actual icon rendering, external broker displays and mouse behavior remain part of the [interface in-game checks](#interface).

Window-position checks in `tests/interface.lua` cover account-wide saving, unchanged placement across Content/Settings view changes, restoration after reinitialization, centered defaults for missing or malformed values, and temporary movement without writes on read-only profiles. Group keys, privacy and feature preferences must remain unchanged. Actual placement after reload, login or character changes requires the interface in-game checks.

`tests/overview.lua` checks presence with position sharing disabled, sender identity, level/party updates, last-contact expiry, retained metadata, group isolation and read-only data. Roster, position and production startup regressions cover legacy bare names restored before realm information is available, different current realms, repeated reloads and retained offline Overview rows. Position checks preserve coordinate age through unavailable/class updates and reload. `tests/interface.lua` covers direct command and Content/Overview navigation and key cleanup. `tests/overview-ui.lua` covers pooled scrolling rows, sorting with unknown values last, region-only labels and Actions dropdown callbacks and cleanup. Native party eligibility is rechecked on click; mocks cover self, stale/same-party targets, permission, capacity and unsupported APIs. Perform the [overview and position in-game checks](#overview-and-positions) for real native target eligibility, delivery and rendering.

Any failed check stops verification with a nonzero exit code. Fix the cause and rerun. Add regression coverage to the relevant suite when behavior changes can be meaningfully exercised by the mocks. Put new suites directly under `tests/` and reusable helpers under `tests/support/`; verification discovers them automatically. Keep test files out of `LockInTools.toc`.

Verification also runs `tests/link-wow.ps1` on Windows. It uses temporary client folders to check junction creation and removal, dry runs, reruns, repository preservation and refusal to change conflicting folders, files or broken links. It does not change an installed WoW client; addon discovery still needs an in-game check after linking.

## In-game verification

Mocks verify callbacks and state transitions. Rendering, actual clipboard/focus behavior, client event ordering and server channels require in-game checks. Record addon version and client build with `/lit status`, plus realm and faction. Use an isolated test profile or preserved SavedVariables fixture for fresh-install and schema scenarios.

### Setup and groups

- On an unconfigured profile with initial login display enabled, confirm Content opens once without key fields and saves a new account-wide key. Existing and invalid saved keys must survive opening Content or Settings. Check `/lit welcome on|off`; configured groups must not reopen Content automatically.
- In Settings → Group, copy the complete saved key with **Select key** and Ctrl+C. Both key fields remain readable, the saved display cannot be edited and blank drafts disable **Use key**. **Generate key** must leave the current group active until applied. Check **Group info**, matching public group IDs on two clients and action tooltips.
- Applying a different key requires **Use key** and confirmation; editing resets confirmation, invalid keys preserve the group and case/whitespace variants of the current key require no switch. Switching or leaving must pause sharing, leave both old channels before new joins, clear old peers/subscriptions and preserve unrelated channels. Check failed leaves, a newer pending destination, late obsolete joins and channels restored after reload/relog; notices must preserve unfinished input.
- Reload, relog and switch characters to check the shared key, fingerprint and preferences. With a disposable newer-schema fixture, editing and initial key creation must be blocked and saved data preserved. All key holders share authority; channel delivery is limited to the same internal realm and faction, and shared messages are not encrypted or individually authenticated.

### Interface

- Check `/lit`, `/lit content`, `/lit overview` and the legacy `/lit welcome` alias open Content/Overview. The first `/lit options` opens Settings/Group; later calls restore the selected page, including from Content. Check all Settings pages, header navigation and repeated opens reuse the window. Preferences and clickable checkbox labels must take effect immediately.
- Close with the title-bar button and Escape, then hide/restore with Alt+Z. A focused edit box may consume the first Escape. Leaving Group, switching to Content or hiding the window must clear key fields, drafts and confirmations; reopening Group restores the saved key. Check tooltip dismissal across navigation and closing.
- Move the window, then reload, relog and switch characters. Both views must restore the same position without changing keys or preferences. Check centered defaults, native styling, readable text and controls on small screens and different UI scales. Newer-schema profiles allow temporary movement without saved writes.
- Check minimap left-click opens Content and right-click opens Settings, tooltips and dragging on round/square minimaps, saved placement across reloads/characters and temporary read-only movement. With a compatible DataBroker display, check its shortcuts and tooltip. Restart WoW after manifest additions; `/reload` is enough for edits to existing files.

### Chat and data connections

- With chat autojoin disabled, initial setup and key import must save without joining human chat while the independent data connection still joins. Enabling autojoin connects immediately; disabling it retains membership. **Leave chat** or `/lit leave` pauses chat reconnection for the session without leaving the group; check manual join and reload/login behavior.
- Exchange `/lit chat` messages across zones and instances. Check readable **LockInTools** and **LockInTools Data** labels in notices, messages, composer headers and status. Clickable labels and `/number` must target the current channel after reload and group switches without changing unrelated labels or normal message text. Test rejected joins, wrong passwords and ownership changes; membership alone does not verify participant identity or password enforcement.
- With chat autojoin and positions off, check automatic data reconnection after `/lit data leave` and native channel leave, silent-loss recovery within about 15 seconds, retries capped at 30 seconds, immediate `/lit data join`, channel renumbering and no duplicate pending joins. Group changes, logout and read-only settings must stop old transport/retries. Test zone/loading recovery and capacity with 6–10 clients; production uses native channel broadcasts without whisper fallback.

### Overview and positions

- With two clients sharing a key, check discovery, immediate local XP updates, peer updates and party actions while chat and positions are off. Exercise XP gains, level-ups, exact-XP tooltips and zero/unknown/MAX values. Unchanged XP must remain current while contact continues; reload/reconnect must retain saved progress as stale until fresh reports arrive, including the previous character's XP. **Active** and elapsed last-contact labels indicate addon contact, not confirmed logout. The roster contains discovered characters rather than every key holder.
- With more than eight players, check fixed headers, sorting in both directions with unknowns last, wheel/scrollbar navigation and retained inactive rows. Test Actions dropdown eligibility, disabled reasons, native confirmations and delivery with eligible/stale/same-party/full-party targets. Check dismissal on scrolling, sorting, outside clicks, Escape and close; cached party flags must not authorize actions. Group changes must clear the old roster.
- Position sharing starts off and must send no locations while disabled. Enable it on both clients and check two-second movement samples, thirty-second stationary refreshes, initial locations for new arrivals, self-echo exclusion, unavailable locations and reconnects. Map dots must move smoothly, show class colors or blue for unknown classes, use hover-only names and list overlapping players in one tooltip across zooms and UI scales. After 60 seconds without a fresh position, check hollow gray last-known markers; this does not confirm logout. Overview shows regions without coordinates/ages and marks retained regions **Last:**.
- Check map close, zone/loading recovery and retained locations across reloads, logins and characters. Disabling sharing hides pins and stops exchange; group changes clear retained locations. Toggle **LockInTools → Show player icons** in the world map filter: dots must hide/show immediately while updates and expiry continue, with the choice saved across reloads/characters. Test **Keep last-known positions**, native map projection and unavailable areas; location lag and smoothing delay are expected.

### Ranking

- Show the overlay through Settings → Ranking and `/lit ranking on|off`; check top-five overflow, the highlighted own row or separate own row, missing XP and compact spacing without a descriptive subtitle or count footer. Compare XP gains, level-ups, exact ties and confirmed maximum level on two clients. Higher levels rank first, exact within-level XP fractions decide order and ties share ranks such as **1, 2, 2, 4**. **Awaiting XP** means a complete report is unavailable.
- With chat and positions off, check disconnect/reconnect, expired reports, reload and group changes. Saved offline progress must remain ranked with dimmed stale rows and `~` values until fresh reports arrive; local progress continues during connection loss. Standings cover discovered characters and reported current-level progress, not verified competition or session XP gains.
- Check Settings/slash controls, header lock/dragging, row click-through, help/action tooltips, long names and UI scales. Closing Content/Settings or pressing Escape leaves the overlay visible; check its own close button, Alt+Z and account-wide visibility/lock/position. On newer-schema profiles, session dismissal/reopening and temporary movement of an unlocked overlay must preserve saved data.

### RestedXP

- On two clients, inspect installed/disabled/missing RestedXP, installed guide names/versions, scrolling, draft cleanup and read-only controls at different UI scales. With recoverable guides already imported, check automatic availability, late arrival, **Follow** and **Update guides** without **Share export**. Verify recipient-local BattleTag handling, successful native import and last-installed state; installed names without complete source must explain the sharing limit.
- Import a higher guide version directly into RestedXP and confirm follower updates. Matching IDs/versions, including content changes that keep the same versions, must finish without another export/download/import. Login and manual checks must finish with no packs and report unavailable publishers separately. Check `/lit rxp test` and `/lit rxp stats`; metadata-only benchmarks must not prepare exports or send discovery requests.
- Test **Share export** with a stable pack ID and source BattleTag, replacements, multiple packs, throttling, packet loss/reconnects, combat, an unavailable importer and another import already running. Source BattleTags/drafts must clear on page exit and remain unsaved/unsent. Group changes during transfer must cancel old packets/imports while installed guides remain; failed updates must not report installation or discard the previous cached pack. RestedXP may already have applied changes, so failure does not promise rollback. Check actual transfer throughput and paste/import rendering; transfers require an online pack holder and can take minutes.

Report the verification command and result with each change, separately from actual in-game validation and any client/server behavior left unverified.
