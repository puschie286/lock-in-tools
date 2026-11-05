#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$converter = Join-Path $repositoryRoot 'tools\convert-restedxp.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) 'LockInTools-convert-restedxp-tests'
$scratchDirectory = Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratchDirectory) | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
$script:passedChecks = 0

# Fictional guide fixture from restedxp-codec.lua. Expected ciphertext was
# generated independently with Python RC4, including the native key derivation.
$source = '3|2264937395:AhsZ1dzvgtAFDamPfcMylA1hPII4MWFIhcYJIwK/5SValxoMF/N2mVQZtb+J4RjOc00SsBSPQtyeElNvpxXNJRIDEUh/Xs9jBRivS0x2hMaNd7qeS+3aXxnFSGfFNAXZPKCffVwy0HeKh1IS4S8h+iB5%1585388498:AhtnUiOsbt7HRJ/glORATDi0jtTia+HgRDXokTLEFx2wWiiLRBVvGU8giEobS3PPQ6CWw9koPuKSLrm5SnTHS3Fzxpgw2StO+Cp2pJkyx5lyxw==%|40000'
$expected = '3|2264937395:KP55zzEa+624m7/+ZxEFMzpFyejB/LykE0Bqh8gR/7wtZYW/WiFCgE3T+GLQjLKPK/G125GquG4n0/+LmgbLBhQKenr9DVrHil8IUsJJptr+YAfs1NWrS73ieyHg/TSg3r0HVxUQPjH61FyAW5nT1cZ+%1585388498:KP4HSM5ZF6N60omRjjZ36w+Qe74bpjwM0rOLNfhqDYTHqLc4CcdbAFbqxZdCJtmOGxwxqFwNxFAr7xVdd2fBaHd6raqyir7qd23RvRcN5YUB0A==%|40000'
$unicodeSource = '3|2264937395:f8PGB6W0uOhyL42DZukqn5K+hm8TpCIWhYRVHS2VTrvCJmVm+gXYxi7lSOCEAiRjJXou6yNLBviqiE7xM/gdYF7AMfpsOp20RmTUC38NgMMRH9Tp3h0/kZc2H8PQdT7bAOKlIbDCRC2p75wkpxpC5n0a%1585388498:f8O4gFr3VOawZrvsj85YR6drNDnJ/qK+RHe0rx3uvIMo61fhqePBRjXcdRUWqE9iFZeqmO7sesamtKQn3pkXDj2w5iojvXmZu1YN5KpJw5zurw==%|40000'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Message)
    $rejected = $false
    try { & $Action | Out-Null }
    catch { $rejected = $true }
    Assert-True $rejected $Message
}

function Invoke-Check {
    param([string]$Name, [scriptblock]$Action)
    & $Action
    $script:passedChecks++
    Write-Host "PASS: $Name"
}

function New-Input {
    param([string]$Name, [string]$Content = $source, [Text.Encoding]$Encoding = $utf8)
    $path = Join-Path $scratchDirectory $Name
    [IO.File]::WriteAllText($path, $Content, $Encoding)
    return $path
}

function Assert-Output {
    param([object[]]$Result, [string]$Path)
    Assert-True ($Result.Count -eq 1 -and $Result[0] -ceq $Path) 'The converter must return only the absolute output path.'
    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-True ($bytes.Length -eq $expected.Length) 'Output includes a BOM, newline, or unexpected data.'
    Assert-True ([Text.Encoding]::ASCII.GetString($bytes) -ceq $expected) 'Output differs from independently generated Player#1234 ciphertext.'
}

try {
    Invoke-Check 'multi-block conversion matches independent ciphertext and preserves the input' {
        $inputPath = New-Input 'Guide [Source#1234].txt'
        $outputPath = Join-Path $scratchDirectory 'Guide [Player#1234].txt'
        $beforeHash = (Get-FileHash -LiteralPath $inputPath).Hash
        Assert-Output @(& $converter -InputPath $inputPath) $outputPath
        Assert-True ((Get-FileHash -LiteralPath $inputPath).Hash -eq $beforeHash) 'Conversion changed the source file.'
    }

    Invoke-Check 'an extensionless filename with multiple separators retains its other text' {
        $inputPath = New-Input 'Example Guide - Sample Pack!_locale_Source#1234'
        $outputPath = Join-Path $scratchDirectory 'Example Guide - Sample Pack!_locale_Player#1234'
        Assert-Output @(& $converter $inputPath) $outputPath
    }

    Invoke-Check 'Unicode tags and paths retain UTF-8 bytes when sent to Lua' {
        $unicodeDirectory = Join-Path $scratchDirectory ('Guides ' + [char]0x00FC + ' [folder]')
        [IO.Directory]::CreateDirectory($unicodeDirectory) | Out-Null
        $inputPath = Join-Path $unicodeDirectory ('Guide [L' + [char]0x00E9 + 'a#1234].txt')
        [IO.File]::WriteAllText($inputPath, $unicodeSource, $utf8)
        $outputPath = Join-Path $unicodeDirectory 'Guide [Player#1234].txt'
        Assert-Output @(& $converter $inputPath) $outputPath
    }

    Invoke-Check 'UTF-8 and UTF-16 BOMs, pasted whitespace and escaped pipes are accepted' {
        $pasted = " `r`n" + $source.Replace('|', '||').Replace('%', "%`r`n") + "`t"
        $encodings = @((New-Object Text.UTF8Encoding($true)), [Text.Encoding]::Unicode)
        for ($index = 0; $index -lt $encodings.Count; $index++) {
            $inputPath = New-Input "Pasted$index-Source#1234.txt" $pasted $encodings[$index]
            $outputPath = Join-Path $scratchDirectory "Pasted$index-Player#1234.txt"
            Assert-Output @(& $converter $inputPath) $outputPath
        }
    }

    Invoke-Check 'relative input and explicit output work outside the checkout' {
        New-Input 'Relative-Source#1234.txt' | Out-Null
        $outputPath = Join-Path $scratchDirectory 'chosen output.txt'
        Push-Location $scratchDirectory
        try { Assert-Output @(& $converter '.\Relative-Source#1234.txt' '.\chosen output.txt') $outputPath }
        finally { Pop-Location }
    }

    Invoke-Check 'missing and ambiguous filename tags are rejected without creating output' {
        foreach ($name in @('No tag.txt', 'Source#1234 Other#5678.txt', 'Incomplete#tag.txt')) {
            $inputPath = New-Input $name
            $outputPath = Join-Path $scratchDirectory 'rejected output.txt'
            Assert-Rejected { & $converter $inputPath $outputPath } "Invalid filename was accepted: $name"
            Assert-True (-not (Test-Path -LiteralPath $outputPath)) 'Filename rejection created an output file.'
            Assert-True ([IO.File]::ReadAllText($inputPath) -ceq $source) 'Filename rejection changed the input.'
        }
    }

    Invoke-Check 'empty, oversized and malformed exports leave no output' {
        $invalid = @('', ('x' * (2 * 1024 * 1024 + 1)), '1|1:Zg==%|40001', '1|1:Zh==%|40000', '1|1:Zg==|40000')
        for ($index = 0; $index -lt $invalid.Count; $index++) {
            $inputPath = New-Input "Invalid$index-Source#1234.txt" $invalid[$index]
            $outputPath = Join-Path $scratchDirectory "Invalid$index-Player#1234.txt"
            $beforeHash = (Get-FileHash -LiteralPath $inputPath).Hash
            Assert-Rejected { & $converter $inputPath } "Invalid export $index was accepted."
            Assert-True (-not (Test-Path -LiteralPath $outputPath)) 'Invalid export created an output file.'
            Assert-True ((Get-FileHash -LiteralPath $inputPath).Hash -eq $beforeHash) 'Invalid export changed the input.'
        }
    }

    Invoke-Check 'existing output and in-place conversion are rejected without overwriting data' {
        $inputPath = New-Input 'Protected-Source#1234.txt'
        $outputPath = New-Input 'Protected-Player#1234.txt' 'keep existing output'
        Assert-Rejected { & $converter $inputPath } 'An existing default output was overwritten.'
        Assert-Rejected { & $converter $inputPath $outputPath } 'An existing explicit output was overwritten.'
        Assert-Rejected { & $converter $inputPath $inputPath } 'In-place conversion was accepted.'
        Assert-True ([IO.File]::ReadAllText($inputPath) -ceq $source) 'Protected source was changed.'
        Assert-True ([IO.File]::ReadAllText($outputPath) -ceq 'keep existing output') 'Protected output was changed.'
        $genericInput = New-Input 'Already-Player#1234.txt' $expected
        Assert-Rejected { & $converter $genericInput } 'An already-generic file was overwritten in place.'
        Assert-True ([IO.File]::ReadAllText($genericInput) -ceq $expected) 'Already-generic source was changed.'
    }

    Write-Host "PASS: RestedXP Windows converter integration ($script:passedChecks checks)"
}
finally {
    $resolvedScratch = [IO.Path]::GetFullPath($scratchDirectory)
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\') + '\'
    if (-not $resolvedScratch.StartsWith($resolvedTestRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove a test directory outside the intended scratch root.'
    }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}
