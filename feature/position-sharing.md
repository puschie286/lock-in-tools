# Position sharing

Show friends' locations on the world map using the same [group key](group.md). Sharing is optional and starts disabled.

## Use and behavior

Open `/lit options` → **Shared positions** and enable sharing on each client. Compact class-colored dots move smoothly between updates; unknown classes use blue. Names appear only on hover, with one shared tooltip listing players whose dots overlap. After 60 seconds without a fresh position, a dot becomes a hollow gray ring and its tooltip says **Last known position**; this indicates stale data rather than a confirmed logout.

- **Keep last-known positions** starts enabled and retains locations across reloads, logins and characters. Disabling sharing hides pins and stops position exchange; changing or leaving the group clears retained locations.
- **Show player icons**, under **LockInTools** in the world map filter, hides the dots while sharing continues.

These preferences save account-wide and apply immediately. Checkbox labels are clickable; tooltips explain each setting and provide full connection details.

## Connection and limits

Positions use the [shared data connection](group.md#shared-data-pipeline), independently of human chat. Movement is checked every two seconds and sends only when the location changes. Current locations also travel with player-status reports, including initial snapshots and idle refreshes every thirty seconds; there is no separate position heartbeat. This exchange requires position sharing to be enabled. `/lit status` shows connection state; reconnecting happens automatically.

Friends must share an internal realm and faction. Cross-realm delivery and whisper fallback are unsupported. Messages are plain and intended for trusted friends. Locations can lag behind movement or be unavailable in some areas; smoothing adds display delay.

## In-game checks

- With two clients, check moving dots, stationary refreshes, initial locations for a newly connected client and no location exchange while sharing is off. Check class colors, hollow stale/retained dots, hover-only names and overlapping-player tooltips at different map zooms and UI scales. Check map filtering and cleanup on map close, reload and zone changes, plus checkbox labels and help tooltips.
- Check recovery after a connection loss and cleanup after switching groups. Map rendering, recovery and larger-group performance still require in-game validation.
