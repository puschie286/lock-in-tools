# Shared chat

Native WoW chat for friends using the same [group key](group.md), faction and realm/ruleset context, with no external backend.

## Use

Use **Group** in `/lit options` to share a key or join a friend's group. Shared chat joins automatically by default; change **Automatically join shared chat on login** under **Shared chat**, or join manually with `/lit join`. Once **Joined**, use `/lit chat` to type in normal WoW chat.

`/lit leave` pauses reconnection for the session and keeps the group. Disabling autojoin retains existing membership. Changing or leaving the group removes its old channels and saved subscriptions.

## Limits

The native interface handles messages, links and restrictions. Channels appear locally as **LockInTools** and **LockInTools Data**; native channel management or other chat addons may show their generated names. There is no dedicated Friends tab, offline delivery or synchronized history.

Password protection depends on WoW's channel ownership rules. **Joined** confirms membership, not participant identity; messages are neither signed nor encrypted end to end. Server routing, password enforcement and ownership behavior remain unverified in game.

## In-game checks

- Record client and realm context; exchange messages across zones and instances, checking labels and `/lit chat` routing.
- Check autojoin, manual leave and group changes across reloads and logins, including old-channel cleanup.
- Test wrong passwords and ownership changes for clear failures and correct access control.
