# Player overview

Open `/lit`, `/lit content` or `/lit overview` to see your group's discovered characters on **Content → Overview**. The table shows up to eight players at a time; use the mouse wheel or scrollbar to browse the roster. Click **Name**, **Level**, **Region** or **Last seen** to sort, and click again to reverse the order. Initially your character appears first, followed by active players and then names; unknown values stay last when sorting. The **Settings** header button opens group and feature preferences.

## Discovery and optional positions

Discovery uses the [group connection](group.md#shared-data-pipeline), independently of shared chat and [position sharing](position-sharing.md). Position sharing starts off; Overview does not enable it. When sharing settings allow positions, Overview shows the region and update age without exact coordinates. A retained region is marked **Last:** when the current position is unavailable.

Discovered characters remain saved account-wide for the current group. Reloaded entries start inactive; changing or leaving the group clears them. “Active” means recent addon contact. “Last seen” does not confirm a logout, and unknown information stays visibly unknown.

## Party actions and limits

Each player's **Actions** dropdown offers **Invite** and **Request to join** through WoW's native party controls. Availability depends on recent contact, party membership, permissions, space and supported client APIs. Disabled actions explain why; eligibility is checked again on selection, and native confirmations and acceptance still apply.

The roster is a list of locally discovered characters, not every key holder. Discovery is limited to the same internal realm and faction. Older clients may provide less information.

## In-game checks

- Open Overview directly, switch to Settings and back to Content, and check that Settings retains its selected page and only one window is visible.
- With two clients sharing a key, check discovery and levels while chat and position sharing are off, then enable positions and check region names, update ages and the absence of exact coordinates.
- With more than eight players, check wheel and scrollbar navigation, fixed headers and both sort directions. Check retained inactive players after reload and roster clearing after a group change.
- Check the Actions dropdown, disabled reasons and native confirmations with eligible and unavailable players. Check dismissal on scrolling, sorting, outside clicks, Escape and window close. Actual delivery, native eligibility and rendering remain unvalidated.
