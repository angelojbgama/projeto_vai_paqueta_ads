import 'package:dio/dio.dart';

import '../../services/api_client.dart';

class CorridaResumo {
  final int id;
  final String status;
  final int lugares;
  final double? origemLat;
  final double? origemLng;
  final double? destinoLat;
  final double? destinoLng;
  final double? motoristaLat;
  final double? motoristaLng;
  final DateTime? motoristaPingEm;
  final double? motoristaBearing;
  final String? origemEndereco;
  final String? destinoEndereco;
  final String? motoristaNome;
  final String? motoristaTelefone;
  final DateTime? atualizadoEm;
  final DateTime? serverTime;

  CorridaResumo({
    required this.id,
    required this.status,
    required this.lugares,
    this.origemLat,
    this.origemLng,
    this.destinoLat,
    this.destinoLng,
    this.motoristaLat,
    this.motoristaLng,
    this.motoristaPingEm,
    this.motoristaBearing,
    this.origemEndereco,
    this.destinoEndereco,
    this.motoristaNome,
    this.motoristaTelefone,
    this.atualizadoEm,
    this.serverTime,
  });

  factory CorridaResumo.fromJson(Map<String, dynamic> json) {
    double? d(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v);
      return null;
    }
    DateTime? dt(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      if (v is String) return DateTime.tryParse(v);
      return null;
    }
    final motorista = json['motorista'];
    String? motoristaNome;
    String? motoristaTelefone;
    if (motorista is Map<String, dynamic>) {
      motoristaNome = (motorista['nome'] as String?)?.trim();
      motoristaTelefone = (motorista['telefone'] as String?)?.trim();
    }
    return CorridaResumo(
      id: json['id'] as int,
      status: json['status'] as String,
      lugares: (json['lugares'] as num?)?.toInt() ?? 1,
      origemLat: d(json['origem_lat']),
      origemLng: d(json['origem_lng']),
      destinoLat: d(json['destino_lat']),
      destinoLng: d(json['destino_lng']),
      motoristaLat: d(json['motorista_lat']),
      motoristaLng: d(json['motorista_lng']),
      motoristaPingEm: dt(json['motorista_ping_em']),
      motoristaBearing: d(json['motorista_bearing']),
      origemEndereco: (json['origem_endereco'] as String?)?.trim(),
      destinoEndereco: (json['destino_endereco'] as String?)?.trim(),
      motoristaNome: motoristaNome,
      motoristaTelefone: motoristaTelefone,
      atualizadoEm: dt(json['atualizado_em']),
      serverTime: dt(json['server_time']),
    );
  }
}

class MotoristaProximo {
  final int perfilId;
  final double latitude;
  final double longitude;
  final double? precisaoM;
  final double distKm;

  MotoristaProximo({
    required this.perfilId,
    required this.latitude,
    required this.longitude,
    required this.distKm,
    this.precisaoM,
  });

  factory MotoristaProximo.fromJson(Map<String, dynamic> json) {
    return MotoristaProximo(
      perfilId: json['perfil_id'] as int,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      precisaoM: (json['precisao_m'] as num?)?.toDouble(),
      distKm: (json['dist_km'] as num).toDouble(),
    );
  }
}

class RidesService {
  final Dio _dio = ApiClient.client;

  Future<List<CorridaResumo>> listarCorridas({int? perfilId}) async {
    final resp = await _dio.get('/corridas/', queryParameters: {
      if (perfilId != null) 'perfil_id': perfilId,
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
    required int lugares,
    String origemEndereco = '',
    String destinoEndereco = '',
  }) async {
    final resp = await _dio.post('/corridas/solicitar/', data: {
      'perfil_id': perfilId,
      'origem_lat': origemLat,
      'origem_lng': origemLng,
      'destino_lat': destinoLat,
      'destino_lng': destinoLng,
      'lugares': lugares,
      'origem_endereco': origemEndereco,
      'destino_endereco': destinoEndereco,
    });
    return CorridaResumo.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<CorridaResumo?> buscarCorridaAtiva({required int perfilId}) async {
    final resp = await _dio.get(
      '/corridas/para_passageiro/$perfilId/',
      options: Options(validateStatus: (_) => true),
    );
    if (resp.statusCode != 200 || resp.data is! Map<String, dynamic>) return null;
    final data = resp.data as Map<String, dynamic>;
    if (data.isEmpty) return null;
    return CorridaResumo.fromJson(data);
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
    await _dio.post('/corridas/$corridaId/cancelar/');
  }

  Future<void> finalizarCorrida(int corridaId) async {
    await _dio.post('/corridas/$corridaId/finalizar/');
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
