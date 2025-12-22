import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthStorage {
  static const _accessKey = 'auth_access';
  static const _refreshKey = 'auth_refresh';
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  static Future<void> saveTokens({required String access, required String refresh}) async {
    await _storage.write(key: _accessKey, value: access);
    await _storage.write(key: _refreshKey, value: refresh);
  }

  static Future<String?> getAccessToken() async {
    return _storage.read(key: _accessKey);
  }

  static Future<String?> getRefreshToken() async {
    return _storage.read(key: _refreshKey);
  }

  static Future<void> clearTokens() async {
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
  }
}
