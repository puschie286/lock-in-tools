# Position sharing

Share world-map positions with friends using the same [group key](group.md), internal realm and faction. The addon connects through the separate **LITDATA** channel automatically; position sharing starts off. Whisper fallback is disabled pending validation.

## Use and behavior

1. Open `/lit options`, enable **Enable position sharing**, and click **Save position settings** on each client. Saving with sharing enabled automatically reconnects a paused or failed data connection when a group is configured and the character is ready. An existing connection or pending join continues unchanged. **Keep last-known positions** starts enabled.
2. Check `/lit status` for the group-data connection and position state, then open the world map. `/lit data leave` pauses it without leaving the group or human chat; it stays paused until you save with sharing enabled again or use `/lit data join`.

The model checks movement every two seconds. It broadcasts changed serialized map/coordinates, or a heartbeat after 15 seconds without an accepted send: normally every 16 seconds with two-second polling. Unavailable positions use the same suppression and heartbeat. Failed sends retry the current sample on the next tick, without a backlog. Reconnecting, switching groups or re-enabling sharing resets suppression.

Pins show player names without update ages. Recent peers are cyan; 60 seconds without a valid newer update marks them gray with **(Offline)**. This means no recent data here, not confirmed logout. Retained peers restored after reload also start offline. Native map rectangles project coordinates onto their own zone and parent maps.

Last-known coordinates persist across reloads and characters; changing or leaving the group clears them. An unavailable-position update confirms activity and preserves previous coordinates when retention is enabled. With retention off, unavailable updates remove pins immediately and silence removes them after 60 seconds. Disabling sharing hides pins and stops position sampling/receiving while preserving retained locations; the shared data connection remains available to other features.

## Connection and limits

`Position.lua` uses the [shared data pipeline](group.md#shared-data-pipeline) under `position`. `Data.lua` joins the temporary group-derived channel on login, independently of chat autojoin and the position preference. It broadcasts each packet once through `CHANNEL`; receiving requires the addon prefix and current group route. No roster lookup or whisper delivery is needed. Native full-name matching excludes self echoes.

Delivery is supported within the validated internal-realm scope. Two clients on `ClassicBetaPvE` and `ClassicBetaPvE2` saw separate self-only channels despite matching PvE rulesets and faction. A [firsthand beta report](https://us.forums.blizzard.com/en/wow/t/wow-forever-custom-chat-channels-not-working-crossrealm-not-game-mode/2370263) describes the same split. Cross-internal-realm sharing is unsupported; there is no production whisper fallback.

This is a convenience feature for trusted friends. Messages are plain, without signing, encryption or authentication handshakes. Format, coordinate and ordering checks support correct behavior; channel membership does not authenticate individual peers. Never log group keys or passwords. Native acceptance confirms a send request, not delivery.

Each moving sender produces up to 30 broadcasts/minute; unchanged positions normally produce about 3.75/minute per sender, regardless of group size. Capacity for 6–10 players and other future features remains an in-game check. `PositionMap.lua`/`PositionPins.xml` use native map pins; actual rendering also remains unverified in game. Existing group credentials and newer-schema read-only behavior are preserved.

## Live evidence

Transport checks using a now-removed standalone probe ran on client **1.60.1/70450**; they do not establish production pin rendering or recovery.

| Test | Observed result |
| --- | --- |
| Two ClassicBetaPvP/Horde clients, CHANNEL | Each received 21 valid peer positions; receive gaps were 4.95–5.04 and 4.77–5.25 seconds. Each accepted 23 sends with no send errors or rejected updates. |
| ClassicBetaPvE/Alliance versus ClassicBetaPvE2/Alliance | Each accepted 23 channel sends but received only self echoes. Self-only rosters supplied no automatic-whisper targets; whisper delivery was not exercised. |
| Solo ClassicBetaPvP/Horde, 2026-10-19 | Channel and whisper self receipts passed, with the native full name recognized. Self receipts do not prove peer delivery. |

The channel run used five-second probe samples, not production movement suppression. Unsynchronized run overlap means send/receive totals are not a packet-loss measurement. An earlier 10.61-second gap coincided with reported loading; loading recovery still needs validation.

## In-game checks

- With two clients sharing a key, internal realm and faction, enable sharing and confirm moving pins near two-second updates, unchanged/unavailable heartbeats near 16 seconds, and gray offline pins after 60 seconds of silence. Check names, self-echo exclusion, retention on/off and restored peers after reload.
- Check zone/continent projection, delayed map loading, combat, layers, unavailable coordinates and recovery after loading. Repeat with 6–10 clients and longer runs; inspect errors and update gaps.
- Check automatic data connection with chat autojoin and sharing disabled, `/lit data leave`/`join`, channel renumbering and disconnect recovery. Changing/leaving the group must leave the old data channel and clear position caches while preserving unrelated channels and human-chat preferences.
- Leave the data channel, then enable sharing and save; it must reconnect and resume positions without `/lit data join`. Repeat by saving while sharing is already enabled. An intentional leave afterward must stay paused until another enabled save/retry. Existing joins must not duplicate or restart, and rejected joins must stop after bounded retries.

[Offline verification](../tests/testing.md) checks the model, native channel callbacks and map callbacks. Delivery between clients, rendering and larger-group performance require the live checks above.
