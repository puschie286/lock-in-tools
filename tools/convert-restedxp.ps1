#Requires -Version 5.1

<#
.SYNOPSIS
Re-encodes a RestedXP export for Player#1234 using the BattleTag in its filename.
.DESCRIPTION
Uses the addon's RestedXPCodec.lua and the local tools/lua runtime. Accepts
format-40000 exports up to 2 MiB. Creates a new file beside the input, replacing
the filename's BattleTag with Player#1234. Never overwrites an existing file.
.PARAMETER InputPath
Export file with exactly one Name#1234 tag in its filename. Spaces, underscores,
hyphens and brackets can separate the tag from the rest of the filename.
.PARAMETER OutputPath
Optional destination file. Its parent directory must already exist.
.EXAMPLE
.\tools\convert-restedxp.ps1 'C:\Guides\Example Guide_Source#1234'
.EXAMPLE
.\tools\convert-restedxp.ps1 -InputPath 'C:\Guides\Guide_Source#1234.txt' -OutputPath 'C:\Guides\Generic.txt'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,

    [Parameter(Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$inputFile = Get-Item -LiteralPath $InputPath -Force
if ($inputFile -isnot [IO.FileInfo]) {
    throw 'InputPath must be an export file.'
}

$tagMatches = [regex]::Matches($inputFile.BaseName,
    '(?<![\p{L}\p{M}\p{N}#])[\p{L}\p{M}\p{N}]+#[0-9]+(?![\p{L}\p{M}\p{N}#])')
if ($tagMatches.Count -ne 1) {
    throw 'The filename must contain exactly one BattleTag in Name#1234 form.'
}
$sourceTag = $tagMatches[0].Value
$destinationTag = 'Player#1234'
if (-not $OutputPath) {
    $outputName = $inputFile.Name.Substring(0, $tagMatches[0].Index) + $destinationTag +
        $inputFile.Name.Substring($tagMatches[0].Index + $sourceTag.Length)
    $OutputPath = Join-Path $inputFile.DirectoryName $outputName
}
$outputFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ([string]::Equals($inputFile.FullName, $outputFile, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The output must be a different file from the input. Specify -OutputPath.'
}
if (Test-Path -LiteralPath $outputFile) {
    throw "Output already exists: $outputFile"
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$luaExecutable = Join-Path $PSScriptRoot 'lua\lua5.1.exe'
if (-not (Test-Path -LiteralPath $luaExecutable -PathType Leaf)) {
    throw 'Local Lua runtime missing. Run tools\setup-lua.ps1 from the checkout first.'
}
if ($inputFile.Length -eq 0 -or $inputFile.Length -gt 2MB) {
    throw 'Guide export is empty or exceeds the 2 MiB limit.'
}
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$raw = [IO.File]::ReadAllText($inputFile.FullName, $utf8)

# Send data as UTF-8 over stdin: the Windows Lua runtime's ANSI command-line
# arguments and file APIs would otherwise corrupt Unicode tags and paths.
$startInfo = New-Object Diagnostics.ProcessStartInfo
$startInfo.FileName = $luaExecutable
$startInfo.Arguments = 'tools/convert-restedxp.lua'
$startInfo.WorkingDirectory = $repositoryRoot
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$process = New-Object Diagnostics.Process
$process.StartInfo = $startInfo
try {
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $payload = $utf8.GetBytes($sourceTag + "`n" + $raw)
    $process.StandardInput.BaseStream.Write($payload, 0, $payload.Length)
    $process.StandardInput.Close()
    $converted = $stdout.GetAwaiter().GetResult()
    $problem = $stderr.GetAwaiter().GetResult()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw "RestedXP conversion failed: $($problem.Trim())"
    }
}
finally {
    $process.Dispose()
}

# CreateNew also protects existing files if another process creates the output
# while conversion is running. The export is ASCII, without a BOM or newline.
$bytes = [Text.Encoding]::ASCII.GetBytes($converted)
$stream = [IO.File]::Open($outputFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
try {
    $stream.Write($bytes, 0, $bytes.Length)
}
finally {
    $stream.Dispose()
}
$outputFile
