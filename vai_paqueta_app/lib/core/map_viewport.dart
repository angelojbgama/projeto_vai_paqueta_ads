import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:latlong2/latlong.dart';

import 'map_config.dart';

class MapViewport {
  static LatLng defaultCenter() {
    return LatLng(MapTileConfig.defaultCenterLat, MapTileConfig.defaultCenterLng);
  }

  static List<LatLng> collectPins(Iterable<LatLng?> pins) {
    return pins.whereType<LatLng>().toList();
  }

  static LatLng centerForPins(List<LatLng> pins) {
    if (pins.isEmpty) return defaultCenter();
    var minLat = pins.first.latitude;
    var maxLat = pins.first.latitude;
    var minLng = pins.first.longitude;
    var maxLng = pins.first.longitude;
    for (final p in pins.skip(1)) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    return LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);
  }

  static LatLng clampCenter(LatLng center, LatLngBounds bounds) {
    return LatLng(
      center.latitude.clamp(bounds.south, bounds.north),
      center.longitude.clamp(bounds.west, bounds.east),
    );
  }

  static LatLngBounds? boundsForPins(List<LatLng> pins) {
    if (pins.length < 2) return null;
    return LatLngBounds.fromPoints(pins);
  }

  static List<LatLng> clampPinsToBounds(List<LatLng> pins, LatLngBounds bounds) {
    if (pins.isEmpty) return pins;
    return pins.map((p) => clampCenter(p, bounds)).toList();
  }

  static double zoomForPins(
    List<LatLng> pins, {
    double? minZoom,
    double? maxZoom,
    double? fallbackZoom,
  }) {
    final minZ = minZoom ?? MapTileConfig.displayMinZoom.toDouble();
    final maxZ = maxZoom ?? MapTileConfig.displayMaxZoom.toDouble();
    final fallback = fallbackZoom ?? MapTileConfig.assetsSampleZoom.toDouble();
    if (pins.length <= 1) {
      return _clampZoom(fallback, minZ, maxZ);
    }

    var minLat = pins.first.latitude;
    var maxLat = pins.first.latitude;
    var minLng = pins.first.longitude;
    var maxLng = pins.first.longitude;
    for (final p in pins.skip(1)) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final span = math.max((maxLat - minLat).abs(), (maxLng - minLng).abs());

    double zoom;
    if (span > 0.30) {
      zoom = 12;
    } else if (span > 0.15) {
      zoom = 13;
    } else if (span > 0.08) {
      zoom = 14;
    } else if (span > 0.04) {
      zoom = 15;
    } else if (span > 0.02) {
      zoom = 16;
    } else if (span > 0.01) {
      zoom = 17;
    } else {
      zoom = 18;
    }
    return _clampZoom(zoom, minZ, maxZ);
  }

  static double _clampZoom(double zoom, double minZoom, double maxZoom) {
    if (zoom < minZoom) return minZoom;
    if (zoom > maxZoom) return maxZoom;
    return zoom;
  }

  static String signatureForPins(List<LatLng> pins, {int precision = 5}) {
    if (pins.isEmpty) return 'none';
    return pins
        .map(
          (p) => '${p.latitude.toStringAsFixed(precision)},${p.longitude.toStringAsFixed(precision)}',
        )
        .join('|');
  }
}
