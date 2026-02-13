#!/usr/bin/env python3

"""Build a station-only GraphML file from a NIMBY Rails SQLite export.

Usage:
  build_graph.py -i <db> [-o <file>] [-d] [-s] [--force]

Options:
  -i, --input   PATH  Input SQLite database exported from NIMBY Rails (required).
  -o, --output  PATH  Output GraphML file (default: nimby_rails.graphml).
  -d, --directed      Emit directed edges (a->b and b->a for each connection).
                       Default is undirected (single edge per connection).
  -s, --sanitize      Remove stations that have no connections.
      --force         Overwrite the output file if it already exists.

Input DB schema (expected):
  - stations(station_id, name, lon, lat)
  - line_stops(line_id, stop_index, station_id, arrival_s, departure_s, leg_distance_m)

Output:
  - GraphML file with Station nodes and connection edges, with haversine
    distance (metres) on each edge.
"""

from __future__ import annotations

import html
import math
import re
import sqlite3
import sys
import unicodedata
from argparse import ArgumentParser
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Tuple


@dataclass(frozen=True)
class StationIn:
    station_id: str
    name: str
    lon: float
    lat: float


@dataclass(frozen=True)
class StopIn:
    line_id: str
    stop_index: int
    station_id: str


def fail(message: str) -> None:
    print(f"Error: {message}", file=sys.stderr)
    sys.exit(1)


def parse_args():
    parser = ArgumentParser(
        description="Build a station graph (GraphML) from nimby_rails.db."
    )
    parser.add_argument(
        "-i", "--input",
        required=True,
        help="Path to input nimby_rails.db",
    )
    parser.add_argument(
        "-o", "--output",
        default="nimby_rails.graphml",
        help="Path to output GraphML file (default: nimby_rails.graphml)",
    )
    parser.add_argument(
        "--force", action="store_true",
        help="Overwrite output if it exists",
    )
    parser.add_argument(
        "-d", "--directed", action="store_true",
        help="Emit directed edges (a->b and b->a). Default is undirected.",
    )
    parser.add_argument(
        "-s", "--sanitize", action="store_true",
        help="Remove stations with no connections",
    )
    return parser.parse_args()


def validate_input_schema(conn: sqlite3.Connection) -> None:
    rows = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    ).fetchall()
    existing = {r[0] for r in rows}
    missing = sorted({"stations", "line_stops"} - existing)
    if missing:
        fail(f"Input DB missing required tables: {', '.join(missing)}")


def load_input(conn: sqlite3.Connection) -> Tuple[Dict[str, StationIn], Dict[str, List[StopIn]]]:
    station_rows = conn.execute(
        "SELECT station_id, name, lon, lat FROM stations"
    ).fetchall()
    stop_rows = conn.execute(
        "SELECT line_id, stop_index, station_id FROM line_stops ORDER BY line_id, stop_index"
    ).fetchall()

    stations: Dict[str, StationIn] = {
        r[0]: StationIn(r[0], r[1], float(r[2]), float(r[3])) for r in station_rows
    }
    stops_by_line: Dict[str, List[StopIn]] = {}
    for r in stop_rows:
        stop = StopIn(line_id=r[0], stop_index=int(r[1]), station_id=r[2])
        stops_by_line.setdefault(stop.line_id, []).append(stop)

    return stations, stops_by_line


def normalize_name(text: str, fallback: str) -> str:
    value = (text or "").strip().lower()
    value = (
        value.replace("ä", "ae").replace("ö", "oe")
        .replace("ü", "ue").replace("ß", "ss")
    )
    value = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii")
    value = re.sub(r"[^a-z0-9]+", "_", value).strip("_")
    return value or fallback


def build_unique_ids(
    source_to_name: Iterable[Tuple[str, str]],
    fallback_prefix: str,
) -> Dict[str, str]:
    entries: List[Tuple[str, str]] = []
    for source_id, name in source_to_name:
        source_fb = normalize_name(source_id, fallback_prefix)
        base = normalize_name(name, f"{fallback_prefix}_{source_fb}")
        entries.append((source_id, base))

    entries.sort(key=lambda x: (x[1], x[0]))

    mapping: Dict[str, str] = {}
    counts: Dict[str, int] = {}
    for source_id, base in entries:
        count = counts.get(base, 0) + 1
        counts[base] = count
        mapping[source_id] = base if count == 1 else f"{base}_{count}"

    return mapping


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> int:
    r = 6_371_000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlambda / 2) ** 2
    return max(1, round(r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))))


def transform(
    stations_in: Dict[str, StationIn],
    stops_by_line: Dict[str, List[StopIn]],
    directed: bool = False,
) -> Tuple[List[dict], List[dict]]:
    id_map = build_unique_ids(
        ((s.station_id, s.name) for s in stations_in.values()),
        fallback_prefix="station",
    )

    stations = [
        {
            "id": id_map[s.station_id],
            "name": s.name,
            "lat": s.lat,
            "lon": s.lon,
        }
        for s in stations_in.values()
    ]

    edges: Dict[Tuple[str, str], int] = {}
    for line_stops in stops_by_line.values():
        for i in range(len(line_stops) - 1):
            a, b = line_stops[i], line_stops[i + 1]
            if a.station_id == b.station_id:
                continue
            if a.station_id not in stations_in or b.station_id not in stations_in:
                continue

            sa, sb = stations_in[a.station_id], stations_in[b.station_id]
            dist = haversine_m(sa.lat, sa.lon, sb.lat, sb.lon)
            fa, fb = id_map[a.station_id], id_map[b.station_id]
            pair = (fa, fb) if fa < fb else (fb, fa)
            edges[pair] = min(edges.get(pair, dist), dist)

    connections = []
    for (a, b), distance in sorted(edges.items()):
        connections.append({"src": a, "dst": b, "distance": distance})
        if directed:
            connections.append({"src": b, "dst": a, "distance": distance})

    return stations, connections


def write_graphml(
    path: Path,
    stations: List[dict],
    connections: List[dict],
    directed: bool = False,
) -> None:
    nodes = sorted(stations, key=lambda x: x["id"])

    with path.open("w", encoding="utf-8") as f:
        f.write("<?xml version='1.0' encoding='UTF-8'?>\n")
        f.write(
            "<graphml xmlns='http://graphml.graphdrawing.org/xmlns' "
            "xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance' "
            "xsi:schemaLocation='http://graphml.graphdrawing.org/xmlns "
            "http://graphml.graphdrawing.org/xmlns/1.0/graphml.xsd'>\n"
        )
        f.write("  <key id='name' for='node' attr.name='name' attr.type='string'/>\n")
        f.write("  <key id='latitude' for='node' attr.name='latitude' attr.type='double'/>\n")
        f.write("  <key id='longitude' for='node' attr.name='longitude' attr.type='double'/>\n")
        f.write("  <key id='distance' for='edge' attr.name='distance' attr.type='int'/>\n")
        edge_dir = "directed" if directed else "undirected"
        f.write(f"  <graph id='G' edgedefault='{edge_dir}'>\n")

        for s in nodes:
            nid = html.escape(s["id"], quote=True)
            name = html.escape(s["name"], quote=False)
            f.write(f"    <node id='{nid}'>\n")
            f.write(f"      <data key='name'>{name}</data>\n")
            f.write(f"      <data key='latitude'>{s['lat']:.7f}</data>\n")
            f.write(f"      <data key='longitude'>{s['lon']:.7f}</data>\n")
            f.write("    </node>\n")

        for i, c in enumerate(connections):
            src = html.escape(c["src"], quote=True)
            dst = html.escape(c["dst"], quote=True)
            f.write(f"    <edge id='e{i}' source='{src}' target='{dst}'>\n")
            f.write(f"      <data key='distance'>{c['distance']}</data>\n")
            f.write("    </edge>\n")

        f.write("  </graph>\n")
        f.write("</graphml>\n")


def main() -> None:
    args = parse_args()

    input_db = Path(args.input)
    output = Path(args.output)

    if not input_db.is_file():
        fail(f"Input DB not found: {input_db}")
    if output.exists() and not args.force:
        fail(f"Output exists: {output} (use --force to overwrite)")

    conn = sqlite3.connect(input_db)
    try:
        validate_input_schema(conn)
        stations_in, stops_by_line = load_input(conn)
    finally:
        conn.close()

    stations, connections = transform(stations_in, stops_by_line, directed=args.directed)

    if args.sanitize:
        connected = {c["src"] for c in connections} | {c["dst"] for c in connections}
        removed = len(stations) - len(connected)
        stations = [s for s in stations if s["id"] in connected]
        if removed:
            print(f"Sanitized: removed {removed} unconnected station(s)")

    write_graphml(output, stations, connections, directed=args.directed)

    print(f"Written: {output}")
    print(f"Stations: {len(stations)}, Edges: {len(connections)}")


if __name__ == "__main__":
    main()
