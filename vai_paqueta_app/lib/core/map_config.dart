import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:latlong2/latlong.dart';

import 'api_config.dart';

class MapTileConfig {
  /// URL template do mapa. Use {z}/{x}/{y} e, se necessário, {key} para a chave.
  /// Exemplo MapTiler: https://api.maptiler.com/maps/streets-v2/256/{z}/{x}/{y}.png?key={key}
  /// Se não definir nada, usa os tiles do backend.
  static const _envTemplate = String.fromEnvironment(
    'MAP_TILE_URL',
    defaultValue: '',
  );

  /// Chave opcional para provedores como MapTiler/Mapbox.
  static const apiKey = String.fromEnvironment('MAP_TILE_API_KEY', defaultValue: '');

  /// Define se devemos usar tiles locais (assets). Ajuste para true via:
  /// --dart-define=MAP_TILE_USE_ASSETS=true
  static const useAssets = String.fromEnvironment('MAP_TILE_USE_ASSETS', defaultValue: 'false') == 'true';
  static const allowNetworkFallback =
      String.fromEnvironment('MAP_TILE_ALLOW_FALLBACK', defaultValue: 'true') == 'true';

  /// Caminho padrão para tiles locais.
  static const assetsPrefix = 'assets/tiles/';
  static const assetsTemplate = '$assetsPrefix{z}/{x}/{y}.png';
  static const assetsMinZoom = int.fromEnvironment('MAP_TILE_MIN_ZOOM', defaultValue: 12);
  static const assetsMaxZoom = int.fromEnvironment('MAP_TILE_MAX_ZOOM', defaultValue: 19);
  static const _displayMinZoomEnv = int.fromEnvironment('MAP_TILE_DISPLAY_MIN_ZOOM', defaultValue: -1);
  static const _displayMaxZoomEnv = int.fromEnvironment('MAP_TILE_DISPLAY_MAX_ZOOM', defaultValue: -1);
  static const assetsSampleZoom = int.fromEnvironment('MAP_TILE_SAMPLE_ZOOM', defaultValue: 16);
  static const _tilesSouthEnv = String.fromEnvironment('MAP_TILE_SOUTH', defaultValue: '');
  static const _tilesWestEnv = String.fromEnvironment('MAP_TILE_WEST', defaultValue: '');
  static const _tilesNorthEnv = String.fromEnvironment('MAP_TILE_NORTH', defaultValue: '');
  static const _tilesEastEnv = String.fromEnvironment('MAP_TILE_EAST', defaultValue: '');
  static final double tilesSouth = _doubleFromEnv(_tilesSouthEnv, -22.774914);
  static final double tilesWest = _doubleFromEnv(_tilesWestEnv, -43.133396);
  static final double tilesNorth = _doubleFromEnv(_tilesNorthEnv, -22.741042);
  static final double tilesEast = _doubleFromEnv(_tilesEastEnv, -43.090621);
  static const defaultCenterLat = -22.763;
  static const defaultCenterLng = -43.106;

  static int get displayMinZoom {
    if (_displayMinZoomEnv >= 0) return _displayMinZoomEnv;
    return math.max(0, assetsMinZoom - 2);
  }

  static int get displayMaxZoom {
    if (_displayMaxZoomEnv >= 0) return _displayMaxZoomEnv;
    return math.min(24, assetsMaxZoom + 2);
  }

  static LatLngBounds get tilesBounds {
    return LatLngBounds(
      LatLng(tilesSouth, tilesWest),
      LatLng(tilesNorth, tilesEast),
    );
  }

  static double _doubleFromEnv(String raw, double fallback) {
    final value = raw.trim();
    if (value.isEmpty) return fallback;
    final normalized = value.replaceAll(',', '.');
    return double.tryParse(normalized) ?? fallback;
  }

  /// Template que sempre aponta para tiles de rede (com chave, se existir).
  static String get networkTemplate {
    final template = _envTemplate.isNotEmpty
        ? _envTemplate
        : '${ApiConfig.baseOrigin}/static/landing/assets/tiles/{z}/{x}/{y}.png';
    if (apiKey.isNotEmpty && template.contains('{key}')) {
      return template.replaceAll('{key}', apiKey);
    }
    return template;
  }

  static String get urlTemplate {
    if (useAssets) return assetsTemplate;
    return networkTemplate;
  }

  static String assetPathForLatLng({
    required double lat,
    required double lng,
    int zoom = assetsSampleZoom,
  }) {
    final n = 1 << zoom;
    final x = ((lng + 180.0) / 360.0 * n).floor();
    final latRad = lat * math.pi / 180.0;
    final y = ((1.0 - math.log(math.tan(latRad) + (1 / math.cos(latRad))) / math.pi) / 2.0 * n).floor();
    final safeX = x.clamp(0, n - 1);
    final safeY = y.clamp(0, n - 1);
    return '$assetsPrefix$zoom/$safeX/$safeY.png';
  }
}
