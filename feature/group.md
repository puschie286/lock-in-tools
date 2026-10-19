# Groups

One account-wide group key connects friends across all LockInTools features. The key and preferences persist across reloads and characters.

## Setup and management

Open `/lit` for the welcome screen. It creates a key when none is saved; use **Select key** and Ctrl+C to share it. To join a friend, enter their key, choose **Join friend**, then **Confirm switch**. Shared chat joins automatically when autojoin is enabled.

Use `/lit options` to create, reveal, replace or leave a group. Switching and leaving require confirmation, affect every feature and clear the old group's channels and cached peers. [Leaving chat](shared-chat.md) alone keeps the group. Closing a window clears its displayed key fields without deleting the saved key.

`/lit help` lists commands, `/lit status` shows the public group fingerprint and feature state, and `/lit welcome on|off` controls the login welcome.

## Shared data pipeline

[Player overview](overview.md) and [position sharing](position-sharing.md) share an automatically reconnecting data connection, separate from human chat. It remains available when chat autojoin or position sharing is off. `/lit status` shows its connection state.

## Limits

Group keys provide shared access for trusted friends. All holders have equal authority; replace the key to remove access. Keys are stored locally, and shared messages are not encrypted or individually authenticated. Delivery is limited to the same internal realm and faction; cross-realm sharing is unsupported.

## In-game checks

- Share a key between two clients, then reload and switch characters to check persistence and matching fingerprints.
- Switch or leave a group and confirm the old channels and peers are cleared. Check data reconnects independently of human chat and position sharing.
