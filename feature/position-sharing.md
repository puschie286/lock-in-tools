# Position sharing

Show friends' locations on the world map using the same [group key](group.md). Sharing is optional and starts disabled.

## Use and behavior

Open `/lit options` → **Shared positions** and enable sharing on each client. Pins show player names and class icons, with smooth movement between updates. After 60 seconds without a fresh position, a pin becomes gray and **(Offline)**; this indicates stale data rather than a confirmed logout.

- **Keep last-known positions** starts enabled and retains locations across reloads and characters. Disabling sharing hides pins and stops position exchange; changing or leaving the group clears retained locations.
- **Show player icons**, under **LockInTools** in the world map filter, hides pins and names while sharing continues.
- **Show movement trails** adds fading paths behind moving pins. Trails start enabled at 10 seconds, adjustable from 1–30 seconds. Trail paths are temporary and are not saved or transmitted.

These preferences save account-wide and apply immediately. Checkbox labels are clickable; tooltips explain each setting and provide full connection details. Trail length remains editable while trails are off.

## Connection and limits

Positions use the [shared data connection](group.md#shared-data-pipeline), independently of human chat. `/lit status` shows connection state; reconnecting happens automatically.

Friends must share an internal realm and faction. Cross-realm delivery and whisper fallback are unsupported. Messages are plain and intended for trusted friends. Locations can lag behind movement or be unavailable in some areas; smoothing adds display delay.

## In-game checks

- With two clients, check moving pins, class icons, trails, map filtering and stale/retained locations, including after reload and zone changes. Check checkbox labels, trail input and help tooltips at different UI scales.
- Check recovery after a connection loss and cleanup after switching groups. Map rendering, recovery and larger-group performance still require in-game validation.
