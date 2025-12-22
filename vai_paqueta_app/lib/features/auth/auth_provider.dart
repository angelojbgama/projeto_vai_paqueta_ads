import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/auth_storage.dart';
import 'auth_service.dart';

final authProvider = AsyncNotifierProvider<AuthNotifier, AuthUser?>(() {
  return AuthNotifier();
});

class AuthNotifier extends AsyncNotifier<AuthUser?> {
  final _service = AuthService();

  @override
  Future<AuthUser?> build() async {
    final token = await AuthStorage.getAccessToken();
    if (token == null) return null;
    try {
      return await _service.me();
    } catch (_) {
      await AuthStorage.clearTokens();
      return null;
    }
  }

  Future<AuthUser?> login(String email, String password) async {
    state = const AsyncLoading();
    try {
      final user = await _service.login(email: email, password: password);
      state = AsyncData(user);
      return user;
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }

  Future<AuthUser?> register(String email, String password, {String nome = '', String telefone = ''}) async {
    state = const AsyncLoading();
    try {
      final user = await _service.register(
        email: email,
        password: password,
        nome: nome,
        telefone: telefone,
      );
      state = AsyncData(user);
      return user;
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }

  Future<AuthUser?> atualizarPerfil({
    String? nome,
    String? telefone,
    String? tipo,
    String? deviceUuid,
    String? plataforma,
  }) async {
    state = const AsyncLoading();
    try {
      final user = await _service.atualizarPerfil(
        nome: nome,
        telefone: telefone,
        tipo: tipo,
        deviceUuid: deviceUuid,
        plataforma: plataforma,
      );
      state = AsyncData(user);
      return user;
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }

  Future<void> logout() async {
    await _service.logout();
    state = const AsyncData(null);
  }
}
