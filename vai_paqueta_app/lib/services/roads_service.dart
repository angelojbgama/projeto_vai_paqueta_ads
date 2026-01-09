import 'package:dio/dio.dart';
import 'package:latlong2/latlong.dart';

import 'api_client.dart';

class RoadSegment {
  final int id;
  final String name;
  final String? color;
  final List<LatLng> points;

  const RoadSegment({
    required this.id,
    required this.name,
    required this.points,
    this.color,
  });
}

class RoadsService {
  RoadsService({Dio? dio}) : _dio = dio ?? ApiClient.client;

  final Dio _dio;
  static List<RoadSegment>? _cache;

  Future<List<RoadSegment>> fetchRoads({bool force = false}) async {
    if (!force && _cache != null) return _cache!;
    final roads = await _fetchRoads();
    _cache = roads;
    return roads;
  }

  Future<List<RoadSegment>> _fetchRoads() async {
    try {
      final resp = await _dio.get(
        '/geo/roads/',
        options: Options(validateStatus: (_) => true),
      );
      if (resp.statusCode == 200 && resp.data is Map<String, dynamic>) {
        return _parseRoadsJson(resp.data as Map<String, dynamic>);
      }
      final geo = await _dio.get(
        '/geo/roads/geojson/',
        options: Options(validateStatus: (_) => true),
      );
      if (geo.statusCode == 200 && geo.data is Map<String, dynamic>) {
        return _parseGeoJson(geo.data as Map<String, dynamic>);
      }
    } catch (_) {
      return const <RoadSegment>[];
    }
    return const <RoadSegment>[];
  }

  List<RoadSegment> _parseRoadsJson(Map<String, dynamic> data) {
    final rawRoads = data['roads'];
    if (rawRoads is! List) return const <RoadSegment>[];
    final roads = <RoadSegment>[];
    for (final raw in rawRoads) {
      if (raw is! Map) continue;
      final pointsRaw = raw['points'];
      if (pointsRaw is! List) continue;
      final points = <LatLng>[];
      for (final point in pointsRaw) {
        if (point is! Map) continue;
        final lat = _asDouble(point['lat']);
        final lng = _asDouble(point['lng']);
        if (lat == null || lng == null) continue;
        points.add(LatLng(lat, lng));
      }
      if (points.length < 2) continue;
      final id = _asInt(raw['id'], fallback: roads.length + 1);
      final name = (raw['name'] ?? 'Road $id').toString();
      final color = raw['color']?.toString();
      roads.add(RoadSegment(id: id, name: name, points: points, color: color));
    }
    return roads;
  }

  List<RoadSegment> _parseGeoJson(Map<String, dynamic> data) {
    if (data['type'] != 'FeatureCollection') return const <RoadSegment>[];
    final features = data['features'];
    if (features is! List) return const <RoadSegment>[];
    final roads = <RoadSegment>[];
    for (final feature in features) {
      if (feature is! Map) continue;
      final geometry = feature['geometry'];
      if (geometry is! Map || geometry['type'] != 'LineString') continue;
      final coords = geometry['coordinates'];
      if (coords is! List) continue;
      final points = <LatLng>[];
      for (final coord in coords) {
        if (coord is! List || coord.length < 2) continue;
        final lng = _asDouble(coord[0]);
        final lat = _asDouble(coord[1]);
        if (lat == null || lng == null) continue;
        points.add(LatLng(lat, lng));
      }
      if (points.length < 2) continue;
      final props = feature['properties'];
      final id = _asInt(props is Map ? props['id'] : null, fallback: roads.length + 1);
      final name = props is Map && props['name'] != null ? props['name'].toString() : 'Road $id';
      final color = props is Map ? props['color']?.toString() : null;
      roads.add(RoadSegment(id: id, name: name, points: points, color: color));
    }
    return roads;
  }

  int _asInt(dynamic value, {required int fallback}) {
    if (value == null) return fallback;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString()) ?? fallback;
  }

  double? _asDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }
}
