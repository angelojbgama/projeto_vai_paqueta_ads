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

  Future<Map<String, dynamic>?> aceitarCorrida({required int corridaId, required int motoristaId}) async {
    final resp = await _dio.post('/corridas/$corridaId/aceitar/', data: {'motorista_id': motoristaId});
    return resp.data is Map<String, dynamic> ? resp.data as Map<String, dynamic> : null;
  }

  Future<Map<String, dynamic>?> iniciarCorrida({required int corridaId, required int motoristaId}) async {
    final resp = await _dio.post('/corridas/$corridaId/iniciar/', data: {'motorista_id': motoristaId});
    return resp.data is Map<String, dynamic> ? resp.data as Map<String, dynamic> : null;
  }

  Future<Map<String, dynamic>?> finalizarCorrida({required int corridaId, required int motoristaId}) async {
    final resp = await _dio.post('/corridas/$corridaId/finalizar/', data: {'motorista_id': motoristaId});
    return resp.data is Map<String, dynamic> ? resp.data as Map<String, dynamic> : null;
  }

  Future<void> cancelarCorrida({required int corridaId, int? perfilId}) async {
    await _dio.post('/corridas/$corridaId/cancelar/', data: {
      if (perfilId != null) 'perfil_id': perfilId,
    });
  }

  Future<void> reatribuirCorrida(int corridaId, {int? excluirMotoristaId}) async {
    await _dio.post('/corridas/$corridaId/reatribuir/', data: {
      if (excluirMotoristaId != null) 'excluir_motorista_id': excluirMotoristaId,
    });
  }
}
