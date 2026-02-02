import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/platform_info.dart';
import '../../services/api_client.dart';
import '../../services/fcm_service.dart';

class DeviceInfo {
  final String deviceUuid;
  final int perfilId;
  final String perfilTipo;

  DeviceInfo({
    required this.deviceUuid,
    required this.perfilId,
    required this.perfilTipo,
  });
}

class DeviceService {
  static const _prefsKeyUuid = 'device_uuid';
  static const _prefsKeyTipo = 'device_tipo';

  Future<String> _loadOrCreateUuid() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_prefsKeyUuid);
    if (cached != null && cached.isNotEmpty) return cached;
    final generated = const Uuid().v4();
    await prefs.setString(_prefsKeyUuid, generated);
    return generated;
  }

  Future<String> _loadTipoPreferido() async {
    final prefs = await SharedPreferences.getInstance();
    final salvo = prefs.getString(_prefsKeyTipo);
    if (salvo == 'cliente') {
      await prefs.setString(_prefsKeyTipo, 'passageiro');
      return 'passageiro';
    }
    return salvo ?? 'passageiro';
  }

  Future<void> _salvarTipoPreferido(String tipo) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeyTipo, tipo);
  }

  Future<DeviceInfo> registrarDispositivo({
    String plataforma = 'flutter',
    String? tipo,
    String nome = '',
  }) async {
    final uuid = await _loadOrCreateUuid();
    var tipoFinal = tipo ?? await _loadTipoPreferido();
    if (tipoFinal == 'cliente') tipoFinal = 'passageiro';
    final dio = ApiClient.client;
    final fcmToken = await FcmService.getToken();

    if (kDebugMode) {
      debugPrint('[DEVICE] Registrando device UUID=$uuid na API ${dio.options.baseUrl} tipo=$tipoFinal');
    }

    final resp = await dio.post('/device/registrar/', data: {
      'device_uuid': uuid,
      'plataforma': plataforma,
      'tipo': tipoFinal,
      'nome': nome,
      if (fcmToken != null) 'fcm_token': fcmToken,
      if (fcmToken != null) 'fcm_plataforma': platformLabel,
    });

    final device = resp.data['device'] as Map<String, dynamic>;
    final perfil = resp.data['perfil'] as Map<String, dynamic>;

    await _salvarTipoPreferido(tipoFinal);

    if (kDebugMode) {
      debugPrint('[DEVICE] Registrado com sucesso: device=${device['device_uuid']} perfil=${perfil['id']} tipo=${perfil['tipo']}');
    }

    return DeviceInfo(
      deviceUuid: device['device_uuid'] as String,
      perfilId: perfil['id'] as int,
      perfilTipo: perfil['tipo'] as String,
    );
  }
}
