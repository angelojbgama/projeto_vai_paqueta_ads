class MapTileConfig {
  /// URL template do mapa. Use {z}/{x}/{y} e, se necessário, {key} para a chave.
  /// Exemplo MapTiler: https://api.maptiler.com/maps/streets-v2/256/{z}/{x}/{y}.png?key={key}
  /// Se não definir nada, usa OSM padrão.
  static const _template = String.fromEnvironment(
    'MAP_TILE_URL',
    defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  );

  /// Chave opcional para provedores como MapTiler/Mapbox.
  static const apiKey = String.fromEnvironment('MAP_TILE_API_KEY', defaultValue: '');

  /// Define se devemos usar tiles locais (assets). Ajuste para true via:
  /// --dart-define=MAP_TILE_USE_ASSETS=true
  static const useAssets = String.fromEnvironment('MAP_TILE_USE_ASSETS', defaultValue: 'true') == 'true';

  /// Caminho padrão para tiles locais.
  static const assetsPrefix = 'assets/tiles/';
  static const assetsTemplate = '${assetsPrefix}{z}/{x}/{y}.png';

  /// Template que sempre aponta para tiles de rede (com chave, se existir).
  static String get networkTemplate {
    if (apiKey.isNotEmpty && _template.contains('{key}')) {
      return _template.replaceAll('{key}', apiKey);
    }
    return _template;
  }

  static String get urlTemplate {
    if (useAssets) return assetsTemplate;
    return networkTemplate;
  }
}
