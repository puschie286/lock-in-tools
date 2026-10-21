# LockInTools

A World of Warcraft Forever addon for playing with friends.

## Development setup

1. Link this repository into the Forever client's `Interface/AddOns/LockInTools` folder using the PowerShell script below, or copy it there with `LockInTools.toc` directly inside the folder. Selected libraries are bundled in `Libs/`; no build step or separate library installation is required.
2. Restart WoW and enable **LockInTools** in the AddOns list.
3. Content opens on your first login and saves a group key for you. Use `/lit` for the player overview, `/lit options` → Group to share your key or enter a friend's, and `/lit status` to check the addon version and client build.

From the repository root on Windows, preview the detected destination, then create the directory junction:

```powershell
.\tools\link-wow.ps1 -WhatIf
.\tools\link-wow.ps1
```

Automatic detection checks common local WoW locations and Battle.net's WoW registry keys for `_classic_beta_`; it stops if none or more than one is found. For another location, or to select a specific client, pass the folder containing the WoW executable:

```powershell
.\tools\link-wow.ps1 -WowPath 'D:\BattleNetLibrary\World of Warcraft\_classic_beta_'
```

The script works from any current directory when invoked by full path, creates missing `Interface/AddOns` folders and safely reuses a matching link. It refuses to replace existing folders or conflicting links. Keep the checkout at its linked location; edits appear in the client without copying. Junctions require local drives and write access to the client's AddOns folder.

To remove the link while keeping the repository and its files intact:

```powershell
.\tools\link-wow.ps1 -Unlink -WhatIf
.\tools\link-wow.ps1 -Unlink
```

Run unlinking from the original checkout path. `-Unlink` also accepts `-WowPath`. It removes only a directory link pointing to this checkout, refuses ordinary folders or links to another checkout, and does nothing when no link exists.

Use `/reload` after editing existing Lua files. Restart the client after adding files to the manifest.

The manifest targets interface **16001**; the inspected local Forever beta build was **1.60.1.70374**. This is a local baseline, not proof of in-game validation. Check `/lit status` after client updates.

## Checks

From the repository root, install the local native Lua 5.1 runtime once, then run verification after changes:

```powershell
.\tools\setup-lua.ps1
.\tools\verify.ps1
```

The runtime lives in ignored `tools/lua/`. Verification checks addon, bundled-library and test syntax and runs every offline suite without downloading anything. Both scripts resolve repository paths themselves, so they also work when invoked by full path from another directory.

See [the verification process](tests/testing.md) for offline coverage and [in-game checks](tests/testing.md#in-game-verification).

For version bumps and automatic GitHub ZIP releases, see [the release process](docs/releasing.md).
