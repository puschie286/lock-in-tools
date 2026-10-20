[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'These integration checks require Windows directory junctions.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$linkScript = Join-Path $repositoryRoot 'tools\link-wow.ps1'
if (-not (Test-Path -LiteralPath $linkScript -PathType Leaf)) {
    throw "Link script missing: $linkScript"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) 'LockInTools-link-tests'
$scratchDirectory = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratchDirectory) | Out-Null
$junctionPaths = New-Object 'System.Collections.Generic.List[string]'
$script:passedChecks = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Message)
    $rejected = $false
    try {
        & $Action | Out-Null
    }
    catch {
        $rejected = $true
    }
    Assert-True $rejected $Message
}

function Invoke-Check {
    param([string]$Name, [scriptblock]$Action)
    & $Action
    $script:passedChecks++
    Write-Host "PASS: $Name"
}

function New-TestClient {
    param([string]$Name, [string]$Executable = 'Wow.exe')
    $clientPath = Join-Path $scratchDirectory $Name
    [IO.Directory]::CreateDirectory($clientPath) | Out-Null
    [IO.File]::WriteAllText((Join-Path $clientPath $Executable), '')
    return $clientPath
}

function Get-TestDestination {
    param([string]$ClientPath)
    $destination = Join-Path $ClientPath 'Interface\AddOns\LockInTools'
    if (-not $junctionPaths.Contains($destination)) {
        $junctionPaths.Add($destination)
    }
    return $destination
}

try {
    Invoke-Check 'dry run does not create Interface or a link' {
        $clientPath = New-TestClient 'Dry run [client]'
        Get-TestDestination $clientPath | Out-Null
        & $linkScript -WowPath $clientPath -WhatIf | Out-Null
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $clientPath 'Interface'))) 'Dry run created Interface.'
    }

    Invoke-Check 'link works from another directory with spaces and brackets in the client path' {
        $clientPath = New-TestClient 'World of Warcraft [Forever beta]' 'WowB.exe'
        $destination = Get-TestDestination $clientPath
        Push-Location $scratchDirectory
        try {
            & $linkScript -WowPath $clientPath -Confirm:$false | Out-Null
        }
        finally {
            Pop-Location
        }
        $item = Get-Item -LiteralPath $destination -Force
        Assert-True ($item.LinkType -eq 'Junction') 'Addon destination is not a directory junction.'
        $linkedToc = Join-Path $destination 'LockInTools.toc'
        Assert-True (Test-Path -LiteralPath $linkedToc -PathType Leaf) 'The linked addon manifest is missing.'
        Assert-True ((Get-FileHash -LiteralPath $linkedToc).Hash -eq (Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'LockInTools.toc')).Hash) 'The link does not expose this repository manifest.'
        Assert-True (Test-Path -LiteralPath (Join-Path $destination 'tools\link-wow.ps1') -PathType Leaf) 'The link does not expose the repository tools.'
        $beforeTarget = [string]$item.Target
        & $linkScript -WowPath $clientPath -Confirm:$false | Out-Null
        Assert-True ([string](Get-Item -LiteralPath $destination -Force).Target -eq $beforeTarget) 'Rerunning changed the existing link.'
    }

    Invoke-Check 'classic executable names are accepted' {
        foreach ($executable in @('WowClassic.exe', 'WowClassicB.exe')) {
            $clientPath = New-TestClient $executable $executable
            $destination = Get-TestDestination $clientPath
            & $linkScript -WowPath $clientPath -Confirm:$false | Out-Null
            Assert-True (Test-Path -LiteralPath (Join-Path $destination 'LockInTools.toc') -PathType Leaf) "Client with $executable was not linked."
        }
    }

    Invoke-Check 'unlink removes only the link and preserves every checkout file' {
        $clientPath = New-TestClient 'Unlink client [Forever beta]'
        $destination = Get-TestDestination $clientPath
        $copiedRepository = Join-Path $scratchDirectory 'Checkout keep intact'
        $copiedTools = Join-Path $copiedRepository 'tools'
        $nestedDirectory = Join-Path $copiedRepository 'nested'
        [IO.Directory]::CreateDirectory($copiedTools) | Out-Null
        [IO.Directory]::CreateDirectory($nestedDirectory) | Out-Null
        $copiedScript = Join-Path $copiedTools 'link-wow.ps1'
        Copy-Item -LiteralPath $linkScript -Destination $copiedScript
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'LockInTools.toc') -Destination (Join-Path $copiedRepository 'LockInTools.toc')
        [IO.File]::WriteAllText((Join-Path $copiedRepository 'keep.txt'), 'checkout root must survive')
        [IO.File]::WriteAllText((Join-Path $nestedDirectory 'keep.txt'), 'nested checkout files must survive')
        $beforeHashes = @{}
        foreach ($file in (Get-ChildItem -LiteralPath $copiedRepository -File -Recurse)) {
            $beforeHashes[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName).Hash
        }

        & $copiedScript -WowPath $clientPath -Confirm:$false | Out-Null
        Assert-True ((Get-Item -LiteralPath $destination -Force).LinkType -eq 'Junction') 'The unlink fixture did not create a junction.'
        $otherAddon = Join-Path (Split-Path -Parent $destination) 'OtherAddon'
        [IO.Directory]::CreateDirectory($otherAddon) | Out-Null
        $otherAddonMarker = Join-Path $otherAddon 'keep.txt'
        [IO.File]::WriteAllText($otherAddonMarker, 'another addon must survive')
        & $copiedScript -WowPath $clientPath -Unlink -WhatIf | Out-Null
        Assert-True ((Get-Item -LiteralPath $destination -Force).LinkType -eq 'Junction') 'Unlink dry run removed the junction.'
        Assert-True ([string](Get-Item -LiteralPath $destination -Force).Target -eq $copiedRepository) 'Unlink dry run changed the junction target.'
        & $copiedScript -WowPath $clientPath -Unlink -Confirm:$false | Out-Null
        Assert-True (-not (Test-Path -LiteralPath $destination)) 'Unlink left the addon junction present.'
        Assert-True (Test-Path -LiteralPath (Split-Path -Parent $destination) -PathType Container) 'Unlink removed the AddOns directory.'
        & $copiedScript -WowPath $clientPath -Unlink -Confirm:$false | Out-Null
        Assert-True (-not (Test-Path -LiteralPath $destination)) 'Repeated unlink recreated the addon destination.'
        Assert-True ([IO.File]::ReadAllText($otherAddonMarker) -eq 'another addon must survive') 'Unlink changed another addon.'
        $afterFiles = @(Get-ChildItem -LiteralPath $copiedRepository -File -Recurse)
        Assert-True ($afterFiles.Count -eq $beforeHashes.Count) 'Unlink changed the number of checkout files.'
        foreach ($filePath in $beforeHashes.Keys) {
            Assert-True (Test-Path -LiteralPath $filePath -PathType Leaf) "Unlink removed a checkout file: $filePath"
            Assert-True ((Get-FileHash -LiteralPath $filePath).Hash -eq $beforeHashes[$filePath]) "Unlink changed a checkout file: $filePath"
        }
    }

    Invoke-Check 'unlink with no addon leaves missing parent folders uncreated' {
        $clientPath = New-TestClient 'Unlinked client [no Interface]'
        $destination = Get-TestDestination $clientPath
        & $linkScript -WowPath $clientPath -Unlink -Confirm:$false | Out-Null
        & $linkScript -WowPath $clientPath -Unlink -WhatIf | Out-Null
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $clientPath 'Interface'))) 'Unlink created missing parent folders.'
        Assert-True (-not (Test-Path -LiteralPath $destination)) 'Unlink created an addon destination.'
    }

    Invoke-Check 'an existing addon directory is preserved' {
        $clientPath = New-TestClient 'Existing folder'
        $destination = Get-TestDestination $clientPath
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        $sentinel = Join-Path $destination 'keep.txt'
        [IO.File]::WriteAllText($sentinel, 'existing addon')
        Assert-Rejected { & $linkScript -WowPath $clientPath -Confirm:$false } 'An unrelated addon directory was accepted.'
        Assert-Rejected { & $linkScript -WowPath $clientPath -Unlink -Confirm:$false } 'Unlink accepted an unrelated addon directory.'
        Assert-True ([IO.File]::ReadAllText($sentinel) -eq 'existing addon') 'Existing addon files changed.'
        Assert-True (((Get-Item -LiteralPath $destination -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Existing addon directory became a link.'
    }

    Invoke-Check 'an existing addon file is preserved' {
        $clientPath = New-TestClient 'Existing file'
        $destination = Get-TestDestination $clientPath
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        [IO.File]::WriteAllText($destination, 'keep file')
        Assert-Rejected { & $linkScript -WowPath $clientPath -Confirm:$false } 'An unrelated addon file was accepted.'
        Assert-Rejected { & $linkScript -WowPath $clientPath -Unlink -Confirm:$false } 'Unlink accepted an unrelated addon file.'
        Assert-True ([IO.File]::ReadAllText($destination) -eq 'keep file') 'Existing addon file changed.'
    }

    Invoke-Check 'a junction to another directory and its contents are preserved' {
        $clientPath = New-TestClient 'Wrong link'
        $destination = Get-TestDestination $clientPath
        $otherTarget = Join-Path $scratchDirectory 'Another addon source'
        [IO.Directory]::CreateDirectory($otherTarget) | Out-Null
        $sentinel = Join-Path $otherTarget 'keep.txt'
        [IO.File]::WriteAllText($sentinel, 'other source')
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        New-Item -ItemType Junction -Path $destination -Target $otherTarget | Out-Null
        $beforeTarget = [string](Get-Item -LiteralPath $destination -Force).Target
        Assert-Rejected { & $linkScript -WowPath $clientPath -Confirm:$false } 'A junction to another source was accepted.'
        Assert-Rejected { & $linkScript -WowPath $clientPath -Unlink -Confirm:$false } 'Unlink accepted a junction to another source.'
        Assert-True ([string](Get-Item -LiteralPath $destination -Force).Target -eq $beforeTarget) 'The unrelated junction changed.'
        Assert-True ([IO.File]::ReadAllText($sentinel) -eq 'other source') 'The unrelated junction target changed.'
    }

    Invoke-Check 'a broken junction is preserved' {
        $clientPath = New-TestClient 'Broken link'
        $destination = Get-TestDestination $clientPath
        $missingTarget = Join-Path $scratchDirectory 'Removed addon source'
        [IO.Directory]::CreateDirectory($missingTarget) | Out-Null
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        New-Item -ItemType Junction -Path $destination -Target $missingTarget | Out-Null
        [IO.Directory]::Delete($missingTarget)
        $beforeTarget = [string](Get-Item -LiteralPath $destination -Force).Target
        Assert-Rejected { & $linkScript -WowPath $clientPath -Confirm:$false } 'A broken junction was accepted.'
        Assert-Rejected { & $linkScript -WowPath $clientPath -Unlink -Confirm:$false } 'Unlink accepted a broken junction.'
        Assert-True ([string](Get-Item -LiteralPath $destination -Force).Target -eq $beforeTarget) 'The broken junction changed.'
        Assert-True (-not (Test-Path -LiteralPath $missingTarget)) 'The missing target was recreated.'
    }

    Invoke-Check 'missing clients and directories without a WoW executable are rejected' {
        $missingClient = Join-Path $scratchDirectory 'Missing client'
        Assert-Rejected { & $linkScript -WowPath $missingClient -Confirm:$false } 'A missing client was accepted.'
        Assert-Rejected { & $linkScript -WowPath $missingClient -Unlink -Confirm:$false } 'Unlink accepted a missing client.'
        Assert-True (-not (Test-Path -LiteralPath $missingClient)) 'A missing client directory was created.'
        $invalidClient = Join-Path $scratchDirectory 'Not a WoW client'
        [IO.Directory]::CreateDirectory($invalidClient) | Out-Null
        Assert-Rejected { & $linkScript -WowPath $invalidClient -Confirm:$false } 'A directory without a WoW executable was accepted.'
        Assert-Rejected { & $linkScript -WowPath $invalidClient -Unlink -Confirm:$false } 'Unlink accepted a directory without a WoW executable.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $invalidClient 'Interface'))) 'An invalid client was modified.'
    }

    Invoke-Check 'a directly installed repository is preserved and cannot be unlinked' {
        $clientPath = New-TestClient 'Direct installation'
        $destination = Get-TestDestination $clientPath
        $copiedTools = Join-Path $destination 'tools'
        [IO.Directory]::CreateDirectory($copiedTools) | Out-Null
        $copiedScript = Join-Path $copiedTools 'link-wow.ps1'
        Copy-Item -LiteralPath $linkScript -Destination $copiedScript
        $copiedToc = Join-Path $destination 'LockInTools.toc'
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'LockInTools.toc') -Destination $copiedToc
        $beforeScriptHash = (Get-FileHash -LiteralPath $copiedScript).Hash
        $beforeTocHash = (Get-FileHash -LiteralPath $copiedToc).Hash
        & $copiedScript -WowPath $clientPath -Confirm:$false | Out-Null
        Assert-Rejected { & $copiedScript -WowPath $clientPath -Unlink -Confirm:$false } 'Unlink accepted a repository installed directly at the destination.'
        Assert-True (((Get-Item -LiteralPath $destination -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'The direct installation became a link.'
        Assert-True ((Get-FileHash -LiteralPath $copiedScript).Hash -eq $beforeScriptHash) 'The directly installed script changed.'
        Assert-True ((Get-FileHash -LiteralPath $copiedToc).Hash -eq $beforeTocHash) 'The directly installed manifest changed.'
    }

    Write-Host "PASS: all addon-link integration checks ($script:passedChecks checks)"
}
finally {
    # Remove only junction entries before recursively deleting the scratch tree.
    # Directory.Delete without recursion does not traverse their repository targets.
    $resolvedRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $testRoot).ProviderPath).TrimEnd('\')
    $resolvedScratch = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $scratchDirectory).ProviderPath).TrimEnd('\')
    $rootPrefix = $resolvedRoot + '\'
    if (-not $resolvedScratch.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $resolvedScratch -ne [IO.Path]::GetFullPath($scratchDirectory).TrimEnd('\')) {
        throw 'Refusing to clean a scratch directory outside the addon-link test root.'
    }
    foreach ($junctionPath in $junctionPaths) {
        $fullPath = [IO.Path]::GetFullPath($junctionPath)
        if (-not $fullPath.StartsWith($resolvedScratch + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to clean a junction outside the scratch directory.'
        }
        $item = Get-Item -LiteralPath $junctionPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            [IO.Directory]::Delete($fullPath)
        }
    }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}
