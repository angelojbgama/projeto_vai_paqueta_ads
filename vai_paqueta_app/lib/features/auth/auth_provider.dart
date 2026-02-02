import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/auth_storage.dart';
import '../../services/fcm_service.dart';
import '../device/device_service.dart';
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
      final user = await _service.me();
      if (user != null) {
        await _registrarDevice(user);
      }
      return user;
    } catch (_) {
      await AuthStorage.clearTokens();
      return null;
    }
  }

  Future<AuthUser?> login(String email, String password) async {
    state = const AsyncLoading();
    try {
      final user = await _service.login(email: email, password: password);
      await _registrarDevice(user);
      state = AsyncData(user);
      return user;
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }

  Future<AuthUser?> register(
    String email,
    String password, {
    String nome = '',
    String ddi = '',
    String ddd = '',
    String numero = '',
  }) async {
    state = const AsyncLoading();
    try {
      final user = await _service.register(
        email: email,
        password: password,
        nome: nome,
        ddi: ddi,
        ddd: ddd,
        numero: numero,
      );
      await _registrarDevice(user);
      state = AsyncData(user);
      return user;
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }

  Future<AuthUser?> atualizarPerfil({
    String? nome,
    String? ddi,
    String? ddd,
    String? numero,
    String? tipo,
    String? deviceUuid,
    String? plataforma,
  }) async {
    state = const AsyncLoading();
    try {
      final user = await _service.atualizarPerfil(
        nome: nome,
        ddi: ddi,
        ddd: ddd,
        numero: numero,
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

  Future<void> deleteAccount({
    required String password,
    required String passwordConfirm,
  }) async {
    state = const AsyncLoading();
    try {
      await _service.deleteAccount(
        password: password,
        passwordConfirm: passwordConfirm,
      );
      state = const AsyncData(null);
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }

  Future<void> _registrarDevice(AuthUser user) async {
    try {
      await DeviceService().registrarDispositivo(
        tipo: user.perfilTipo,
        nome: user.nome,
      );
      await FcmService.syncTokenWithBackend();
    } catch (_) {
      // Não bloqueia login se falhar o registro do device.
    }
  }
}
