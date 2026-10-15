# Verification

- Keep addon code compatible with Lua 5.1.
- After changing Lua code or tests, run `.\tools\verify.ps1` from the repository root. It checks syntax and runs both offline suites; resolve failures before finishing.
- If the local runtime is missing, run `.\tools\setup-lua.ps1`. Keep the downloaded runtime in ignored `tools/lua/`.
- For behavior changes, extend the existing mocked tests when they can catch a meaningful regression. The test harness is never loaded by the addon.
- Follow `docs/testing.md` for the full process and relevant in-game checks. Report offline results separately from any actual in-game validation.
