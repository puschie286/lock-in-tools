# LockInTools

- World of Warcraft Forever addon using Lua 5.1, native WoW APIs/UI and selected bundled libraries; no build step, separately installed runtime dependencies or backend.
- `Core.lua`: startup/settings; `Crypto.lua`/`Group.lua`: group keys/credentials; `Chat.lua`: native chat; `Options.lua`/`Commands.lua`: welcome, settings and commands.
- Features share one account-wide group key in `LockInToolsDB`. Preserve migrations, legacy keys and newer-schema read-only behavior. Never log group keys.
- `LockInTools.toc` defines metadata and load order. Register new addon files there; keep tests out. Use `/reload` for existing Lua edits; restart WoW after manifest additions.
- Keep `README.md` focused on development setup.
- Keep one concise overview per feature in `feature/`: purpose, main user-facing behavior, important limits and brief in-game checks. Not every tiny detail needs to be recorded; omit implementation minutiae, exhaustive checklists and change history. Label planned features clearly.

## Verification

- After changing Lua, tests or verification tooling, run `.\tools\verify.ps1`; resolve failures before finishing. It checks syntax and runs all offline suites.
- If the local runtime is missing, run `.\tools\setup-lua.ps1`. Keep downloads in ignored `tools/lua/`.
- Extend existing mocked tests for meaningful behavior regressions. The test harness is never loaded by the addon.
- Follow [tests/testing.md](tests/testing.md) for the full process. Report verification commands/results separately from actual in-game validation.
