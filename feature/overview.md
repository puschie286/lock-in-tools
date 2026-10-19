# Player overview

Open `/lit overview` or **Overview** in `/lit options` to see your group's discovered characters. Four players appear per page with their name, level, last position, activity and party actions.

## Discovery and optional positions

Discovery uses the [group connection](group.md#shared-data-pipeline), independently of shared chat and [position sharing](position-sharing.md). Position sharing starts off; Overview does not enable it. Coordinates appear only when your sharing settings allow them, with the age of the last position update.

Discovered characters remain saved account-wide for the current group. Reloaded entries start inactive; changing or leaving the group clears them. “Active” means recent addon contact. “Last seen” does not confirm a logout, and unknown information stays visibly unknown.

## Party actions and limits

**Invite** and **Request to join** use WoW's native party controls. Availability depends on recent contact, party membership, permissions, space and supported client APIs. Disabled actions explain why; native confirmations and acceptance still apply.

The roster is a list of locally discovered characters, not every key holder. Discovery is limited to the same internal realm and faction. Older clients may provide less information.

## In-game checks

- With two clients sharing a key, check discovery and levels while chat and position sharing are off, then enable positions and check their age.
- Check paging, retained inactive players after reload, and roster clearing after a group change.
- Check party actions and native confirmations with eligible and unavailable players. Actual delivery, native eligibility and rendering remain unvalidated.
