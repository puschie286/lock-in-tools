# Groups

One account-wide key identifies your friends across all features. Open the welcome screen with `/lit` or `/lit welcome`, and settings with `/lit options`. `/lit help` lists commands, `/lit status` shows the public fingerprint and feature state, and `/lit welcome on|off` controls the login message and automatic initial welcome screen.

## Setup

1. On your first login, the welcome screen creates and saves a key such as `otter-4827`. Existing groups keep their key. Reopen the screen anytime with `/lit`.
2. Your saved key is visible under **Your secret key**. Click **Select key**, then press Ctrl+C to copy and share it.
3. To use a friend's key instead, enter it under **Have a friend's key?**, click **Join friend**, then **Confirm switch** to replace your current group. Your displayed key updates to the shared key. Shared chat joins automatically when autojoin is enabled.
4. Click **Done** to close, or **More options** for group management and feature settings.

## Key management

- The welcome screen shows your saved key in a selectable field that cannot change the saved key. Closing clears both displayed keys; the saved key remains.
- In `/lit options`, **Create group** prepares a new key; **Use key** saves it. **Show key** reveals the field for Ctrl+C. Closing settings clears and masks the field.
- Switching groups and **Leave group** require confirmation and affect every feature. [Leaving chat](shared-chat.md) keeps your group.
- Custom keys: 3–40 ASCII letters/digits, with single hyphens between them. Case and surrounding whitespace are ignored. The reserved `lit1-` prefix supports legacy codes without changing their identity or credentials.
- Generated keys use ordinary randomness and are guessable. All holders have equal authority; change keys to remove access. Keys persist in `LockInToolsDB`, readable on disk and by other addons.

## Implementation and settings

`Group.lua` generates/validates keys; `Crypto.lua` uses distinct versioned HKDF-SHA256 labels for the fingerprint, channel/password and authentication root/feature-specific HMAC keys. Keys are not broadcast; fingerprints compare groups without authenticating peers.

Optional signing helpers cover exact payload bytes without encryption. Features define their own message handling; the shared data pipeline below uses plain messages for trusted friends.

`Core.lua` loads schema 3 settings on `ADDON_LOADED`, then derives the group. At login, an unconfigured player with welcome enabled sees the welcome screen. Opening it creates a key only when no key is saved; invalid saved keys stay intact for correction. Reload/logout persists settings. Migration preserves welcome/autojoin and unrelated fields; old channel names remain stored but unused. Newer schemas remain intact with temporary defaults and saved edits blocked. `Options.lua`/`Commands.lua` expose controls.

## Shared data pipeline

Human chat keeps its existing channel. Shared feature data has a separate group-derived name beginning **LITDATA** and separate derived credentials. This is the addon's naming convention on a normal custom channel, not a special WoW channel mode. Existing friendly/legacy fingerprints and chat credentials stay unchanged.

The group's channels appear locally as **LockInTools** and **LockInTools Data** in chat prefixes, join/leave notices, the composer header and addon status. These display aliases leave derived native names/passwords and routing unchanged. Native channel management, channel-list output and moderation notices may show actual names; addons replacing native chat formatting may display labels differently.

`Data.lua` provides one pipeline with the addon prefix `LockInToolsData`. Position sharing registers as `position`; future features register their own identifier and use the same backend. Streaming messages use `1|feature|payload`, preserving the payload verbatim, with a 255-byte total packet cap. Sampling, ordering, persistence and message retries remain each feature's responsibility; the pipeline owns connection retries.

Shared internal helpers:

- `RegisterDataFeature(name, receive, connectionChanged)`: one receiver per feature and an optional connection-change callback.
- `SendData(name, payload)` / `ReceiveData(sender, message)`: frame outgoing data and route incoming data using WoW's sender.
- `RegisterDataRequest(name, onRequest, onResponse)`: register a snapshot exchange separately from streaming features. `onRequest(sender, payload)` returns a response string or nil/false to decline; `onResponse(sender, payload)` consumes each peer's response.
- `RequestData(name, payload)`: broadcast one request and return acceptance plus its request ID. Features choose when to request, such as in their connection callback, and whether to retry a failed send.
- `SetDataTransport(send)`: provide a backend accepting `(prefix, framedMessage)` and returning true when accepted; nil disconnects it. `IsDataConnected()` reports availability.
- `GetGroupDataChannelName()` / `GetGroupDataChannelPassword()`: obtain the common data-channel credentials. Never log passwords or group keys.

On login, `Data.lua` registers the native prefix and keeps the group's temporary data channel connected while the character is ready and a valid, writable group is configured. This connection is independent of chat autojoin and individual feature switches, so other features can reuse it when position sharing is off. Native events confirm membership. Leaving or losing the channel schedules reconnection after about one second; a membership check every 15 seconds detects silent loss. Join retries continue with delays capped at 30 seconds; native errors use the 30-second delay. `/lit data leave` temporarily disconnects and automatically reconnects; `/lit data join` requests an immediate retry. No feature-settings save is needed. Existing connections and pending joins are preserved. `/lit status` shows connection state.

Each send resolves the current local channel number and broadcasts once through `CHANNEL`. Incoming messages must match the prefix and current group route before `ReceiveData` receives WoW's sender. Native errors are handled without breaking feature callbacks. No roster lookup or whisper fallback is used. Accepted sends do not prove peer delivery; the validated scope is friends on the same internal realm and faction, with [cross-realm limits and live evidence](position-sharing.md#connection-and-limits).

Request frames use `1|Q|feature|id|payload`; responses use `1|R|feature|id|requester|payload`, within the same 255-byte total cap. Payloads may contain pipes. Each registered peer may answer a request once; self echoes are ignored. Multiple peers can answer during a ten-second response window. Replies dispatch only for the local requester and matching feature/request ID, with duplicate responders suppressed. Callback failures are isolated. Replacing or disconnecting the transport clears outstanding requests and reply tracking. There is no automatic request resend; [class sharing](position-sharing.md#connection-and-limits) uses this exchange on join instead of recurring announcements. Older clients ignore these frames while continuing to exchange streaming data.

Switching/leaving the group, logging out or entering read-only settings stops the old data transport and its retries while retaining feature registrations. Switching/leaving also leaves the old data channel. Both old group channels are removed from saved chat-window subscriptions, and late joins for obsolete group channels are left again. Login, world entry and restored chat settings clean up leftover names matching the complete generated format, preserving the current group and unrelated channels; newer-schema read-only startup skips this cleanup. Reconnecting notifies features to reset send suppression. Human chat and unrelated channels retain their own controls. The pipeline has no queue, fragmentation, signing, encryption or authentication handshake.

## In-game checks

- Compare fingerprints after entering the same key with different case/whitespace; reload, relog and change characters. Existing `LIT1-` groups must retain their fingerprint and channel.
- On a fresh install, check that welcome opens once with a visible saved key and shared chat begins joining. Copy the key, reload and reopen `/lit`; it must stay the same. Join a friend's key and verify confirmation, the updated displayed key and the new chat channel. Check layout at different UI scales, Escape/close cleanup, and **More options**.
- Verify create versus save, copy/masking, switch/leave confirmations, help/status/welcome, and unsaved fields surviving notices. Switching/leaving groups must leave both previous group channels and remove them from every chat window while preserving unrelated channels. Repeat with a pending old join and with old addon channels restored on reload/relog.
- After reload and a group switch, check readable chat/data labels and current `/number` routing without changing normal message text or unrelated channel labels. Follow the [shared-chat checks](shared-chat.md#in-game-checks) for clickable labels and the composer header.
- With chat autojoin and position sharing off, confirm that group data still connects. Check automatic reconnection after `/lit data leave` or a native leave, recovery within about 15 seconds of silent loss, continuing retries after rejected joins, `/lit data join` for an immediate retry and local channel-number changes. Human-chat state must stay unchanged. See the [position checks](position-sharing.md#in-game-checks) for peer delivery and map behavior.
