#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-Usage {
  @'
Create a normalized SQLite DB from NIMBY Rails export files.

Usage:
  ./build_nimby.ps1 --geo <geo.json> --timetable <timetable.json> [--output <nimby_rails.db>] [--force]

Options:
  --geo        Path to geo JSON export ("Export GeoJSON" in game settings).
  --timetable  Path to timetable JSON export ("Export Timetables" in game settings).
  --output     Output SQLite database path. Default: ./nimby_rails.db
  --force      Overwrite output DB if it already exists.
  -h, --help   Show this help.
'@ | Write-Host
}

function Fail {
  param([string]$Message)
  [Console]::Error.WriteLine("Error: $Message")
  exit 1
}

function Require-Command {
  param([string[]]$Names)
  foreach ($Name in $Names) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
      Fail "Required command not found: $Name"
    }
  }
}

function ConvertFrom-JsonSafe {
  param([string]$Json)
  if ($PSVersionTable.PSVersion.Major -ge 6) {
    return $Json | ConvertFrom-Json -Depth 100
  }
  return $Json | ConvertFrom-Json
}

function To-DecimalId {
  param([Parameter(Mandatory = $true)] [object]$Id)
  $Text = [string]$Id
  if ($Text -match '^0x[0-9a-fA-F]+$') {
    return ([Convert]::ToUInt64($Text.Substring(2), 16)).ToString()
  }

  if ($Text -match '^\d+$') {
    return ([UInt64]$Text).ToString()
  }

  Fail "Unsupported station id format: $Text"
}

function Escape-TsvField {
  param([object]$Value)
  $Text = [string]$Value
  $Text = $Text -replace '\\', '\\\\'
  $Text = $Text -replace "`t", '\t'
  $Text = $Text -replace "`r", '\r'
  $Text = $Text -replace "`n", '\n'
  return $Text
}

function Write-TsvRows {
  param(
    [string]$Path,
    [Parameter(Mandatory = $true)] [System.Collections.IEnumerable]$Rows
  )

  $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  $Writer = [System.IO.StreamWriter]::new($Path, $false, $Utf8NoBom)
  try {
    foreach ($Row in $Rows) {
      $Fields = foreach ($Field in $Row) { Escape-TsvField $Field }
      $Writer.WriteLine(($Fields -join "`t"))
    }
  }
  finally {
    $Writer.Dispose()
  }
}

function Escape-SqliteCliPath {
  param([string]$Path)
  return ($Path -replace "'", "''")
}

function Invoke-Sqlite {
  param(
    [string]$Database,
    [string]$Sql,
    [string]$ErrorContext
  )
  $Result = & sqlite3 $Database $Sql 2>&1
  if ($LASTEXITCODE -ne 0) {
    $Message = ($Result -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($Message)) {
      Fail "sqlite3 failed ($ErrorContext)"
    }
    Fail "sqlite3 failed ($ErrorContext):`n$Message"
  }
  return $Result
}

Require-Command @('sqlite3')

$geo = ''
$timetable = ''
$output = 'nimby_rails.db'
$force = $false

for ($i = 0; $i -lt $args.Count; $i++) {
  $arg = $args[$i]
  switch ($arg) {
    '--geo' {
      if ($i + 1 -ge $args.Count) { Fail '--geo requires a file path' }
      $geo = $args[$i + 1]
      $i++
    }
    '--timetable' {
      if ($i + 1 -ge $args.Count) { Fail '--timetable requires a file path' }
      $timetable = $args[$i + 1]
      $i++
    }
    '--output' {
      if ($i + 1 -ge $args.Count) { Fail '--output requires a file path' }
      $output = $args[$i + 1]
      $i++
    }
    '--force' {
      $force = $true
    }
    '-h' {
      Show-Usage
      exit 0
    }
    '--help' {
      Show-Usage
      exit 0
    }
    default {
      Fail "Unknown argument: $arg"
    }
  }
}

if ([string]::IsNullOrWhiteSpace($geo)) { Fail 'Missing required argument: --geo' }
if ([string]::IsNullOrWhiteSpace($timetable)) { Fail 'Missing required argument: --timetable' }
if (-not (Test-Path -LiteralPath $geo -PathType Leaf)) { Fail "Geo file not found: $geo" }
if (-not (Test-Path -LiteralPath $timetable -PathType Leaf)) { Fail "Timetable file not found: $timetable" }

if (Test-Path -LiteralPath $output) {
  if ($force) {
    Remove-Item -LiteralPath $output -Force
  }
  else {
    Fail "Output DB already exists: $output (use --force to overwrite)"
  }
}

$outputDir = Split-Path -Path $output -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

try {
  $geoJson = Get-Content -LiteralPath $geo -Raw | ConvertFrom-JsonSafe
}
catch {
  Fail "Geo file is not valid JSON: $geo"
}

if ($geoJson.type -ne 'FeatureCollection') {
  Fail "Geo file is not a valid GeoJSON FeatureCollection: $geo"
}

try {
  $timetableJson = Get-Content -LiteralPath $timetable -Raw | ConvertFrom-JsonSafe
}
catch {
  Fail "Timetable file is not valid JSON: $timetable"
}

if (-not ($timetableJson -is [System.Array])) {
  Fail "Timetable file is not a valid JSON array: $timetable"
}

$tmpdir = Join-Path ([System.IO.Path]::GetTempPath()) ("nimby-import.{0}" -f ([guid]::NewGuid().ToString('N').Substring(0, 6)))
New-Item -ItemType Directory -Path $tmpdir | Out-Null

try {
  $stationsTsv = Join-Path $tmpdir 'stations.tsv'
  $linesTsv = Join-Path $tmpdir 'lines.tsv'
  $lineStopsTsv = Join-Path $tmpdir 'line_stops.tsv'
  $tagsTsv = Join-Path $tmpdir 'tags.tsv'
  $lineTagsTsv = Join-Path $tmpdir 'line_tags.tsv'
  $trainsTsv = Join-Path $tmpdir 'trains.tsv'
  $trainTagsTsv = Join-Path $tmpdir 'train_tags.tsv'
  $schedulesTsv = Join-Path $tmpdir 'schedules.tsv'
  $scheduleTagsTsv = Join-Path $tmpdir 'schedule_tags.tsv'
  $scheduleTrainsTsv = Join-Path $tmpdir 'schedule_trains.tsv'
  $scheduleTrainShiftsTsv = Join-Path $tmpdir 'schedule_train_shifts.tsv'
  $shiftsTsv = Join-Path $tmpdir 'shifts.tsv'
  $shiftTagsTsv = Join-Path $tmpdir 'shift_tags.tsv'
  $runsTsv = Join-Path $tmpdir 'runs.tsv'
  $schemaSql = Join-Path $tmpdir 'schema.sql'

  $stations = @($timetableJson | Where-Object { $_.class -eq 'Station' })
  $lines = @($timetableJson | Where-Object { $_.class -eq 'Line' })

  $stationRows = foreach ($station in $stations) {
    if ($null -eq $station.lonlat -or $station.lonlat.Count -lt 2) {
      Fail "Station has invalid lonlat coordinates: $($station.id)"
    }
    ,@(
      [string]$station.id
      [string]$station.name
      [string]$station.lonlat[0]
      [string]$station.lonlat[1]
    )
  }
  Write-TsvRows -Path $stationsTsv -Rows $stationRows

  $lineRows = foreach ($line in $lines) {
    ,@(
      [string]$line.id
      [string]$line.name
      [string]$line.code
      [string]$line.color
    )
  }
  Write-TsvRows -Path $linesTsv -Rows $lineRows

  $lineStopRows = foreach ($line in $lines) {
    if ($null -eq $line.stops) { continue }
    foreach ($stop in $line.stops) {
      if ([string]$stop.station_id -eq '0x0') { continue }
      ,@(
        [string]$line.id
        [string]$stop.idx
        [string]$stop.station_id
        [string]$stop.arrival
        [string]$stop.departure
        [string]$stop.leg_distance
      )
    }
  }
  Write-TsvRows -Path $lineStopsTsv -Rows $lineStopRows

  $tags = @($timetableJson | Where-Object { $_.class -eq 'Tag' })
  $tagRows = foreach ($tag in $tags) {
    ,@(
      [string]$tag.id
      [string]$tag.name
      [string]$tag.parent_id
    )
  }
  Write-TsvRows -Path $tagsTsv -Rows $tagRows

  $lineTagRows = foreach ($line in $lines) {
    if ($null -eq $line.tags) { continue }
    foreach ($tagId in $line.tags) {
      ,@([string]$line.id, [string]$tagId)
    }
  }
  Write-TsvRows -Path $lineTagsTsv -Rows $lineTagRows

  $trains = @($timetableJson | Where-Object { $_.class -eq 'Train' })
  $trainRows = foreach ($train in $trains) {
    ,@(
      [string]$train.id
      [string]$train.name
      [string]$train.code
    )
  }
  Write-TsvRows -Path $trainsTsv -Rows $trainRows

  $trainTagRows = foreach ($train in $trains) {
    if ($null -eq $train.tags) { continue }
    foreach ($tagId in $train.tags) {
      ,@([string]$train.id, [string]$tagId)
    }
  }
  Write-TsvRows -Path $trainTagsTsv -Rows $trainTagRows

  $schedules = @($timetableJson | Where-Object { $_.class -eq 'Schedule' })
  $scheduleRows = foreach ($sched in $schedules) {
    ,@(
      [string]$sched.id
      [string]$sched.name
      [string]$sched.color
      [string]$sched.tz_delta_s
    )
  }
  Write-TsvRows -Path $schedulesTsv -Rows $scheduleRows

  $scheduleTagRows = foreach ($sched in $schedules) {
    if ($null -eq $sched.tags) { continue }
    foreach ($tagId in $sched.tags) {
      ,@([string]$sched.id, [string]$tagId)
    }
  }
  Write-TsvRows -Path $scheduleTagsTsv -Rows $scheduleTagRows

  $scheduleTrainRows = foreach ($sched in $schedules) {
    if ($null -eq $sched.trains) { continue }
    foreach ($trainId in $sched.trains.PSObject.Properties.Name) {
      ,@([string]$sched.id, [string]$trainId)
    }
  }
  Write-TsvRows -Path $scheduleTrainsTsv -Rows $scheduleTrainRows

  $scheduleTrainShiftRows = foreach ($sched in $schedules) {
    if ($null -eq $sched.trains) { continue }
    foreach ($entry in $sched.trains.PSObject.Properties) {
      $trainId = $entry.Name
      $shiftIds = @($entry.Value)
      foreach ($shiftId in $shiftIds) {
        ,@([string]$sched.id, [string]$trainId, [string]$shiftId)
      }
    }
  }
  Write-TsvRows -Path $scheduleTrainShiftsTsv -Rows $scheduleTrainShiftRows

  $shiftRows = foreach ($sched in $schedules) {
    if ($null -eq $sched.shifts) { continue }
    foreach ($shift in $sched.shifts) {
      ,@(
        [string]$sched.id
        [string]$shift.id
        [string]$shift.name
      )
    }
  }
  Write-TsvRows -Path $shiftsTsv -Rows $shiftRows

  $shiftTagRows = foreach ($sched in $schedules) {
    if ($null -eq $sched.shifts) { continue }
    foreach ($shift in $sched.shifts) {
      if ($null -eq $shift.tags) { continue }
      foreach ($tagId in $shift.tags) {
        ,@([string]$sched.id, [string]$shift.id, [string]$tagId)
      }
    }
  }
  Write-TsvRows -Path $shiftTagsTsv -Rows $shiftTagRows

  $runRows = foreach ($sched in $schedules) {
    if ($null -eq $sched.shifts) { continue }
    foreach ($shift in $sched.shifts) {
      if ($null -eq $shift.runs) { continue }
      foreach ($run in $shift.runs) {
        $timingsJson = $null
        if ($null -ne $run.arrival_departure) {
          $timingsJson = ($run.arrival_departure | ConvertTo-Json -Compress)
        }
        ,@(
          [string]$sched.id
          [string]$shift.id
          [string]$run.idx
          [string]$run.line_id
          [string]$run.enter_stop_idx
          [string]$run.exit_stop_idx
          [string]$timingsJson
        )
      }
    }
  }
  Write-TsvRows -Path $runsTsv -Rows $runRows

  $zeroStopCount = @(
    foreach ($line in $lines) {
      if ($null -eq $line.stops) { continue }
      foreach ($stop in $line.stops) {
        if ([string]$stop.station_id -eq '0x0') { 1 }
      }
    }
  ).Count

  $geoStationFeatures = @(
    foreach ($feature in $geoJson.features) {
      if ($feature.properties.preview_type -eq 'station') { $feature }
    }
  )

  $timetableStationIdsDec = [System.Collections.Generic.HashSet[string]]::new()
  foreach ($station in $stations) {
    [void]$timetableStationIdsDec.Add((To-DecimalId $station.id))
  }

  $geoStationIdsDec = [System.Collections.Generic.HashSet[string]]::new()
  foreach ($feature in $geoStationFeatures) {
    [void]$geoStationIdsDec.Add((To-DecimalId $feature.properties.id))
  }

  $missingInGeo = 0
  foreach ($id in $timetableStationIdsDec) {
    if (-not $geoStationIdsDec.Contains($id)) {
      $missingInGeo++
    }
  }

  $missingInTimetable = 0
  foreach ($id in $geoStationIdsDec) {
    if (-not $timetableStationIdsDec.Contains($id)) {
      $missingInTimetable++
    }
  }

  if ($missingInGeo -ne 0 -or $missingInTimetable -ne 0) {
    Fail "Station ID mismatch between timetable and geo (missing_in_geo=$missingInGeo, missing_in_timetable=$missingInTimetable)"
  }

  $timetableStationNamesById = @{}
  foreach ($station in $stations) {
    $id = To-DecimalId $station.id
    $timetableStationNamesById[$id] = [string]$station.name
  }

  $geoStationNamesById = @{}
  foreach ($feature in $geoStationFeatures) {
    $id = To-DecimalId $feature.properties.id
    $geoStationNamesById[$id] = [string]$feature.properties.name
  }

  $nameMismatches = 0
  foreach ($id in $timetableStationNamesById.Keys) {
    if ($timetableStationNamesById[$id] -ne $geoStationNamesById[$id]) {
      $nameMismatches++
    }
  }

  if ($nameMismatches -ne 0) {
    Fail "Station name mismatch between timetable and geo (count=$nameMismatches)"
  }

  $stationsImport = Escape-SqliteCliPath $stationsTsv
  $linesImport = Escape-SqliteCliPath $linesTsv
  $lineStopsImport = Escape-SqliteCliPath $lineStopsTsv
  $tagsImport = Escape-SqliteCliPath $tagsTsv
  $lineTagsImport = Escape-SqliteCliPath $lineTagsTsv
  $trainsImport = Escape-SqliteCliPath $trainsTsv
  $trainTagsImport = Escape-SqliteCliPath $trainTagsTsv
  $schedulesImport = Escape-SqliteCliPath $schedulesTsv
  $scheduleTagsImport = Escape-SqliteCliPath $scheduleTagsTsv
  $scheduleTrainsImport = Escape-SqliteCliPath $scheduleTrainsTsv
  $scheduleTrainShiftsImport = Escape-SqliteCliPath $scheduleTrainShiftsTsv
  $shiftsImport = Escape-SqliteCliPath $shiftsTsv
  $shiftTagsImport = Escape-SqliteCliPath $shiftTagsTsv
  $runsImport = Escape-SqliteCliPath $runsTsv

  $schema = @"
PRAGMA foreign_keys = ON;

DROP VIEW IF EXISTS line_stops_enriched;
DROP TABLE IF EXISTS runs;
DROP TABLE IF EXISTS shift_tags;
DROP TABLE IF EXISTS shifts;
DROP TABLE IF EXISTS schedule_train_shifts;
DROP TABLE IF EXISTS schedule_trains;
DROP TABLE IF EXISTS schedule_tags;
DROP TABLE IF EXISTS schedules;
DROP TABLE IF EXISTS train_tags;
DROP TABLE IF EXISTS line_tags;
DROP TABLE IF EXISTS trains;
DROP TABLE IF EXISTS tags;
DROP TABLE IF EXISTS line_stops;
DROP TABLE IF EXISTS lines;
DROP TABLE IF EXISTS stations;

CREATE TABLE stations (
  station_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  lon REAL NOT NULL,
  lat REAL NOT NULL
);

CREATE TABLE lines (
  line_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  code TEXT NOT NULL,
  color TEXT
);

CREATE TABLE line_stops (
  line_id TEXT NOT NULL,
  stop_index INTEGER NOT NULL CHECK(stop_index >= 0),
  station_id TEXT NOT NULL,
  arrival_s INTEGER NOT NULL CHECK(arrival_s >= 0),
  departure_s INTEGER NOT NULL CHECK(departure_s >= 0),
  leg_distance_m REAL NOT NULL CHECK(leg_distance_m >= 0),
  PRIMARY KEY (line_id, stop_index),
  FOREIGN KEY (line_id) REFERENCES lines(line_id) ON DELETE CASCADE,
  FOREIGN KEY (station_id) REFERENCES stations(station_id) ON DELETE RESTRICT,
  CHECK(departure_s >= arrival_s)
);

CREATE INDEX idx_line_stops_station_id ON line_stops(station_id);
CREATE INDEX idx_line_stops_line_id ON line_stops(line_id);

CREATE TABLE tags (
  tag_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  parent_tag_id TEXT
);

CREATE TABLE line_tags (
  line_id TEXT NOT NULL,
  tag_id TEXT NOT NULL,
  PRIMARY KEY (line_id, tag_id),
  FOREIGN KEY (line_id) REFERENCES lines(line_id) ON DELETE CASCADE,
  FOREIGN KEY (tag_id) REFERENCES tags(tag_id) ON DELETE RESTRICT
);

CREATE TABLE trains (
  train_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  code TEXT NOT NULL
);

CREATE TABLE train_tags (
  train_id TEXT NOT NULL,
  tag_id TEXT NOT NULL,
  PRIMARY KEY (train_id, tag_id),
  FOREIGN KEY (train_id) REFERENCES trains(train_id) ON DELETE CASCADE,
  FOREIGN KEY (tag_id) REFERENCES tags(tag_id) ON DELETE RESTRICT
);

CREATE TABLE schedules (
  schedule_id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  color TEXT,
  tz_delta_s INTEGER NOT NULL
);

CREATE TABLE schedule_tags (
  schedule_id TEXT NOT NULL,
  tag_id TEXT NOT NULL,
  PRIMARY KEY (schedule_id, tag_id),
  FOREIGN KEY (schedule_id) REFERENCES schedules(schedule_id) ON DELETE CASCADE,
  FOREIGN KEY (tag_id) REFERENCES tags(tag_id) ON DELETE RESTRICT
);

CREATE TABLE schedule_trains (
  schedule_id TEXT NOT NULL,
  train_id TEXT NOT NULL,
  PRIMARY KEY (schedule_id, train_id),
  FOREIGN KEY (schedule_id) REFERENCES schedules(schedule_id) ON DELETE CASCADE,
  FOREIGN KEY (train_id) REFERENCES trains(train_id) ON DELETE CASCADE
);

CREATE TABLE schedule_train_shifts (
  schedule_id TEXT NOT NULL,
  train_id TEXT NOT NULL,
  shift_id TEXT NOT NULL,
  PRIMARY KEY (schedule_id, train_id, shift_id),
  FOREIGN KEY (schedule_id, train_id) REFERENCES schedule_trains(schedule_id, train_id) ON DELETE CASCADE,
  FOREIGN KEY (schedule_id, shift_id) REFERENCES shifts(schedule_id, shift_id) ON DELETE CASCADE
);

CREATE TABLE shifts (
  schedule_id TEXT NOT NULL,
  shift_id TEXT NOT NULL,
  name TEXT,
  PRIMARY KEY (schedule_id, shift_id),
  FOREIGN KEY (schedule_id) REFERENCES schedules(schedule_id) ON DELETE CASCADE
);

CREATE TABLE shift_tags (
  schedule_id TEXT NOT NULL,
  shift_id TEXT NOT NULL,
  tag_id TEXT NOT NULL,
  PRIMARY KEY (schedule_id, shift_id, tag_id),
  FOREIGN KEY (schedule_id, shift_id) REFERENCES shifts(schedule_id, shift_id) ON DELETE CASCADE,
  FOREIGN KEY (tag_id) REFERENCES tags(tag_id) ON DELETE RESTRICT
);

CREATE TABLE runs (
  schedule_id TEXT NOT NULL,
  shift_id TEXT NOT NULL,
  run_idx INTEGER NOT NULL,
  line_id TEXT NOT NULL,
  enter_stop_idx INTEGER NOT NULL,
  exit_stop_idx INTEGER NOT NULL,
  timings_json TEXT NOT NULL,
  PRIMARY KEY (schedule_id, shift_id, run_idx),
  FOREIGN KEY (schedule_id, shift_id) REFERENCES shifts(schedule_id, shift_id) ON DELETE CASCADE,
  FOREIGN KEY (line_id) REFERENCES lines(line_id) ON DELETE RESTRICT
);

.mode tabs
.import '$stationsImport' stations
.import '$linesImport' lines
.import '$lineStopsImport' line_stops
.import '$tagsImport' tags
.import '$lineTagsImport' line_tags
.import '$trainsImport' trains
.import '$trainTagsImport' train_tags
.import '$schedulesImport' schedules
.import '$scheduleTagsImport' schedule_tags
.import '$scheduleTrainsImport' schedule_trains
.import '$shiftsImport' shifts
.import '$scheduleTrainShiftsImport' schedule_train_shifts
.import '$shiftTagsImport' shift_tags
.import '$runsImport' runs

CREATE VIEW line_stops_enriched AS
SELECT
  ls.line_id,
  l.name AS line_name,
  l.code AS line_code,
  l.color AS line_color,
  ls.stop_index,
  ls.station_id,
  s.name AS station_name,
  s.lon,
  s.lat,
  ls.arrival_s,
  ls.departure_s,
  ls.leg_distance_m
FROM line_stops ls
JOIN lines l ON l.line_id = ls.line_id
JOIN stations s ON s.station_id = ls.station_id;
"@

  [System.IO.File]::WriteAllText($schemaSql, $schema)
  $schemaImportResult = & sqlite3 $output ".read $schemaSql" 2>&1
  if ($LASTEXITCODE -ne 0) {
    $importMessage = ($schemaImportResult -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($importMessage)) {
      Fail 'sqlite3 failed while creating schema/importing data'
    }
    Fail "sqlite3 failed while creating schema/importing data:`n$importMessage"
  }

  $fkIssuesRaw = Invoke-Sqlite -Database $output -Sql 'PRAGMA foreign_keys = ON; PRAGMA foreign_key_check;' -ErrorContext 'foreign key check query'
  $fkIssues = ($fkIssuesRaw -join "`n").Trim()
  if (-not [string]::IsNullOrWhiteSpace($fkIssues)) {
    Fail "Foreign key check failed:`n$fkIssues"
  }

  $stationsCount = (Invoke-Sqlite -Database $output -Sql 'SELECT COUNT(*) FROM stations;' -ErrorContext 'count stations' | Out-String).Trim()
  $linesCount = (Invoke-Sqlite -Database $output -Sql 'SELECT COUNT(*) FROM lines;' -ErrorContext 'count lines' | Out-String).Trim()
  $lineStopsCount = (Invoke-Sqlite -Database $output -Sql 'SELECT COUNT(*) FROM line_stops;' -ErrorContext 'count line_stops' | Out-String).Trim()
  $null = Invoke-Sqlite -Database $output -Sql 'SELECT COUNT(*) FROM line_stops_enriched;' -ErrorContext 'count line_stops_enriched'
  $tagsCount = (Invoke-Sqlite -Database $output -Sql 'SELECT COUNT(*) FROM tags;' -ErrorContext 'count tags' | Out-String).Trim()
  $trainsCount = (Invoke-Sqlite -Database $output -Sql 'SELECT COUNT(*) FROM trains;' -ErrorContext 'count trains' | Out-String).Trim()
  $schedulesCount = (Invoke-Sqlite -Database $output -Sql 'SELECT COUNT(*) FROM schedules;' -ErrorContext 'count schedules' | Out-String).Trim()
  $shiftsCount = (Invoke-Sqlite -Database $output -Sql 'SELECT COUNT(*) FROM shifts;' -ErrorContext 'count shifts' | Out-String).Trim()
  $runsCount = (Invoke-Sqlite -Database $output -Sql 'SELECT COUNT(*) FROM runs;' -ErrorContext 'count runs' | Out-String).Trim()

  Write-Host "Created: $output"
  Write-Host "Stations: $stationsCount"
  Write-Host "Lines: $linesCount"
  Write-Host "Stops: $lineStopsCount (ex. $zeroStopCount waypoints)"
  Write-Host "Tags: $tagsCount"
  Write-Host "Trains: $trainsCount"
  Write-Host "Schedules: $schedulesCount"
  Write-Host "Shifts: $shiftsCount"
  Write-Host "Runs: $runsCount"
  Write-Host ''
  Write-Host 'Have fun!'
}
finally {
  if (Test-Path -LiteralPath $tmpdir) {
    Remove-Item -LiteralPath $tmpdir -Recurse -Force
  }
}
