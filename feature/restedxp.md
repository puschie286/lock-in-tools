# RestedXP guide sharing

Settings → **RestedXP** shows whether RestedXP Guides is installed and loaded, plus the guide names and versions found in its active profile. **Update guides** checks online LIT members and installs packs from publishers you follow.

## Sharing and updates

Imported guides are automatically shared with your LIT group when RestedXP retains their complete source. No sharing switch or export step is needed. LIT announces available packs on login and refreshes them after guides are imported or updated directly in RestedXP. The sharing status reports unavailable source separately; installed guide names alone do not guarantee a guide can be shared.

Members choose **Follow** beside a pack's publisher, then **Update guides**. Subsequent announcements from that publisher automatically fetch changed content. Pack hashes detect changes even when the embedded guide versions are unchanged. Each recipient personalizes the pack using their own local BattleTag before passing it to RestedXP. The displayed guide versions are informational.

Login and manual checks finish with a result even when no packs are available. If LIT has already installed the same pack content, checking again downloads and installs nothing. An offline followed publisher is reported separately because its latest content cannot be checked.

**Share export** remains a fallback for source that cannot be recovered from installed guides. Enter a stable pack ID, paste a RestedXP export and supply its source BattleTag. **Import & share** validates it and makes the pack available to your group. Reuse that ID for replacements. Source BattleTags and import drafts are cleared when leaving the page; they are not saved or sent to other members.

Availability is announced when the data channel connects and when a pack is imported or received. New arrivals request existing members' packs. Verified cached packs can be served by their current holder; follow that holder explicitly to use them as your publisher. Installation is confirmed separately from download completion. Combat, an unavailable importer or another import can defer installation. A failed update retains the previous package for recovery; it does not promise rollback of changes RestedXP has already applied.

## Limits

Sharing needs the same internal realm/faction and an online member holding the pack. Transfers are throttled and can take several minutes. LIT does not download vendor releases; a group member must first import updated guides into RestedXP. Supported importers must expose RestedXP's format-40000 import interface, and automatic sharing needs its compatible saved source cache. The local BattleTag must be available through Battle.net.

The feature limits export size to 2 MiB, cached packages to eight per group and total cached data to 8 MiB. It verifies group authentication and content integrity; traffic is not encrypted and all group-key holders share authority. Only follow trusted publishers. Switching or leaving groups cancels transfers and clears old-group sharing state; guides already installed in RestedXP remain there. Newer-schema profiles are read-only.

## In-game checks

- On two Forever clients, inspect the installed/disabled/missing RestedXP states and installed guide versions. Verify the new tab, scrolling, draft cleanup and read-only controls at different UI scales.
- With guides already imported into RestedXP, log in without using **Share export**. Confirm automatic availability, then log the recipient in later, follow the publisher and update. Check recipient-side BattleTag handling, successful native import and the last-installed state.
- Import changed content directly into RestedXP, including unchanged guide versions, and confirm the shared pack refreshes and its follower receives it. Reload and confirm the packs are available again. Guides without complete saved source should remain listed as installed with an explanation of the sharing limit.
- With the same shared content installed, update again and confirm a finished, up-to-date result without another import. With no recoverable guides or shared exports, login and update checks should finish. Test the manual export fallback, multiple packs, unavailable publishers, throttling, reconnects, combat and an import already running in RestedXP.
- Switch groups during transfer and confirm no old-group packets or imports continue. Confirm installed guides survive leaving LIT and failed imports are not reported as installed.

Offline tests cover conversion, source identity and versions, asynchronous import outcomes, discovery, packet loss, content changes and lifecycle isolation. Native delivery, throughput, paste handling and RestedXP rendering remain in-game checks.
