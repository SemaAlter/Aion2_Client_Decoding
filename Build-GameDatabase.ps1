<#
.SYNOPSIS
One command from your AION2 installation to a filled game database.

.DESCRIPTION
Runs Extract-GameData.ps1 (paks -> raw files -> decrypted .bin -> decoded JSON) and then
Import-GameDataToDatabase.ps1 (decoded JSON -> database in config\database.ini).

.EXAMPLE
# Everything (all ~900,000 client files, 100+ GB), then the database
.\Build-GameDatabase.ps1 -GameDirectory 'C:\Games\AION2'

.EXAMPLE
# Only the game data the database needs (~2,400 files)
.\Build-GameDatabase.ps1 -DataOnly
#>
[CmdletBinding()]
param(
    # AION2 install folder; found in the Steam libraries when omitted.
    [string]$GameDirectory,
    [string]$AesKey,
    [string]$RawDirectory,
    [switch]$DataOnly,
    [string]$MySqlPath = 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe',
    [string]$Python = 'python'
)

$ErrorActionPreference = 'Stop'
$extract = @{ DataOnly = $DataOnly; Python = $Python }
if ($GameDirectory) { $extract.GameDirectory = $GameDirectory }
if ($AesKey) { $extract.AesKey = $AesKey }
if ($RawDirectory) { $extract.RawDirectory = $RawDirectory }
& (Join-Path $PSScriptRoot 'Extract-GameData.ps1') @extract
& (Join-Path $PSScriptRoot 'Import-GameDataToDatabase.ps1') -MySqlPath $MySqlPath -Python $Python
