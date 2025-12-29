class ApiConfig {
  /// Base da API. Pode ser sobrescrita em build com:
  /// flutter run --dart-define=API_BASE_URL=http://192.168.x.x:8000/api
  static const baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://vaipaqueta.com.br/api/',
  );

  /// Base do servidor sem o sufixo /api (para acessar assets estáticos).
  static String get baseOrigin {
    var url = baseUrl.trim();
    if (url.isEmpty) return url;
    url = url.replaceFirst(RegExp(r'/api/?$'), '');
    return url.replaceFirst(RegExp(r'/$'), '');
  }
}
