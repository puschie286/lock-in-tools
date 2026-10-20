# Embedded libraries

These runtime sources are bundled with LockInTools; users do not install separate library addons. Load only the five Lua files below, in order. All upstream Lua files are unmodified. No AceAddon, AceDB, AceComm, AceSerializer, AceGUI or AceConfig is included.

| File | Pinned source |
| --- | --- |
| `LibStub/LibStub.lua` | LibStub minor 2; [Ace3 commit `40f4cc1356ae7fcc0cf71fc0a19dc7d50d6ae6c2`](https://github.com/WoWUIDev/Ace3/tree/40f4cc1356ae7fcc0cf71fc0a19dc7d50d6ae6c2) |
| `CallbackHandler-1.0/CallbackHandler-1.0.lua` | CallbackHandler minor 8; same Ace3 commit |
| `AceEvent-3.0/AceEvent-3.0.lua` | AceEvent minor 4; same Ace3 commit |
| `LibDataBroker-1.1/LibDataBroker-1.1.lua` | LDB minor 4; [upstream tag v1.1.4, commit `1a63ede0248c11aa1ee415187c1f9c9489ce3e02`](https://github.com/tekkub/libdatabroker-1-1/tree/1a63ede0248c11aa1ee415187c1f9c9489ce3e02) |
| `LibDBIcon-1.0/LibDBIcon-1.0.lua` | LibDBIcon minor 56; installed Questie library snapshot, copied 2026-10-20 and pinned by SHA-256 below |

The LibDBIcon snapshot came from `D:\BattleNetLibrary\World of Warcraft\_classic_beta_\Interface\AddOns\Questie\Libs\LibDBIcon-1.0\LibDBIcon-1.0.lua`. Its exact upstream release equivalence is unverified. The [official v12.1.1 release](https://www.wowace.com/projects/libdbicon-1-0/files/9119909) advertises a Forever icon fix, but its bytes were unavailable for comparison during this import. Do not label this snapshot v12.1.1. Actual Forever icon rendering and minimap integration remain in-game checks.

## Integrity

SHA-256 hashes of the imported Lua bytes:

```text
02d25b7433af734b59f0c4571bfaa73b2b660992d71d2fb6a8809b32de3f964c  LibStub/LibStub.lua
e44e74da6fdfd71c0aeee304a716482f31a9f138a58956fda9506262d852af6f  CallbackHandler-1.0/CallbackHandler-1.0.lua
a7ac0189fbf8cc73eabb53f4257b28d161960d6cbdb0cce5a1856f11416115ab  AceEvent-3.0/AceEvent-3.0.lua
d79b3eada649684543bbbc3c511c2515e16d644f198fa991a201ee64d045b0f2  LibDataBroker-1.1/LibDataBroker-1.1.lua
85c426947fa50319071b64c7cb845326c44316341713a3847dc8149c1e36716b  LibDBIcon-1.0/LibDBIcon-1.0.lua
```

## Notices and updates

- LibStub's public-domain dedication and credits remain in its source header.
- CallbackHandler and AceEvent use the upstream [Ace3 license](LICENSE-Ace3.txt).
- LibDBIcon's [official project license](https://www.wowace.com/project/15552/license) is Ace3 Style BSD; its matching notice is retained in [LibDBIcon-1.0/LICENSE.txt](LibDBIcon-1.0/LICENSE.txt).
- LDB supplies no separate license file in the pinned repository. Its original [README](LibDataBroker-1.1/README.textile) is retained, and the author's [official embedding instructions](https://www.wowace.com/projects/libdatabroker-1-1) explicitly direct addon authors to hard-embed it. The project metadata says All Rights Reserved; no alternate license is asserted here.

For an update, review upstream changes, replace the relevant source verbatim, update its source/version/hash here, and run `..\tools\verify.ps1` from this directory. Test both fresh library loading and reuse of a newer copy supplied by another addon. Keep library settings isolated from newer-schema saved data.
