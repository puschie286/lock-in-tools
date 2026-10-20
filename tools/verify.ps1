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
        Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'Libs') -Filter '*.lua' -File -Recurse
        Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'tests') -Filter '*.lua' -File -Recurse
    )
    foreach ($file in $sourceFiles) {
        & $compilerExecutable -p $file.FullName
        if ($LASTEXITCODE -ne 0) {
            throw "Lua 5.1 syntax check failed: $($file.FullName)"
        }
    }
    Write-Host "PASS: Lua 5.1 syntax ($($sourceFiles.Count) files)"

    $xmlFiles = @(
        Get-ChildItem -LiteralPath $repositoryRoot -Filter '*.xml' -File
        Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'Libs') -Filter '*.xml' -File -Recurse
    )
    foreach ($file in $xmlFiles) {
        [xml](Get-Content -LiteralPath $file.FullName -Raw) | Out-Null
    }
    Write-Host "PASS: XML syntax ($($xmlFiles.Count) files)"

    $suites = Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'tests') -Filter '*.lua' -File | Sort-Object Name
    foreach ($suite in $suites) {
        Write-Host "Running tests/$($suite.Name)..."
        & $luaExecutable $suite.FullName
        if ($LASTEXITCODE -ne 0) {
            throw "Test suite failed: $($suite.Name) (exit $LASTEXITCODE)"
        }
    }
    Write-Host 'PASS: all offline checks'
}
finally {
    Pop-Location
}
