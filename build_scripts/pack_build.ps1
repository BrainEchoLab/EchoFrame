<#
.SYNOPSIS
    Package a Release output directory as binaries/build_<CONFIG>/build.zip.

.DESCRIPTION
    Writes an archive whose entries are build/Release/<file>, matching the layout
    the README tells people to unpack into echoframe/cpp/src/.

    Entry names use forward slashes. Compress-Archive on Windows PowerShell
    writes backslash separators, which the ZIP specification does not allow and
    which non-Windows unzip implementations read as one flat filename rather
    than a directory tree.

.EXAMPLE
    pwsh -File build_scripts/pack_build.ps1 `
         -ReleaseDir build_CUDA_12.8_MATLAB_2024a/Release `
         -Out binaries/build_CUDA_12.8_MATLAB_2024a/build.zip
#>
param(
    [Parameter(Mandatory = $true)][string]$ReleaseDir,
    [Parameter(Mandatory = $true)][string]$Out
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

if (-not (Test-Path -LiteralPath $ReleaseDir -PathType Container)) {
    throw "no such Release directory: $ReleaseDir"
}
$ReleaseDir = (Resolve-Path -LiteralPath $ReleaseDir).Path

$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Force }

$count = 0
$zip = [System.IO.Compression.ZipFile]::Open($Out, 'Create')
try {
    Get-ChildItem -LiteralPath $ReleaseDir -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($ReleaseDir.Length).TrimStart('\', '/').Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $_.FullName, "build/Release/$rel",
            [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        $count++
    }
}
finally {
    $zip.Dispose()
}

if ($count -eq 0) {
    Remove-Item -LiteralPath $Out -Force
    throw "no files found under $ReleaseDir"
}

Write-Host ("Packaged {0} file(s) -> {1} ({2} bytes)" -f `
    $count, $Out, (Get-Item -LiteralPath $Out).Length)
