[CmdletBinding()]
param(
    [string]$MySqlPath = 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe',
    # Connection and database name come from config/database.ini.
    [string]$DatabaseConfig = (Join-Path $PSScriptRoot '..\config\database.ini'),
    # Generated CSVs are only staging for this load; the database is the source of truth afterwards.
    [switch]$KeepGeneratedFiles
)

$ErrorActionPreference = 'Stop'
$settings = @{}
foreach ($line in Get-Content -LiteralPath $DatabaseConfig) {
    if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $settings[$Matches[1]] = $Matches[2] }
}
$HostName = $settings['host']; $Port = [int]$settings['port']; $User = $settings['user']
$Password = $settings['password']; $Database = $settings['database']
Write-Host "Target database: $Database at ${HostName}:$Port (from $DatabaseConfig)"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$schemaPath = Join-Path $repositoryRoot 'database\schema.sql'
$dataDirectory = Join-Path $repositoryRoot 'output\catalogs'
$clientManifest = Join-Path $repositoryRoot 'output\decryption-manifest.csv'

foreach ($required in @($MySqlPath, $schemaPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required file does not exist: $required" }
}
if ($Database -notmatch '^[A-Za-z0-9_]+$') { throw "Invalid database name in ${DatabaseConfig}: $Database" }

function Invoke-MySql([string]$Sql, [switch]$UseDatabase) {
    $arguments = @('--protocol=tcp', '-h', $HostName, '-P', $Port, '-u', $User, "--password=$Password",
        '--default-character-set=utf8mb4', '--local-infile=1', '--batch')
    if ($UseDatabase) { $arguments += $Database }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = [Diagnostics.ProcessStartInfo]::new()
    $process.StartInfo.FileName = $MySqlPath
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardInput = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    foreach ($argument in $arguments) { $process.StartInfo.ArgumentList.Add([string]$argument) }
    if (-not $process.Start()) { throw 'Could not start mysql.exe.' }
    $process.StandardInput.WriteLine($Sql)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "mysql.exe failed: $stderr" }
    if ($stdout) { Write-Host $stdout.TrimEnd() }
}

Invoke-MySql "CREATE DATABASE IF NOT EXISTS ``$Database`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
$schemaSql = [IO.File]::ReadAllText($schemaPath)
Invoke-MySql $schemaSql -UseDatabase

function SqlPath([string]$Path) {
    return ([IO.Path]::GetFullPath($Path).Replace('\', '/').Replace("'", "''"))
}

$generatedSkills = Join-Path $dataDirectory 'skills.csv'
$imports = [Collections.Generic.List[string]]::new()
$imports.Add('SET FOREIGN_KEY_CHECKS=0;')
# Truncate only when staging CSVs exist to refill the tables (they are deleted after each load).
$hasGenerated = Test-Path -LiteralPath $dataDirectory -PathType Container
if ($hasGenerated) { $imports.Add('TRUNCATE TABLE spawns; TRUNCATE TABLE monsters; TRUNCATE TABLE npcs; TRUNCATE TABLE items; TRUNCATE TABLE skills;') }
else { Write-Host 'No generated catalogs found; keeping existing rows.' }
if (Test-Path -LiteralPath $generatedSkills -PathType Leaf) {
    $imports.Add("LOAD DATA LOCAL INFILE '$(SqlPath $generatedSkills)' REPLACE INTO TABLE skills CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '`"' LINES TERMINATED BY '\n' IGNORE 1 LINES (id,name,max_level,cooldown_ms,cast_time_ms,skill_range,target,hit_shape,max_targets,@angle_degrees) SET angle_degrees=TRIM(TRAILING '\r' FROM @angle_degrees);")
}
# Catalogs generated from the client by tools/client-data/october/catalogs.py and tools/Import-Aion2GameData.ps1.
if ($hasGenerated) { $imports.Add('TRUNCATE TABLE quests; TRUNCATE TABLE quest_objectives; TRUNCATE TABLE quest_rewards; TRUNCATE TABLE maps; TRUNCATE TABLE npc_skills; TRUNCATE TABLE loot_table_entries; TRUNCATE TABLE loot_tables; TRUNCATE TABLE loot_owners; TRUNCATE TABLE loot_table_links; TRUNCATE TABLE quest_class_rewards; TRUNCATE TABLE skill_effects; TRUNCATE TABLE world_event_actions; TRUNCATE TABLE world_events; TRUNCATE TABLE env_object_spawns; TRUNCATE TABLE env_objects;') }
$catalogColumns = [ordered]@{
    items = '(id,name,category,max_stack,required_level)'
    npcs = '(id,name,kind,level,faction,interaction)'
    monsters = '(id,npc_id,monster_rank,max_health,attack_value,defense_value,aggro_radius,move_speed,attack_range,server_skill_id,attack_interval_ms)'
    spawns = '(id,template_id,kind,map_id,x,y,z,heading,respawn_seconds)'
    quests = '(id,name,minimum_level,faction,repeatable)'
    maps = "(id,name,@walk_mesh_path) SET walk_mesh_path=NULLIF(@walk_mesh_path,'')"
    npc_skills = "(npc_id,skill_id,priority,@cooldown) SET cooldown_override_ms=NULLIF(@cooldown,'')"
    loot_tables = '(id,name)'
    loot_table_entries = '(loot_table_id,item_id,minimum_count,maximum_count,chance)'
    quest_objectives = "(quest_id,objective_index,objective_type,@target_id,required_count,payload) SET target_id=NULLIF(@target_id,'')"
    quest_rewards = "(quest_id,reward_index,@item_id,item_count,experience,currency) SET item_id=NULLIF(@item_id,'')"
    quest_class_rewards = '(quest_id,character_class,reward_index,item_id,item_count)'
    loot_table_links = '(parent_loot_table_id,child_loot_table_id,chance,item_count,level_min,level_max,link_source)'
    loot_owners = "(owner_table,owner_key,@owner_id,owner_kind,loot_table_id,link_field,link_source) SET owner_id=NULLIF(@owner_id,'')"
    skill_effects = "(skill_id,effect_index,effect_type,value_expression,@filter,source_payload) SET target_filter_id=NULLIF(@filter,'')"
    world_events = '(id,name,map_id,trigger_type,trigger_value,enabled,source_payload)'
    world_event_actions = '(event_id,action_index,action_type,delay_ms,payload)'
    env_objects = '(id,name,usage_type,usage_value,interact_range,interact_time_ms,source_payload)'
    env_object_spawns = '(id,env_object_id,map_id,x,y,z,heading)'
}
foreach ($table in $catalogColumns.Keys) {
    $generated = Join-Path $dataDirectory "$table.csv"
    if (Test-Path -LiteralPath $generated -PathType Leaf) {
        $imports.Add("LOAD DATA LOCAL INFILE '$(SqlPath $generated)' REPLACE INTO TABLE $table CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '`"' ESCAPED BY '' LINES TERMINATED BY '\n' IGNORE 1 LINES $($catalogColumns[$table]);")
    }
}
$imports.Add('SET FOREIGN_KEY_CHECKS=1;')
if (Test-Path -LiteralPath $clientManifest -PathType Leaf) {
    $imports.Add('DELETE FROM client_data_records; DELETE FROM client_data_tables;')
    $imports.Add("LOAD DATA LOCAL INFILE '$(SqlPath $clientManifest)' REPLACE INTO TABLE client_data_tables CHARACTER SET utf8mb4 FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '`"' LINES TERMINATED BY '\r\n' IGNORE 1 LINES (virtual_path,family,@algorithm,@source_container,@decrypted_path,@decrypted_bytes,sha256,@structured_status,@structured_json_path) SET schema_version=IF(@structured_status='json',13,NULL),row_count=NULL;")
}
Invoke-MySql ($imports -join "`n") -UseDatabase
Invoke-MySql 'SELECT COUNT(*) AS skills FROM skills; SELECT COUNT(*) AS items FROM items; SELECT COUNT(*) AS npcs FROM npcs; SELECT COUNT(*) AS monsters FROM monsters; SELECT COUNT(*) AS spawns FROM spawns; SELECT COUNT(*) AS quests FROM quests; SELECT COUNT(*) AS quest_objectives FROM quest_objectives; SELECT COUNT(*) AS quest_rewards FROM quest_rewards; SELECT COUNT(*) AS maps FROM maps; SELECT COUNT(*) AS npc_skills FROM npc_skills; SELECT COUNT(*) AS loot_tables FROM loot_tables; SELECT COUNT(*) AS loot_table_entries FROM loot_table_entries; SELECT COUNT(*) AS loot_owners FROM loot_owners; SELECT COUNT(*) AS loot_table_links FROM loot_table_links; SELECT COUNT(*) AS quest_class_rewards FROM quest_class_rewards; SELECT COUNT(*) AS skill_effects FROM skill_effects; SELECT COUNT(*) AS world_events FROM world_events; SELECT COUNT(*) AS world_event_actions FROM world_event_actions; SELECT COUNT(*) AS env_objects FROM env_objects; SELECT COUNT(*) AS env_object_spawns FROM env_object_spawns; SELECT COUNT(*) AS client_data_tables FROM client_data_tables;' -UseDatabase
$generatedDirectory = $dataDirectory
if (-not $KeepGeneratedFiles -and (Test-Path -LiteralPath $generatedDirectory)) {
    Remove-Item -LiteralPath $generatedDirectory -Recurse -Force
    Write-Host "Removed staging CSVs in $generatedDirectory (rerun catalogs.py to regenerate)."
}
Write-Host "Initialized database $Database at ${HostName}:$Port."
