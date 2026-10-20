#Requires -Version 5.1

<#
.SYNOPSIS
Links or unlinks this checkout in a WoW Forever client's Interface\AddOns directory.
.DESCRIPTION
Creates a Windows directory junction without copying addon files. With no path,
looks for _classic_beta_ clients in common local WoW locations and Battle.net's
WoW registry keys. Use -WowPath for other locations or multiple installations.
Existing files, folders and links to another checkout are never replaced.
Unlinking removes only a directory link to this checkout, leaving its files intact.
.PARAMETER WowPath
The client directory containing WowB.exe (or another WoW executable).
.PARAMETER Unlink
Remove only the existing directory link to this checkout. A missing link is a no-op.
.EXAMPLE
.\tools\link-wow.ps1 -WhatIf
.EXAMPLE
.\tools\link-wow.ps1 -WowPath 'D:\BattleNetLibrary\World of Warcraft\_classic_beta_'
.EXAMPLE
.\tools\link-wow.ps1 -Unlink -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$WowPath,

    [switch]$Unlink
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This tool creates Windows directory junctions and requires Windows.'
}

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot 'LockInTools.toc') -PathType Leaf)) {
    throw 'LockInTools.toc is missing. Run the script from a complete LockInTools checkout.'
}

function Test-WowClient {
    param([string]$Path)

    foreach ($executable in @('WowB.exe', 'Wow.exe', 'WowClassic.exe', 'WowClassicB.exe')) {
        if (Test-Path -LiteralPath (Join-Path $Path $executable) -PathType Leaf) {
            return $true
        }
    }
    return $false
}

function Test-CheckoutLink {
    param($Item)

    if ($null -eq $Item -or -not $Item.PSIsContainer -or
        ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -or
        $Item.LinkType -notin @('Junction', 'SymbolicLink')) {
        return $false
    }
    $targets = @($Item.Target)
    if ($targets.Count -ne 1 -or -not $targets[0]) {
        return $false
    }
    $linkTarget = [string]$targets[0]
    if (-not [IO.Path]::IsPathRooted($linkTarget)) {
        $linkTarget = Join-Path (Split-Path -Parent $Item.FullName) $linkTarget
    }
    return [IO.Path]::GetFullPath($linkTarget).TrimEnd('\') -eq $repositoryRoot
}

function Find-WowClient {
    $installRoots = @(
        foreach ($programDirectory in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if ($programDirectory) {
                Join-Path $programDirectory 'World of Warcraft'
            }
        }
        foreach ($drive in [IO.DriveInfo]::GetDrives()) {
            if ($drive.DriveType -eq [IO.DriveType]::Fixed -and $drive.IsReady) {
                foreach ($directory in @('BattleNetLibrary\World of Warcraft', 'Games\World of Warcraft', 'World of Warcraft')) {
                    Join-Path $drive.RootDirectory.FullName $directory
                }
            }
        }
        foreach ($registryPath in @(
            'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft',
            'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft',
            'HKCU:\SOFTWARE\Blizzard Entertainment\World of Warcraft'
        )) {
            Get-ItemProperty -LiteralPath $registryPath -Name InstallPath -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty InstallPath -ErrorAction SilentlyContinue
        }
    )

    foreach ($installRoot in ($installRoots | Sort-Object -Unique)) {
        if ((Split-Path -Leaf $installRoot.TrimEnd('\')) -eq '_classic_beta_') {
            $candidate = $installRoot
        }
        else {
            $candidate = Join-Path $installRoot '_classic_beta_'
        }
        if (Test-WowClient $candidate) {
            [IO.Path]::GetFullPath($candidate).TrimEnd('\')
        }
    }
}

if (-not $WowPath) {
    $candidates = @(Find-WowClient | Sort-Object -Unique)
    if ($candidates.Count -eq 0) {
        throw 'No Forever beta client found in common locations. Use -WowPath with the client folder containing WowB.exe.'
    }
    if ($candidates.Count -gt 1) {
        throw "Multiple beta clients found. Select the Forever client with -WowPath:`n$($candidates -join "`n")"
    }
    $WowPath = $candidates[0]
}

$client = Get-Item -LiteralPath $WowPath -Force
if ($client.PSProvider.Name -ne 'FileSystem' -or -not $client.PSIsContainer -or
    -not (Test-WowClient $client.FullName)) {
    throw '-WowPath must be the client folder containing a WoW executable, rather than Interface or AddOns.'
}
$clientRoot = $client.FullName
if ($repositoryRoot.StartsWith('\\') -or $clientRoot.StartsWith('\\')) {
    throw 'Directory junctions require local paths. Use a local checkout and WoW installation.'
}
$addonsDirectory = Join-Path $clientRoot 'Interface\AddOns'
$destination = Join-Path $addonsDirectory 'LockInTools'

Write-Host "Checkout: $repositoryRoot"
Write-Host "Addon:    $destination"

if ($destination -eq $repositoryRoot) {
    if ($Unlink) {
        throw 'This checkout is installed directly in AddOns, rather than linked. Nothing was removed.'
    }
    Write-Host 'This checkout is already installed directly in AddOns.'
    return
}
if ($destination.StartsWith($repositoryRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The WoW destination must be outside this checkout to avoid a recursive directory link.'
}

# Enumerating the parent also finds broken links that Test-Path can miss.
$existing = $null
if (Test-Path -LiteralPath $addonsDirectory -PathType Container) {
    $existing = Get-ChildItem -LiteralPath $addonsDirectory -Force |
        Where-Object { $_.Name -eq 'LockInTools' } | Select-Object -First 1
}
if ($Unlink -and $null -eq $existing) {
    Write-Host 'No addon link exists. Nothing to unlink.'
    return
}
if ($null -ne $existing) {
    if (Test-CheckoutLink $existing) {
        if ($Unlink) {
            if ($PSCmdlet.ShouldProcess($destination, 'Remove only the directory link; keep the checkout intact')) {
                # Recheck after a possible confirmation prompt. Never delete an ordinary directory.
                $current = Get-Item -LiteralPath $destination -Force
                if (-not (Test-CheckoutLink $current)) {
                    throw 'The destination changed and is no longer a link to this checkout. Nothing was removed.'
                }
                # Nonrecursive deletion removes the link entry without traversing its target.
                [IO.Directory]::Delete($destination, $false)
                Write-Host 'Unlinked. The checkout and its files are unchanged.'
            }
        }
        else {
            Write-Host 'Already linked to this checkout.'
        }
        return
    }
    if ($Unlink) {
        throw "Refusing to unlink: $destination is not a directory link to this checkout. Nothing was removed."
    }
    throw "Destination already exists: $destination. Move the existing addon or conflicting link yourself, then rerun. Nothing was replaced."
}

if ($PSCmdlet.ShouldProcess($destination, "Create a directory junction to '$repositoryRoot', including missing parent folders")) {
    [IO.Directory]::CreateDirectory($addonsDirectory) | Out-Null
    # A literal location avoids interpreting brackets in directory names as wildcards.
    Push-Location -LiteralPath $addonsDirectory
    try {
        New-Item -Path . -Name 'LockInTools' -ItemType Junction -Value $repositoryRoot | Out-Null
    }
    finally {
        Pop-Location
    }
    Write-Host 'Linked. Restart WoW and enable LockInTools in the AddOns list.'
}
