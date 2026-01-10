import heapq
import json
import math
import threading
from dataclasses import dataclass
from pathlib import Path

from django.conf import settings
from rest_framework.response import Response
from rest_framework.views import APIView

_EARTH_RADIUS_M = 6371000.0


class ReverseGeocodeView(APIView):
    """
    Geocodificação reversa simples (lat/lng -> endereço).
    Usa geopy.Nominatim; em produção use chave própria (ex: Google Geocoding).
    """

    def get(self, request):
        try:
            lat = float(request.query_params.get("lat"))
            lng = float(request.query_params.get("lng"))
        except (TypeError, ValueError):
            return Response({"detail": "lat e lng são obrigatórios."}, status=400)

        try:
            from geopy.geocoders import Nominatim

            geolocator = Nominatim(user_agent="vai-paqueta")
            location = geolocator.reverse(f"{lat}, {lng}", language="pt")
            if not location:
                return Response({"detail": "Endereço não encontrado."}, status=404)
            raw = getattr(location, "raw", {}) or {}
            address = raw.get("address") or {}
            street = (
                address.get("road")
                or address.get("pedestrian")
                or address.get("street")
                or address.get("residential")
                or address.get("path")
                or address.get("footway")
                or address.get("neighbourhood")
            )
            number = address.get("house_number")
            if street and number:
                short_address = f"{street}, {number}"
            elif street:
                short_address = street
            else:
                short_address = location.address
            return Response({"endereco": short_address, "endereco_completo": location.address})
        except Exception as exc:  # noqa: BLE001
            return Response({"detail": f"Falha no geocoding: {exc}"}, status=500)


class NearbySearchView(APIView):
    """
    Busca endereços próximos ao ponto informado (lat/lng) contendo o texto.
    Usa Nominatim com viewbox para limitar o raio aproximado.
    """

    def get(self, request):
        query = request.query_params.get("q")
        try:
            lat = float(request.query_params.get("lat"))
            lng = float(request.query_params.get("lng"))
        except (TypeError, ValueError):
            return Response({"detail": "Parâmetros q, lat e lng são obrigatórios."}, status=400)

        radius_km = float(request.query_params.get("radius_km", 5))
        limit = int(request.query_params.get("limit", 5))

        # Aproximação simples de bbox
        lat_deg = radius_km / 111.0
        lng_deg = radius_km / (111.0 * max(abs(math.cos(math.radians(lat))), 0.01))
        viewbox = [
            lng - lng_deg,
            lat - lat_deg,
            lng + lng_deg,
            lat + lat_deg,
        ]

        try:
            from geopy.geocoders import Nominatim

            geolocator = Nominatim(user_agent="vai-paqueta")
            results = geolocator.geocode(
                query,
                exactly_one=False,
                limit=limit,
                viewbox=viewbox,
                bounded=True,
                language="pt",
            )
            if not results:
                return Response([], status=200)
            resposta = []
            for r in results:
                resposta.append(
                    {
                        "latitude": r.latitude,
                        "longitude": r.longitude,
                        "endereco": r.address,
                        "nome": r.raw.get("display_name", r.address),
                    }
                )
            return Response(resposta)
        except Exception as exc:  # noqa: BLE001
            return Response({"detail": f"Falha na busca: {exc}"}, status=500)


class ForwardGeocodeView(APIView):
    """
    Geocodificação direta (endereço -> lat/lng).
    """

    def get(self, request):
        query = request.query_params.get("q")
        if not query:
            return Response({"detail": "Parâmetro q é obrigatório."}, status=400)
        try:
            from geopy.geocoders import Nominatim

            geolocator = Nominatim(user_agent="vai-paqueta")
            location = geolocator.geocode(query, language="pt")
            if not location:
                return Response({"detail": "Endereço não encontrado."}, status=404)
            return Response(
                {
                    "latitude": location.latitude,
                    "longitude": location.longitude,
                    "endereco": location.address,
                }
            )
        except Exception as exc:  # noqa: BLE001
            return Response({"detail": f"Falha no geocoding: {exc}"}, status=500)


class CountryListView(APIView):
    """
    Lista países com DDI (código internacional) para o seletor de telefone.
    """

    permission_classes = []
    authentication_classes = []

    def get(self, request):
        try:
            import phonenumbers
        except ImportError:
            return Response({"detail": "Biblioteca phonenumbers não instalada."}, status=500)

        try:
            import pycountry
        except ImportError:
            pycountry = None

        countries = []
        for region in sorted(phonenumbers.SUPPORTED_REGIONS):
            code = phonenumbers.country_code_for_region(region)
            if not code:
                continue
            name = region
            if pycountry:
                country = pycountry.countries.get(alpha_2=region)
                if country:
                    name = country.name
            countries.append({"iso2": region, "name": name, "ddi": str(code)})

        countries.sort(key=lambda item: item["name"])
        return Response({"countries": countries})


def _normalize_path(value: str | Path) -> Path:
    path = Path(value)
    if not path.is_absolute():
        path = (settings.BASE_DIR / path).resolve()
    return path


def _load_json_from_candidates(candidates: list[Path]):
    for path in candidates:
        if not path.exists() or not path.is_file():
            continue
        try:
            return path, json.loads(path.read_text(encoding="utf-8")), None
        except (OSError, json.JSONDecodeError) as exc:
            return path, None, exc
    return None, None, None


def _float_from_params(params, *keys: str) -> float | None:
    for key in keys:
        raw = params.get(key)
        if raw is None or raw == "":
            continue
        try:
            return float(raw)
        except (TypeError, ValueError) as exc:
            raise ValueError(f"{key} inválido: {raw}") from exc
    return None


def _round6(value: float) -> float:
    return float(f"{value:.6f}")


def _haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    radius = 6371000.0
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lng = math.radians(lng2 - lng1)
    a = math.sin(d_phi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(d_lng / 2) ** 2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return radius * c


def _densify_road_points(points: list[tuple[float, float]], max_segment_m: float) -> list[tuple[float, float]]:
    if max_segment_m <= 0 or len(points) < 2:
        return points
    densified: list[tuple[float, float]] = [points[0]]
    for lat_next, lng_next in points[1:]:
        lat_prev, lng_prev = densified[-1]
        segment_dist = _haversine_m(lat_prev, lng_prev, lat_next, lng_next)
        if segment_dist <= max_segment_m:
            densified.append((lat_next, lng_next))
            continue
        steps = int(math.ceil(segment_dist / max_segment_m))
        for step in range(1, steps + 1):
            t = step / steps
            densified.append(
                (
                    lat_prev + (lat_next - lat_prev) * t,
                    lng_prev + (lng_next - lng_prev) * t,
                )
            )
    return densified


def _dedup_points(points: list[dict[str, float]]) -> list[dict[str, float]]:
    deduped: list[dict[str, float]] = []
    for point in points:
        if not deduped:
            deduped.append(point)
            continue
        last = deduped[-1]
        if last["lat"] == point["lat"] and last["lng"] == point["lng"]:
            continue
        deduped.append(point)
    return deduped


def _parse_float(value) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _road_entry_payload(entry: dict[str, object], distance: float) -> dict[str, object]:
    return {
        "id": entry.get("id"),
        "name": entry.get("name"),
        "points": [{"lat": lat, "lng": lng} for lat, lng in entry.get("points", [])],
        "distance_m": round(distance, 2),
    }


def _project(lat: float, lng: float) -> tuple[float, float]:
    lat_rad = math.radians(lat)
    lng_rad = math.radians(lng)
    x = _EARTH_RADIUS_M * lng_rad * math.cos(lat_rad)
    y = _EARTH_RADIUS_M * lat_rad
    return x, y


def _segment_point_distance_m(lat: float, lng: float, lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    x, y = _project(lat, lng)
    x1, y1 = _project(lat1, lng1)
    x2, y2 = _project(lat2, lng2)
    dx = x2 - x1
    dy = y2 - y1
    if dx == 0 and dy == 0:
        return math.hypot(x - x1, y - y1)
    t = ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    proj_x = x1 + t * dx
    proj_y = y1 + t * dy
    return math.hypot(x - proj_x, y - proj_y)


def _find_nearest_road_entry(
    entries: list[dict[str, object]], lat: float, lng: float
) -> dict[str, object] | None:
    best: dict[str, object] | None = None
    best_dist = None
    for entry in entries:
        points = entry.get("points", []) or []
        for idx in range(len(points) - 1):
            lat1, lng1 = points[idx]
            lat2, lng2 = points[idx + 1]
            dist = _segment_point_distance_m(lat, lng, lat1, lng1, lat2, lng2)
            if best_dist is None or dist < best_dist:
                best_dist = dist
                best = entry
    if best is None or best_dist is None:
        return None
    return _road_entry_payload(best, best_dist)


def _extract_road_entries(data: dict) -> list[dict[str, object]]:
    entries: list[dict[str, object]] = []
    counter = 1

    def add_entry(source: dict[str, object], raw_points: list):
        points: list[tuple[float, float]] = []
        for point in raw_points:
            if not isinstance(point, dict):
                continue
            lat = _parse_float(point.get("lat"))
            lng = _parse_float(point.get("lng"))
            if lat is None or lng is None:
                continue
            points.append((lat, lng))
        if len(points) < 2:
            return
        nonlocal counter
        entry_id = source.get("id") or counter
        name = source.get("name") or source.get("nome") or f"Road {counter}"
        entries.append({"id": entry_id, "name": name, "points": points})
        counter += 1

    if isinstance(data, dict) and isinstance(data.get("roads"), list):
        for road in data.get("roads", []):
            if not isinstance(road, dict):
                continue
            add_entry(road, road.get("points", []) or [])
        if entries:
            return entries

    if data.get("type") == "FeatureCollection" and isinstance(data.get("features"), list):
        for feature in data.get("features", []):
            if not isinstance(feature, dict):
                continue
            geometry = feature.get("geometry") or {}
            if not isinstance(geometry, dict) or geometry.get("type") != "LineString":
                continue
            raw_points = geometry.get("coordinates") or []
            formatted = []
            for coord in raw_points:
                if not isinstance(coord, list) or len(coord) < 2:
                    continue
                formatted.append({"lng": coord[0], "lat": coord[1]})
            add_entry(feature.get("properties") or {}, formatted)
    return entries


@dataclass
class RoadGraph:
    nodes: list[tuple[float, float]]
    edges: dict[int, list[tuple[int, float]]]

    def nearest_node(self, lat: float, lng: float) -> tuple[int | None, float | None]:
        best_id = None
        best_dist = None
        for idx, (nlat, nlng) in enumerate(self.nodes):
            dist = _haversine_m(lat, lng, nlat, nlng)
            if best_dist is None or dist < best_dist:
                best_dist = dist
                best_id = idx
        return best_id, best_dist

    def shortest_path(self, start_id: int, end_id: int) -> tuple[list[int], float]:
        if start_id == end_id:
            return [start_id], 0.0
        open_set: list[tuple[float, int]] = []
        heapq.heappush(open_set, (0.0, start_id))
        came_from: dict[int, int] = {}
        g_score: dict[int, float] = {start_id: 0.0}
        goal = self.nodes[end_id]

        while open_set:
            _, current = heapq.heappop(open_set)
            if current == end_id:
                return _reconstruct_path(came_from, current), g_score.get(current, 0.0)
            for neighbor, weight in self.edges.get(current, []):
                tentative = g_score[current] + weight
                if tentative < g_score.get(neighbor, float("inf")):
                    came_from[neighbor] = current
                    g_score[neighbor] = tentative
                    nlat, nlng = self.nodes[neighbor]
                    heuristic = _haversine_m(nlat, nlng, goal[0], goal[1])
                    heapq.heappush(open_set, (tentative + heuristic, neighbor))
        return [], 0.0


def _reconstruct_path(came_from: dict[int, int], current: int) -> list[int]:
    path = [current]
    while current in came_from:
        current = came_from[current]
        path.append(current)
    path.reverse()
    return path


def _build_graph(roads: list[list[tuple[float, float]]], snap_decimals: int) -> RoadGraph:
    nodes: list[tuple[float, float]] = []
    node_index: dict[tuple[float, float], int] = {}
    edges: dict[int, list[tuple[int, float]]] = {}
    densify_max = float(getattr(settings, "ROADS_DENSIFY_MAX_SEGMENT_M", 0.0))

    def get_node_id(lat: float, lng: float) -> int:
        key = (round(lat, snap_decimals), round(lng, snap_decimals))
        if key in node_index:
            return node_index[key]
        node_id = len(nodes)
        node_index[key] = node_id
        nodes.append(key)
        return node_id

    for road in roads:
        densified_road = _densify_road_points(road, densify_max) if densify_max > 0 else road
        prev_id: int | None = None
        for lat, lng in densified_road:
            node_id = get_node_id(lat, lng)
            if prev_id is not None and prev_id != node_id:
                lat1, lng1 = nodes[prev_id]
                lat2, lng2 = nodes[node_id]
                dist = _haversine_m(lat1, lng1, lat2, lng2)
                edges.setdefault(prev_id, []).append((node_id, dist))
                edges.setdefault(node_id, []).append((prev_id, dist))
            prev_id = node_id
    _connect_nearby_nodes(nodes, edges, getattr(settings, "ROADS_CONNECT_RADIUS", 15.0))
    return RoadGraph(nodes=nodes, edges=edges)


def _connect_nearby_nodes(
    nodes: list[tuple[float, float]],
    edges: dict[int, list[tuple[int, float]]],
    max_distance_m: float,
) -> None:
    if max_distance_m <= 0 or not nodes:
        return
    n = len(nodes)
    for i in range(n):
        lat_i, lng_i = nodes[i]
        for j in range(i + 1, n):
            lat_j, lng_j = nodes[j]
            dist = _haversine_m(lat_i, lng_i, lat_j, lng_j)
            if dist <= max_distance_m:
                adj_i = edges.setdefault(i, [])
                adj_j = edges.setdefault(j, [])
                if all(neighbor != j for neighbor, _ in adj_i):
                    adj_i.append((j, dist))
                if all(neighbor != i for neighbor, _ in adj_j):
                    adj_j.append((i, dist))


_ROAD_GRAPH_LOCK = threading.Lock()
_ROAD_GRAPH_CACHE: dict[str, object] = {"path": None, "mtime": None, "graph": None, "roads": None}


def _load_road_graph() -> tuple[RoadGraph | None, list[dict[str, object]] | None, str | None]:
    candidates = [
        _normalize_path(settings.ROADS_JSON_PATH),
        _normalize_path(settings.ROADS_GEOJSON_PATH),
        _normalize_path("scripts/roads.json"),
        _normalize_path("scripts/roads.geojson"),
    ]
    path, data, error = _load_json_from_candidates(candidates)
    if error is not None:
        return None, None, f"Erro ao ler {path}: {error}"
    if data is None or path is None:
        return None, None, "Arquivo de vias nao encontrado."
    try:
        mtime = path.stat().st_mtime
    except OSError:
        return None, None, "Falha ao ler arquivo de vias."

    with _ROAD_GRAPH_LOCK:
        if _ROAD_GRAPH_CACHE["path"] == path and _ROAD_GRAPH_CACHE["mtime"] == mtime:
            graph = _ROAD_GRAPH_CACHE.get("graph")
            roads = _ROAD_GRAPH_CACHE.get("roads")
            if isinstance(graph, RoadGraph):
                return graph, roads if isinstance(roads, list) else None, None
    road_entries = _extract_road_entries(data if isinstance(data, dict) else {})
    if not road_entries:
        return None, None, "Nenhuma via encontrada."

    snap_decimals = int(getattr(settings, "ROADS_SNAP_DECIMALS", 5))
    graph = _build_graph([entry["points"] for entry in road_entries], snap_decimals=snap_decimals)
    with _ROAD_GRAPH_LOCK:
        _ROAD_GRAPH_CACHE["path"] = path
        _ROAD_GRAPH_CACHE["mtime"] = mtime
        _ROAD_GRAPH_CACHE["graph"] = graph
        _ROAD_GRAPH_CACHE["roads"] = road_entries
    return graph, road_entries, None


class RoadsView(APIView):
    """
    Retorna o JSON de vias desenhadas manualmente (roads.json).
    """

    permission_classes = []
    authentication_classes = []

    def get(self, request):
        candidates = [
            _normalize_path(settings.ROADS_JSON_PATH),
            _normalize_path("scripts/roads.json"),
        ]
        path, data, error = _load_json_from_candidates(candidates)
        if error is not None:
            return Response({"detail": f"Erro ao ler {path}: {error}"}, status=500)
        if data is None:
            return Response({"detail": "Arquivo roads.json não encontrado."}, status=404)
        return Response(data)


class RoadsGeoJSONView(APIView):
    """
    Retorna o GeoJSON das vias desenhadas manualmente (roads.geojson).
    """

    permission_classes = []
    authentication_classes = []

    def get(self, request):
        candidates = [
            _normalize_path(settings.ROADS_GEOJSON_PATH),
            _normalize_path("scripts/roads.geojson"),
        ]
        path, data, error = _load_json_from_candidates(candidates)
        if error is not None:
            return Response({"detail": f"Erro ao ler {path}: {error}"}, status=500)
        if data is None:
            return Response({"detail": "Arquivo roads.geojson não encontrado."}, status=404)
        return Response(data)


def calculate_route_payload(start_lat: float, start_lng: float, end_lat: float, end_lng: float) -> dict[str, object]:
    """
    Shared helper that mirrors RouteView, returning the same payload so the SVG renderer
    can reuse the path trimming logic from the frontend.
    """
    fallback = [
        {"lat": _round6(start_lat), "lng": _round6(start_lng)},
        {"lat": _round6(end_lat), "lng": _round6(end_lng)},
    ]
    graph, roads, info = _load_road_graph()
    if graph is None:
        return {"source": "fallback", "route": fallback, "detail": info}

    start_id, start_dist = graph.nearest_node(start_lat, start_lng)
    end_id, end_dist = graph.nearest_node(end_lat, end_lng)
    if start_id is None or end_id is None:
        return {"source": "fallback", "route": fallback, "detail": "Vias insuficientes."}

    path, distance = graph.shortest_path(start_id, end_id)
    if not path:
        return {"source": "fallback", "route": fallback, "detail": "Sem caminho encontrado."}

    route = [{"lat": _round6(start_lat), "lng": _round6(start_lng)}]
    for node_id in path:
        lat, lng = graph.nodes[node_id]
        route.append({"lat": _round6(lat), "lng": _round6(lng)})
    route.append({"lat": _round6(end_lat), "lng": _round6(end_lng)})
    route = _dedup_points(route)
    payload: dict[str, object] = {
        "source": "roads",
        "route": route,
        "distance_m": round(distance, 2),
        "snap_start_m": None if start_dist is None else round(start_dist, 2),
        "snap_end_m": None if end_dist is None else round(end_dist, 2),
    }
    trace_distance = float(getattr(settings, "ROADS_TRACE_DISTANCE", 30.0))
    if roads and (start_dist is None or start_dist > trace_distance):
        start_road = _find_nearest_road_entry(roads, start_lat, start_lng)
        if start_road:
            payload["closest_road_start"] = start_road
    if roads and (end_dist is None or end_dist > trace_distance):
        end_road = _find_nearest_road_entry(roads, end_lat, end_lng)
        if end_road:
            payload["closest_road_end"] = end_road
    return payload


class RouteView(APIView):
    """
    Calcula a rota mais curta entre dois pontos usando as vias desenhadas.
    """

    permission_classes = []
    authentication_classes = []

    def get(self, request):
        try:
            start_lat = _float_from_params(request.query_params, "start_lat", "origem_lat", "lat_ini", "lat_inicial")
            start_lng = _float_from_params(request.query_params, "start_lng", "origem_lng", "lng_ini", "lng_inicial")
            end_lat = _float_from_params(request.query_params, "end_lat", "destino_lat", "lat_fim", "lat_final")
            end_lng = _float_from_params(request.query_params, "end_lng", "destino_lng", "lng_fim", "lng_final")
        except ValueError as exc:
            return Response({"detail": str(exc)}, status=400)

        if start_lat is None or start_lng is None or end_lat is None or end_lng is None:
            return Response({"detail": "Parâmetros start_lat, start_lng, end_lat e end_lng são obrigatórios."}, status=400)

        payload = calculate_route_payload(start_lat, start_lng, end_lat, end_lng)
        return Response(payload)
