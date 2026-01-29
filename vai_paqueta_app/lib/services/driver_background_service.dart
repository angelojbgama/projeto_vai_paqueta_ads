import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';

import '../core/driver_settings.dart';
import '../features/driver/driver_service.dart';
import 'auth_storage.dart';
import 'notification_service.dart';

const _configEvent = 'driver_config';
const _stopEvent = 'driver_stop';

class DriverBackgroundService {
  static Future<void> initialize() async {
    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: driverServiceOnStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: NotificationService.trackingChannelId,
        initialNotificationTitle: 'Vai Paqueta',
        initialNotificationContent: 'Enviando localizacao em segundo plano',
        foregroundServiceNotificationId: NotificationService.trackingNotificationId,
        foregroundServiceTypes: [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: driverServiceOnStart,
        onBackground: driverServiceOnIosBackground,
      ),
    );
  }

  static Future<void> start({
    required int perfilId,
    required String perfilTipo,
  }) async {
    if (perfilId == 0 || perfilTipo != 'ecotaxista') return;
    final service = FlutterBackgroundService();
    final running = await service.isRunning();
    if (!running) {
      await service.startService();
    }
    service.invoke(_configEvent, {
      'perfilId': perfilId,
      'perfilTipo': perfilTipo,
    });
  }

  static Future<void> stop() async {
    final service = FlutterBackgroundService();
    service.invoke(_stopEvent);
  }
}

String _normalizeStatus(String? status) {
  final raw = (status ?? '').trim().toLowerCase();
  if (raw.isEmpty) return '';
  final normalized = raw.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  if (normalized == 'aguardando_motorista') return 'aguardando';
  return normalized;
}

double _round6(double value) => double.parse(value.toStringAsFixed(6));

@pragma('vm:entry-point')
Future<bool> driverServiceOnIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void driverServiceOnStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await NotificationService.initialize();

  int perfilId = 0;
  String perfilTipo = '';
  String? lastRideKey;

  service.on(_configEvent).listen((event) {
    final data = event ?? const {};
    perfilId = (data['perfilId'] as int?) ?? perfilId;
    perfilTipo = (data['perfilTipo'] as String?) ?? perfilTipo;
  });

  service.on(_stopEvent).listen((event) {
    service.stopSelf();
  });

  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: 'Vai Paqueta',
      content: 'Enviando localizacao em segundo plano',
    );
  }

  Timer.periodic(DriverSettings.backgroundPingInterval, (timer) async {
    final token = await AuthStorage.getAccessToken();
    if (token == null || token.isEmpty) {
      timer.cancel();
      service.stopSelf();
      return;
    }
    if (perfilId == 0 || perfilTipo != 'ecotaxista') {
      return;
    }
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        return;
      }
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      await DriverService().enviarPing(
        perfilId: perfilId,
        latitude: _round6(pos.latitude),
        longitude: _round6(pos.longitude),
        precisao: pos.accuracy,
      );
    } catch (e) {
      debugPrint('Erro ao enviar ping em segundo plano: $e');
    }

    try {
      final corrida = await DriverService().corridaAtribuida(perfilId);
      if (corrida == null || corrida.isEmpty) {
        lastRideKey = null;
        return;
      }
      final corridaId = corrida['id'];
      final status = _normalizeStatus(corrida['status']?.toString());
      if (corridaId is int) {
        final key = '$corridaId:$status';
        if (status == 'aguardando' && key != lastRideKey) {
          await NotificationService.showRideAvailable(
            id: corridaId,
            title: 'Corrida disponivel',
            body: 'Abra o app para aceitar a corrida.',
            payload: 'ride:$corridaId',
          );
          lastRideKey = key;
        }
      }
    } catch (e) {
      debugPrint('Erro ao verificar corrida em segundo plano: $e');
    }
  });
}
