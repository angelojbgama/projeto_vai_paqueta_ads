#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import os
import sys
from functools import partial
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

DEFAULT_BOUNDS = {"south": -22.78, "west": -43.13, "north": -22.74, "east": -43.08}
DEFAULT_MIN_ZOOM = 12
DEFAULT_MAX_ZOOM = 19


def resolve_path(base_dir: Path, value: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = (base_dir / path).resolve()
    return path


def rel_path(base_dir: Path, path: Path) -> str | None:
    try:
        return str(path.resolve().relative_to(base_dir))
    except ValueError:
        return None


def list_zoom_levels(tile_root: Path) -> list[int]:
    zooms: list[int] = []
    if not tile_root.exists():
        return zooms
    for entry in os.scandir(tile_root):
        if entry.is_dir() and entry.name.isdigit():
            zooms.append(int(entry.name))
    return sorted(zooms)


def tile_x_to_lon(x: int, zoom: int) -> float:
    return x / (2**zoom) * 360.0 - 180.0


def tile_y_to_lat(y: int, zoom: int) -> float:
    n = math.pi - (2.0 * math.pi * y) / (2**zoom)
    return math.degrees(math.atan(math.sinh(n)))


def compute_bounds(tile_root: Path, zoom: int) -> dict[str, float] | None:
    zoom_dir = tile_root / str(zoom)
    if not zoom_dir.exists():
        return None
    min_x = max_x = min_y = max_y = None
    for x_entry in os.scandir(zoom_dir):
        if not x_entry.is_dir() or not x_entry.name.isdigit():
            continue
        x = int(x_entry.name)
        min_x = x if min_x is None else min(min_x, x)
        max_x = x if max_x is None else max(max_x, x)
        for y_entry in os.scandir(x_entry.path):
            if not y_entry.is_file() or not y_entry.name.endswith(".png"):
                continue
            base = y_entry.name[:-4]
            if not base.isdigit():
                continue
            y = int(base)
            min_y = y if min_y is None else min(min_y, y)
            max_y = y if max_y is None else max(max_y, y)
    if min_x is None or min_y is None or max_x is None or max_y is None:
        return None
    west = tile_x_to_lon(min_x, zoom)
    east = tile_x_to_lon(max_x + 1, zoom)
    north = tile_y_to_lat(min_y, zoom)
    south = tile_y_to_lat(max_y + 1, zoom)
    return {"south": south, "west": west, "north": north, "east": east}


def parse_bounds(value: str) -> dict[str, float]:
    parts = [part.strip() for part in value.split(",")]
    if len(parts) != 4:
        raise ValueError("bounds must be south,west,north,east")
    south, west, north, east = [float(part) for part in parts]
    return {"south": south, "west": west, "north": north, "east": east}


class RoadTracerHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/road-tracer-config":
            self._send_json(self.server.config)
            return
        super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path != "/road-tracer-save":
            self.send_error(404, "Not found")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        body = self.rfile.read(length or 0)
        try:
            payload = json.loads(body.decode("utf-8"))
        except json.JSONDecodeError:
            self._send_json({"ok": False, "error": "invalid json"}, status=400)
            return
        output_path: Path = self.server.output_path
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
        rel_output = rel_path(self.server.base_dir, output_path) or str(output_path)
        self._send_json({"ok": True, "path": rel_output, "message": f"Saved to {rel_output}"})

    def _send_json(self, payload: dict, status: int = 200):
        data = json.dumps(payload, ensure_ascii=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def build_config(
    base_dir: Path,
    tile_root: Path,
    output_path: Path,
    min_zoom: int | None,
    max_zoom: int | None,
    default_zoom: int | None,
    bounds: dict[str, float] | None,
) -> dict:
    tile_rel = rel_path(base_dir, tile_root)
    if tile_rel is None:
        raise RuntimeError("Tile root must live under the project directory.")
    tile_url = "/" + tile_rel.replace(os.sep, "/") + "/{z}/{x}/{y}.png"

    if bounds is None:
        bounds = DEFAULT_BOUNDS.copy()

    center = {
        "lat": (bounds["south"] + bounds["north"]) / 2,
        "lng": (bounds["west"] + bounds["east"]) / 2,
    }

    output_rel = rel_path(base_dir, output_path) or str(output_path)
    existing = None
    if output_path.exists():
        try:
            existing = json.loads(output_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            existing = None

    return {
        "tileUrl": tile_url,
        "minZoom": min_zoom,
        "maxZoom": max_zoom,
        "defaultZoom": default_zoom,
        "bounds": bounds,
        "center": center,
        "outputPath": output_rel,
        "existing": existing,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Local road tracer for Paqueta tiles.")
    parser.add_argument(
        "--tiles",
        default="static/landing/assets/tiles",
        help="Tile directory (z/x/y.png). Default: static/landing/assets/tiles",
    )
    parser.add_argument(
        "--output",
        default="geo/roads.json",
        help="Output JSON path (relative to project root by default).",
    )
    parser.add_argument("--host", default="127.0.0.1", help="Bind host (default: 127.0.0.1).")
    parser.add_argument("--port", type=int, default=8008, help="Bind port (default: 8008).")
    parser.add_argument("--min-zoom", type=int, help="Override min zoom.")
    parser.add_argument("--max-zoom", type=int, help="Override max zoom.")
    parser.add_argument("--default-zoom", type=int, help="Override default zoom.")
    parser.add_argument(
        "--bounds",
        help="Override bounds as south,west,north,east (decimal degrees).",
    )
    parser.add_argument("--open", action="store_true", help="Open the browser automatically.")
    args = parser.parse_args()

    base_dir = Path(__file__).resolve().parents[1]
    tile_root = resolve_path(base_dir, args.tiles)
    if not tile_root.exists():
        print(f"Tile directory not found: {tile_root}", file=sys.stderr)
        return 1

    zoom_levels = list_zoom_levels(tile_root)
    min_zoom = args.min_zoom if args.min_zoom is not None else (min(zoom_levels) if zoom_levels else DEFAULT_MIN_ZOOM)
    max_zoom = args.max_zoom if args.max_zoom is not None else (max(zoom_levels) if zoom_levels else DEFAULT_MAX_ZOOM)
    default_zoom = args.default_zoom if args.default_zoom is not None else max_zoom
    if default_zoom < min_zoom:
        default_zoom = min_zoom
    if default_zoom > max_zoom:
        default_zoom = max_zoom

    bounds = None
    if args.bounds:
        try:
            bounds = parse_bounds(args.bounds)
        except ValueError as exc:
            print(f"Invalid bounds: {exc}", file=sys.stderr)
            return 1
    else:
        bounds = compute_bounds(tile_root, max_zoom)

    output_path = resolve_path(base_dir, args.output)
    try:
        config = build_config(base_dir, tile_root, output_path, min_zoom, max_zoom, default_zoom, bounds)
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    handler = partial(RoadTracerHandler, directory=str(base_dir))
    server = HTTPServer((args.host, args.port), handler)
    server.config = config
    server.output_path = output_path
    server.base_dir = base_dir

    url = f"http://{args.host}:{args.port}/scripts/road_tracer.html"
    print(f"Serving road tracer at {url}")
    if args.open:
        try:
            import webbrowser

            webbrowser.open(url)
        except Exception:
            pass
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
