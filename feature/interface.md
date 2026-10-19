# Interface

The welcome and settings windows use a shared native style: dark panels, simple borders, clear labels and consistent buttons, fields and checkboxes. Windows remain draggable and scale down to fit smaller screens when opened. LockInTools works without a separate UI addon.

The AddOns list uses the interlocking steel links with a blue glow as the addon icon. `Media/Icon.png` preserves the original artwork; `Media/Icon.tga` is the 256×256 uncompressed 32-bit texture referenced by `LockInTools.toc`.

Use `/reload` after editing existing Lua files. Restart WoW after adding files to the manifest.

## Settings and navigation

Settings use three tabs: **Group**, **Shared chat** and **Shared positions**. The first settings open selects **Group**. Later opens reuse the same window and keep its selected tab, including repeated `/lit options` commands. Unsaved preference choices survive switching tabs. Leaving **Group** clears and masks its key draft and cancels pending group confirmation.

**More options** moves from welcome to settings; **Back to welcome** returns. Opening either window hides the other, so only one is visible. Hiding a window clears its key fields and pending confirmations; reopening welcome restores the saved key. Navigation and tab changes never save a preference by themselves.

## Optional EllesmereUI skin

When a compatible EllesmereUI is installed, its skin controls list **LockInTools**. Enabling the skin uses EllesmereUI's accent and fonts; reload WoW after disabling it to restore LockInTools' native style. The integration keeps later-created windows consistent with the current style and refreshes fonts through EllesmereUI's appearance-change callback when available. This integration adds no LockInTools preference or saved-data schema change.

The skin changes appearance only. Key copying, hidden-field cleanup, group confirmations and newer-schema read-only behavior keep their existing rules. Windows are created when first opened; the skin does not open them automatically. Neither the native style nor the optional skin changes other addons or the WoW interface.

## Limits and in-game checks

EllesmereUI integration depends on its supported skin API. Missing or unsupported APIs leave the native style available. Offline mocks check callbacks and style selection; actual rendering, fonts, focus and client compatibility require in-game validation.

- Check welcome and settings with EllesmereUI absent, installed with the LockInTools skin disabled, and enabled. With the skin enabled, change its accent and fonts while a window is visible, then open the other window for the first time. Disable the skin, reload and check both windows again.
- After restarting WoW, check that the AddOns list shows the chain-link icon for LockInTools, upright and recognizable at its displayed size.
- Open settings for the first time and confirm **Group** is selected. Switch through all three tabs, check only the selected category is visible and confirm unsaved preference choices survive. Prepare a key change/confirmation in **Group**, leave the tab and return; the draft must be cleared/masked and confirmation cancelled.
- Move between **More options** and **Back to welcome** repeatedly; only one window may be visible. Repeat `/lit options` on each tab and check the same settings window and selected tab remain. Open welcome through `/lit` or `/lit welcome` while settings is visible and check settings hides with key cleanup.
- Check readable text, clear enabled/disabled controls, field outlines and button hover states at different UI scales. Move each window, reopen it and check that its controls remain usable.
- Copy the complete key with **Select key** and Ctrl+C. Check friend-key confirmation and unsaved drafts while asynchronous status updates arrive. Close using **Done**, the title-bar close button and Escape; a focused field may consume the first Escape. Hidden key fields must clear, and reopening must restore only the saved key.
- With a disposable newer-schema fixture, check disabled edits and preserved saved data in both styles. Record addon/client versions and EllesmereUI version when installed. Live visual validation remains pending.
