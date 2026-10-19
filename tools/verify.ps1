[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$runtimeDirectory = Join-Path $PSScriptRoot 'lua'
$luaExecutable = Join-Path $runtimeDirectory 'lua5.1.exe'
$compilerExecutable = Join-Path $runtimeDirectory 'luac5.1.exe'

if (-not (Test-Path -LiteralPath $luaExecutable -PathType Leaf) -or
    -not (Test-Path -LiteralPath $compilerExecutable -PathType Leaf)) {
    throw 'Local Lua runtime missing. Run .\tools\setup-lua.ps1 first.'
}

Push-Location $repositoryRoot
try {
    & $luaExecutable -e "assert(_VERSION == 'Lua 5.1', 'Verification requires Lua 5.1')"
    if ($LASTEXITCODE -ne 0) {
        throw "Lua version check failed (exit $LASTEXITCODE)."
    }

    $sourceFiles = @(
        Get-ChildItem -LiteralPath $repositoryRoot -Filter '*.lua' -File
        Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'tests') -Filter '*.lua' -File -Recurse
        Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'position-probe') -Filter '*.lua' -File
    )
    foreach ($file in $sourceFiles) {
        & $compilerExecutable -p $file.FullName
        if ($LASTEXITCODE -ne 0) {
            throw "Lua 5.1 syntax check failed: $($file.FullName)"
        }
    }
    Write-Host "PASS: Lua 5.1 syntax ($($sourceFiles.Count) files)"

    [xml](Get-Content -LiteralPath (Join-Path $repositoryRoot 'PositionPins.xml') -Raw) | Out-Null
    Write-Host 'PASS: position pin XML syntax'

    foreach ($suite in @('tests/group.lua', 'tests/smoke.lua', 'tests/position-probe.lua', 'tests/data.lua', 'tests/position.lua', 'tests/position-map.lua')) {
        Write-Host "Running $suite..."
        & $luaExecutable $suite
        if ($LASTEXITCODE -ne 0) {
            throw "Test suite failed: $suite (exit $LASTEXITCODE)"
        }
    }
    Write-Host 'PASS: all offline checks'
}
finally {
    Pop-Location
}
