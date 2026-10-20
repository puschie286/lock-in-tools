# Interface

Content and Settings share one draggable native window that fits smaller screens. The chain-link icon identifies the addon in the AddOns list, minimap and window header.

## Minimap button

Left-click the minimap button to open **Content**; right-click to open **Settings**. The button remains available when the initial login screen is disabled. Drag it around the minimap; its position is saved account-wide. Compatible DataBroker displays can also show these shortcuts.

## Screens and navigation

The window has two views: **Content**, currently containing only the [player overview](overview.md), and **Settings**, with **Group**, **Shared chat**, **Shared positions**, **Ranking** and **RestedXP** pages. `/lit`, `/lit content` and `/lit overview` open Content; `/lit welcome` remains an alias for Content. `/lit options` opens Settings, initially on Group, and remembers its selected page. Chat, position and ranking preferences save immediately.

The header buttons **Settings** and **Content** switch views within the window. Pages use the available height below the header. All key sharing and editing is in Settings → Group. Leaving Group, switching to Content or closing the window clears displayed key fields, drafts and pending confirmations; group changes require confirmation.

The window position is saved account-wide and restored after reloads, logins and character changes. The window starts centered when no valid saved position is available. Newer-schema profiles allow temporary movement without saving it.

The optional [player ranking overlay](player-ranking.md) has its own saved visibility and position. Open it from Settings → Ranking or `/lit ranking`; closing the main window or pressing Escape leaves it visible. Unlock its header to drag it; rows let clicks pass through.

When enabled on an unconfigured profile, the initial login screen opens Content and saves a new group key. `/lit welcome on|off` retains control of this login behavior. Existing or invalid saved keys are preserved, and newer-schema data remains read-only.

## Optional EllesmereUI skin

A compatible EllesmereUI installation can style LockInTools with its accent and fonts. Enable it in EllesmereUI's skin controls; reload after disabling it to restore the native style.

## Limits and in-game checks

Unsupported skin APIs leave the native style available. Minimap placement follows shapes recognized by the bundled icon library. Newer-schema settings allow temporary icon movement without saving it. Live rendering, fonts and client compatibility remain unvalidated.

Restart WoW after installing versions that add addon files, including the ranking overlay; `/reload` is enough for later edits to existing Lua files.

- Check Content and Settings, unchanged position when switching views, header navigation, Settings page tabs, retained page selection, direct slash opens, immediate preference saving and draft cleanup through navigation and reopening the window.
- Move the window, then `/reload`, relog and switch characters to check that it restores the saved position. On a newer-schema profile, check temporary movement without changing saved data.
- Check the window and icons remain readable at smaller UI scales, with EllesmereUI absent, disabled and enabled, including views first opened after a style change.
- Check minimap clicks and dragging on round and square minimaps, then reload or switch characters to confirm its saved position. With a DataBroker display installed, check its shortcuts and tooltip too.
