import 'package:dio/dio.dart';

import 'api_client.dart';
import 'offline_geo_store.dart';

class GeoResult {
  final double lat;
  final double lng;
  final String endereco;

  GeoResult({
    required this.lat,
    required this.lng,
    required this.endereco,
  });
}

class GeoService {
  final OfflineGeoStore _offline = OfflineGeoStore();

  Future<bool> isInsideServiceArea(double lat, double lng) async {
    try {
      await ApiClient.client.get('geo/reverse/', queryParameters: {'lat': lat, 'lng': lng});
      return true;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        final data = e.response?.data;
        if (data is Map && data['detail'] == 'Fora da area atendida.') {
          return false;
        }
      }
      return true; // Assume it's inside if there's another error
    }
  }

  Future<GeoResult> forward(String query) async {
    final offline = await _offline.forward(query);
    if (offline != null) {
      return GeoResult(lat: offline.lat, lng: offline.lng, endereco: offline.endereco);
    }
    throw Exception('Endereco nao encontrado nos enderecos disponiveis.');
  }

  Future<GeoResult> reverse(double lat, double lng) async {
    final offline = await _offline.reverse(lat, lng);
    if (offline != null) {
      return GeoResult(lat: offline.lat, lng: offline.lng, endereco: offline.endereco);
    }
    throw Exception('Endereco nao encontrado nos enderecos disponiveis.');
  }

  Future<List<GeoResult>> searchNearby({
    required String query,
    required double lat,
    required double lng,
    double radiusKm = 5,
    int limit = 5,
  }) async {
    final offlineResults = await _offline.searchNearby(
      query: query,
      lat: lat,
      lng: lng,
      radiusKm: radiusKm,
      limit: limit,
    );
    return offlineResults
        .map(
          (e) => GeoResult(
            lat: e.lat,
            lng: e.lng,
            endereco: e.endereco,
          ),
        )
        .toList();
  }
}
