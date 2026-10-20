# Player ranking overlay

**Planned; not implemented.** A compact floating leaderboard would show how your character's level and XP progress compare with friends in the current LockInTools group while playing.

## Proposed first version

The overlay would be optional and initially off, independent of the main Content window. A proposed `/lit ranking` command and a Settings control would show or hide it. Its position and visibility would save account-wide. An unlocked header would allow dragging; locked rows would let clicks pass through. Native styling and the optional EllesmereUI skin would match the existing interface.

Show the top five ranked characters with rank, name, level, XP percentage and a small progress bar. Highlight your character without moving it ahead of other players; if it falls outside the top five, show its actual rank in a separate row. If your progress is unavailable, show **Waiting for XP** without a numeric rank. Overview would remain the place to browse the full roster.

Higher levels always rank first, including when a lower-level player reports 100% XP. Within a level, compare exact XP fractions rather than rounded percentages. Equal progress shares a rank, such as **1, 2, 2, 4**, with a stable character order within ties. Confirmed maximum-level characters at the same level share a rank and show **MAX**.

Label the standings **Active reports**. Only characters with current, complete progress receive a rank. Missing XP is not zero: show how many active characters are awaiting data. Stale or inactive reports leave the ranking and remain available in Overview. Rank counts describe eligible reports, not every group member. On connection loss, show **Connection lost — your progress only**, remove peer rows and leave your group rank unavailable; contact loss does not confirm a logout.

## Data and limits

The existing [player overview](overview.md) supplies level, XP and contact state. No extra sharing, transport fields or backend would be needed. Local progress updates immediately; peer changes follow the existing five-second status checks and thirty-second presence refreshes. Unchanged progress stays current while contact continues. Status values, including XP, save locally for peers and your own characters. After reload or reconnect, retained peer progress remains available in Overview but needs a fresh report to qualify for the proposed active standings.

Standings cover discovered characters on the same internal realm and faction, not unique people or all key holders. They reflect reported progress and are unsuitable as verified competition results. Session XP gains, leveling speed and cross-level XP gaps are outside this proposal. Group changes would clear the standings, and newer-schema settings would remain read-only.

## Future in-game checks

No overlay is available in the addon yet. When implemented, check ranking and ties across XP gains, level-ups and maximum level; missing reports, disconnect/reconnect and reload; group changes; and visibility, dragging, click-through, overflow and both themes at different UI scales. Use two clients with chat and position sharing off to confirm the overlay uses the existing independent status connection.
