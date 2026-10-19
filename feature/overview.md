# Player overview

Open `/lit overview`, or select **Overview** in `/lit options`, to see characters discovered in your LockInTools group. The existing settings window and its native/optional EllesmereUI style are reused. Four players appear per page; **Previous** and **Next** reach the rest. The ordinary first settings open still selects **Group**.

Each row shows the character's name, level, last position, recent activity and **Invite** / **Request to join**. Your own character appears first, followed by recently seen peers and retained peers. Unknown levels and positions remain visibly unknown. “Active” means recent addon contact; silence is shown as “Last seen”, not a confirmed logout.

## Discovery and optional positions

Name, level and party metadata use the existing [shared data connection](group.md#shared-data-pipeline), independently of human chat and position sharing. Updated clients exchange a roster snapshot when connecting and when opening Overview, with requests limited to once per ten seconds. Presence broadcasts follow local metadata changes on events/the next five-second check, and otherwise every 30 seconds. After 90 seconds without fresh presence a peer remains listed as last seen, with party actions disabled. Reopening the page does not create another connection.

Discovered names, levels and last-contact times persist account-wide for the current group. Reloaded entries start inactive; changing or leaving the group clears the roster. Existing group credentials, saved-data migrations and newer-schema read-only behavior are preserved. The optional roster cache adds no schema-version change.

[Position sharing](position-sharing.md) stays optional and starts off. Overview neither enables it nor sends coordinates in roster messages. The existing sharing and retention controls govern received/cached positions; with local sharing disabled the page shows no shared coordinates. A player can appear with name and level while not sharing a position. Available locations show the zone and coordinates, with the time since the last coordinate update. Unavailable updates and presence heartbeats cannot make old coordinates look newer. Old cached locations with no reliable coordinate timestamp show an unknown age.

## Party actions and limits

**Invite** uses WoW's normal party invitation when the peer is recently seen and ungrouped, you have invite permission, and your party has space. **Request to join** uses WoW's native join request when you are solo and the peer reports a party with space. Requests may be made through a party member; native target eligibility still applies. Actions are disabled for yourself, current party/raid members, stale players and unsupported APIs. Hover a disabled action for its reason. Eligibility is checked again on click. Native invitation acceptance and confirmation remain required; a Lua call does not establish delivery or membership.

The roster contains locally discovered characters, not a complete directory of every key holder or account. Older clients can contribute name/position rows through position sharing but cannot report levels or party metadata. Delivery retains the validated same-internal-realm/faction scope. There is no backend, cross-realm discovery or automatic party acceptance. Peers use the existing trusted-friend, unauthenticated channel model.

## In-game checks

- Restart WoW after installing this version because it adds manifest files. Check `/lit overview`, tab navigation, normal `/lit options` reopening, Group-key cleanup, welcome navigation, Escape/close, small UI scales and the optional skin. Check more than four players and page bounds as the roster changes.
- With human-chat autojoin and position sharing off on two clients sharing a key, confirm both names and levels appear, coordinates remain absent and no position preference changes. Level up, form/leave a party, reload, disconnect/reconnect and check fresh metadata and retained inactive rows. Confirm actions become unavailable after loss of contact.
- Enable position sharing, move, stop, enter a location with unavailable coordinates and reload with retention enabled. Check zone/coordinates and genuine coordinate age. Disable retention and sharing independently; the roster must remain usable while existing location limits are respected.
- Exercise Invite and Request to join with distant friend/nonfriend peers, a party leader/member, a full party, an existing party member, stale players and a party-state change immediately before clicking. Check native confirmations, decline/error notices and final membership; no party may be joined or left automatically. Native request-target eligibility and actual rendering remain unvalidated until these checks run.

Offline regression checks cover presence, ordering, lifecycle, optional location merging, party eligibility and UI navigation. They do not establish server delivery or native rendering. Record addon/client versions, realm and faction with live results.
