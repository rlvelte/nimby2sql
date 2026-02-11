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
