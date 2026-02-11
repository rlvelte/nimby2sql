# NIMBY Rails -> SQLite 
Simple savegame to database converter for analysis or optimization. 
Builds a query-friendly SQLite schema from GeoJSON and timetable exports.

## Quick use 
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rlvelte/nimby2sql/master/build_nimby.sh) \
  --geo <path-to-geo> \
  --timetable <path-to-timetable>
```

## Requirements
- `bash`/`zsh`
- `curl` (for bootstrap)
- `jq`
- `sqlite3`
- `awk`, `sort`, `comm`, `wc`, `mktemp`, `join`


## 1. Export
Use the export functions in **NIMBY Rails**:
1. `Export GeoJSON` -> creates `geo.json`
2. `Export Timetables` -> creates `timetable.json`


## 2. Build SQLite
```bash
./build_nimby.sh --geo geo.json --timetable timetable.json
```


## CLI Options
- `--geo <path>`: GeoJSON export from the game
- `--timetable <path>`: timetable export from the game
- `--output <path>`: target DB (default: `./nimby_rails.db`)
- `--force`: overwrite existing DB
- `-h`, `--help`: show help


## Result
The script creates:
- Table `stations`
  - `station_id`, `name`, `lon`, `lat`
- Table `lines`
  - `line_id`, `name`, `code`, `color`
- Table `line_stops`
  - `line_id`, `stop_index`, `station_id`, `arrival_s`, `departure_s`, `leg_distance_m`
- View `line_stops_enriched`
  - Join of `line_stops`, `lines`, `stations`

Integrity:
- Foreign keys are enabled.
- `PRAGMA foreign_key_check` is checked.

> [!NOTE]
> Stops with `station_id = 0x0` are waypoints and intentionally filtered.
