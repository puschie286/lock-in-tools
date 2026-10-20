# Player ranking overlay

A compact floating leaderboard shows how your character's level and XP progress compare with friends in the current LockInTools group while playing.

## Using the overlay

The overlay starts off, with its position locked. Use **Settings → Ranking** or `/lit ranking` to show or hide it; `/lit ranking on|off` sets visibility and `/lit ranking lock|unlock` controls movement. Visibility, lock state and position save account-wide. Unlock to drag the header; player rows always let clicks pass through. Closing Content or Settings and pressing Escape leave the overlay visible. Its native style and optional EllesmereUI skin match the rest of the interface.

The top five characters show rank, name, level, XP percentage and a progress bar. Your character is highlighted in place; outside the top five, it appears in a separate row with its actual rank. Missing local progress shows **Waiting for XP** without a numeric rank. Content → Overview remains the place to browse the full roster.

Higher levels always rank first, including when a lower-level player reports 100% XP. Within a level, exact XP fractions decide order. Equal progress shares a rank, such as **1, 2, 2, 4**, with stable character order within ties. Confirmed maximum-level characters at the same level share a rank and show **MAX**.

**Active reports** includes only current, complete progress. Counts distinguish characters awaiting XP, stale reports and inactive characters; retained values remain available in Overview. On connection loss, **Connection lost — your progress only** replaces peer rows with your local progress and leaves your group rank unavailable. Contact loss does not confirm a logout.

## Data and limits

The existing [player overview](overview.md) supplies level, XP and contact state, using the independent status connection even with chat and position sharing off. Local progress updates immediately; peer changes follow the existing five-second status checks and thirty-second refreshes. Unchanged progress stays current while valid reports continue. Status values, including XP, save locally for peers and your own characters. After reload or reconnect, retained peer progress needs a fresh report before it qualifies for active standings.

Standings cover discovered characters on the same internal realm and faction, not unique people or every key holder. They reflect reported progress and are unsuitable as verified competition results. Session XP gains, leveling speed and cross-level XP gaps are not shown. Group changes clear the previous standings. Newer-schema profiles leave saved data untouched: an already enabled overlay can be dismissed or reopened for the session, and an unlocked overlay can be moved temporarily.

## In-game checks

Offline checks cover ranking and UI behavior; native rendering and server delivery still need in-game validation. Restart WoW after installing this version so it discovers the new addon files.

- Compare XP gains, level-ups, exact ties and maximum level on two clients; check top-five overflow, your separate row and missing XP.
- With chat and position sharing off, check disconnect/reconnect, missing and expired reports, reload and group changes. Cached XP must remain in Overview without claiming a current peer rank.
- Check Settings and slash controls, header dragging, click-through, closing Content, Escape, Alt+Z, saved placement and temporary read-only movement/dismissal. Check both themes, long names and different UI scales.
