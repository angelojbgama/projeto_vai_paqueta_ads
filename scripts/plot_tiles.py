#!/usr/bin/env python3
"""
Gera mosaico PNG a partir dos tiles baixados em assets/tiles/{z}/{x}/{y}.png.

Exemplos:
  # Plotar um zoom especifico
  python scripts/plot_tiles.py --zoom 19 --output mosaico.png

  # Plotar todos os zooms disponiveis (gera um PNG por zoom com sufixo _zZ)
  python scripts/plot_tiles.py --all-zooms --output mosaico.png

Flags uteis:
  --zoom Z                Zoom a plotar (ex.: 18, 19 ou 20).
  --all-zooms             Plota todos os zooms encontrados em assets/tiles.
  --padding N             Tiles extras ao redor da bbox (igual ao usado no download).
  --tiles-dir PATH        Diretorio base dos tiles (default: assets/tiles).
  --bbox S W N E          BBox (se quiser diferente da padrao da ilha).

Requer: Pillow (instale com `pip install pillow`).
"""
from __future__ import annotations

import argparse
import math
from pathlib import Path
from typing import List, Tuple

from PIL import Image

# BBox padrao: Ilha de Paqueta
SOUTH = -22.774914
WEST = -43.133396
NORTH = -22.741042
EAST = -43.090621

TILE_SIZE = 256


def _deg2num(lat_deg: float, lon_deg: float, zoom: int) -> Tuple[int, int]:
    lat_rad = math.radians(lat_deg)
    n = 2.0 ** zoom
    xtile = int((lon_deg + 180.0) / 360.0 * n)
    ytile = int((1.0 - math.log(math.tan(lat_rad) + (1 / math.cos(lat_rad))) / math.pi) / 2.0 * n)
    return xtile, ytile


def _tile_bounds(
    south: float, west: float, north: float, east: float, zoom: int, padding: int
) -> Tuple[int, int, int, int]:
    x_min, y_max = _deg2num(south, west, zoom)
    x_max, y_min = _deg2num(north, east, zoom)
    n = 2 ** zoom
    pad = max(0, padding)
    x_from = max(0, min(x_min, x_max) - pad)
    x_to = min(n - 1, max(x_min, x_max) + pad)
    y_from = max(0, min(y_min, y_max) - pad)
    y_to = min(n - 1, max(y_min, y_max) + pad)
    return x_from, x_to, y_from, y_to


def available_zooms(tiles_dir: Path) -> List[int]:
    zooms: List[int] = []
    if not tiles_dir.exists():
        return zooms
    for p in tiles_dir.iterdir():
        if p.is_dir() and p.name.isdigit():
            zooms.append(int(p.name))
    return sorted(zooms)


def stitch_tiles(
    tiles_dir: Path,
    zoom: int,
    south: float,
    west: float,
    north: float,
    east: float,
    padding: int = 0,
) -> tuple[Image.Image, List[Path]]:
    x_from, x_to, y_from, y_to = _tile_bounds(south, west, north, east, zoom, padding)
    width = (x_to - x_from + 1) * TILE_SIZE
    height = (y_to - y_from + 1) * TILE_SIZE

    canvas = Image.new("RGBA", (width, height), (235, 235, 235, 255))
    missing: List[Path] = []

    for x in range(x_from, x_to + 1):
        for y in range(y_from, y_to + 1):
            tile_path = tiles_dir / str(zoom) / str(x) / f"{y}.png"
            if not tile_path.exists():
                missing.append(tile_path)
                continue
            try:
                tile = Image.open(tile_path).convert("RGBA")
            except Exception:
                missing.append(tile_path)
                continue
            dx = (x - x_from) * TILE_SIZE
            dy = (y - y_from) * TILE_SIZE
            canvas.paste(tile, (dx, dy))
    return canvas, missing


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Plota um mosaico a partir de tiles locais.")
    parser.add_argument("--zoom", type=int, help="Zoom a plotar (ex.: 18, 19 ou 20).")
    parser.add_argument("--all-zooms", action="store_true", help="Plota todos os zooms encontrados no diretorio.")
    parser.add_argument("--padding", type=int, default=3, help="Tiles extras ao redor da bbox.")
    parser.add_argument("--tiles-dir", type=Path, default=Path("assets/tiles"), help="Diretorio base dos tiles.")
    parser.add_argument("--output", type=Path, default=Path("mosaico.png"), help="Arquivo de saida PNG.")
    parser.add_argument(
        "--bbox",
        type=float,
        nargs=4,
        metavar=("SOUTH", "WEST", "NORTH", "EAST"),
        help="BBox customizada (por padrao usa a da ilha de Paqueta).",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    south, west, north, east = args.bbox if args.bbox else (SOUTH, WEST, NORTH, EAST)
    zooms: List[int]
    if args.all_zooms:
        zooms = available_zooms(args.tiles_dir)
        if not zooms:
            raise SystemExit(f"Nenhum zoom encontrado em {args.tiles_dir}")
    elif args.zoom is not None:
        zooms = [args.zoom]
    else:
        zooms = available_zooms(args.tiles_dir)
        if not zooms:
            raise SystemExit("Informe --zoom ou use --all-zooms (nenhum zoom encontrado).")

    args.output.parent.mkdir(parents=True, exist_ok=True)

    for zoom in zooms:
        img, missing = stitch_tiles(args.tiles_dir, zoom, south, west, north, east, padding=args.padding)
        if len(zooms) > 1:
            out_path = args.output.with_name(f"{args.output.stem}_z{zoom}{args.output.suffix}")
        else:
            out_path = args.output
        out_path.parent.mkdir(parents=True, exist_ok=True)
        img.save(out_path)
        print(f"Mosaico salvo em {out_path} (zoom {zoom}, tamanho: {img.size[0]}x{img.size[1]})")
        if missing:
            print(f"Aviso: {len(missing)} tiles faltando para z{zoom}. Exemplos: {missing[:3]}")


if __name__ == "__main__":
    main()
