# Position sharing

Share world-map positions with friends using the same [group key](group.md), internal realm and faction. The addon connects through the separate **LITDATA** channel automatically; position sharing starts off. Whisper fallback is disabled pending validation.

## Use and behavior

1. Open `/lit options`, enable **Enable position sharing**, and click **Save position settings** on each client. **Keep last-known positions** starts enabled.
2. Check `/lit status` for the group-data connection and position state, then open the world map. Group data reconnects automatically regardless of the position preference. `/lit data leave` temporarily disconnects without leaving the group or human chat; `/lit data join` requests an immediate retry.
3. Open the world map's filter dropdown and use **Show player icons** under **LockInTools** to hide or show the addon's player pins and names. It starts enabled, applies immediately and is saved account-wide across reloads and characters. Sharing, incoming updates, class discovery and last-known retention continue while icons are hidden; showing them again uses the latest received locations.

The model checks movement every two seconds. It broadcasts changed serialized map/coordinates, or a heartbeat after 15 seconds without an accepted send: normally every 16 seconds with two-second polling. Unavailable positions use the same suppression and heartbeat. Failed sends retry the current sample on the next tick, without a backlog. Reconnecting, switching groups or re-enabling sharing resets suppression.

Pins show player names without update ages and use native 16-pixel class icons. Active peers have full-color icons; 60 seconds without a valid newer position update dims them to grayscale with **(Offline)**. This means no recent position data here, not confirmed logout. Retained peers restored after reload also start offline. Peers or saved positions without class information keep the cyan/gray square until their class is learned. Pins use their own map coordinates or native map rectangles; when no usable rectangle exists, native world-coordinate conversion places them on overlapping maps such as Thunder Bluff and Mulgore. Positions outside the displayed map are omitted.

While the map is visible, online pins move linearly from their displayed position to each new position over two seconds. A new target continues from the current displayed point; class updates and other peers do not restart the movement. This adds up to about two seconds of visual delay without predicting movement or increasing network traffic. Opening or switching the map, first sightings, presence changes, source-zone changes and jumps exceeding 10% of the source map snap to the latest coordinates. Offline pins stay fixed, and animation stops at the last received position. Smoothing never changes saved coordinates.

Last-known coordinates and known classes persist across reloads and characters; changing or leaving the group clears them. An unavailable-position update confirms activity and preserves previous coordinates when retention is enabled. With retention off, unavailable updates remove pins immediately and silence removes them after 60 seconds. Disabling sharing hides pins and stops position sampling/receiving while preserving retained locations; the shared data connection remains available to other features.

## Connection and limits

`Position.lua` uses the [shared data pipeline](group.md#shared-data-pipeline) under `position`. `Data.lua` keeps the temporary group-derived channel connected while the character is ready and a valid, writable group is configured, independently of chat autojoin and the position preference. Disconnects reconnect after about one second; a 15-second membership check catches silent loss. Retries continue with delays capped at 30 seconds, including after native errors. It broadcasts each packet once through `CHANNEL`; receiving requires the addon prefix and current group route. No roster lookup or whisper delivery is needed. Native full-name matching excludes self echoes.

Class sharing uses the [shared request/response helpers](group.md#shared-data-pipeline) under `position-class`. When sharing is enabled and group data connects or reconnects, the client sends one request containing its own class. Every enabled peer learns the requester's class and replies with its own; only the requester consumes those replies. There are no periodic class announcements. A failed request send retries on the next two-second tick, up to three attempts per connection/enable cycle. Accepted sends do not guarantee delivery; reconnecting or disabling/re-enabling sharing starts a fresh exchange if a class is missing.

Class payloads (`1|C|timestamp|CLASS`) retain independent ordering and never create coordinates or keep an old position online. Existing position/unavailable packet formats are unchanged, so older addon versions still exchange positions. Legacy class broadcasts are still readable, but clients without the new request helpers cannot answer class requests. Update and `/reload` on each client to use the exchange.

Delivery is supported within the validated internal-realm scope. Two clients on `ClassicBetaPvE` and `ClassicBetaPvE2` saw separate self-only channels despite matching PvE rulesets and faction. A [firsthand beta report](https://us.forums.blizzard.com/en/wow/t/wow-forever-custom-chat-channels-not-working-crossrealm-not-game-mode/2370263) describes the same split. Cross-internal-realm sharing is unsupported; there is no production whisper fallback.

This is a convenience feature for trusted friends. Messages are plain, without signing, encryption or authentication handshakes. Format, coordinate and ordering checks support correct behavior; channel membership does not authenticate individual peers. Never log group keys or passwords. Native acceptance confirms a send request, not delivery.

Each moving sender produces up to 30 position broadcasts/minute; unchanged positions normally produce about 3.75/minute. Class traffic is one request plus one response per connected, enabled peer when a client joins or starts sharing, with no ongoing class heartbeat. Capacity for 6–10 players and other future features remains an in-game check. `PositionMap.lua`/`PositionPins.xml` use native map pins; actual rendering also remains unverified in game. Existing group credentials and newer-schema read-only behavior are preserved.

## Live evidence

Transport checks using a now-removed standalone probe ran on client **1.60.1/70450**; they do not establish production pin rendering or recovery.

| Test | Observed result |
| --- | --- |
| Two ClassicBetaPvP/Horde clients, CHANNEL | Each received 21 valid peer positions; receive gaps were 4.95–5.04 and 4.77–5.25 seconds. Each accepted 23 sends with no send errors or rejected updates. |
| ClassicBetaPvE/Alliance versus ClassicBetaPvE2/Alliance | Each accepted 23 channel sends but received only self echoes. Self-only rosters supplied no automatic-whisper targets; whisper delivery was not exercised. |
| Solo ClassicBetaPvP/Horde, 2026-10-19 | Channel and whisper self receipts passed, with the native full name recognized. Self receipts do not prove peer delivery. |

The channel run used five-second probe samples, not production movement suppression. Unsynchronized run overlap means send/receive totals are not a packet-loss measurement. An earlier 10.61-second gap coincided with reported loading; loading recovery still needs validation.

## In-game checks

- Open the world map's filter dropdown and check **LockInTools → Show player icons** starts checked. With sharing enabled and a moving peer visible, uncheck it and confirm all addon icons and names disappear immediately. Keep moving both clients, then check it again: peers must appear at their latest location and continue moving. Leave it unchecked through `/reload` and a character switch, then confirm it stays unchecked. Check offline and retained peers follow the same filter, expiry continues while hidden, and toggling it leaves position-sharing settings unchanged.
- Watch a moving peer with the world map open: pins should move smoothly between two-second updates. Stop and confirm the pin reaches the last received position without continuing beyond it. Close/reopen or switch maps during movement and check immediate placement; source-zone changes and large jumps must snap. Class updates and other peers' movement must not interrupt a pin's progress.
- With two updated clients sharing a key, internal realm and faction, enable sharing and confirm matching class icons, moving pins near two-second updates, unchanged/unavailable heartbeats near 16 seconds, and grayscale offline icons after 60 seconds of position silence. Check names, self-echo exclusion, retention on/off and restored classes after reload. Connect a third client while peers are moving: it must learn their classes from replies, and both peers must learn its class from the request. Repeat simultaneous joins, reconnects, sharing toggles and group changes; class traffic must stop after each exchange. Check older clients still exchange positions and class-only messages cannot keep stale coordinates online.
- With a peer in Thunder Bluff, switch between Thunder Bluff, Mulgore and Kalimdor; the pin must appear at the corresponding location on all three. Move into Mulgore and repeat, checking the city map only shows the pin while its position is within that map. Also check unrelated maps, delayed map loading, combat, layers, unavailable coordinates and recovery after loading. Repeat with 6–10 clients and longer runs; inspect errors and update gaps.
- With chat autojoin and sharing disabled, check automatic data connection and reconnection after `/lit data leave` or a native channel leave, without saving settings. Check silent loss recovery within about 15 seconds, continuing retries after rejected joins, `/lit data join` for an immediate retry and channel renumbering. Existing connections and pending joins must not duplicate or restart.
- With sharing enabled, disconnect the data channel and confirm automatic reconnection resumes positions. Changing/leaving the group must stop old-channel retries, leave that channel and clear position caches while preserving unrelated channels and human-chat preferences. Logout and newer-schema read-only settings must stop the data transport.

[Offline verification](../tests/testing.md) checks the model, native channel callbacks and map callbacks. Delivery between clients, rendering and larger-group performance require the live checks above.
