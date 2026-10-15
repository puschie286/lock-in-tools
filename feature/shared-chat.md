# Shared chat

Native WoW chat for friends using the same [group key](group.md), faction and realm/ruleset context. There is no external backend.

## Use

1. Open `/lit`, enable **Automatically join shared chat on login**, and click **Save chat settings**; alternatively, use `/lit join`.
2. Wait for **Joined**, then use `/lit chat` to type in normal WoW chat.

## Joining and leaving

- `/lit join` works with autojoin disabled. `/lit leave` pauses reconnection for this session and keeps the group.
- Disabling autojoin stops future addon join requests but keeps confirmed membership; WoW may independently restore permanent channels.
- Changing or leaving the group cancels pending requests and leaves its previous channel, including independently restored membership. Unrelated channels are preserved.

## Behavior and limits

`Chat.lua` joins once the character is ready, on eligible logins or saved group/autojoin changes. `JoinPermanentChannel` receives derived credentials; roster-confirmed owners/moderators request `SetChannelPassword`. Channel notices/list updates confirm membership. Transient retries are bounded; wrong passwords, kicks, bans and deliberate leaves stop them until an explicit retry or eligible later login.

`/lit chat` resolves the current channel number by name. The native interface handles sending on Enter, display, links and restrictions. There is no dedicated Friends tab, automated human-chat payload, offline delivery or synchronized history.

Native password admission depends on WoW's ownership rules. **Joined** confirms membership without authenticating every participant; human messages are neither signed nor encrypted end to end. Server routing, password enforcement and ownership behavior remain unverified in game.

## In-game checks

- Record build, region, faction and realm/ruleset. Two ungrouped friends should exchange messages across zones, guilds, layers and instances; changing unrelated channel numbers must keep `/lit chat` targeting correctly.
- Reverse join order, transfer ownership, let the owner/everyone leave, then rejoin an empty room. Wrong passwords must fail clearly without retry loops; inspect access before password application.
- Reload, relog and switch characters without duplicate requests. Addon/native leave must stay paused across zone changes; disabling autojoin must prevent later addon requests.
- Check restricted/unavailable APIs and combat transitions for errors. Repeat routing and password checks when moving from beta to a release client.
