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

require_cmd jq sqlite3 awk sort comm wc mktemp join

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

mkdir -p "$(dirname "$output")"

tmpdir="$(mktemp -d /tmp/nimby-import.XXXXXX)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

# EXTRACT
jq -r '
  .[]
  | select(.class=="Station")
  | [.id, .name, .lonlat[0], .lonlat[1]]
  | @tsv
' "$timetable" >"$tmpdir/stations.tsv"

jq -r '
  .[]
  | select(.class=="Line")
  | [.id, .name, .code, .color]
  | @tsv
' "$timetable" >"$tmpdir/lines.tsv"

# Ignore Waypoint (station_id 0x0)
jq -r '
  .[]
  | select(.class=="Line") as $line
  | $line.stops[]
  | select(.station_id != "0x0")
  | [$line.id, .idx, .station_id, .arrival, .departure, .leg_distance]
  | @tsv
' "$timetable" >"$tmpdir/line_stops.tsv"

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
' "$timetable" | awk '{printf "%.0f\n", strtonum($1)}' | sort >"$tmpdir/timetable_station_ids_dec.txt"

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
' "$timetable" | awk -F'\t' '{printf "%.0f\t%s\n", strtonum($1), $2}' | sort >"$tmpdir/timetable_station_names_dec.tsv"

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

sqlite3 "$output" <<SQL
PRAGMA foreign_keys = ON;

DROP VIEW IF EXISTS line_stops_enriched;
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

.mode tabs
.import $tmpdir/stations.tsv stations
.import $tmpdir/lines.tsv lines
.import $tmpdir/line_stops.tsv line_stops

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

fk_issues="$(sqlite3 "$output" "PRAGMA foreign_keys = ON; PRAGMA foreign_key_check;")"
[[ -z "$fk_issues" ]] || die "Foreign key check failed:\n$fk_issues"

stations_count="$(sqlite3 "$output" "SELECT COUNT(*) FROM stations;")"
lines_count="$(sqlite3 "$output" "SELECT COUNT(*) FROM lines;")"
line_stops_count="$(sqlite3 "$output" "SELECT COUNT(*) FROM line_stops;")"
view_count="$(sqlite3 "$output" "SELECT COUNT(*) FROM line_stops_enriched;")"

echo "Created: $output"
echo "Stations: $stations_count"
echo "Lines: $lines_count"
echo "Stops: $line_stops_count (ex. $zero_stop_count waypoints)"
echo ""
echo "Have fun!"