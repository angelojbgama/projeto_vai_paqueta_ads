#!/usr/bin/env python3
"""
Script simples, sem argumentos, para baixar:
- Enderecos (via Overpass/OSM) de uma bbox fixa.
- Tiles raster da mesma bbox (para uso offline em assets/tiles/{z}/{x}/{y}.png).

Configure os parametros na secao CONFIG abaixo e execute:
  python scripts/fetch_addresses_overpass.py

Dependencias: pip install requests
"""
from __future__ import annotations

import json
import math
import time
from pathlib import Path
from typing import Any, Dict, List, Set, Tuple

import requests

# ===================== CONFIG =====================
# BBox da Ilha (Paqueta)
SOUTH = -22.774914
WEST = -43.133396
NORTH = -22.741042
EAST = -43.090621

# Overpass
OVERPASS_ENDPOINT = "https://overpass-api.de/api/interpreter"
# Lista de fallback (opcional). O primeiro que responder sera usado.
OVERPASS_ENDPOINTS = [
    OVERPASS_ENDPOINT,
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.openstreetmap.fr/api/interpreter",
]
OVERPASS_PAUSE = 1.0  # segundos

# Saida de enderecos
OUT_ADDRESSES = "addresses.json"

# Tiles (configure apenas servidores cujo uso voce pode/tem permissao)
DOWNLOAD_TILES = True
TILE_TEMPLATE = "https://tile.openstreetmap.de/{z}/{x}/{y}.png"
TILE_USER_AGENT = "vai-paqueta-tile-downloader"
MIN_ZOOM = 19
MAX_ZOOM = 20  # zoom maximo default; aumente/diminua conforme necessidade
TILE_PADDING = 3  # tiles extras ao redor da bbox para cobrir a tela
TILES_OUT = Path("assets/tiles")

# Ordem de preferencia de servidores; o primeiro que suportar o zoom desejado sera usado.
# Sempre respeite os termos de uso de cada servidor antes de efetuar downloads em lote.
TILE_PROVIDERS: List[Dict[str, Any]] = [
    {
        "name": "osm_de",
        "template": "https://tile.openstreetmap.de/{z}/{x}/{y}.png",
        "min_zoom": 0,
        "max_zoom": 18,
    },
    {
        "name": "osm_org",
        "template": "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
        "min_zoom": 0,
        "max_zoom": 19,
    },
    {
        "name": "carto_light",
        "template": "https://cartodb-basemaps-a.global.ssl.fastly.net/light_all/{z}/{x}/{y}.png",
        "min_zoom": 0,
        "max_zoom": 20,
    },
    # Exemplo para um servidor proprio ou com token:
    # {
    #     "name": "seu_servidor",
    #     "template": f"https://tiles.suaempresa.com/{z}/{x}/{y}.png?api-key=TOKEN",
    #     "min_zoom": 0,
    #     "max_zoom": 22,
    # },
]
# ==================================================


def build_query(south: float, west: float, north: float, east: float) -> str:
    return f"""
    [out:json][timeout:60];
    (
      nwr["addr:street"]({south},{west},{north},{east});
      nwr["addr:housenumber"]({south},{west},{north},{east});
    );
    out center;
    """


def fetch_addresses(
    south: float,
    west: float,
    north: float,
    east: float,
    endpoint: str,
    pause: float,
) -> List[Dict[str, Any]]:
    query = build_query(south, west, north, east)
    resp = requests.post(endpoint, data=query.encode("utf-8"), headers={"Content-Type": "text/plain"})
    resp.raise_for_status()
    data = resp.json()
    items: List[Dict[str, Any]] = []
    seen: Set[Tuple[str, int]] = set()

    for el in data.get("elements", []):
        osm_type = el.get("type")
        osm_id = el.get("id")
        tags = el.get("tags", {}) or {}
        street = tags.get("addr:street") or tags.get("name")
        number = tags.get("addr:housenumber")
        if not street:
            continue

        lat = el.get("lat")
        lng = el.get("lon")
        center = el.get("center") or {}
        if lat is None or lng is None:
            lat = center.get("lat")
            lng = center.get("lon")
        if lat is None or lng is None:
            continue

        key = (osm_type, osm_id)
        if key in seen:
            continue
        seen.add(key)

        items.append(
            {
                "street": street,
                "housenumber": number,
                "lat": lat,
                "lng": lng,
                "osm_type": osm_type,
                "osm_id": osm_id,
            }
        )

    time.sleep(pause)
    return items


def _deg2num(lat_deg: float, lon_deg: float, zoom: int) -> Tuple[int, int]:
    lat_rad = math.radians(lat_deg)
    n = 2.0 ** zoom
    xtile = int((lon_deg + 180.0) / 360.0 * n)
    ytile = int((1.0 - math.log(math.tan(lat_rad) + (1 / math.cos(lat_rad))) / math.pi) / 2.0 * n)
    return xtile, ytile


def download_tiles(
    south: float,
    west: float,
    north: float,
    east: float,
    min_zoom: int,
    max_zoom: int,
    template: str | None,
    base_dir: Path,
    timeout: float = 30.0,
    user_agent: str = "vai-paqueta-tile-downloader",
    retries: int = 4,
    backoff: float = 1.5,
    padding_tiles: int = 0,
    providers: List[Dict[str, Any]] | None = None,
) -> tuple[int, int]:
    base_dir.mkdir(parents=True, exist_ok=True)
    session = requests.Session()
    session.headers.update({"User-Agent": user_agent})
    total = 0
    failed = 0
    provider_list: List[Dict[str, Any]] = []

    if providers:
        for prov in providers:
            tpl = prov.get("template")
            if not tpl:
                raise ValueError(f"Tile provider sem template: {prov}")
            provider_list.append(
                {
                    "name": prov.get("name") or tpl,
                    "template": tpl,
                    "min_zoom": prov.get("min_zoom", min_zoom),
                    "max_zoom": prov.get("max_zoom", max_zoom),
                }
            )
    elif template:
        provider_list.append(
            {"name": "default", "template": template, "min_zoom": min_zoom, "max_zoom": max_zoom}
        )
    else:
        raise ValueError("Nenhum template ou provider de tile configurado.")

    for z in range(min_zoom, max_zoom + 1):
        candidates = [p for p in provider_list if p["min_zoom"] <= z <= p["max_zoom"]]
        if not candidates:
            print(f"Sem provedor configurado para o zoom {z}; pulando.")
            continue

        x_min, y_max = _deg2num(south, west, z)
        x_max, y_min = _deg2num(north, east, z)
        n = 2 ** z
        pad = max(0, padding_tiles)
        x_from = max(0, min(x_min, x_max) - pad)
        x_to = min(n - 1, max(x_min, x_max) + pad)
        y_from = max(0, min(y_min, y_max) - pad)
        y_to = min(n - 1, max(y_min, y_max) + pad)

        for x in range(x_from, x_to + 1):
            for y in range(y_from, y_to + 1):
                out_path = base_dir / str(z) / str(x) / f"{y}.png"
                out_path.parent.mkdir(parents=True, exist_ok=True)
                if out_path.exists():
                    continue
                ok = False
                for provider in candidates:
                    delay = backoff
                    url = provider["template"].format(z=z, x=x, y=y)
                    for attempt in range(retries + 1):
                        try:
                            resp = session.get(url, timeout=timeout)
                            if resp.status_code == 200 and resp.content:
                                out_path.write_bytes(resp.content)
                                total += 1
                                ok = True
                                break
                            else:
                                print(
                                    f"Falha ao baixar tile z{z}/{x}/{y} em {provider['name']}: {resp.status_code}"
                                )
                        except Exception as exc:  # noqa: BLE001
                            print(
                                f"Erro ao baixar tile z{z}/{x}/{y} em {provider['name']} "
                                f"(tentativa {attempt+1}/{retries+1}): {exc}"
                            )
                        time.sleep(delay)
                        delay *= 2
                    if ok:
                        break
                if not ok:
                    print(f"Desistindo do tile z{z}/{x}/{y} apos {retries+1} tentativas.")
                    failed += 1
        time.sleep(0.5)
    return total, failed


def main() -> None:
    print(">> Baixando enderecos...")
    endpoints = OVERPASS_ENDPOINTS or [OVERPASS_ENDPOINT]
    addrs: List[Dict[str, Any]] | None = None
    last_err: Exception | None = None
    for ep in endpoints:
        try:
            addrs = fetch_addresses(SOUTH, WEST, NORTH, EAST, endpoint=ep, pause=OVERPASS_PAUSE)
            break
        except Exception as exc:  # noqa: BLE001
            last_err = exc
            print(f">> Falha no endpoint {ep}: {exc}")
            time.sleep(1.0)

    if addrs is None:
        raise SystemExit(f"Falha ao baixar enderecos; ultimo erro: {last_err}")

    Path(OUT_ADDRESSES).write_text(json.dumps(addrs, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f">> Salvo {len(addrs)} enderecos em {OUT_ADDRESSES}")

    if DOWNLOAD_TILES:
        print(">> Baixando tiles (pode levar alguns minutos)...")
        passes = 3
        for attempt in range(1, passes + 1):
            novos, falhas = download_tiles(
                SOUTH,
                WEST,
                NORTH,
                EAST,
                min_zoom=MIN_ZOOM,
                max_zoom=MAX_ZOOM,
                template=TILE_TEMPLATE,
                base_dir=TILES_OUT,
                user_agent=TILE_USER_AGENT,
                padding_tiles=TILE_PADDING,
                providers=TILE_PROVIDERS,
            )
            print(f">> Passo {attempt}/{passes}: novos={novos}, falhas={falhas}")
            if falhas == 0:
                break
            time.sleep(2)
        print(">> Download de tiles concluido (reexecute se ainda faltar algo).")


if __name__ == "__main__":
    main()
