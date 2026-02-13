# NIMBY2SQL
Converts NIMBY Rails savegame into an SQLite database, so you can explore stations/lines and their relations with SQL for analysis and optimization.

## Requirements
Linux/macOS:
- `bash`
- `curl` (for bootstrap)
- `jq`
- `sqlite3`
- `python3` (optional, for GraphML export)
- `awk`, `sort`, `comm`, `wc`, `mktemp`, `join`

Windows:
- `pwsh` (PowerShell 7+)
- `sqlite3` in `PATH`
- `python` (optional, for GraphML export)


## 1. Export
Use the export functions in **NIMBY Rails** located at `Company and Accounting -> Info`:
1. Export GeoJSON -> `C:\users\<user>\Saved Games\Weird and Wry\NIMBY Rails\<savegame-name>.json`
2. Export Timetables -> `C:\users\<user>\Saved Games\Weird and Wry\NIMBY Rails\<savegame-name> Timetable Export.json`

> [!NOTE]
> Linux saves those files in `/.local/share/Steam/steamapps/compatdata/1134710/pfx/drive_c/...`


## 2. Run the script
You can run the script directly from the command line or clone the repository and run it from the project root.
Remember to change the placeholder (`path-to-geo.json` and `path-to-timetable.json`) with the actual paths to the exported files.

Linux
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rlvelte/nimby2sql/master/build_nimby.sh) --geo path-to-geo.json --timetable path-to-timetable.json
```

Windows
```powershell
$script = Join-Path ([System.IO.Path]::GetTempPath()) "build_nimby.ps1"; Invoke-WebRequest "https://raw.githubusercontent.com/rlvelte/nimby2sql/master/build_nimby.ps1" -OutFile $script; pwsh -NoProfile -ExecutionPolicy Bypass -File $script --geo "C:\path\to\geo.json" --timetable "C:\path\to\timetable.json"
```


## 3. Result
The script creates a `.db` file in the same directory as the exported files. You can use it with `sqlite3` or any other client of your choice. 
If you prefer a GUI, I can recommend [DB Browser for SQLite](https://sqlitebrowser.org/).

> [!NOTE]
> Stops with `station_id = 0x0` are waypoints and intentionally filtered.


## 4. Build GraphML (optional)
Use the Python script to convert the generated `.db` into a station-only GraphML file (`nimby_rails.graphml`) for graph based network analysis and visualization tools. 
If you also need a GUI for that, I can recommend [Gephi](https://gephi.org/).

Linux
```bash
python3 build_graph.py -i path-to-nimby_rails.db
```

## 5. Example queries
Here are some example queries that you can run against the database to gain some insights you can use for optimization of your network or to visualize with additional software.

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
