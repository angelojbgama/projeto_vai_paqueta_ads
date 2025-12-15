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
  final Dio _dio = ApiClient.client;
  final OfflineGeoStore _offline = OfflineGeoStore();

  Future<GeoResult> forward(String query) async {
    final offline = await _offline.forward(query);
    if (offline != null) {
      return GeoResult(lat: offline.lat, lng: offline.lng, endereco: offline.endereco);
    }

    final resp = await _dio.get(
      '/geo/forward/',
      queryParameters: {'q': query},
    );
    final data = resp.data as Map<String, dynamic>;
    return GeoResult(
      lat: (data['latitude'] as num).toDouble(),
      lng: (data['longitude'] as num).toDouble(),
      endereco: data['endereco'] as String? ?? query,
    );
  }

  Future<GeoResult> reverse(double lat, double lng) async {
    final offline = await _offline.reverse(lat, lng);
    if (offline != null) {
      return GeoResult(lat: offline.lat, lng: offline.lng, endereco: offline.endereco);
    }

    final resp = await _dio.get(
      '/geo/reverse/',
      queryParameters: {'lat': lat, 'lng': lng},
    );
    final data = resp.data as Map<String, dynamic>;
    return GeoResult(
      lat: lat,
      lng: lng,
      endereco: data['endereco'] as String? ?? '',
    );
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
    if (offlineResults.length >= limit) {
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

    try {
      final remaining = limit - offlineResults.length;
      final resp = await _dio.get(
        '/geo/search/',
        queryParameters: {
          'q': query,
          'lat': lat,
          'lng': lng,
          'radius_km': radiusKm,
          'limit': remaining,
        },
        options: Options(validateStatus: (_) => true),
      );
      final extra = <GeoResult>[];
      if (resp.statusCode == 200) {
        final data = resp.data as List<dynamic>;
        extra.addAll(
          data.map(
            (e) => GeoResult(
              lat: (e['latitude'] as num).toDouble(),
              lng: (e['longitude'] as num).toDouble(),
              endereco: e['endereco'] as String? ?? '',
            ),
          ),
        );
      }
      final offlineConverted = offlineResults
          .map(
            (e) => GeoResult(
              lat: e.lat,
              lng: e.lng,
              endereco: e.endereco,
            ),
          )
          .toList();
      return [...offlineConverted, ...extra].take(limit).toList();
    } catch (_) {
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
}
