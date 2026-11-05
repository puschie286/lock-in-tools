# RestedXP file converter for Windows

Run `tools/convert-restedxp.ps1` in Windows PowerShell 5.1 or PowerShell 7 from
a complete checkout. It uses the addon's codec to decode the export's original
BattleTag envelope and re-encode it for `Player#1234`. Guide contents stay
compressed; no guide code is executed.

Install the checkout's local Lua runtime once if it is missing:

```powershell
.\tools\setup-lua.ps1
```

Convert a file by passing its path in quotes:

```powershell
.\tools\convert-restedxp.ps1 'C:\Guides\Example Guide_Source#1234'
```

This creates
`C:\Guides\Example Guide_Player#1234` and returns
its full path. The input is preserved. Extensions such as `.txt` are retained;
extensionless files also work. The filename must contain exactly one literal
BattleTag, with spaces, underscores, hyphens or brackets separating it from
other words. Missing or multiple tags are rejected.

Choose a different output path when needed; the destination directory must exist:

```powershell
.\tools\convert-restedxp.ps1 -InputPath 'C:\Guides\Guide_Source#1234.txt' -OutputPath 'C:\Guides\Generic.txt'
```

Existing output files are never overwritten. The script also works from another
directory when invoked by full path. It accepts format `40000` exports up to
2 MiB, including wrapped lines and WoW-escaped pipes, and writes plain ASCII
without a byte order mark or trailing newline.

The filename determines the source key; the envelope cannot prove that the tag
is correct. RestedXP validates the decoded contents when importing. Paste the
converted file into LockInTools without entering a source BattleTag. LockInTools
always reads exports as `Player#1234` and retargets them to your signed-in
BattleTag before importing.
