import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static const String trackingChannelId = 'vaipaqueta_tracking';
  static const String ridesChannelId = 'vaipaqueta_corridas';
  static const String speedChannelId = 'vaipaqueta_velocidade';
  static const int trackingNotificationId = 4101;
  static const int speedNotificationId = 4102;

  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static final StreamController<String?> _tapController = StreamController<String?>.broadcast();
  static String? _pendingPayload;
  static final Int64List _rideVibrationPattern = Int64List.fromList([0, 500, 250, 500]);

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
      AndroidNotificationChannel(
        ridesChannelId,
        'Corridas disponiveis',
        description: 'Alertas quando houver corrida para voce.',
        importance: Importance.high,
        enableVibration: true,
        vibrationPattern: _rideVibrationPattern,
        playSound: true,
      ),
    );
    await android.createNotificationChannel(
      const AndroidNotificationChannel(
        speedChannelId,
        'Aviso de velocidade',
        description: 'Alertas quando o ecotaxista ultrapassa a velocidade configurada.',
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

  static Future<bool> areNotificationsEnabled() async {
    if (kIsWeb) return true;
    await initialize();
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return false;
    try {
      return await android.areNotificationsEnabled() ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> showRideAvailable({
    required int id,
    required String title,
    required String body,
    String? payload,
    bool vibrate = true,
    bool playSound = true,
  }) async {
    await initialize();
    final android = AndroidNotificationDetails(
      ridesChannelId,
      'Corridas disponiveis',
      channelDescription: 'Alertas quando houver corrida para voce.',
      importance: Importance.max,
      priority: Priority.high,
      ticker: 'corrida_disponivel',
      enableVibration: vibrate,
      vibrationPattern: vibrate ? _rideVibrationPattern : null,
      playSound: playSound,
    );
    final ios = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: playSound,
    );
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(android: android, iOS: ios),
      payload: payload,
    );
  }

  static Future<void> showSpeedWarning({
    required double speedKmh,
    required double limitKmh,
    int? timeoutAfterMs,
  }) async {
    await initialize();
    final android = AndroidNotificationDetails(
      speedChannelId,
      'Aviso de velocidade',
      channelDescription: 'Alertas quando o ecotaxista ultrapassa a velocidade configurada.',
      importance: Importance.high,
      priority: Priority.high,
      ticker: 'aviso_velocidade',
      timeoutAfter: timeoutAfterMs,
    );
    const ios = DarwinNotificationDetails();
    final body =
        'Você está acima de ${limitKmh.toStringAsFixed(0)} km/h (~${speedKmh.toStringAsFixed(0)} km/h). Reduza a velocidade.';
    await _plugin.show(
      speedNotificationId,
      'Atenção à velocidade',
      body,
      NotificationDetails(android: android, iOS: ios),
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
