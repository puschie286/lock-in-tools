# RestedXP guide sharing

Settings → **RestedXP** shows whether RestedXP Guides is installed and loaded, plus the guide names and versions found in its active profile. **Update guides** checks online LIT members and installs packs from publishers you follow.

## Sharing and updates

Choose **Share export**, enter a stable pack ID, paste a RestedXP export and supply its source BattleTag. **Import & share** validates the export and makes the pack available to your group. Reuse the same pack ID when publishing a replacement. Source BattleTags and import drafts are cleared when leaving the page; they are not saved or sent to other members.

Members choose **Follow** beside a pack's publisher, then **Update guides**. Subsequent announcements from that publisher automatically fetch changed content. Pack hashes detect changes even when the embedded guide versions are unchanged. Each recipient personalizes the pack using their own local BattleTag before passing it to RestedXP. The displayed guide versions are informational.

Availability is announced when the data channel connects and when a pack is imported or received. New arrivals request existing members' packs. Verified cached packs can be served by their current holder; follow that holder explicitly to use them as your publisher. Installation is confirmed separately from download completion. Combat, an unavailable importer or another import can defer installation. A failed update retains the previous package for recovery; it does not promise rollback of changes RestedXP has already applied.

## Limits

Sharing needs the same internal realm/faction and an online member holding the pack. Transfers are throttled and can take several minutes. LIT does not download vendor releases; a publisher supplies each new export. Supported importers must expose RestedXP's format-40000 import interface. The local BattleTag must be available through Battle.net.

The feature limits export size to 2 MiB, cached packages to eight per group and total cached data to 8 MiB. It verifies group authentication and content integrity; traffic is not encrypted and all group-key holders share authority. Only follow trusted publishers. Switching or leaving groups cancels transfers and clears old-group sharing state; guides already installed in RestedXP remain there. Newer-schema profiles are read-only.

## In-game checks

- On two Forever clients, inspect the installed/disabled/missing RestedXP states and installed guide versions. Verify the new tab, scrolling, draft cleanup and read-only controls at different UI scales.
- Share a small test export, log the recipient in later, follow its publisher and update. Confirm recipient-side BattleTag handling, successful native import and the last-installed state.
- Publish changed content with unchanged guide versions and confirm the follower receives it. Test multiple packs, unavailable publishers, throttling, reconnects, combat and an import already running in RestedXP.
- Switch groups during transfer and confirm no old-group packets or imports continue. Confirm installed guides survive leaving LIT and failed imports are not reported as installed.

Offline tests cover conversion, source identity and versions, asynchronous import outcomes, discovery, packet loss, content changes and lifecycle isolation. Native delivery, throughput, paste handling and RestedXP rendering remain in-game checks.
