import 'package:dio/dio.dart';

import '../../services/api_client.dart';
import '../../services/auth_storage.dart';

class AuthUser {
  final int id;
  final String email;
  final String nome;
  final String telefone;
  final int perfilId;
  final String perfilTipo;
  final String deviceUuid;
  final String devicePlataforma;

  const AuthUser({
    required this.id,
    required this.email,
    required this.nome,
    required this.telefone,
    required this.perfilId,
    required this.perfilTipo,
    required this.deviceUuid,
    required this.devicePlataforma,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: json['id'] as int,
      email: json['email'] as String? ?? '',
      nome: json['nome'] as String? ?? '',
      telefone: json['telefone'] as String? ?? '',
      perfilId: json['perfil_id'] as int? ?? 0,
      perfilTipo: json['perfil_tipo'] as String? ?? '',
      deviceUuid: json['device_uuid'] as String? ?? '',
      devicePlataforma: json['device_plataforma'] as String? ?? '',
    );
  }
}

class AuthService {
  final Dio _dio = ApiClient.client;

  Future<AuthUser> register({
    required String email,
    required String password,
    String nome = '',
    String telefone = '',
  }) async {
    final resp = await _dio.post(
      '/auth/register/',
      data: {
        'email': email.trim(),
        'password': password,
        'nome': nome.trim(),
        'telefone': telefone.trim(),
      },
      options: Options(validateStatus: (_) => true),
    );
    if (resp.statusCode != 201) {
      final detail = (resp.data is Map<String, dynamic>) ? resp.data['detail'] : null;
      throw Exception(detail ?? 'Erro ao cadastrar (code ${resp.statusCode}).');
    }
    final data = resp.data as Map<String, dynamic>;
    final userJson = data['user'] as Map<String, dynamic>?;
    final token = userJson != null ? userJson['token'] as String? : null;
    if (token == null || userJson == null) {
      throw Exception('Resposta inválida do servidor.');
    }
    await AuthStorage.saveToken(token);
    return AuthUser.fromJson(userJson);
  }

  Future<AuthUser> login({required String email, required String password}) async {
    final resp = await _dio.post(
      '/auth/login/',
      data: {
        'email': email.trim(),
        'password': password,
      },
      options: Options(validateStatus: (_) => true),
    );
    if (resp.statusCode != 200) {
      final detail = (resp.data is Map<String, dynamic>) ? resp.data['detail'] : null;
      throw Exception(detail ?? 'Credenciais inválidas.');
    }
    final data = resp.data as Map<String, dynamic>;
    final userJson = data['user'] as Map<String, dynamic>?;
    final token = userJson != null ? userJson['token'] as String? : null;
    if (token == null || userJson == null) {
      throw Exception('Resposta inválida do servidor.');
    }
    await AuthStorage.saveToken(token);
    return AuthUser.fromJson(userJson);
  }

  Future<AuthUser?> me() async {
    final resp = await _dio.get(
      '/auth/me/',
      options: Options(validateStatus: (_) => true),
    );
    if (resp.statusCode == 401) return null;
    if (resp.statusCode != 200 || resp.data is! Map<String, dynamic>) return null;
    final data = resp.data as Map<String, dynamic>;
    final userJson = data['user'] as Map<String, dynamic>?;
    if (userJson == null) return null;
    return AuthUser.fromJson(userJson);
  }

  Future<AuthUser> atualizarPerfil({
    String? nome,
    String? telefone,
    String? tipo,
    String? deviceUuid,
    String? plataforma,
  }) async {
    final resp = await _dio.patch(
      '/auth/me/',
      data: {
        if (nome != null) 'nome': nome,
        if (telefone != null) 'telefone': telefone,
        if (tipo != null) 'tipo': tipo,
        if (deviceUuid != null) 'device_uuid': deviceUuid,
        if (plataforma != null) 'plataforma': plataforma,
      },
      options: Options(validateStatus: (_) => true),
    );
    if (resp.statusCode != 200) {
      final detail = (resp.data is Map<String, dynamic>) ? resp.data['detail'] : null;
      throw Exception(detail ?? 'Erro ao atualizar perfil.');
    }
    final data = resp.data as Map<String, dynamic>;
    final userJson = data['user'] as Map<String, dynamic>?;
    if (userJson == null) {
      throw Exception('Resposta inválida do servidor.');
    }
    return AuthUser.fromJson(userJson);
  }

  Future<void> logout() async {
    await AuthStorage.clearToken();
  }
}
