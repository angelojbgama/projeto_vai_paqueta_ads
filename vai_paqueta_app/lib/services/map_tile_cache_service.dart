import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';

class MapTileCacheService {
  static const String _storeName = 'vai_paqueta_tiles';
  static final FMTCStore _store = FMTCStore(_storeName);
  static TileProvider? _cachedProvider;
  static Future<void>? _initFuture;

  static Future<void> initialize() {
    _initFuture ??= _initInternal();
    return _initFuture!;
  }

  static Future<void> _initInternal() async {
    if (kIsWeb) return;
    try {
      await FMTCObjectBoxBackend().initialise();
      final ready = await _store.manage.ready;
      if (!ready) {
        await _store.manage.create();
      }
      _cachedProvider = _store.getTileProvider();
    } catch (_) {
      _cachedProvider = null;
    }
  }

  static TileProvider networkTileProvider() {
    return _cachedProvider ?? NetworkTileProvider();
  }
}
