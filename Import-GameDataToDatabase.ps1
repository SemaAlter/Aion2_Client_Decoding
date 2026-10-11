<#
.SYNOPSIS
Creates the game database from the decoded client data (run Extract-GameData.ps1 first).

.DESCRIPTION
1. tools\client-data\october\catalogs.py   typed catalogs (items, NPCs, monsters, spawns, quests,
                                            maps, loot, events, environment objects)
2. tools\Import-Aion2GameData.ps1          skills
3. tools\Initialize-GameDatabase.ps1       database, schema (database\schema.sql), catalogs,
                                            client table manifest
4. tools\Import-StructuredClientData.ps1   every decoded table/map as client_data_records
5. tools\client-data\october\client_tables.py   one ct_* table per client table

The connection and database name come from config\database.ini.
#>
[CmdletBinding()]
param(
    [string]$MySqlPath = 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe',
    [string]$Python = 'python'
)

$ErrorActionPreference = 'Stop'
$tools = Join-Path $PSScriptRoot 'tools'
$october = Join-Path $tools 'client-data\october'
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'config\database.ini') -PathType Leaf)) {
    throw 'config\database.ini is missing; copy config\database.example.ini and fill in your connection.'
}
if (-not (Test-Path -LiteralPath $MySqlPath -PathType Leaf)) { throw "MySQL client not found: $MySqlPath (pass -MySqlPath)" }
$decoded = Join-Path $PSScriptRoot 'output\decoded\AION2\Content\Data\Table'
if (-not (Test-Path -LiteralPath $decoded -PathType Container)) {
    throw "Decoded tables not found under $decoded; run Extract-GameData.ps1 first."
}

function Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Check([string]$What) { if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" } }

Step 'Building typed catalogs'
& $Python -I (Join-Path $october 'catalogs.py')
Check 'catalogs.py'

Step 'Building skills'
& (Join-Path $tools 'Import-Aion2GameData.ps1')

Step 'Creating the database'
& (Join-Path $tools 'Initialize-GameDatabase.ps1') -MySqlPath $MySqlPath

Step 'Importing every client table and map'
& (Join-Path $tools 'Import-StructuredClientData.ps1') -MySqlPath $MySqlPath

Step 'Creating one ct_* table per client table'
$env:MYSQL_PATH = $MySqlPath
& $Python -I (Join-Path $october 'client_tables.py')
Check 'client_tables.py'

Write-Host "`nGame data imported."
