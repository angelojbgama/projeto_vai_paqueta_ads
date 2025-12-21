import math

from rest_framework.response import Response
from rest_framework.views import APIView


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
