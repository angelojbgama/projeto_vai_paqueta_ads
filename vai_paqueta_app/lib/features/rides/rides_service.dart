import 'package:dio/dio.dart';

import '../../services/api_client.dart';

class CorridaResumo {
  final int id;
  final String status;
  final double? origemLat;
  final double? origemLng;
  final double? destinoLat;
  final double? destinoLng;

  CorridaResumo({
    required this.id,
    required this.status,
    this.origemLat,
    this.origemLng,
    this.destinoLat,
    this.destinoLng,
  });

  factory CorridaResumo.fromJson(Map<String, dynamic> json) {
    double? _d(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v);
      return null;
    }
    return CorridaResumo(
      id: json['id'] as int,
      status: json['status'] as String,
      origemLat: _d(json['origem_lat']),
      origemLng: _d(json['origem_lng']),
      destinoLat: _d(json['destino_lat']),
      destinoLng: _d(json['destino_lng']),
    );
  }
}

class MotoristaProximo {
  final int perfilId;
  final String deviceUuid;
  final double latitude;
  final double longitude;
  final double? precisaoM;
  final double distKm;

  MotoristaProximo({
    required this.perfilId,
    required this.deviceUuid,
    required this.latitude,
    required this.longitude,
    required this.distKm,
    this.precisaoM,
  });

  factory MotoristaProximo.fromJson(Map<String, dynamic> json) {
    return MotoristaProximo(
      perfilId: json['perfil_id'] as int,
      deviceUuid: json['device_uuid'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      precisaoM: (json['precisao_m'] as num?)?.toDouble(),
      distKm: (json['dist_km'] as num).toDouble(),
    );
  }
}

class RidesService {
  final Dio _dio = ApiClient.client;

  Future<List<CorridaResumo>> listarCorridas({int? perfilId, String? deviceUuid}) async {
    final resp = await _dio.get('/corridas/', queryParameters: {
      if (perfilId != null) 'perfil_id': perfilId,
      if (deviceUuid != null) 'device_uuid': deviceUuid,
    });
    final data = resp.data as List<dynamic>;
    return data.map((e) => CorridaResumo.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<CorridaResumo> solicitar({
    required int perfilId,
    required double origemLat,
    required double origemLng,
    required double destinoLat,
    required double destinoLng,
    String origemEndereco = '',
    String destinoEndereco = '',
  }) async {
    final resp = await _dio.post('/corridas/solicitar/', data: {
      'perfil_id': perfilId,
      'origem_lat': origemLat,
      'origem_lng': origemLng,
      'destino_lat': destinoLat,
      'destino_lng': destinoLng,
      'origem_endereco': origemEndereco,
      'destino_endereco': destinoEndereco,
    });
    return CorridaResumo.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<CorridaResumo?> buscarCorridaAtiva({required int perfilId}) async {
    final corridas = await listarCorridas(perfilId: perfilId);
    for (final c in corridas) {
      if (c.status != 'concluida' && c.status != 'cancelada' && c.status != 'rejeitada') {
        return c;
      }
    }
    return null;
  }

  Future<List<MotoristaProximo>> motoristasProximos({
    required double lat,
    required double lng,
    double raioKm = 3,
    int minutos = 10,
    int limite = 10,
  }) async {
    final resp = await _dio.get('/motoristas-proximos/', queryParameters: {
      'lat': lat,
      'lng': lng,
      'raio_km': raioKm,
      'minutos': minutos,
      'limite': limite,
    });
    final data = resp.data as List<dynamic>;
    return data.map((e) => MotoristaProximo.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> atribuirMotorista({required int corridaId, required int motoristaId}) async {
    await _dio.post('/corridas/$corridaId/aceitar/', data: {'motorista_id': motoristaId});
  }

  Future<void> cancelarCorrida(int corridaId) async {
    await _dio.post('/corridas/$corridaId/cancelar');
  }

  Future<CorridaResumo?> obterCorrida(int corridaId) async {
    final resp = await _dio.get(
      '/corridas/$corridaId/',
      options: Options(validateStatus: (_) => true),
    );
    if (resp.statusCode != 200 || resp.data is! Map<String, dynamic>) return null;
    return CorridaResumo.fromJson(resp.data as Map<String, dynamic>);
  }
}
