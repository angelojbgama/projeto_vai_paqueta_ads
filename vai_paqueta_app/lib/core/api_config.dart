class ApiConfig {
  /// Base da API. Pode ser sobrescrita em build com:
  /// flutter run --dart-define=API_BASE_URL=http://192.168.x.x:8000/api
  static const baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://ensemble-data-doors-assuming.trycloudflare.com/api/',
  );
}
