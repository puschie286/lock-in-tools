# Position sharing

Position settings, sampling, retained locations and world-map pins are implemented. **Group communication remains planned and disconnected** pending live transport validation. Actual map rendering also needs an in-game check.

## Use and behavior

Open `/lit options` for **Enable position sharing** and **Keep last-known positions**. Sharing starts off; retention starts on. Disabling sharing hides pins and stops receiving/sampling while preserving retained locations.

Pins show player names without update ages. Peers with recent data are cyan; 60 seconds without a valid newer update marks them gray with **(Offline)**. Cached peers restored after reload are also offline until a new update arrives. Offline means no recent data here; it does not confirm logout. Native map rectangles project positions onto their own zone and parent maps.

Last-known coordinates persist across reloads and characters in the account-wide settings; switching or leaving the group clears them. With retention off, unavailable updates remove pins immediately and silence removes them after 60 seconds. An unavailable-position update confirms activity and, with retention on, preserves the previous coordinates.

The model samples every two seconds when a connection is supplied. It sends when the serialized map/coordinates change, excluding timestamps from the comparison, or once 15 seconds have passed since the last accepted send. With two-second polling, unchanged-position heartbeats normally arrive every 16 seconds; delayed sampling can extend this. Unavailable-position updates use the same suppression and heartbeat. Failed sends retry the latest current sample on the next tick without a backlog; reconnecting, switching groups or re-enabling sharing resets suppression. Until connected, status reads **Waiting for a group connection**, and the feature sends no network messages.

`Position.lua` owns the model and additive schema-3 preferences. `PositionMap.lua`/`PositionPins.xml` use native map pins without a library. Existing [group credentials](group.md) and newer-schema read-only behavior remain intact. Restart WoW after adding these files to the manifest.

Position sharing uses the [shared data pipeline](group.md#shared-data-pipeline) under the `position` identifier. It sends through `SendData` and registers its receiver once; the backend delivers WoW's sender to `ReceivePosition`. Reconnecting resets movement suppression. Group changes disconnect the backend until it reconnects to the new group. These paths are tested with mocked connections.

## Planned communication

Prefer one addon broadcast through the group's separate **LITDATA** channel when peer delivery is proven; otherwise whisper to peers discovered through its roster. Other features will share this pipeline. Channel membership stays independent of shared-chat controls. A working broadcast does not depend on roster retrieval; whisper fallback does.

The communication foundation will serve other features and should support **6–10 players**. Position updates require up to 30 broadcasts/minute per moving sender, or about 3.75/minute while unchanged. At ten players, whispering to the other nine requires up to 270 outgoing whispers/minute while moving or about 33.75/minute while unchanged. Idle rates assume the normal 16-second heartbeat cadence. Validate cadence, traffic and membership changes before connecting it; additional features will share client/server capacity.

This is a convenience feature for trusted friends. Use plain messages without signing or authentication handshakes. Check message format, coordinates and ordering for correct behavior. Ordering does not expire retained pins. Never log group keys or passwords.

## Transport probe

The separate developer addon under `tools/position-probe/` is not loaded by `LockInTools.toc` and saves no settings or positions. Assemble it with:

```powershell
.\tools\position-probe\prepare.ps1
```

Copy/link the resulting `tools/position-probe/package/LockInToolsPositionProbe` folder beside LockInTools in the client's `Interface/AddOns`. Restart WoW and enable **LockInTools Position Probe**. It stays inactive until started.

- `/litprobe channel`: two-minute broadcast-only run, one sample every five seconds.
- `/litprobe whisper`: two-minute whisper-only run, up to nine roster-discovered recipients per sender.
- `/litprobe start`: quick comparison of both paths with independent receipt/order statistics.
- `/litprobe self`: one-client coordinate, whisper and channel-echo check; does not prove peer delivery.
- `/litprobe status`: per-path attempts/rate, API acceptance, payload bytes, errors, received positions and receipt gaps.
- `/litprobe stop`: cancel and leave only the probe channel. Logout/group changes also stop it.

Use separate channel/whisper runs for performance comparisons so they do not compete for message allowance. The probe sends every five seconds even when unchanged; it does not use feature suppression or heartbeats. It samples/serializes once per interval, resolves channel numbers dynamically and isolates failures. Native roster selection may change the Channels panel selection; its completeness remains unverified. The diagnostic does not feed feature pins.

## Validation and remaining work

On two ungrouped clients sharing a key, realm and faction, run channel mode on both, then whisper mode on both. Confirm repeated peer positions near five-second intervals while moving. Repeat across zones, layers, combat, unavailable coordinates, channel leave/rejoin and local channel-number changes. Check errors/gaps and preserve ordinary chat/unrelated channels. Repeat with 6–10 clients for capacity.

**Selection:** prefer broadcasts when repeated peer delivery passes on both clients; otherwise use whispers when roster discovery and whisper delivery pass. API acceptance, one receipt or self echoes are insufficient. If neither passes, communication remains unresolved.

After connecting a validated transport, check moving updates near two-second intervals, unchanged/unavailable heartbeats near 16 seconds, and silence marking peers **(Offline)** after 60 seconds. Check cyan active pins, gray offline/restored pins, renewed activity, retention on/off, zone/continent projection, delayed map loading, reloads and character changes. Unavailable positions confirm activity; they remove pins immediately only with retention off. Disabling sharing hides pins; group changes clear caches.

[Offline verification](../tests/testing.md) covers model behavior, native map callbacks and the probe. It does not establish rendering or actual server delivery. **Live validation remains pending: no second client is currently available; neither transport nor 6–10-player performance has been proven.**
