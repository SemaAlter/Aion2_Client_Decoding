<#
.SYNOPSIS
Extracts your AION2 client: every pak/IoStore file, the decrypted data tables (.bin), and the
decoded tables and maps (JSON).

.DESCRIPTION
1. Setup-Dependencies.ps1 prepares CUE4Parse (pinned, AION2 patches) and builds Aion2Extractor.
2. Aion2Extractor mounts all containers with the archive AES key, writes every virtual file to
   output\raw (unchanged files are skipped on reruns), and decrypts every .dat into
   output\decrypted\**.bin with output\decryption-manifest.csv.
3. tools\client-data\october\export.py decodes the .bin tables and maps into output\decoded\
   (JSON), and the manifest is updated.

.EXAMPLE
.\Extract-GameData.ps1 -GameDirectory 'C:\Games\AION2'
#>
[CmdletBinding()]
param(
    # AION2 install folder (the one containing Aion2\Content\Paks). Found in the Steam
    # libraries when omitted.
    [string]$GameDirectory,
    [string]$KeyPath = (Join-Path $PSScriptRoot 'config\client-data-aes-key.txt'),
    [string]$AesKey,
    # Extracted client files can take 100+ GB; put them on another drive if needed.
    [string]$RawDirectory = (Join-Path $PSScriptRoot 'output\raw'),
    # Only Content/Data, StartUpData, L10N and .dat files (what the database needs, ~2,400 files)
    # instead of all ~900,000 files.
    [switch]$DataOnly,
    [string]$Python = 'python'
)

$ErrorActionPreference = 'Stop'
if (-not $GameDirectory) {
    $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue).SteamPath
    $libraries = @()
    if ($steam) {
        $libraries += $steam
        $folders = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $folders) {
            $libraries += [regex]::Matches((Get-Content -Raw -LiteralPath $folders), '"path"\s+"([^"]+)"') |
                ForEach-Object { $_.Groups[1].Value.Replace('\\', '\') }  # VDF escapes backslashes
        }
    }
    $GameDirectory = $libraries | ForEach-Object { Join-Path $_ 'steamapps\common\AION2' } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ 'Aion2\Content\Paks') } | Select-Object -First 1
    if (-not $GameDirectory) { throw 'AION2 not found in the Steam libraries; pass -GameDirectory <install folder>.' }
    Write-Host "Game directory: $GameDirectory"
}
$paks = Join-Path ([IO.Path]::GetFullPath($GameDirectory)) 'Aion2\Content\Paks'
if (-not (Test-Path -LiteralPath $paks -PathType Container)) { throw "No Aion2\Content\Paks under $GameDirectory" }
$raw = [IO.Path]::GetFullPath($RawDirectory)
$output = Join-Path $PSScriptRoot 'output'  # the decoder and the import read this folder

function Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Check([string]$What) { if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" } }

Step 'Preparing dependencies'
& (Join-Path $PSScriptRoot 'Setup-Dependencies.ps1') -Python $Python
$extractor = Join-Path $PSScriptRoot 'Aion2Extractor\bin\Release\net10.0\Aion2Extractor.exe'

Step "Extracting and decrypting ($(if ($DataOnly) { 'game data only' } else { 'all files' }))"
$arguments = @('--paks', $paks, '--raw', $raw, '--output', $output)
$arguments += if ($AesKey) { @('--key', $AesKey) } else { @('--key-file', [IO.Path]::GetFullPath($KeyPath)) }
if ($DataOnly) { $arguments += '--data-only' }
New-Item -ItemType Directory -Force -Path $raw, $output | Out-Null
& $extractor @arguments
Check 'Extraction'

Step 'Decoding tables and maps'
& $Python -I (Join-Path $PSScriptRoot 'tools\client-data\october\export.py') `
    --decrypted (Join-Path $output 'decrypted') --out (Join-Path $output 'decoded') `
    --usmap (Join-Path $PSScriptRoot 'dependencies\AION2-5.3.2.0.usmap')
$audit = Join-Path $output 'decoded\audit.csv'
if ($LASTEXITCODE -ne 0) {
    if (-not (Test-Path -LiteralPath $audit)) { throw "Decoding failed with exit code $LASTEXITCODE" }
    # A changed layout after a client update: those files are skipped, the rest is imported.
    Write-Warning "Some tables did not decode with the bundled layouts; see $audit"
}
& $Python -I (Join-Path $PSScriptRoot 'finish_manifest.py') $output
Check 'Manifest update'

Write-Host "`nRaw files:       $raw"
Write-Host "Decrypted (.bin): $(Join-Path $output 'decrypted')"
Write-Host "Decoded (JSON):   $(Join-Path $output 'decoded')"
