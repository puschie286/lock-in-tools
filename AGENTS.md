# LockInTools

- World of Warcraft Forever addon using Lua 5.1, native WoW APIs/UI and selected bundled libraries; no build step, separately installed runtime dependencies or backend.
- `Core.lua` handles startup and settings. `DataChannel.lua`, `Data.lua` and `DataStatus.lua` handle Guild and Friends sharing. `Options.lua` and `Commands.lua` handle content, settings and commands.
- Settings and player history are account-wide in `LockInToolsDB`. Preserve migrations, player history and newer-schema read-only behavior. Guild and Friends use native addon messaging without group keys or custom channels.
- `LockInTools.toc` defines metadata and load order. Register new addon files there; keep tests out. Use `/reload` for existing Lua edits; restart WoW after manifest additions.
- Keep `README.md` focused on development setup.
- Keep non-obvious behavior constraints beside the relevant code or regression tests, and manual in-game checks in `tests/testing.md`.

## Verification

- After changing Lua, tests or verification tooling, run `.\tools\verify.ps1`; resolve failures before finishing. It checks syntax and runs all offline suites.
- If the local runtime is missing, run `.\tools\setup-lua.ps1`. Keep downloads in ignored `tools/lua/`.
- Extend existing mocked tests for meaningful behavior regressions. The test harness is never loaded by the addon.
- Follow [tests/testing.md](tests/testing.md) for the full process. Report verification commands/results separately from actual in-game validation.
