#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Create a normalized SQLite DB from NIMBY Rails export files.

Usage:
  ./build_nimby.sh --geo <geo.json> --timetable <timetable.json> [--output <nimby_rails.db>] [--force]

Options:
  --geo        Path to geo JSON export ("Export GeoJSON" in game settings).
  --timetable  Path to timetable JSON export ("Export Timetables" in game settings).
  --output     Output SQLite database path. Default: ./nimby_rails.db
  --force      Overwrite output DB if it already exists.
  -h, --help   Show this help.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
  done
}

trim_count() {
  tr -d '[:space:]'
}

escape_tsv() {
  awk 'BEGIN{FS="\t";OFS="\t"}{for(i=1;i<=NF;i++){gsub(/\\/,"\\\\",$i);gsub(/\t/,"\\t",$i);gsub(/\r/,"\\r",$i);gsub(/\n/,"\\n",$i)}print}'
}

progress() {
  local cur="$1" total="$2" label="$3"
  echo "[$cur/$total] $label"
}

total_steps=7

require_cmd jq sqlite3 awk sort comm wc mktemp join tr

geo=""
timetable=""
output="nimby_rails.db"
force=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --geo)
      [[ $# -ge 2 ]] || die "--geo requires a file path"
      geo="$2"
      shift 2
      ;;
    --timetable)
      [[ $# -ge 2 ]] || die "--timetable requires a file path"
      timetable="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a file path"
      output="$2"
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

# PARAMS
[[ -n "$geo" ]] || die "Missing required argument: --geo"
[[ -n "$timetable" ]] || die "Missing required argument: --timetable"
[[ -f "$geo" ]] || die "Geo file not found: $geo"
[[ -f "$timetable" ]] || die "Timetable file not found: $timetable"

jq -e '.type == "FeatureCollection"' "$geo" >/dev/null || die "Geo file is not a valid GeoJSON FeatureCollection: $geo"
jq -e 'type == "array"' "$timetable" >/dev/null || die "Timetable file is not a valid JSON array: $timetable"

if [[ -e "$output" ]]; then
  if [[ "$force" -eq 1 ]]; then
    rm -f "$output"
  else
    die "Output DB already exists: $output (use --force to overwrite)"
  fi
fi

progress 1 $total_steps "Validating inputs"

mkdir -p "$(dirname "$output")"

tmpdir="$(mktemp -d /tmp/nimby-import.XXXXXX)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

progress 2 $total_steps "Extracting stations, lines, and stops"

jq -r '
  .[]
  | select(.class=="Station")
  | [.id, .name, .lonlat[0], .lonlat[1]]
  | @tsv
' "$timetable" | escape_tsv >"$tmpdir/stations.tsv"

jq -r '
  .[]
  | select(.class=="Line")
  | [.id, .name, .code, .color]
  | @tsv
' "$timetable" | escape_tsv >"$tmpdir/lines.tsv"

# Ignore Waypoint (station_id 0x0)
jq -r '
  .[]
  | select(.class=="Line") as $line
  | $line.stops[]
  | select(.station_id != "0x0")
  | [$line.id, .idx, .station_id, .arrival, .departure, .leg_distance]
  | @tsv
' "$timetable" | escape_tsv >"$tmpdir/line_stops.tsv"

progress 3 $total_steps "Extracting tags, trains, and assignments"

jq -r '
  .[]
  | select(.class=="Tag")
  | [.id, .name, .parent_id]
  | @tsv
' "$timetable" | escape_tsv >"$tmpdir/tags.tsv"

# Line → tags
jq -r '
  .[]
  | select(.class=="Line") as $line
  | $line.tags[]
  | [$line.id, .]
  | @tsv
' "$timetable" | escape_tsv >"$tmpdir/line_tags.tsv"

# Trains (rolling stock)
jq -r '
  .[]
  | select(.class=="Train")
  | [.id, .name, .code]
  | @tsv
' "$timetable" | escape_tsv >"$tmpdir/trains.tsv"

# Train → tags
jq -r '
  .[]
  | select(.class=="Train") as $train
  | $train.tags[]
  | [$train.id, .]
  | @tsv
' "$timetable" | escape_tsv >"$tmpdir/train_tags.tsv"

progress 4 $total_steps "Extracting schedules, shifts, and runs"

jq -r '
  .[]
  | select(.class=="Schedule")
  | [.id, .name, .color, .tz_delta_s]
  | @tsv
' "$timetable" | escape_tsv >"$tmpdir/schedules.tsv"

# Schedule → tags
jq -r '
  .[]
  | select(.class=="Schedule") as $sched
  | $sched.tags[]
  | [$sched.id, .]
  | @tsv
' "$timetable" | escape_tsv >"$tmpdir/schedule_tags.tsv"

# Schedule → train assignments
jq -r '
  .[]
  | select(.class=="Schedule") as $sched
  | $sched.trains | to_entries[]
  | [$sched.id, .key]
  | @tsv
' "$timetable" | escape_tsv >"$tmpdir/schedule_trains.tsv"

# Which shift each train serves within a schedule
jq -r '
  .[]
  | select(.class=="Schedule") as $sched
  | $sched.trains | to_entries[]
  | $sched.id as $sid
  | .key as $train_id
  | .value[]
  | [$sid, $train_id, .]
  | @tsv
' "$timetable" | escape_tsv >"$tmpdir/schedule_train_shifts.tsv"

# Shifts
jq -r '
  .[]
  | select(.class=="Schedule") as $sched
  | $sched.shifts[]
  | [$sched.id, .id, .name]
  | @tsv
' "$timetable" | escape_tsv >"$tmpdir/shifts.tsv"

# Shift → tags
jq -r '
  .[]
  | select(.class=="Schedule") as $sched
  | $sched.shifts[] as $shift
  | $shift.tags[]
  | [$sched.id, $shift.id, .]
  | @tsv
' "$timetable" | escape_tsv >"$tmpdir/shift_tags.tsv"

# Runs
jq -r '
  .[]
  | select(.class=="Schedule") as $sched
  | $sched.shifts[] as $shift
  | $shift.runs[] as $run
  | [$sched.id, $shift.id, $run.idx, $run.line_id, $run.enter_stop_idx, $run.exit_stop_idx, ($run.arrival_departure | @json)]
  | @tsv
' "$timetable" | escape_tsv >"$tmpdir/runs.tsv"

progress 5 $total_steps "Cross-validating timetable and geo"

zero_stop_count="$(
  jq -r '
    [.[] | select(.class=="Line") | .stops[] | select(.station_id=="0x0")]
    | length
  ' "$timetable"
)"

jq -r '
  .[]
  | select(.class=="Station")
  | .id
' "$timetable" | while IFS= read -r id; do printf '%d\n' "$id"; done | sort >"$tmpdir/timetable_station_ids_dec.txt"

jq -r '
  .features[]
  | select(.properties.preview_type=="station")
  | .properties.id
' "$geo" | sort >"$tmpdir/geo_station_ids_dec.txt"

missing_in_geo="$(
  comm -23 "$tmpdir/timetable_station_ids_dec.txt" "$tmpdir/geo_station_ids_dec.txt" | wc -l | trim_count
)"
missing_in_timetable="$(
  comm -13 "$tmpdir/timetable_station_ids_dec.txt" "$tmpdir/geo_station_ids_dec.txt" | wc -l | trim_count
)"

if [[ "$missing_in_geo" != "0" || "$missing_in_timetable" != "0" ]]; then
  die "Station ID mismatch between timetable and geo (missing_in_geo=$missing_in_geo, missing_in_timetable=$missing_in_timetable)"
fi

jq -r '
  .[]
  | select(.class=="Station")
  | [.id, .name]
  | @tsv
' "$timetable" | while IFS=$'\t' read -r id name; do printf '%d\t%s\n' "$id" "$name"; done | sort >"$tmpdir/timetable_station_names_dec.tsv"

jq -r '
  .features[]
  | select(.properties.preview_type=="station")
  | [.properties.id, .properties.name]
  | @tsv
' "$geo" | sort >"$tmpdir/geo_station_names_dec.tsv"

join -t $'\t' -1 1 -2 1 "$tmpdir/timetable_station_names_dec.tsv" "$tmpdir/geo_station_names_dec.tsv" >"$tmpdir/joined_station_names.tsv"
name_mismatches="$(
  awk -F'\t' '$2 != $3 {c++} END {print c+0}' "$tmpdir/joined_station_names.tsv"
)"

if [[ "$name_mismatches" != "0" ]]; then
  die "Station name mismatch between timetable and geo (count=$name_mismatches)"
fi

progress 6 $total_steps "Creating database and importing data"

sqlite3 "$output" <<SQL
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
.import $tmpdir/stations.tsv stations
.import $tmpdir/lines.tsv lines
.import $tmpdir/line_stops.tsv line_stops
.import $tmpdir/tags.tsv tags
.import $tmpdir/line_tags.tsv line_tags
.import $tmpdir/trains.tsv trains
.import $tmpdir/train_tags.tsv train_tags
.import $tmpdir/schedules.tsv schedules
.import $tmpdir/schedule_tags.tsv schedule_tags
.import $tmpdir/schedule_trains.tsv schedule_trains
.import $tmpdir/shifts.tsv shifts
.import $tmpdir/schedule_train_shifts.tsv schedule_train_shifts
.import $tmpdir/shift_tags.tsv shift_tags
.import $tmpdir/runs.tsv runs

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
SQL

progress 7 $total_steps "Verifying integrity and generating summary"

fk_issues="$(sqlite3 "$output" "PRAGMA foreign_keys = ON; PRAGMA foreign_key_check;")"
[[ -z "$fk_issues" ]] || die "Foreign key check failed:\n$fk_issues"

stations_count="$(sqlite3 "$output" "SELECT COUNT(*) FROM stations;")"
lines_count="$(sqlite3 "$output" "SELECT COUNT(*) FROM lines;")"
line_stops_count="$(sqlite3 "$output" "SELECT COUNT(*) FROM line_stops;")"
view_count="$(sqlite3 "$output" "SELECT COUNT(*) FROM line_stops_enriched;")"
tags_count="$(sqlite3 "$output" "SELECT COUNT(*) FROM tags;")"
trains_count="$(sqlite3 "$output" "SELECT COUNT(*) FROM trains;")"
schedules_count="$(sqlite3 "$output" "SELECT COUNT(*) FROM schedules;")"
shifts_count="$(sqlite3 "$output" "SELECT COUNT(*) FROM shifts;")"
runs_count="$(sqlite3 "$output" "SELECT COUNT(*) FROM runs;")"

echo "Created: $output"
echo "Stations: $stations_count"
echo "Lines: $lines_count"
echo "Stops: $line_stops_count (ex. $zero_stop_count waypoints)"
echo "Tags: $tags_count"
echo "Trains: $trains_count"
echo "Schedules: $schedules_count"
echo "Shifts: $shifts_count"
echo "Runs: $runs_count"
echo ""
echo "Have fun!"