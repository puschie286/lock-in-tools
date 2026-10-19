# Interface

Welcome and settings use draggable native windows that fit smaller screens. The chain-link icon identifies the addon in the AddOns list, minimap and window headers.

## Minimap button

Left-click the minimap button to open settings; right-click to open welcome. The button remains available when the login welcome is disabled. Drag it around a round or square minimap; its position is saved account-wide.

## Settings and navigation

Settings contain **Overview**, **Group**, **Shared chat** and **Shared positions**. The first ordinary open selects **Group**; later opens retain the selected tab. The [player overview](overview.md) also opens directly with `/lit overview`. Chat and position preferences save immediately.

**More options** and **Back to welcome** switch between windows. Only one is visible at a time. Closing windows or leaving **Group** clears key drafts and pending confirmations; group changes require confirmation.

## Optional EllesmereUI skin

A compatible EllesmereUI installation can style LockInTools with its accent and fonts. Enable it in EllesmereUI's skin controls; reload after disabling it to restore the native style.

## Limits and in-game checks

Unsupported skin APIs leave the native style available. Custom minimap shapes other than square use round placement. Newer-schema settings remain read-only. Live rendering, fonts and client compatibility remain unvalidated.

- Check navigation, tabs, immediate preference saving and key cleanup through closing and reopening windows.
- Check readable windows and icons at smaller UI scales, with EllesmereUI absent, disabled and enabled.
- Check minimap clicks and dragging, then reload or switch characters to confirm its saved position.
