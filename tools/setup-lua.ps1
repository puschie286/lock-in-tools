[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runtimeDirectory = Join-Path $PSScriptRoot 'lua'
$luaExecutable = Join-Path $runtimeDirectory 'lua5.1.exe'
$compilerExecutable = Join-Path $runtimeDirectory 'luac5.1.exe'
$archivePath = Join-Path $runtimeDirectory 'lua-5.1.5_Win64_bin.zip'
$downloadUri = 'https://downloads.sourceforge.net/project/luabinaries/5.1.5/Tools%20Executables/lua-5.1.5_Win64_bin.zip'
# SHA-256 of the LuaBinaries Windows x64 archive. Keep updates explicit.
$archiveHash = '5F34CF7D40A20A587EA351482A4207D93B92EF6F1983E910A13338253819FE93'

if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'This setup installs the Windows x64 Lua 5.1.5 runtime.'
}

if (-not (Test-Path -LiteralPath $luaExecutable -PathType Leaf) -or
    -not (Test-Path -LiteralPath $compilerExecutable -PathType Leaf)) {
    New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ne $archiveHash) {
        Write-Host 'Downloading Lua 5.1.5 from LuaBinaries...'
        Invoke-WebRequest -Uri $downloadUri -OutFile $archivePath -UseBasicParsing -TimeoutSec 60
    }
    if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ne $archiveHash) {
        throw 'Lua archive checksum mismatch. No downloaded files were executed.'
    }
    Expand-Archive -LiteralPath $archivePath -DestinationPath $runtimeDirectory -Force
}

& $luaExecutable -e "assert(_VERSION == 'Lua 5.1', 'Expected Lua 5.1'); print('Lua 5.1 runtime ready.')"
if ($LASTEXITCODE -ne 0) {
    throw "Lua runtime check failed (exit $LASTEXITCODE)."
}
& $compilerExecutable -v
if ($LASTEXITCODE -ne 0) {
    throw "Lua compiler check failed (exit $LASTEXITCODE)."
}
Write-Host "Installed locally: $runtimeDirectory"
Write-Host 'Run .\tools\verify.ps1 to check the addon.'
