#!/usr/bin/env python3
"""Transform NIMBY Rails SQLite export into a vtraffic-compatible Cypher dataset.

Input DB (expected):
  - stations(station_id, name, lon, lat)
  - lines(line_id, name, code, color)
  - line_stops(line_id, stop_index, station_id, arrival_s, departure_s, leg_distance_m)

Output:
  - Cypher file for Neo4j import
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sqlite3
import sys
import unicodedata
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Tuple


@dataclass(frozen=True)
class StationIn:
    station_id: str
    name: str
    lon: float
    lat: float


@dataclass(frozen=True)
class LineIn:
    line_id: str
    name: str
    code: str
    color: str | None


@dataclass(frozen=True)
class StopIn:
    line_id: str
    stop_index: int
    station_id: str
    arrival_s: int
    departure_s: int
    leg_distance_m: float


def fail(message: str) -> None:
    print(f"Error: {message}", file=sys.stderr)
    sys.exit(1)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Transform nimby_rails.db into a vtraffic-compatible Cypher dataset."
    )
    parser.add_argument(
        "--input-db", 
        required=True, 
        help="Path to input nimby_rails.db"
    )
    parser.add_argument(
        "--operator",
        required=True, 
        help="Route operator value for generated output",
    )
    parser.add_argument(
        "--output-cypher",
        default="vtraffic_topology.cypher",
        help="Path to output Cypher file (default: vtraffic_topology.cypher)",
    )
    parser.add_argument("--force", action="store_true", help="Overwrite outputs if they exist")
    return parser.parse_args()


def ensure_overwrite(path: Path, force: bool, label: str) -> None:
    if path.exists():
        if not force:
            fail(f"{label} exists: {path} (use --force to overwrite)")
        path.unlink()


def validate_input_schema(conn: sqlite3.Connection) -> None:
    required = {"stations", "lines", "line_stops"}
    rows = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    ).fetchall()
    existing = {r[0] for r in rows}
    missing = sorted(required - existing)
    if missing:
        fail(f"Input DB missing required tables: {', '.join(missing)}")


def load_input(conn: sqlite3.Connection) -> Tuple[Dict[str, StationIn], Dict[str, LineIn], Dict[str, List[StopIn]]]:
    station_rows = conn.execute(
        "SELECT station_id, name, lon, lat FROM stations"
    ).fetchall()
    line_rows = conn.execute(
        "SELECT line_id, name, code, color FROM lines"
    ).fetchall()
    stop_rows = conn.execute(
        """
        SELECT line_id, stop_index, station_id, arrival_s, departure_s, leg_distance_m
        FROM line_stops
        ORDER BY line_id, stop_index
        """
    ).fetchall()

    stations: Dict[str, StationIn] = {
        r[0]: StationIn(r[0], r[1], float(r[2]), float(r[3])) for r in station_rows
    }
    lines: Dict[str, LineIn] = {
        r[0]: LineIn(r[0], r[1], r[2], r[3]) for r in line_rows
    }
    stops_by_line: Dict[str, List[StopIn]] = {}
    for r in stop_rows:
        stop = StopIn(
            line_id=r[0],
            stop_index=int(r[1]),
            station_id=r[2],
            arrival_s=int(r[3]),
            departure_s=int(r[4]),
            leg_distance_m=float(r[5]),
        )
        stops_by_line.setdefault(stop.line_id, []).append(stop)

    return stations, lines, stops_by_line


def normalize_name_to_snake_case(text: str, fallback: str) -> str:
    value = (text or "").strip().lower()
    value = (
        value.replace("ä", "ae")
        .replace("ö", "oe")
        .replace("ü", "ue")
        .replace("ß", "ss")
    )
    value = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii")
    value = re.sub(r"[^a-z0-9]+", "_", value).strip("_")
    return value or fallback


def build_unique_name_ids(
    source_to_name: Iterable[Tuple[str, str]],
    fallback_prefix: str,
) -> Dict[str, str]:
    entries: List[Tuple[str, str]] = []
    for source_id, name in source_to_name:
        source_fallback = normalize_name_to_snake_case(source_id, fallback_prefix)
        base = normalize_name_to_snake_case(name, f"{fallback_prefix}_{source_fallback}")
        entries.append((source_id, base))

    # Deterministic duplicate handling: same base gets suffix _2, _3, ...
    entries.sort(key=lambda x: (x[1], x[0]))

    mapping: Dict[str, str] = {}
    counts: Dict[str, int] = {}
    for source_id, base in entries:
        count = counts.get(base, 0) + 1
        counts[base] = count
        mapping[source_id] = base if count == 1 else f"{base}_{count}"

    return mapping


def normalize_route_name(code: str, name: str) -> str:
    candidate = (code or "").strip()
    if not candidate:
        candidate = (name or "").strip()
    # vtraffic Route.Name has StringLength(10)
    return candidate[:10] if candidate else "ROUTE"


def normalize_hex_color(raw: str | None) -> str:
    if not raw:
        return "#808080"

    s = raw.strip()
    if re.fullmatch(r"#[0-9a-fA-F]{6}", s):
        return s.upper()
    if s.startswith("0x") or s.startswith("0X"):
        h = s[2:]
        if len(h) == 8:
            h = h[2:]  # drop alpha channel
        if len(h) >= 6:
            return f"#{h[-6:].upper()}"
    if re.fullmatch(r"[0-9a-fA-F]{6}", s):
        return f"#{s.upper()}"
    return "#808080"


def infer_transport_type(code: str, name: str) -> str:
    text = f"{code or ''} {name or ''}".upper().strip()
    compact = text.replace(" ", "")

    if re.match(r"^U\d+", compact):
        return "Metro"
    if re.match(r"^S\d+", compact):
        return "UrbanRail"
    if "TRAM" in text:
        return "Tram"
    if text.startswith("BUS") or compact.startswith("B"):
        return "Bus"
    return "Train"


def infer_route_type(station_sequence: List[str]) -> str:
    if len(station_sequence) >= 2 and station_sequence[0] == station_sequence[-1]:
        return "Circular"
    if len(station_sequence) != len(set(station_sequence)):
        return "OutAndBack"
    return "Linear"


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> int:
    r = 6371000.0
    p1 = math.radians(lat1)
    p2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2.0) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlambda / 2.0) ** 2
    c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))
    return max(1, int(round(r * c)))


def cypher_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace("'", "\\'")
    return f"'{escaped}'"


def cypher_bool(v: bool) -> str:
    return "true" if v else "false"


def transform(
    stations_in: Dict[str, StationIn],
    lines_in: Dict[str, LineIn],
    stops_by_line: Dict[str, List[StopIn]],
    operator: str,
) -> Tuple[List[dict], List[dict], List[dict], List[dict]]:
    routes: List[dict] = []
    stations: List[dict] = []
    servings: List[dict] = []

    # CONNECTS_TO aggregation:
    # key = (from, to), value = min physical distance observed.
    connections: Dict[Tuple[str, str], int] = {}

    # Collect station transport types from all serving routes.
    station_types: Dict[str, set[str]] = {}

    station_id_map = build_unique_name_ids(
        ((s.station_id, s.name) for s in stations_in.values()),
        fallback_prefix="station",
    )
    route_id_map = build_unique_name_ids(
        ((l.line_id, l.name) for l in lines_in.values()),
        fallback_prefix="route",
    )

    for s in stations_in.values():
        sid = station_id_map[s.station_id]
        stations.append(
            {
                "identifier": sid,
                "name": s.name,
                "latitude": s.lat,
                "longitude": s.lon,
                "types": [],
            }
        )
        station_types[sid] = set()

    for line in sorted(lines_in.values(), key=lambda x: x.line_id):
        line_stops = stops_by_line.get(line.line_id, [])
        rid = route_id_map[line.line_id]
        transport_type = infer_transport_type(line.code, line.name)

        route_station_seq = [station_id_map[s.station_id] for s in line_stops]
        route_type = infer_route_type(route_station_seq) if route_station_seq else "Linear"

        routes.append(
            {
                "identifier": rid,
                "name": normalize_route_name(line.code, line.name),
                "hex_color": normalize_hex_color(line.color),
                "transport_type": transport_type,
                "route_type": route_type,
                "description": line.name,
                "operator": operator,
                "source_line_id": line.line_id,
            }
        )

        # SERVINGS: line-based relationship only.
        for i, st in enumerate(line_stops):
            sid = station_id_map[st.station_id]
            servings.append(
                {
                    "route_identifier": rid,
                    "station_identifier": sid,
                    "sequence": i + 1,
                    "is_terminus": i == 0 or i == len(line_stops) - 1,
                }
            )
            station_types[sid].add(transport_type)

        # CONNECTS_TO: physical adjacency proxy, deduped globally.
        # Derived from neighboring station pairs, but persisted as infrastructure edges.
        for i in range(len(line_stops) - 1):
            a = line_stops[i]
            b = line_stops[i + 1]
            if a.station_id == b.station_id:
                continue
            if a.station_id not in stations_in or b.station_id not in stations_in:
                continue

            sa = stations_in[a.station_id]
            sb = stations_in[b.station_id]
            dist = haversine_m(sa.lat, sa.lon, sb.lat, sb.lon)

            fa = station_id_map[a.station_id]
            fb = station_id_map[b.station_id]

            for key in ((fa, fb), (fb, fa)):
                if key in connections:
                    connections[key] = min(connections[key], dist)
                else:
                    connections[key] = dist

    station_by_id = {s["identifier"]: s for s in stations}
    for sid, types in station_types.items():
        station_by_id[sid]["types"] = sorted(types) if types else ["Train"]

    connection_rows = [
        {
            "from_identifier": from_id,
            "to_identifier": to_id,
            "distance": distance,
        }
        for (from_id, to_id), distance in sorted(connections.items())
    ]

    return routes, stations, servings, connection_rows


def write_output_db(
    output_db: Path,
    routes: List[dict],
    stations: List[dict],
    servings: List[dict],
    connections: List[dict],
) -> None:
    conn = sqlite3.connect(output_db)
    try:
        conn.execute("PRAGMA foreign_keys = ON")
        conn.executescript(
            """
            DROP VIEW IF EXISTS route_servings_enriched;
            DROP TABLE IF EXISTS station_connections;
            DROP TABLE IF EXISTS route_servings;
            DROP TABLE IF EXISTS stations;
            DROP TABLE IF EXISTS routes;

            CREATE TABLE routes (
              identifier TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              hex_color TEXT NOT NULL,
              transport_type TEXT NOT NULL,
              route_type TEXT NOT NULL,
              description TEXT,
              operator TEXT,
              source_line_id TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE stations (
              identifier TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              latitude REAL NOT NULL,
              longitude REAL NOT NULL,
              types_json TEXT NOT NULL,
              updated_at TEXT NOT NULL
            );

            CREATE TABLE route_servings (
              route_identifier TEXT NOT NULL,
              station_identifier TEXT NOT NULL,
              sequence INTEGER NOT NULL CHECK(sequence >= 1),
              is_terminus INTEGER NOT NULL CHECK(is_terminus IN (0, 1)),
              PRIMARY KEY (route_identifier, sequence),
              FOREIGN KEY (route_identifier) REFERENCES routes(identifier) ON DELETE CASCADE,
              FOREIGN KEY (station_identifier) REFERENCES stations(identifier) ON DELETE CASCADE
            );

            CREATE TABLE station_connections (
              from_identifier TEXT NOT NULL,
              to_identifier TEXT NOT NULL,
              distance INTEGER NOT NULL CHECK(distance > 0),
              PRIMARY KEY (from_identifier, to_identifier),
              FOREIGN KEY (from_identifier) REFERENCES stations(identifier) ON DELETE CASCADE,
              FOREIGN KEY (to_identifier) REFERENCES stations(identifier) ON DELETE CASCADE
            );

            CREATE INDEX idx_route_servings_station ON route_servings(station_identifier);
            CREATE INDEX idx_station_connections_to ON station_connections(to_identifier);

            CREATE VIEW route_servings_enriched AS
            SELECT
              rs.route_identifier,
              r.name AS route_name,
              r.transport_type,
              r.route_type,
              rs.sequence,
              rs.is_terminus,
              rs.station_identifier,
              s.name AS station_name,
              s.latitude,
              s.longitude
            FROM route_servings rs
            JOIN routes r ON r.identifier = rs.route_identifier
            JOIN stations s ON s.identifier = rs.station_identifier;
            """
        )

        now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
        conn.executemany(
            """
            INSERT INTO routes (
              identifier, name, hex_color, transport_type, route_type,
              description, operator, source_line_id, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                (
                    r["identifier"],
                    r["name"],
                    r["hex_color"],
                    r["transport_type"],
                    r["route_type"],
                    r["description"],
                    r["operator"],
                    r["source_line_id"],
                    now,
                )
                for r in routes
            ],
        )

        conn.executemany(
            """
            INSERT INTO stations (
              identifier, name, latitude, longitude, types_json, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            [
                (
                    s["identifier"],
                    s["name"],
                    s["latitude"],
                    s["longitude"],
                    json.dumps(s["types"], ensure_ascii=False),
                    now,
                )
                for s in stations
            ],
        )

        conn.executemany(
            """
            INSERT INTO route_servings (
              route_identifier, station_identifier, sequence, is_terminus
            ) VALUES (?, ?, ?, ?)
            """,
            [
                (
                    v["route_identifier"],
                    v["station_identifier"],
                    v["sequence"],
                    1 if v["is_terminus"] else 0,
                )
                for v in servings
            ],
        )

        conn.executemany(
            """
            INSERT INTO station_connections (
              from_identifier, to_identifier, distance
            ) VALUES (?, ?, ?)
            """,
            [
                (
                    c["from_identifier"],
                    c["to_identifier"],
                    c["distance"],
                )
                for c in connections
            ],
        )

        conn.commit()
        fk_issues = conn.execute("PRAGMA foreign_key_check").fetchall()
        if fk_issues:
            fail(f"Output DB FK check failed: {fk_issues}")
    finally:
        conn.close()


def write_cypher(
    output_cypher: Path,
    routes: List[dict],
    stations: List[dict],
    servings: List[dict],
    connections: List[dict],
) -> None:
    with output_cypher.open("w", encoding="utf-8") as f:
        f.write("// Auto-generated NIMBY -> vtraffic topology dataset\n")
        f.write(f"// Generated at {datetime.now(timezone.utc).isoformat()}\n\n")

        f.write("CREATE CONSTRAINT station_identifier IF NOT EXISTS\n")
        f.write("FOR (s:Station) REQUIRE s.identifier IS UNIQUE;\n")
        f.write("CREATE CONSTRAINT route_identifier IF NOT EXISTS\n")
        f.write("FOR (r:Route) REQUIRE r.identifier IS UNIQUE;\n")
        f.write("CREATE INDEX station_name IF NOT EXISTS\n")
        f.write("FOR (s:Station) ON (s.name);\n")
        f.write("CREATE INDEX station_location IF NOT EXISTS\n")
        f.write("FOR (s:Station) ON (s.latitude, s.longitude);\n")
        f.write("CREATE INDEX route_name IF NOT EXISTS\n")
        f.write("FOR (r:Route) ON (r.name);\n")
        f.write("CREATE INDEX serves_sequence IF NOT EXISTS\n")
        f.write("FOR ()-[s:SERVES]-() ON (s.sequence);\n")
        f.write("CREATE INDEX connects_distance IF NOT EXISTS\n")
        f.write("FOR ()-[s:CONNECTS_TO]-() ON (s.distance);\n\n")

        f.write("UNWIND [\n")
        sorted_routes = sorted(routes, key=lambda x: x["identifier"])
        for i, r in enumerate(sorted_routes):
            f.write("  {\n")
            f.write(f"    identifier: {cypher_quote(r['identifier'])},\n")
            f.write(f"    name: {cypher_quote(r['name'])},\n")
            f.write(f"    hexColor: {cypher_quote(r['hex_color'])},\n")
            f.write(f"    transportType: {cypher_quote(r['transport_type'])},\n")
            f.write(f"    routeType: {cypher_quote(r['route_type'])},\n")
            f.write(f"    description: {cypher_quote(r['description'])},\n")
            f.write(f"    operator: {cypher_quote(r['operator'])}\n")
            f.write("  }")
            f.write(",\n" if i < len(sorted_routes) - 1 else "\n")
        f.write("] AS route\n")
        f.write("MERGE (r:Route {identifier: route.identifier})\n")
        f.write("SET r.name = route.name,\n")
        f.write("    r.hexColor = route.hexColor,\n")
        f.write("    r.transportType = route.transportType,\n")
        f.write("    r.routeType = route.routeType,\n")
        f.write("    r.description = route.description,\n")
        f.write("    r.operator = route.operator,\n")
        f.write("    r.updatedAt = datetime();\n\n")

        f.write("UNWIND [\n")
        sorted_stations = sorted(stations, key=lambda x: x["identifier"])
        for i, s in enumerate(sorted_stations):
            types = "[" + ", ".join(cypher_quote(t) for t in s["types"]) + "]"
            f.write("  {\n")
            f.write(f"    identifier: {cypher_quote(s['identifier'])},\n")
            f.write(f"    name: {cypher_quote(s['name'])},\n")
            f.write(f"    latitude: {s['latitude']:.7f},\n")
            f.write(f"    longitude: {s['longitude']:.7f},\n")
            f.write(f"    types: {types}\n")
            f.write("  }")
            f.write(",\n" if i < len(sorted_stations) - 1 else "\n")
        f.write("] AS station\n")
        f.write("MERGE (s:Station {identifier: station.identifier})\n")
        f.write("SET s.name = station.name,\n")
        f.write("    s.latitude = station.latitude,\n")
        f.write("    s.longitude = station.longitude,\n")
        f.write("    s.types = station.types,\n")
        f.write("    s.updatedAt = datetime();\n\n")

        f.write("UNWIND [\n")
        for i, c in enumerate(connections):
            f.write(
                "  {from:"
                + cypher_quote(c["from_identifier"])
                + ", to:"
                + cypher_quote(c["to_identifier"])
                + f", distance:{c['distance']}"
                + "}"
            )
            f.write(",\n" if i < len(connections) - 1 else "\n")
        f.write("] AS row\n")
        f.write("MATCH (s1:Station {identifier: row.from})\n")
        f.write("MATCH (s2:Station {identifier: row.to})\n")
        f.write("MERGE (s1)-[rel:CONNECTS_TO]->(s2)\n")
        f.write("SET rel.distance = row.distance;\n\n")

        # Use relationship key by sequence to avoid data loss on repeated stations.
        f.write("UNWIND [\n")
        sorted_servings = sorted(servings, key=lambda x: (x["route_identifier"], x["sequence"]))
        for i, s in enumerate(sorted_servings):
            f.write(
                "  {route:"
                + cypher_quote(s["route_identifier"])
                + ", station:"
                + cypher_quote(s["station_identifier"])
                + f", sequence:{s['sequence']}, isTerminus:{cypher_bool(s['is_terminus'])}"
                + "}"
            )
            f.write(",\n" if i < len(sorted_servings) - 1 else "\n")
        f.write("] AS row\n")
        f.write("MATCH (r:Route {identifier: row.route})\n")
        f.write("MATCH (s:Station {identifier: row.station})\n")
        f.write("MERGE (r)-[rel:SERVES {sequence: row.sequence}]->(s)\n")
        f.write("SET rel.isTerminus = row.isTerminus;\n")


def validate_output(output_db: Path) -> Dict[str, int]:
    conn = sqlite3.connect(output_db)
    try:
        counts = {
            "routes": conn.execute("SELECT COUNT(*) FROM routes").fetchone()[0],
            "stations": conn.execute("SELECT COUNT(*) FROM stations").fetchone()[0],
            "route_servings": conn.execute("SELECT COUNT(*) FROM route_servings").fetchone()[0],
            "station_connections": conn.execute("SELECT COUNT(*) FROM station_connections").fetchone()[0],
            "route_servings_enriched": conn.execute("SELECT COUNT(*) FROM route_servings_enriched").fetchone()[0],
        }
        fk_issues = conn.execute("PRAGMA foreign_key_check").fetchall()
        if fk_issues:
            fail(f"Output DB FK violations: {fk_issues}")
        return counts
    finally:
        conn.close()


def main() -> None:
    args = parse_args()

    input_db = Path(args.input_db)
    output_cypher = Path(args.output_cypher)

    if not input_db.is_file():
        fail(f"Input DB not found: {input_db}")

    ensure_overwrite(output_cypher, args.force, "Output cypher")

    in_conn = sqlite3.connect(input_db)
    try:
        validate_input_schema(in_conn)
        stations_in, lines_in, stops_by_line = load_input(in_conn)
    finally:
        in_conn.close()

    routes, stations, servings, connections = transform(
        stations_in=stations_in,
        lines_in=lines_in,
        stops_by_line=stops_by_line,
        operator=args.operator,
    )

    write_cypher(output_cypher, routes, stations, servings, connections)
    print(f"Created output cypher: {output_cypher}")
    print(f"Routes: {len(routes)}")
    print(f"Stations: {len(stations)}")
    print(f"SERVINGS rows: {len(servings)}")
    print(f"CONNECTS_TO rows: {len(connections)}")


if __name__ == "__main__":
    main()
