# Interface

Content and Settings use draggable native windows that fit smaller screens. The chain-link icon identifies the addon in the AddOns list, minimap and window headers.

## Minimap button

Left-click the minimap button to open **Content**; right-click to open **Settings**. The button remains available when the initial login screen is disabled. Drag it around a round or square minimap; its position is saved account-wide.

## Screens and navigation

There are two windows: **Content**, currently containing only the [player overview](overview.md), and **Settings**, with **Group**, **Shared chat** and **Shared positions** pages. `/lit`, `/lit content` and `/lit overview` open Content; `/lit welcome` remains an alias for Content. `/lit options` opens Settings, initially on Group, and remembers its selected page. Chat and position preferences save immediately.

The header buttons **Settings** and **Content** switch between the windows at the same screen position; only one is visible at a time. Moving either window also sets the position for the other. Pages use the available height below the header. All key sharing and editing is in Settings → Group. Closing Settings or leaving Group clears displayed key fields, drafts and pending confirmations; group changes require confirmation. Leaving Shared positions finishes any trail-length edit.

When enabled on an unconfigured profile, the initial login screen opens Content and saves a new group key. `/lit welcome on|off` retains control of this login behavior. Existing or invalid saved keys are preserved, and newer-schema data remains read-only.

## Optional EllesmereUI skin

A compatible EllesmereUI installation can style LockInTools with its accent and fonts. Enable it in EllesmereUI's skin controls; reload after disabling it to restore the native style.

## Limits and in-game checks

Unsupported skin APIs leave the native style available. Custom minimap shapes other than square use round placement. Newer-schema settings remain read-only. Live rendering, fonts and client compatibility remain unvalidated.

- Check both windows, their shared position after moving either, header navigation, Settings page tabs, retained page selection, direct slash opens, immediate preference saving and draft cleanup through navigation and reopening windows.
- Check readable windows and icons at smaller UI scales, with EllesmereUI absent, disabled and enabled.
- Check minimap clicks and dragging, then reload or switch characters to confirm its saved position.
