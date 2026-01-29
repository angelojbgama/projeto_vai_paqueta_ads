import 'package:dio/dio.dart';
import 'package:latlong2/latlong.dart';

import 'api_client.dart';

class RouteService {
  RouteService({Dio? dio}) : _dio = dio ?? ApiClient.client;

  final Dio _dio;

  Future<List<LatLng>> fetchRoute({
    required LatLng start,
    required LatLng end,
  }) async {
    try {
      final resp = await _dio.get(
        '/geo/route/',
        queryParameters: {
          'start_lat': start.latitude,
          'start_lng': start.longitude,
          'end_lat': end.latitude,
          'end_lng': end.longitude,
        },
        options: Options(validateStatus: (_) => true),
      );
      if (resp.statusCode == 200 && resp.data is Map<String, dynamic>) {
        final payload = resp.data as Map<String, dynamic>;
        final route = _parseRoute(payload);
        if (route.length >= 2) return route;
        var fallback = _parseClosestRoad(payload['closest_road_start']);
        if (fallback.isEmpty) {
          fallback = _parseClosestRoad(payload['closest_road_end']);
        }
        if (fallback.length >= 2) return fallback;
      }
    } catch (_) {
      // fallback abaixo
    }
    return [start, end];
  }

  List<LatLng> _parseRoute(Map<String, dynamic> data) {
    final raw = data['route'];
    if (raw is! List) return const <LatLng>[];
    final points = <LatLng>[];
    for (final item in raw) {
      if (item is Map) {
        final lat = _asDouble(item['lat']);
        final lng = _asDouble(item['lng']);
        if (lat == null || lng == null) continue;
        points.add(LatLng(lat, lng));
        continue;
      }
      if (item is List && item.length >= 2) {
        final lat = _asDouble(item[0]);
        final lng = _asDouble(item[1]);
        if (lat == null || lng == null) continue;
        points.add(LatLng(lat, lng));
      }
    }
    return points;
  }

  List<LatLng> _parseClosestRoad(dynamic value) {
    if (value is! Map) return const <LatLng>[];
    final rawPoints = value['points'];
    if (rawPoints is! List) return const <LatLng>[];
    final points = <LatLng>[];
    for (final item in rawPoints) {
      if (item is! Map) continue;
      final lat = _asDouble(item['lat']);
      final lng = _asDouble(item['lng']);
      if (lat == null || lng == null) continue;
      points.add(LatLng(lat, lng));
    }
    return points;
  }

  double? _asDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }
}
