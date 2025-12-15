import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

class OfflineGeoResult {
  final double lat;
  final double lng;
  final String endereco;

  const OfflineGeoResult({
    required this.lat,
    required this.lng,
    required this.endereco,
  });
}

/// Carrega e consulta endereços locais vindos de assets/addresses.json.
class OfflineGeoStore {
  OfflineGeoStore({this.assetPath = 'assets/addresses.json'});

  final String assetPath;

  List<_OfflineAddress>? _cache;
  final Distance _distance = const Distance();

  Future<List<_OfflineAddress>> _loadAddresses() async {
    if (_cache != null) return _cache!;
    try {
      final content = await rootBundle.loadString(assetPath);
      final data = json.decode(content) as List<dynamic>;
      _cache = data
          .map(
            (e) => _OfflineAddress(
              street: (e['street']?.toString().trim()) ?? '',
              housenumber: e['housenumber'] != null ? e['housenumber'].toString().trim() : null,
              lat: (e['lat'] as num).toDouble(),
              lng: (e['lng'] as num).toDouble(),
            ),
          )
          .where((a) => a.street.isNotEmpty)
          .toList();
    } catch (_) {
      _cache = <_OfflineAddress>[];
    }
    return _cache!;
  }

  Future<OfflineGeoResult?> reverse(
    double lat,
    double lng, {
    double maxDistanceMeters = 250,
  }) async {
    final data = await _loadAddresses();
    if (data.isEmpty) return null;

    final origin = LatLng(lat, lng);
    _OfflineAddress? best;
    double? bestDistance;

    for (final addr in data) {
      final dist = _distance(origin, LatLng(addr.lat, addr.lng));
      if (bestDistance == null || dist < bestDistance) {
        best = addr;
        bestDistance = dist;
      }
    }

    if (best == null) return null;
    if (maxDistanceMeters > 0 && (bestDistance ?? double.infinity) > maxDistanceMeters) {
      return null;
    }
    return OfflineGeoResult(
      lat: best.lat,
      lng: best.lng,
      endereco: best.displayName,
    );
  }

  Future<OfflineGeoResult?> forward(String query) async {
    final data = await _loadAddresses();
    if (data.isEmpty) return null;
    final q = _normalize(query);
    if (q.isEmpty) return null;

    for (final addr in data) {
      if (addr.matches(q)) {
        return OfflineGeoResult(
          lat: addr.lat,
          lng: addr.lng,
          endereco: addr.displayName,
        );
      }
    }
    return null;
  }

  Future<List<OfflineGeoResult>> searchNearby({
    required String query,
    required double lat,
    required double lng,
    double radiusKm = 5,
    int limit = 5,
  }) async {
    final data = await _loadAddresses();
    if (data.isEmpty) return const <OfflineGeoResult>[];

    final q = _normalize(query);
    if (q.isEmpty) return const <OfflineGeoResult>[];

    final origin = LatLng(lat, lng);
    final results = <_Match>[];

    for (final addr in data) {
      if (!addr.matches(q)) continue;
      final distKm = _distance(origin, LatLng(addr.lat, addr.lng)) / 1000.0;
      if (radiusKm.isFinite && distKm > radiusKm) continue;
      results.add(_Match(addr: addr, distanceKm: distKm));
    }

    results.sort((a, b) {
      final cmp = a.distanceKm.compareTo(b.distanceKm);
      if (cmp != 0) return cmp;
      return a.addr.displayName.compareTo(b.addr.displayName);
    });

    return results
        .take(limit)
        .map(
          (m) => OfflineGeoResult(
            lat: m.addr.lat,
            lng: m.addr.lng,
            endereco: m.addr.displayName,
          ),
        )
        .toList();
  }
}

class _Match {
  final _OfflineAddress addr;
  final double distanceKm;

  const _Match({required this.addr, required this.distanceKm});
}

class _OfflineAddress {
  final String street;
  final String? housenumber;
  final double lat;
  final double lng;
  final String _searchText;

  _OfflineAddress({
    required this.street,
    required this.housenumber,
    required this.lat,
    required this.lng,
  }) : _searchText = _normalize('$street ${housenumber ?? ''}');

  String get displayName {
    if (housenumber != null && housenumber!.isNotEmpty) {
      return '$street, $housenumber';
    }
    return street;
  }

  bool matches(String normalizedQuery) => _searchText.contains(normalizedQuery);
}

String _normalize(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9\\u00C0-\\u017F\\s]+'), ' ')
      .replaceAll(RegExp('\\s+'), ' ')
      .trim();
}
