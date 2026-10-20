# Player ranking overlay

A compact floating leaderboard shows how your character's level and XP progress compare with friends in the current LockInTools group while playing.

## Using the overlay

The overlay starts off, with its position locked. Use **Settings → Ranking** or `/lit ranking` to show or hide it; `/lit ranking on|off` sets visibility and `/lit ranking lock|unlock` controls movement. Visibility, lock state and position save account-wide. Unlock to drag the header; player rows always let clicks pass through. Closing Content or Settings and pressing Escape leave the overlay visible. Its native style matches the rest of the interface.

The top five characters show rank, name, level, XP percentage and a progress bar. Your character is highlighted in place; outside the top five, it appears in a separate row with its actual rank. Missing local progress shows **Waiting for XP** without a numeric rank. Content → Overview remains the place to browse the full roster. Hover **Info** for an explanation of the values and status labels.

Higher levels always rank first, including when a lower-level player reports 100% XP. Within a level, exact XP fractions decide order. The percentage is progress through the character's current level, not XP gained this session. Equal progress shares a rank, such as **1, 2, 2, 4**, with stable character order within ties. Confirmed maximum-level characters at the same level share a rank and show **MAX**.

**Last reported standings** includes offline players using their last saved level and XP. Stale rows are dimmed and marked **(stale)**, with **~** before their XP percentage or **MAX**; these values may have changed since the last report. On connection loss, **Connection lost — showing last reports** keeps the standings visible and marks peer values stale while your own progress continues updating. Contact loss does not confirm a logout.

**Awaiting XP** means no usable level-and-XP report is available yet, including older saved entries without XP and temporary level-up updates. It does not mean XP needed for the next level. These characters receive no rank until a complete report arrives. Summary counts show ranked characters, stale ranked reports and characters awaiting XP.

## Data and limits

The existing [player overview](overview.md) supplies level, XP and contact state, using the independent status connection even with chat and position sharing off. Local progress updates immediately; peer changes follow the existing five-second status checks and thirty-second refreshes. Unchanged progress stays current while valid reports continue. Status values, including XP, save locally for peers and your own characters. After reload or reconnect, complete saved progress remains ranked as stale until a fresh report arrives.

Standings cover discovered characters on the same internal realm and faction, not unique people or every key holder. They reflect reported progress and are unsuitable as verified competition results. Session XP gains, leveling speed and cross-level XP gaps are not shown. Group changes clear the previous standings. Newer-schema profiles leave saved data untouched: an already enabled overlay can be dismissed or reopened for the session, and an unlocked overlay can be moved temporarily.

## In-game checks

Offline checks cover ranking and UI behavior; native rendering and server delivery still need in-game validation. Use `/reload` after updating existing addon files; restart WoW if installing the overlay's new files for the first time.

- Compare XP gains, level-ups, exact ties and maximum level on two clients; check top-five overflow, your separate row and missing XP.
- With chat and position sharing off, check disconnect/reconnect, missing and expired reports, reload and group changes. Offline players must keep their last saved rankable progress, visibly stale; a fresh report must clear that marker. Check **Info**, including the meaning of **Awaiting XP**.
- Check Settings and slash controls, header dragging, click-through, closing Content, Escape, Alt+Z, saved placement and temporary read-only movement/dismissal. Check long names and different UI scales.
