#!/usr/bin/env python3
"""
Script simples, sem argumentos, para baixar tiles do OpenStreetMap
para uso local no backend.

Configure os parametros na secao CONFIG abaixo e execute:
  python scripts/fetch_tiles_osm.py

Dependencias: pip install requests
"""
from __future__ import annotations

import math
import time
from pathlib import Path
from typing import Tuple

import requests

# ===================== CONFIG =====================
# BBox da Ilha (Paqueta)
SOUTH = -22.774914
WEST = -43.133396
NORTH = -22.741042
EAST = -43.090621

# Tiles
TILE_TEMPLATE = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
TILE_USER_AGENT = "vai-paqueta-tile-downloader"
MIN_ZOOM = 1
MAX_ZOOM = 25
TILE_PADDING = 3  # tiles extras ao redor da bbox para cobrir a tela
REQUEST_TIMEOUT = 30.0
RETRIES = 4
BACKOFF = 1.5
SLEEP_BETWEEN_TILES = 0.0

# Diretorio de saida (backend)
TILES_OUT = Path("vai_paqueta_backend/static/landing/assets/tiles")
# ==================================================


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


def download_tiles() -> tuple[int, int]:
    TILES_OUT.mkdir(parents=True, exist_ok=True)
    session = requests.Session()
    session.headers.update({"User-Agent": TILE_USER_AGENT})
    total = 0
    failed = 0

    for z in range(MIN_ZOOM, MAX_ZOOM + 1):
        x_from, x_to, y_from, y_to = _tile_bounds(SOUTH, WEST, NORTH, EAST, z, TILE_PADDING)
        for x in range(x_from, x_to + 1):
            for y in range(y_from, y_to + 1):
                out_path = TILES_OUT / str(z) / str(x) / f"{y}.png"
                out_path.parent.mkdir(parents=True, exist_ok=True)
                if out_path.exists():
                    continue
                url = TILE_TEMPLATE.format(z=z, x=x, y=y)
                delay = BACKOFF
                ok = False
                for attempt in range(RETRIES + 1):
                    try:
                        resp = session.get(url, timeout=REQUEST_TIMEOUT)
                        if resp.status_code == 200 and resp.content:
                            out_path.write_bytes(resp.content)
                            total += 1
                            ok = True
                            break
                        print(f"Falha ao baixar tile z{z}/{x}/{y}: {resp.status_code}")
                    except Exception as exc:  # noqa: BLE001
                        print(
                            f"Erro ao baixar tile z{z}/{x}/{y} (tentativa {attempt+1}/{RETRIES+1}): {exc}"
                        )
                    time.sleep(delay)
                    delay *= 2
                if not ok:
                    failed += 1
                    print(f"Desistindo do tile z{z}/{x}/{y} apos {RETRIES+1} tentativas.")
                if SLEEP_BETWEEN_TILES > 0:
                    time.sleep(SLEEP_BETWEEN_TILES)
        time.sleep(0.5)

    return total, failed


def main() -> None:
    print(">> Baixando tiles do OSM...")
    novos, falhas = download_tiles()
    print(f">> Download concluido: novos={novos}, falhas={falhas}")
    if falhas:
        print(">> Reexecute para tentar baixar tiles faltantes.")


if __name__ == "__main__":
    main()
