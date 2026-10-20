# Player overview

Open `/lit`, `/lit content` or `/lit overview` to see your group's discovered characters on **Content → Overview**. The table shows up to eight players at a time; use the mouse wheel or scrollbar to browse the roster. Click **Name**, **Level**, **Region** or **Last seen** to sort, and click again to reverse the order. Initially your character appears first, followed by active players and then names; unknown values stay last when sorting. The **Settings** header button opens group and feature preferences.

**Level** includes XP progress toward the next level as a percentage and a small bar. Hover it for exact XP and XP remaining. Your own values are read locally. A dash means XP is unavailable; `0%` is a valid empty bar, and `MAX` means the client confirmed the level cap. Retained progress is marked with `~` when contact is lost. An unchanged XP value remains current while contact continues.

Clients share level, XP, party availability and the position-sharing preference through one status connection. Changes send the complete current status at most every five seconds, with a full refresh after thirty seconds without a broadcast. Connecting exchanges initial snapshots. Unchanged refreshes maintain presence without resetting the XP report age. Your own progress updates immediately. XP stays in memory; after reload, reconnect or a group change, fresh reports are required.

## Discovery and optional positions

Discovery uses the [group connection](group.md#shared-data-pipeline), independently of shared chat and [position sharing](position-sharing.md). Position sharing starts off; Overview does not enable it. When sharing settings allow positions, Overview shows the region without coordinates or a location age. A retained region is marked **Last:** when the current position is unavailable.

Discovered characters remain saved account-wide for the current group. Reloaded entries start inactive; changing or leaving the group clears them. **Last seen** shows **Active** during recent addon contact, or an elapsed time such as **3m ago** when contact expires. This does not confirm a logout, and unknown information stays visibly unknown.

## Party actions and limits

Each player's **Actions** dropdown offers **Invite** and **Request to join** through WoW's native party controls. Availability depends on recent contact, party membership, permissions, space and supported client APIs. Disabled actions explain why; eligibility is checked again on selection, and native confirmations and acceptance still apply.

The roster is a list of locally discovered characters, not every key holder. Discovery is limited to the same internal realm and faction. All participants need an addon version that sends complete status refreshes.

## In-game checks

- Open Overview directly, switch to Settings and back to Content in the same window, and check that Settings retains its selected page and the window stays in place.
- With two clients sharing a key, check discovery, XP gains and party actions while chat and position sharing are off. Check level-up resets, exact-XP tooltips, zero/unknown/MAX states and both interface themes. Then enable positions and check region names without coordinates or ages.
- Stay at unchanged XP, then reconnect or reload; check that periodic refreshes keep players **Active**, loss of contact shows an elapsed time and retained progress, and reconnecting refreshes the snapshot. Delivery, level-cap detection and rendering require in-game validation.
- With more than eight players, check wheel and scrollbar navigation, fixed headers and both sort directions. Check retained inactive players after reload and roster clearing after a group change.
- Check the Actions dropdown, disabled reasons and native confirmations with eligible and unavailable players. Check dismissal on scrolling, sorting, outside clicks, Escape and window close. Actual delivery, native eligibility and rendering remain unvalidated.
