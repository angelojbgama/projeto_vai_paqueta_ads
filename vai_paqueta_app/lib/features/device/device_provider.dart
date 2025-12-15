import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'device_service.dart';

final deviceProvider = AsyncNotifierProvider<DeviceNotifier, DeviceInfo?>(() {
  return DeviceNotifier();
});

class DeviceNotifier extends AsyncNotifier<DeviceInfo?> {
  final _service = DeviceService();

  @override
  Future<DeviceInfo?> build() async {
    return null;
  }

  Future<DeviceInfo> ensureRegistrado({String? tipo, String nome = ''}) async {
    state = const AsyncLoading();
    try {
      final info = await _service.registrarDispositivo(tipo: tipo, nome: nome);
      state = AsyncData(info);
      return info;
    } catch (e, st) {
      state = AsyncError(e, st);
      rethrow;
    }
  }
}
