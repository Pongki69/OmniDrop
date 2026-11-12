param(
    [string]$LogoPath = (Join-Path $PSScriptRoot '..\assets\brand\omnidrop_logo.png'),
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$resolvedLogoPath = (Resolve-Path $LogoPath).Path
$logo = [System.Drawing.Image]::FromFile($resolvedLogoPath)

function Get-PngFrame([System.Drawing.Image]$Image, [int]$Size) {
    $bitmap = [System.Drawing.Bitmap]::new(
        $Size,
        $Size,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::FromArgb(10, 23, 17))
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.DrawImage($Image, 0, 0, $Size, $Size)
        $stream = [System.IO.MemoryStream]::new()
        try {
            $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            return ,$stream.ToArray()
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

try {
    $icoSizes = @(16, 24, 32, 48, 64, 128, 256)
    $frames = @(
        foreach ($size in $icoSizes) {
            [pscustomobject]@{ Size = $size; Bytes = (Get-PngFrame $logo $size) }
        }
    )

    $iconPath = Join-Path $ProjectRoot 'windows\runner\resources\app_icon.ico'
    $iconStream = [System.IO.File]::Create($iconPath)
    $writer = [System.IO.BinaryWriter]::new($iconStream)
    try {
        $writer.Write([UInt16]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]$frames.Count)
        $offset = 6 + (16 * $frames.Count)
        foreach ($frame in $frames) {
            $dimension = if ($frame.Size -eq 256) { [byte]0 } else { [byte]$frame.Size }
            $writer.Write($dimension)
            $writer.Write($dimension)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([UInt16]1)
            $writer.Write([UInt16]32)
            $writer.Write([UInt32]$frame.Bytes.Length)
            $writer.Write([UInt32]$offset)
            $offset += $frame.Bytes.Length
        }
        foreach ($frame in $frames) { $writer.Write([byte[]]$frame.Bytes) }
    }
    finally {
        $writer.Dispose()
        $iconStream.Dispose()
    }

    $densities = @{
        'mipmap-mdpi' = 48
        'mipmap-hdpi' = 72
        'mipmap-xhdpi' = 96
        'mipmap-xxhdpi' = 144
        'mipmap-xxxhdpi' = 192
    }
    foreach ($entry in $densities.GetEnumerator()) {
        $folder = Join-Path $ProjectRoot "android\app\src\main\res\$($entry.Key)"
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        $png = Get-PngFrame $logo $entry.Value
        [System.IO.File]::WriteAllBytes((Join-Path $folder 'ic_launcher.png'), $png)
    }

    $splashFolder = Join-Path $ProjectRoot 'android\app\src\main\res\drawable-nodpi'
    New-Item -ItemType Directory -Force -Path $splashFolder | Out-Null
    Copy-Item -LiteralPath $resolvedLogoPath -Destination (Join-Path $splashFolder 'omnidrop_logo.png') -Force
}
finally {
    $logo.Dispose()
}

Write-Output "Generated Windows ICO and Android launcher icons from $LogoPath"
