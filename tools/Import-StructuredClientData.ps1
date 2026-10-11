[CmdletBinding()]
param(
    [string]$MySqlPath = 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe',
    # Connection and database name come from config/database.ini.
    [string]$DatabaseConfig = (Join-Path $PSScriptRoot '..\config\database.ini'),
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..\output\decryption-manifest.csv'),
    [string]$StructuredDirectory = (Join-Path $PSScriptRoot '..\output\decoded'),
    [string]$ArtifactDirectory = (Join-Path $PSScriptRoot '..\output'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\output\database-import'),
    [switch]$KeepStagingFile
)

$ErrorActionPreference = 'Stop'
$settings = @{}
foreach ($line in Get-Content -LiteralPath $DatabaseConfig) {
    if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $settings[$Matches[1]] = $Matches[2] }
}
$HostName = $settings['host']; $Port = [int]$settings['port']; $User = $settings['user']
$Password = $settings['password']; $Database = $settings['database']
Write-Host "Target database: $Database at ${HostName}:$Port (from $DatabaseConfig)"
$manifest = [IO.Path]::GetFullPath($ManifestPath)
$structuredRoot = [IO.Path]::GetFullPath($StructuredDirectory)
$artifactRoot = [IO.Path]::GetFullPath($ArtifactDirectory)
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$recordPath = Join-Path $outputRoot 'client-data-records.tsv'
$tableCatalogPath = Join-Path $outputRoot 'structured-tables.csv'

foreach ($required in @($MySqlPath, $manifest, $structuredRoot, $artifactRoot)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required input does not exist: $required" }
}
if ($Database -notmatch '^[A-Za-z0-9_]+$') { throw "Invalid database name in ${DatabaseConfig}: $Database" }
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null

function Resolve-StructuredPath($Entry) {
    $relativeJson = [IO.Path]::ChangeExtension($Entry.virtual_path, '.json').Replace('/', [IO.Path]::DirectorySeparatorChar)
    $currentPath = [IO.Path]::GetFullPath((Join-Path $structuredRoot $relativeJson))
    if ($currentPath.StartsWith($structuredRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.File]::Exists($currentPath) -and ([IO.FileInfo]$currentPath).Length -gt 2) {
        return $currentPath
    }

    if ($Entry.family -eq 'gameplay-table') {
        return $null
    }
    if ($Entry.structured_status -ne 'json' -or [string]::IsNullOrWhiteSpace($Entry.structured_json_path)) {
        return $null
    }

    $manifestPath = [IO.Path]::GetFullPath((Join-Path $artifactRoot $Entry.structured_json_path.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    if (-not $manifestPath.StartsWith($artifactRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Structured path escaped the artifact directory: $manifestPath"
    }
    if ([IO.File]::Exists($manifestPath) -and ([IO.FileInfo]$manifestPath).Length -gt 2) {
        return $manifestPath
    }
    return $null
}

function Get-ScalarText([Text.Json.JsonElement]$Element) {
    switch ($Element.ValueKind) {
        ([Text.Json.JsonValueKind]::String) { return $Element.GetString() }
        ([Text.Json.JsonValueKind]::Number) { return $Element.GetRawText() }
        ([Text.Json.JsonValueKind]::True) { return 'true' }
        ([Text.Json.JsonValueKind]::False) { return 'false' }
        default { return $null }
    }
}

function Get-RecordKey([Text.Json.JsonElement]$Row, [int]$Index) {
    if ($Row.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        foreach ($propertyName in @('ID', 'Id', 'id', 'Name', 'name', 'MapID')) {
            $candidate = [Text.Json.JsonElement]::new()
            if (-not $Row.TryGetProperty($propertyName, [ref]$candidate)) { continue }
            if ($candidate.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                $value = [Text.Json.JsonElement]::new()
                if ($candidate.TryGetProperty('Value', [ref]$value)) {
                    $text = Get-ScalarText $value
                    if (-not [string]::IsNullOrWhiteSpace($text)) { return $text }
                }
            }
            $text = Get-ScalarText $candidate
            if (-not [string]::IsNullOrWhiteSpace($text)) { return $text }
        }
    }
    return $Index.ToString('D10', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-UniqueRecordKey(
    [Text.Json.JsonElement]$Row,
    [int]$Index,
    [Collections.Generic.HashSet[string]]$Seen
) {
    $baseKey = Get-RecordKey $Row $Index
    $key = $baseKey
    $suffix = $Index
    while (-not $Seen.Add($key)) {
        $key = "$baseKey#$suffix"
        $suffix++
    }
    return $key
}

function Open-ValidatedJson([string]$Path) {
    $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
    $validUtf8 = $true
    $reader = [IO.StreamReader]::new($Path, $strictUtf8, $true, 65536)
    try {
        $buffer = [char[]]::new(65536)
        while ($reader.ReadBlock($buffer, 0, $buffer.Length) -gt 0) { }
    }
    catch [Text.DecoderFallbackException] {
        $validUtf8 = $false
    }
    finally { $reader.Dispose() }

    if ($validUtf8) {
        $stream = [IO.File]::OpenRead($Path)
        try { $document = [Text.Json.JsonDocument]::Parse($stream) }
        finally { $stream.Dispose() }
        return [pscustomobject]@{ Document = $document; SanitizedUtf8 = $false }
    }

    $tolerantUtf8 = [Text.UTF8Encoding]::new($false, $false)
    $text = [IO.File]::ReadAllText($Path, $tolerantUtf8)
    $document = [Text.Json.JsonDocument]::Parse($text)
    Write-Warning "Replaced invalid UTF-8 sequences while importing $Path"
    return [pscustomobject]@{ Document = $document; SanitizedUtf8 = $true }
}

$utf8 = [Text.UTF8Encoding]::new($false)
$writer = [IO.StreamWriter]::new($recordPath, $false, $utf8, 1MB)
$selectedTables = [Collections.Generic.List[object]]::new()
$totalRecords = [long]0
$maxPayloadBytes = 0
$maxKeyLength = 0

function Write-Record([string]$VirtualPath, [string]$RecordKey, [string]$RawJson) {
    if ($RecordKey.Length -gt 255) {
        throw "Record key exceeds the database limit ($($RecordKey.Length)): $VirtualPath"
    }
    $keyBytes = $utf8.GetBytes($RecordKey)
    $payloadBytes = $utf8.GetBytes($RawJson)
    $writer.Write([Convert]::ToBase64String($utf8.GetBytes($VirtualPath)))
    $writer.Write("`t")
    $writer.Write([Convert]::ToBase64String($keyBytes))
    $writer.Write("`t")
    $writer.WriteLine([Convert]::ToBase64String($payloadBytes))
    $script:totalRecords++
    $script:maxPayloadBytes = [Math]::Max($script:maxPayloadBytes, $payloadBytes.Length)
    $script:maxKeyLength = [Math]::Max($script:maxKeyLength, $RecordKey.Length)
}

try {
    $entries = Import-Csv -LiteralPath $manifest | Sort-Object virtual_path
    $processed = 0
    $currentVirtualPath = ''
    foreach ($entry in $entries) {
        if ($entry.virtual_path -like '*/key_manifest.dat') { continue }
        $currentVirtualPath = $entry.virtual_path
        $jsonPath = Resolve-StructuredPath $entry
        if ($null -eq $jsonPath) { continue }

        $openedJson = Open-ValidatedJson $jsonPath
        $document = $openedJson.Document

        $rowCount = 0
        try {
            $root = $document.RootElement
            $properties = [Text.Json.JsonElement]::new()
            $data = [Text.Json.JsonElement]::new()
            $entriesObject = [Text.Json.JsonElement]::new()
            $worlds = [Text.Json.JsonElement]::new()

            if ($root.ValueKind -eq [Text.Json.JsonValueKind]::Object -and
                $root.TryGetProperty('Properties', [ref]$properties) -and
                $properties.ValueKind -eq [Text.Json.JsonValueKind]::Object -and
                $properties.TryGetProperty('Data', [ref]$data) -and
                $data.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                $index = 0
                foreach ($row in $data.EnumerateArray()) {
                    Write-Record $entry.virtual_path (Get-UniqueRecordKey $row $index $seen) $row.GetRawText()
                    $rowCount++
                    $index++
                }
            }
            elseif ($root.ValueKind -eq [Text.Json.JsonValueKind]::Object -and
                $root.TryGetProperty('Entries', [ref]$entriesObject) -and
                $entriesObject.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                foreach ($property in $entriesObject.EnumerateObject()) {
                    Write-Record $entry.virtual_path $property.Name $property.Value.GetRawText()
                    $rowCount++
                }
            }
            elseif ($root.ValueKind -eq [Text.Json.JsonValueKind]::Object -and
                $root.TryGetProperty('Worlds', [ref]$worlds) -and
                $worlds.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                $index = 0
                foreach ($row in $worlds.EnumerateArray()) {
                    Write-Record $entry.virtual_path (Get-UniqueRecordKey $row $index $seen) $row.GetRawText()
                    $rowCount++
                    $index++
                }
            }
            elseif ($root.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                $index = 0
                foreach ($row in $root.EnumerateArray()) {
                    Write-Record $entry.virtual_path (Get-UniqueRecordKey $row $index $seen) $row.GetRawText()
                    $rowCount++
                    $index++
                }
            }
            else {
                Write-Record $entry.virtual_path '__root__' $root.GetRawText()
                $rowCount = 1
            }
        }
        finally { $document.Dispose() }

        $selectedTables.Add([pscustomobject]@{
            virtual_path = $entry.virtual_path
            family = $entry.family
            json_path = $jsonPath
            json_sha256 = (Get-FileHash -LiteralPath $jsonPath -Algorithm SHA256).Hash
            row_count = $rowCount
            sanitized_utf8 = $openedJson.SanitizedUtf8
        })
        $processed++
        if (($processed % 25) -eq 0) {
            Write-Host "Prepared $processed structured files and $totalRecords records..."
        }
    }
}
catch {
    throw "Failed to prepare '$currentVirtualPath': $($_.Exception.Message)"
}
finally { $writer.Dispose() }

$selectedTables | Export-Csv -LiteralPath $tableCatalogPath -NoTypeInformation -Encoding utf8

function SqlPath([string]$Path) {
    return ([IO.Path]::GetFullPath($Path).Replace('\', '/').Replace("'", "''"))
}

function Invoke-MySql([string]$Sql) {
    $arguments = @('--protocol=tcp', '-h', $HostName, '-P', $Port, '-u', $User, "--password=$Password",
        '--default-character-set=utf8mb4', '--local-infile=1', '--batch', $Database)
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

$recordSqlPath = SqlPath $recordPath
$tableCatalogSqlPath = SqlPath $tableCatalogPath
$sql = @"
SET FOREIGN_KEY_CHECKS=0;
ALTER TABLE client_data_records
    MODIFY record_key VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL;
TRUNCATE TABLE client_data_records;
DROP TEMPORARY TABLE IF EXISTS client_data_record_stage;
CREATE TEMPORARY TABLE client_data_record_stage (
    virtual_path VARCHAR(1024) NULL,
    virtual_path_base64 TEXT NOT NULL,
    record_key_base64 TEXT NOT NULL,
    payload_base64 LONGTEXT NOT NULL
) ENGINE=InnoDB;
DROP TEMPORARY TABLE IF EXISTS client_data_table_stage;
CREATE TEMPORARY TABLE client_data_table_stage (
    virtual_path VARCHAR(1024) NOT NULL,
    family VARCHAR(64) NOT NULL,
    json_path TEXT NOT NULL,
    json_sha256 CHAR(64) NOT NULL,
    row_count BIGINT UNSIGNED NOT NULL,
    sanitized_utf8 VARCHAR(8) NOT NULL
) ENGINE=InnoDB;
LOAD DATA LOCAL INFILE '$recordSqlPath'
INTO TABLE client_data_record_stage
CHARACTER SET ascii
FIELDS TERMINATED BY '\t'
LINES TERMINATED BY '\r\n'
(virtual_path_base64, record_key_base64, payload_base64);
-- Decode into a column with the database's default collation (MariaDB and MySQL 8 differ) before joining.
UPDATE client_data_record_stage SET virtual_path = CONVERT(FROM_BASE64(virtual_path_base64) USING utf8mb4);
LOAD DATA LOCAL INFILE '$tableCatalogSqlPath'
INTO TABLE client_data_table_stage
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\r\n'
IGNORE 1 LINES
(virtual_path, family, json_path, json_sha256, row_count, sanitized_utf8);
INSERT INTO client_data_records(table_id, record_key, payload)
SELECT source.id,
       CONVERT(FROM_BASE64(stage.record_key_base64) USING utf8mb4),
       CONVERT(FROM_BASE64(stage.payload_base64) USING utf8mb4)
FROM client_data_record_stage AS stage
JOIN client_data_tables AS source
  ON source.virtual_path = stage.virtual_path;
UPDATE client_data_tables AS target
JOIN client_data_table_stage AS imported ON imported.virtual_path = target.virtual_path
SET target.schema_version = 13,
    target.row_count = imported.row_count,
    target.imported_at = CURRENT_TIMESTAMP;
SET FOREIGN_KEY_CHECKS=1;
SELECT COUNT(*) AS structured_tables FROM client_data_tables WHERE row_count IS NOT NULL;
SELECT COUNT(*) AS structured_records FROM client_data_records;
"@

Invoke-MySql $sql

if (-not $KeepStagingFile) {
    Remove-Item -LiteralPath $recordPath -Force
}

Write-Host "Imported $($selectedTables.Count) structured files and $totalRecords records."
Write-Host "Maximum record key length: $maxKeyLength"
Write-Host "Maximum JSON payload bytes: $maxPayloadBytes"
