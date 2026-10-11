[CmdletBinding()]
param(
    [string]$TableDirectory = (Join-Path $PSScriptRoot '..\output\decoded\AION2\Content\Data\Table'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\output\catalogs')
)

$ErrorActionPreference = 'Stop'
$tableRoot = [IO.Path]::GetFullPath($TableDirectory)
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$skillPath = Join-Path $tableRoot 'Skill.json'
$filterPath = Join-Path $tableRoot 'SkillEffectFilter.json'
if (-not [IO.File]::Exists($skillPath)) {
    throw "Structured Skill.json does not exist: $skillPath"
}
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null

function Escape-Csv([string]$Value) {
    if ($null -eq $Value) { return '' }
    if ($Value.IndexOfAny([char[]]@(',', '"', "`r", "`n")) -ge 0) {
        return '"' + $Value.Replace('"', '""') + '"'
    }
    return $Value
}

function Open-Json([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try { return [Text.Json.JsonDocument]::Parse($stream) }
    finally { $stream.Dispose() }
}

$filters = @{}
$filterDocument = $null
if ([IO.File]::Exists($filterPath) -and ([IO.FileInfo]$filterPath).Length -gt 2) {
    $filterDocument = Open-Json $filterPath
    foreach ($row in $filterDocument.RootElement.GetProperty('Properties').GetProperty('Data').EnumerateArray()) {
        $id = $row.GetProperty('ID').GetProperty('Value').GetUInt32()
        $filters[$id] = $row.Clone()
    }
}

$skillDocument = Open-Json $skillPath
$skillsPath = Join-Path $outputRoot 'skills.csv'
$writer = [IO.StreamWriter]::new($skillsPath, $false, [Text.UTF8Encoding]::new($false))
$count = 0
try {
    $writer.WriteLine('id,name,max_level,cooldown_ms,cast_time_ms,range,target,hit_shape,max_targets,angle_degrees')
    foreach ($row in $skillDocument.RootElement.GetProperty('Properties').GetProperty('Data').EnumerateArray()) {
        $id = $row.GetProperty('ID').GetProperty('Value').GetUInt32()
        if ($id -eq 0) { continue }
        $name = $row.GetProperty('SkillString_Key').GetString()
        $maxLevel = [Math]::Max(1, $row.GetProperty('SkillLvMax').GetInt32())
        # NeedCoolTime is already milliseconds (e.g. 3600000 = one hour) in the October 2026 client.
        $cooldownMs = [Math]::Max(0, [Math]::Round($row.GetProperty('NeedCoolTime').GetDouble()))
        $castTimeMs = [Math]::Max(0, $row.GetProperty('CastingTime').GetInt32())
        $rangeMetres = [Math]::Max(0.0, $row.GetProperty('NeedSkillUseRange').GetDouble() / 100.0)
        $disposition = $row.GetProperty('SkillDispositionType').GetString()
        $target = if ($disposition -like '*Negative') { 'hostile' } elseif ($disposition -like '*Positive') { 'friendly' } else { 'self' }
        $shape = 'single'
        $maxTargets = 1
        $angle = 0.0

        $filterId = $row.GetProperty('TargetFilterId').GetProperty('Value').GetUInt32()
        if ($filters.ContainsKey($filterId)) {
            $filter = $filters[$filterId]
            $rangeType = $filter.GetProperty('EffectRangeType').GetString()
            if ($rangeType -match 'Sector|Cone|Fan') { $shape = 'frontal_cone' }
            elseif ($rangeType -match 'Circle|Sphere|Radius') { $shape = 'radius' }
            $declaredMax = $filter.GetProperty('TargetCountMax').GetInt32()
            if ($declaredMax -gt 0) { $maxTargets = $declaredMax }
            $values = @($filter.GetProperty('EffectRangeValues').EnumerateArray() | ForEach-Object { $_.GetDouble() })
            if ($shape -eq 'frontal_cone' -and $values.Count -gt 1) { $angle = $values[-1] }
        }

        $fields = @($id, (Escape-Csv $name), $maxLevel, $cooldownMs, $castTimeMs,
            $rangeMetres.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture),
            $target, $shape, $maxTargets,
            $angle.ToString('0.###', [Globalization.CultureInfo]::InvariantCulture))
        $writer.WriteLine(($fields -join ','))
        $count++
    }
}
finally {
    $writer.Dispose()
    $skillDocument.Dispose()
    if ($filterDocument) { $filterDocument.Dispose() }
}

$manifestPath = Join-Path $outputRoot 'source-manifest.csv'
$sourceRows = @(
    [pscustomobject]@{
        dataset = 'skills'
        source = 'AION2/Content/Data/Table/Skill.dat'
        structured_json_sha256 = (Get-FileHash -LiteralPath $skillPath -Algorithm SHA256).Hash
        imported_rows = $count
    }
)
if ([IO.File]::Exists($filterPath) -and ([IO.FileInfo]$filterPath).Length -gt 2) {
    $sourceRows += [pscustomobject]@{
        dataset = 'skill-target-filters'
        source = 'AION2/Content/Data/Table/SkillEffectFilter.dat'
        structured_json_sha256 = (Get-FileHash -LiteralPath $filterPath -Algorithm SHA256).Hash
        imported_rows = $filters.Count
    }
}
$sourceRows | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding utf8
Write-Host "Imported $count skill records to $skillsPath"
Write-Host "Provenance: $manifestPath"
