[CmdletBinding()]
param()

# Small native UI primitives, kept reproducible without an image editor. The
# addon loads only the generated power-of-two, uncompressed 32-bit TGA assets.
$ErrorActionPreference = 'Stop'
$mediaDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'Media'

function Write-BurningTexture {
    param([string]$Name, [int]$Width, [int]$Height, [scriptblock]$Pixel)
    $stream = [System.IO.File]::Create((Join-Path $mediaDirectory $Name))
    $writer = New-Object System.IO.BinaryWriter $stream
    try {
        $header = New-Object byte[] 18
        $header[2] = 2
        $header[12] = $Width -band 255
        $header[13] = $Width -shr 8
        $header[14] = $Height -band 255
        $header[15] = $Height -shr 8
        $header[16] = 32
        $header[17] = 40 # Eight alpha bits; top-left pixel origin.
        $writer.Write($header)
        for ($y = 0; $y -lt $Height; $y++) {
            for ($x = 0; $x -lt $Width; $x++) {
                $rgba = & $Pixel (($x + 0.5) / $Width) (($y + 0.5) / $Height)
                foreach ($channel in @(2, 1, 0, 3)) {
                    $writer.Write([byte][math]::Round([math]::Max(0.0, [math]::Min(255.0, $rgba[$channel]))))
                }
            }
        }
    }
    finally { $writer.Dispose() }
}

Write-BurningTexture 'BurningGlow.tga' 64 64 {
    param($u, $v)
    $radius = [math]::Sqrt([math]::Pow(2 * $u - 1, 2) + [math]::Pow(2 * $v - 1, 2))
    # Double bounds avoid an integer Math.Max overload quantizing the soft fade.
    $alpha = 255 * [math]::Pow([math]::Max(0.0, 1.0 - $radius), 1.3)
    @(255, 255, 255, $alpha)
}

Write-BurningTexture 'BurningFlame.tga' 32 64 {
    param($u, $v)
    $center = 0.5 + 0.11 * [math]::Sin($v * 5.5) * (1 - $v)
    $radius = 0.015 + 0.47 * [math]::Pow($v, 0.85)
    $edge = [math]::Max(0.0, [math]::Min(1.0, ($radius - [math]::Abs($u - $center)) * 32))
    $alpha = 255 * $edge * [math]::Min(1.0, $v * 25)
    @(255, (80 + 175 * [math]::Pow(1 - $v, 0.4)), (5 + 180 * [math]::Pow(1 - $v, 2)), $alpha)
}

Write-Output 'Generated Media/BurningGlow.tga and Media/BurningFlame.tga.'
