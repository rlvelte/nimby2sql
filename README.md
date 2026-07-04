<img src="assets/logo.png" />

# NIMBY2SQL
Converts NIMBY Rails savegame into an SQLite database, so you can explore your complete network and its relations with SQL for analysis and optimization.

## Requirements
Linux/macOS:
- `bash`
- `curl` (for bootstrap)
- `sqlite3`
- `jq`

Windows:
- `powershell/pwsh`
- `sqlite3` in `PATH`


## 1. Export
Use the export functions in **NIMBY Rails** located at `Company and Accounting -> Info`:
1. Export GeoJSON -> `C:\Users\<user>\Saved Games\Weird and Wry\NIMBY Rails\<savegame-name>.json`
2. Export Timetables -> `C:\Users\<user>\Saved Games\Weird and Wry\NIMBY Rails\<savegame-name> Timetable Export.json`

> [!NOTE]
> Linux saves those files in `~/.local/share/Steam/steamapps/compatdata/1134710/pfx/drive_c/...`


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
The script creates a `.db` file with the following schema. You can use it with `sqlite3` or any other client of your choice. 

> [!NOTE]
> If you prefer a GUI, I can recommend [DB Browser for SQLite](https://sqlitebrowser.org/).

### Core
| Table | Description |
|---|---|
| `stations` | Station ID, name, coordinates |
| `lines` | Line ID, name, code, color |
| `line_stops` | Per stop: line, index, station, arrival/departure seconds, leg distance |
| `line_stops_enriched` | **View (!)** joining line_stops + lines + stations for convenience |

### Tags
| Table | Description |
|---|---|
| `tags` | Tag hierarchy |
| `line_tags` | Which tags each line has |
| `train_tags` | Which tags each train model has |
| `schedule_tags` | Which tags each schedule has |
| `shift_tags` | Tags per shift |

### Trains
| Table | Description |
|---|---|
| `trains` | Your rolling stock |

### Schedules
| Table | Description |
|---|---|
| `schedules` | Timetable plans with name, color, timezone offset |
| `schedule_trains` | Which trains are assigned to which schedule |
| `schedule_train_shifts` | Which shift each train serves within a schedule |
| `shifts` | Individual shift runs |
| `runs` | Line traversal runs with stop range and full timing array as JSON |

> [!NOTE]
> Stops with `station_id = 0x0` are waypoints and intentionally filtered.


## 4. Example queries
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

This query shows each line with its tag classification (e.g. S-Bahn, U-Bahn, ICE).
```sql
SELECT l.line_id, l.name AS line_name, l.code, GROUP_CONCAT(t.name, ', ') AS tags
FROM lines l
LEFT JOIN line_tags lt ON lt.line_id = l.line_id
LEFT JOIN tags t ON t.tag_id = lt.tag_id
GROUP BY l.line_id
ORDER BY l.name;
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