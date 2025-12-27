import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static const String trackingChannelId = 'vaipaqueta_tracking';
  static const String ridesChannelId = 'vaipaqueta_corridas';
  static const int trackingNotificationId = 4101;

  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static final StreamController<String?> _tapController = StreamController<String?>.broadcast();
  static String? _pendingPayload;

  static Stream<String?> get onNotificationTap => _tapController.stream;

  static Future<void> initialize() async {
    if (_initialized) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const settings = InitializationSettings(android: androidInit, iOS: iosInit);
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {
        _emitPayload(response.payload);
      },
    );
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp == true) {
      _emitPayload(launchDetails?.notificationResponse?.payload);
    }
    _initialized = true;
    await _createChannels();
  }

  static Future<void> _createChannels() async {
    if (kIsWeb) return;
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    await android.createNotificationChannel(
      const AndroidNotificationChannel(
        trackingChannelId,
        'Envio de localizacao',
        description: 'Notificacao fixa para envio de localizacao em segundo plano.',
        importance: Importance.low,
      ),
    );
    await android.createNotificationChannel(
      const AndroidNotificationChannel(
        ridesChannelId,
        'Corridas disponiveis',
        description: 'Alertas quando houver corrida para voce.',
        importance: Importance.high,
      ),
    );
  }

  static Future<void> requestPermissions() async {
    if (kIsWeb) return;
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    await ios?.requestPermissions(alert: true, badge: true, sound: true);
  }

  static Future<void> showRideAvailable({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    await initialize();
    final android = AndroidNotificationDetails(
      ridesChannelId,
      'Corridas disponiveis',
      channelDescription: 'Alertas quando houver corrida para voce.',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'corrida_disponivel',
    );
    const ios = DarwinNotificationDetails();
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(android: android, iOS: ios),
      payload: payload,
    );
  }

  static String? consumePendingPayload() {
    final payload = _pendingPayload;
    _pendingPayload = null;
    return payload;
  }

  static void _emitPayload(String? payload) {
    if (payload == null || payload.trim().isEmpty) return;
    _pendingPayload = payload;
    _tapController.add(payload);
  }
}
