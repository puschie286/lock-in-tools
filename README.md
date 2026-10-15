# LockInTools

A World of Warcraft Forever addon for playing with friends. Feature guides: [groups](feature/group.md) and [shared chat](feature/shared-chat.md). Planned: [position sharing](feature/position-sharing.md) and [activity monitoring](feature/activity-monitoring.md).

## Development setup

1. Copy or link this repository into the Forever client's `Interface/AddOns/LockInTools` folder, with `LockInTools.toc` directly inside it. No build step or third-party runtime dependencies are required.
2. Restart WoW and enable **LockInTools** in the AddOns list.
3. The welcome screen opens on your first login and saves a key for you. Use `/lit` to share your key or enter a friend's, `/lit options` for settings, and `/lit status` to check the addon version and client build.

The local checkout is `C:\Repositories\LockInTools`. The existing junction at `D:\BattleNetLibrary\World of Warcraft\_classic_beta_\Interface\AddOns\LockInTools` points to it.

Use `/reload` after editing existing Lua files. Restart the client after adding files to the manifest.

The manifest targets interface **16001**; the inspected local Forever beta build was **1.60.1.70374**. This is a local baseline, not proof of in-game validation. Check `/lit status` after client updates.

## Checks

The source uses Lua 5.1-compatible syntax. Run the offline checks from the repository root with a Lua interpreter:

```text
lua tests/group.lua
lua tests/smoke.lua
```

Offline checks cover key generation, crypto vectors and mocked WoW APIs. Verify rendering, server behavior and saved settings with the feature guides' in-game checks.
