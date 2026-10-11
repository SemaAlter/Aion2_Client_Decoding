<#
.SYNOPSIS
Fetches and prepares everything the extraction needs; safe to rerun.

.DESCRIPTION
- Checks the tools: git, .NET 10 SDK, Python 3, and the MySQL client.
- Clones CUE4Parse into external/CUE4Parse at the pinned commit (with submodules) and applies
  the AION2 patches from dependencies/ (current readers + October 2026 schema). The Oodle and
  zlib-ng DLLs are downloaded by CUE4Parse on the first extraction.
- Builds Aion2Extractor.
#>
[CmdletBinding()]
param(
    [string]$CUE4ParseRepository = 'https://github.com/FabianFG/CUE4Parse.git',
    # The revision the AION2 patches were made against.
    [string]$CUE4ParseCommit = 'ec6595e',
    [string]$MySqlPath = 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe',
    [string]$Python = 'python'
)

$ErrorActionPreference = 'Stop'
function Check([string]$What) { if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" } }

foreach ($command in @('git', 'dotnet', $Python)) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required tool not found on PATH: $command" }
}
$dotnetMajor = [int](((& dotnet --version) -split '\.')[0])
if ($dotnetMajor -lt 10) { throw ".NET 10 SDK or newer is required (found $(& dotnet --version))" }
& $Python -c "import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)"
Check 'Python 3.9+ check'
if (-not (Test-Path -LiteralPath $MySqlPath -PathType Leaf)) {
    Write-Warning "MySQL client not found at $MySqlPath; pass -MySqlPath to the import."
}

$external = Join-Path $PSScriptRoot 'external'
$cue4Parse = Join-Path $external 'CUE4Parse'
if (-not (Test-Path -LiteralPath (Join-Path $cue4Parse '.git'))) {
    New-Item -ItemType Directory -Force -Path $external | Out-Null
    & git clone $CUE4ParseRepository $cue4Parse
    Check 'CUE4Parse clone'
}
$head = (& git -C $cue4Parse rev-parse HEAD).Trim()
if (-not $head.StartsWith($CUE4ParseCommit)) {
    & git -C $cue4Parse diff --quiet
    if ($LASTEXITCODE -ne 0) { throw "external/CUE4Parse has local changes on another revision; delete it and rerun." }
    & git -C $cue4Parse fetch --quiet origin
    & git -C $cue4Parse checkout --quiet $CUE4ParseCommit
    Check 'CUE4Parse checkout'
}
& git -C $cue4Parse submodule update --init --recursive --quiet
Check 'CUE4Parse submodules'

# The patches overlap, so they are applied together onto the pinned commit; a marker with their
# hashes skips the reapply (and the CUE4Parse rebuild) when nothing changed.
$patches = @('CUE4Parse-AION2-current.patch', 'CUE4Parse-AION2-october-schema.patch') |
    ForEach-Object { Join-Path $PSScriptRoot "dependencies\$_" }
$patchState = $CUE4ParseCommit + ' ' + (($patches | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash }) -join ' ')
$marker = Join-Path $cue4Parse '.aion2-patches'
if (-not (Test-Path -LiteralPath $marker) -or (Get-Content -Raw -LiteralPath $marker).Trim() -ne $patchState) {
    & git -C $cue4Parse checkout --quiet -- .
    Check 'CUE4Parse reset'
    foreach ($patch in $patches) {
        & git -C $cue4Parse apply $patch
        Check "Applying $(Split-Path -Leaf $patch)"
        Write-Host "Applied $(Split-Path -Leaf $patch)"
    }
    Set-Content -LiteralPath $marker -Value $patchState
}

& dotnet build (Join-Path $PSScriptRoot 'Aion2Extractor\Aion2Extractor.csproj') -c Release --nologo -v quiet -clp:ErrorsOnly -p:NuGetAudit=false
Check 'Aion2Extractor build'
Write-Host 'Dependencies ready.'
