# Groups

One account-wide group key connects friends across all LockInTools features. The key and preferences persist across reloads and characters.

## Setup and management

Open `/lit options` and select **Group** to share or manage your key. Use **Select key** and Ctrl+C to copy the saved key. To join a friend, enter their key, choose **Use key**, then confirm the switch. **Generate key** prepares a new key without changing your group until you choose **Use key**. Shared chat joins automatically when autojoin is enabled.

Key fields remain readable. **Group info** provides scope, sharing limits and the public group ID in a tooltip. Switching and leaving require confirmation, affect every feature and clear the old group's channels and cached peers. [Leaving chat](shared-chat.md) alone keeps the group. Leaving Group or closing Settings clears displayed key fields and drafts without deleting the saved key.

Switching pauses sharing and leaves both old channels before joining the saved group. Settings shows **Leaving previous group...** while departure is pending; failed leaves retry automatically. The selected key is saved immediately, and a newer selection replaces the pending destination.

`/lit` opens Content and its Overview page. Initial login setup creates a key only when none is saved; `/lit welcome on|off` controls whether Content opens for this setup. `/lit help` lists commands, and `/lit status` shows the public group fingerprint and feature state.

## Shared data pipeline

[Player overview](overview.md) and [position sharing](position-sharing.md) share an automatically reconnecting data connection, separate from human chat. It remains available when chat autojoin or position sharing is off. `/lit status` shows its connection state.

The connection carries player status: level, XP, party availability and the position-sharing preference. Every five seconds it checks for changes and sends the complete current status when needed. A full refresh after thirty seconds without a status broadcast maintains presence; connecting also exchanges initial snapshots. Each report is independent, so a later report replaces a missed one without recovery requests. With position sharing enabled, status reports include the current location; movement updates remain separate and check every two seconds.

## Limits

Group keys provide shared access for trusted friends. All holders have equal authority; replace the key to remove access. Keys are stored locally, and shared messages are not encrypted or individually authenticated. Delivery is limited to the same internal realm and faction; cross-realm sharing is unsupported.

## In-game checks

- Share a key between two clients, then reload and switch characters to check persistence and matching group IDs under **Group info**. Check key selection, draft cleanup and tooltip dismissal when leaving the page or closing Settings.
- Switch or leave a group and confirm sharing pauses, both old channels are left before new joins, and old peers disappear. Check data reconnects independently of human chat and position sharing.
