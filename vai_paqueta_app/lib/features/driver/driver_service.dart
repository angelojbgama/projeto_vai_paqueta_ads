import 'package:dio/dio.dart';

import '../../services/api_client.dart';

class DriverService {
  final Dio _dio = ApiClient.client;

  Future<void> enviarPing({
    required int perfilId,
    required double latitude,
    required double longitude,
    double? precisao,
  }) async {
    await _dio.post('/pings/', data: {
      'perfil': perfilId,
      'latitude': latitude,
      'longitude': longitude,
      'precisao_m': precisao,
    });
  }

  Future<Map<String, dynamic>?> corridaAtribuida(int perfilId) async {
    final resp = await _dio.get(
      '/corridas/para_motorista/$perfilId/',
      options: Options(validateStatus: (_) => true),
    );
    if (resp.statusCode == 404) return null;
    if (resp.statusCode == 200 && resp.data is Map<String, dynamic>) {
      final data = resp.data as Map<String, dynamic>;
      if (data.isEmpty) return null;
      return data;
    }
    return null;
  }
}
