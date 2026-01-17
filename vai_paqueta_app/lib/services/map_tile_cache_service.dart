import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';

import '../core/map_config.dart';

class MapTileCacheService {
  static const String _storeName = 'vai_paqueta_tiles';
  static final FMTCStore _store = FMTCStore(_storeName);
  static Future<void>? _initFuture;
  static Future<void>? _prefetchFuture;
  static bool _ready = false;

  static Future<void> initialize() {
    _initFuture ??= _initInternal();
    return _initFuture!;
  }

  static Future<void> _initInternal() async {
    if (kIsWeb) return;
    try {
      await FMTCObjectBoxBackend().initialise();
      FMTCTileProviderSettings(
        behavior: CacheBehavior.cacheFirst,
        cachedValidDuration: Duration.zero,
        fallbackToAlternativeStore: true,
        maxStoreLength: 0,
        errorHandler: (exception) {
          if (kDebugMode) {
            debugPrint('FMTC tile error ${exception.type.name}: ${exception.networkUrl}');
            if (exception.originalError != null) {
              debugPrint('FMTC tile error detail: ${exception.originalError}');
            }
            if (exception.response != null) {
              debugPrint('FMTC tile status: ${exception.response!.statusCode}');
            }
          }
        },
      );
      final ready = await _store.manage.ready;
      if (!ready) {
        await _store.manage.create();
      }
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  static TileProvider networkTileProvider() {
    if (!_ready) return NetworkTileProvider();
    return _store.getTileProvider();
  }

  static Future<void> prefetchDefault() {
    if (kIsWeb || MapTileConfig.useAssets) return Future.value();
    _prefetchFuture ??= _prefetchInternal();
    return _prefetchFuture!;
  }

  static Future<void> _prefetchInternal() async {
    await initialize();
    if (!_ready) return;
    try {
      final ready = await _store.manage.ready;
      if (!ready) return;
      final length = await _store.stats.length;
      if (length > 0) return;
      final region = RectangleRegion(MapTileConfig.tilesBounds).toDownloadable(
        minZoom: MapTileConfig.assetsMinZoom,
        maxZoom: MapTileConfig.assetsMaxZoom,
        options: TileLayer(
          urlTemplate: MapTileConfig.networkTemplate,
        ),
      );
      await _store.download
          .startForeground(
            region: region,
            parallelThreads: 4,
            maxBufferLength: 200,
            skipExistingTiles: true,
            skipSeaTiles: true,
          )
          .drain();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('FMTC prefetch error: $e');
      }
    }
  }
}
