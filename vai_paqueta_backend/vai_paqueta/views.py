import base64
import json
import math
from pathlib import Path

from django.conf import settings
from django.contrib.auth.decorators import user_passes_test
from django.http import HttpResponse, JsonResponse
from django.shortcuts import render
from django.views.decorators.csrf import csrf_exempt, ensure_csrf_cookie

from corridas.models import Corrida, Perfil
from geo import views as geo_views


def landing(request):
    ecotaxistas_count = Perfil.objects.filter(tipo="ecotaxista").count()
    passageiros_count = Perfil.objects.filter(tipo="passageiro").count()
    corridas_concluidas_count = Corrida.objects.filter(status="concluida").count()
    return render(
        request,
        "landing/index.html",
        {
            "ecotaxistas_count": ecotaxistas_count,
            "passageiros_count": passageiros_count,
            "corridas_concluidas_count": corridas_concluidas_count,
        },
    )


@ensure_csrf_cookie
def webapp(request):
    return render(request, "webapp/index.html")


def privacy(request):
    return render(request, "landing/privacy.html")


def tutorial(request):
    return render(request, "landing/tutorial.html")


@ensure_csrf_cookie
@user_passes_test(lambda u: u.is_superuser, login_url="/admin/login/?next=/relatorio/lab/", redirect_field_name=None)
def relatorio_lab(request):
    """
    Laboratório local para montar corridas fictícias sem gravar no banco.
    Permite clicar no mapa para origem/destino, visualizar o traçado de rota e exportar CSV.
    """
    addresses = []
    address_path = Path(settings.BASE_DIR) / "addresses.json"
    if address_path.exists():
        try:
            addresses = json.loads(address_path.read_text(encoding="utf-8"))
        except Exception:
            addresses = []
    return render(
        request,
        "relatorios/lab.html",
        {
            "addresses_json": json.dumps(addresses, ensure_ascii=False),
        },
    )


@csrf_exempt
@user_passes_test(lambda u: u.is_superuser, login_url="/admin/login/?next=/relatorio/lab/", redirect_field_name=None)
def relatorio_lab_svg(request):
    """
    Gera o SVG do trajeto usando o mesmo estilo do relatorio_corridas, sem gravar no banco.
    Espera um JSON com `route` (lista de [lat,lng]) ou start/end para reconstituir a rota.
    """
    if request.method != "POST":
        return JsonResponse({"detail": "Method not allowed"}, status=405)
    try:
        payload = json.loads(request.body.decode("utf-8"))
    except Exception:
        return JsonResponse({"detail": "Invalid JSON"}, status=400)

    route = payload.get("route") or []
    start = payload.get("start")
    end = payload.get("end")

    def _coord(val):
        if not isinstance(val, (list, tuple)) or len(val) < 2:
            return None
        try:
            return float(val[0]), float(val[1])
        except (TypeError, ValueError):
            return None

    if not route and start and end:
        start_coord = _coord([start.get("lat"), start.get("lng")])
        end_coord = _coord([end.get("lat"), end.get("lng")])
        if start_coord and end_coord:
            data = geo_views.calculate_route_payload(start_coord[0], start_coord[1], end_coord[0], end_coord[1])
            route = geo_views._dedup_points(
                [{"lat": p.get("lat"), "lng": p.get("lng")} for p in (data.get("route") or []) if isinstance(p, dict)]
            )
    points = []
    for pt in route:
        if isinstance(pt, (list, tuple)) and len(pt) >= 2:
            try:
                points.append((float(pt[0]), float(pt[1])))
            except (TypeError, ValueError):
                continue
        elif isinstance(pt, dict):
            try:
                points.append((float(pt.get("lat")), float(pt.get("lng"))))
            except (TypeError, ValueError):
                continue
    if len(points) < 2:
        return JsonResponse({"detail": "Rota insuficiente"}, status=400)

    try:
        svg = _build_svg(points)
    except Exception as exc:  # noqa: BLE001
        return JsonResponse({"detail": f"Erro ao gerar SVG: {exc}"}, status=500)
    return HttpResponse(svg, content_type="image/svg+xml")


def _build_svg(route_points):
    tile_root = Path(settings.BASE_DIR) / "static" / "landing" / "assets" / "tiles"
    tile_zoom = 16

    def latlng_to_pixel(lat, lng, zoom):
        lat = max(min(lat, 85.05112878), -85.05112878)
        n = 2**zoom
        x = (lng + 180.0) / 360.0
        lat_rad = math.radians(lat)
        y = (1 - math.log(math.tan(lat_rad) + 1 / math.cos(lat_rad)) / math.pi) / 2
        return x * n * 256, y * n * 256

    pixels = [latlng_to_pixel(lat, lng, tile_zoom) for lat, lng in route_points]
    px_vals = [p[0] for p in pixels]
    py_vals = [p[1] for p in pixels]
    n_tiles = 2**tile_zoom
    margin_tiles = 1
    tile_min_x = max(0, int(math.floor(min(px_vals) / 256)) - margin_tiles)
    tile_max_x = min(n_tiles - 1, int(math.floor(max(px_vals) / 256)) + margin_tiles)
    tile_min_y = max(0, int(math.floor(min(py_vals) / 256)) - margin_tiles)
    tile_max_y = min(n_tiles - 1, int(math.floor(max(py_vals) / 256)) + margin_tiles)

    width = (tile_max_x - tile_min_x + 1) * 256
    height = (tile_max_y - tile_min_y + 1) * 256
    offset_x = tile_min_x * 256
    offset_y = tile_min_y * 256

    coords = [(px - offset_x, py - offset_y) for px, py in pixels]
    path_data = " ".join(f"{x:.2f},{y:.2f}" for x, y in coords)

    images_svg = []
    if tile_root.exists():
        for tile_x in range(tile_min_x, tile_max_x + 1):
            for tile_y in range(tile_min_y, tile_max_y + 1):
                tile_path = tile_root / str(tile_zoom) / str(tile_x) / f"{tile_y}.png"
                if not tile_path.exists():
                    continue
                try:
                    data = tile_path.read_bytes()
                except OSError:
                    continue
                encoded = base64.b64encode(data).decode("ascii")
                href = f"data:image/png;base64,{encoded}"
                x = (tile_x - tile_min_x) * 256
                y = (tile_y - tile_min_y) * 256
                images_svg.append(
                    f'<image href="{href}" x="{x}" y="{y}" width="256" height="256" preserveAspectRatio="none" />'
                )

    svg_parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="#f8fafc" />',
    ]
    svg_parts.extend(images_svg)

    _, roads, _ = geo_views._load_road_graph()
    road_list = roads if isinstance(roads, list) else []
    if road_list:
        for road in road_list:
            pts = road.get("points") or []
            pts_px = []
            for lat, lng in pts:
                px, py = latlng_to_pixel(float(lat), float(lng), tile_zoom)
                pts_px.append((px - offset_x, py - offset_y))
            if len(pts_px) < 2:
                continue
            if not any(0 <= px <= width and 0 <= py <= height for px, py in pts_px):
                continue
            path = " ".join(f"{x:.2f},{y:.2f}" for x, y in pts_px)
            color = road.get("color") or "#94a3b8"
            svg_parts.append(
                f'<polyline points="{path}" fill="none" stroke="{color}" stroke-width="1" stroke-linejoin="round" stroke-linecap="round" stroke-opacity="0.5" />'
            )

    svg_parts.append(
        f'<polyline points="{path_data}" fill="none" stroke="#0f172a" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" />'
    )
    svg_parts.append(
        f'<circle cx="{coords[0][0]:.2f}" cy="{coords[0][1]:.2f}" r="5" fill="#22c55e" stroke="#14532d" />'
    )
    svg_parts.append(
        f'<circle cx="{coords[-1][0]:.2f}" cy="{coords[-1][1]:.2f}" r="5" fill="#ef4444" stroke="#7f1d1d" />'
    )
    svg_parts.append("</svg>")
    return "\n".join(svg_parts)
