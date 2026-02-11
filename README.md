# NIMBY Rails -> SQLite 
Simple savegame to database converter for analysis or optimization. 
Builds a query-friendly SQLite schema from GeoJSON and timetable exports.

## Quick use (Linux)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rlvelte/nimby2sql/master/build_nimby.sh) --geo path-to-geo.json --timetable path-to-timetable.json
```

## Quick use (Windows)
```powershell
$script = Join-Path ([System.IO.Path]::GetTempPath()) "build_nimby.ps1"; Invoke-WebRequest "https://raw.githubusercontent.com/rlvelte/nimby2sql/master/build_nimby.ps1" -OutFile $script; pwsh -NoProfile -ExecutionPolicy Bypass -File $script --geo "C:\path\to\geo.json" --timetable "C:\path\to\timetable.json"
```

## Requirements
Linux/macOS:
- `bash`
- `curl` (for bootstrap)
- `jq`
- `sqlite3`
- `awk`, `sort`, `comm`, `wc`, `mktemp`, `join`

Windows:
- `pwsh` (PowerShell 7+)
- `sqlite3` in `PATH`


## 1. Export
Use the export functions in **NIMBY Rails** located at `Company and Accounting -> Info`:
1. Export GeoJSON -> `C:\users\<user>\Saved Games\Weird and Wry\NIMBY Rails\<savegame-name>.json`
2. Export Timetables -> `C:\users\<user>\Saved Games\Weird and Wry\NIMBY Rails\<savegame-name> Timetable Export.json`

> [!NOTE]
> Steam saves those files in `/.local/share/Steam/steamapps/compatdata/1134710/pfx/drive_c/...` on Linux.


## 2. Run
```bash
./build_nimby.sh --geo geo.json --timetable timetable.json
```
```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\build_nimby.ps1 `
  --geo .\geo.json `
  --timetable .\timetable.json
```


## 3. Result
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


## 4. Example queries
This query shows the 20 stations that are served by the highest number of distinct lines.
```sql
SELECT station_id, station_name, COUNT(DISTINCT line_id) AS lines_serving
FROM line_stops_enriched
GROUP BY station_id, station_name
ORDER BY lines_serving DESC, station_name
LIMIT 20;
```

This query analyzes dwell times per line (departure minus arrival) and returns min/avg/max stop dwell durations.
```sql
SELECT line_id, line_name, COUNT(*) AS n_stops, MIN(departure_s - arrival_s) AS min_dwell_s, ROUND(AVG(departure_s - arrival_s), 1) AS avg_dwell_s, MAX(departure_s - arrival_s) AS max_dwell_s
FROM line_stops_enriched
WHERE arrival_s IS NOT NULL AND departure_s IS NOT NULL
GROUP BY line_id, line_name
ORDER BY avg_dwell_s DESC;
```

This query finds, for each major hub station (served by at least 5 lines), the geographically nearest other hub using a Haversine distance in meters: `hubs` builds averaged station coordinates and hub strength, `pairs` computes all hub-to-hub distances, `ranked` selects the nearest neighbor per hub with `ROW_NUMBER()`, and the final `SELECT` returns one nearest-hub match per hub ordered by the largest nearest-neighbor gap.
```sql
WITH
    hubs AS (
        SELECT
            station_id,
            station_name,
            AVG(lat) AS lat,
            AVG(lon) AS lon,
            COUNT(DISTINCT line_id) AS lines_serving
        FROM line_stops_enriched
        WHERE lat IS NOT NULL AND lon IS NOT NULL
        GROUP BY station_id, station_name
        HAVING COUNT(DISTINCT line_id) >= 5
    ),
    pairs AS (
        SELECT
            a.station_id AS a_id,
            a.station_name AS a_name,
            a.lines_serving AS a_lines,
            b.station_id AS b_id,
            b.station_name AS b_name,
            b.lines_serving AS b_lines,
            6371000.0 * 2.0 * asin(
                    sqrt(
                            pow(sin(radians((b.lat - a.lat) / 2.0)), 2) +
                            cos(radians(a.lat)) * cos(radians(b.lat)) *
                            pow(sin(radians((b.lon - a.lon) / 2.0)), 2)
                    )
                              ) AS d_m
        FROM hubs a
                 JOIN hubs b
                      ON b.station_id <> a.station_id
    ),
    ranked AS (
        SELECT
            *,
            ROW_NUMBER() OVER (PARTITION BY a_id ORDER BY d_m) AS rn
        FROM pairs
    )
SELECT
    a_id AS hub_station_id,
    a_name AS hub_station_name,
    a_lines AS hub_lines,
    b_id  AS nearest_hub_id,
    b_name AS nearest_hub_name,
    b_lines AS nearest_hub_lines,
    ROUND(d_m, 1) AS nearest_hub_distance_m,
    ROUND(d_m / 1000.0, 2) AS nearest_hub_distance_km
FROM ranked
WHERE rn = 1
ORDER BY nearest_hub_distance_m DESC;
```
