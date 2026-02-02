import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../core/platform_info.dart';
import 'api_client.dart';
import 'notification_service.dart';

class FcmService {
  static bool _initialized = false;
  static bool _firebaseReady = false;
  static StreamSubscription<String>? _tokenSub;

  static Future<void> initialize() async {
    if (_initialized || kIsWeb) return;
    try {
      await Firebase.initializeApp();
      _firebaseReady = true;
    } catch (e) {
      debugPrint('[FCM] Falha ao iniciar Firebase: $e');
      return;
    }
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    FirebaseMessaging.onMessage.listen(_onForegroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_onOpenedMessage);
    _initialized = true;
  }

  static Future<void> requestPermissions() async {
    if (!_firebaseReady) return;
    await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);
  }

  static Future<bool> areNotificationsAuthorized() async {
    if (!_firebaseReady) return true;
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (e) {
      debugPrint('[FCM] Falha ao consultar permissao de notificacao: $e');
      return true;
    }
  }

  static Future<String?> getToken() async {
    if (!_firebaseReady) return null;
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('[FCM] Falha ao obter token: $e');
      return null;
    }
  }

  static Future<void> syncTokenWithBackend() async {
    if (!_firebaseReady) return;
    final token = await getToken();
    if (token != null) {
      await _sendToken(token);
    }
    _tokenSub ??= FirebaseMessaging.instance.onTokenRefresh.listen(
      (newToken) async => _sendToken(newToken),
    );
  }

  static Future<void> _sendToken(String token) async {
    try {
      await ApiClient.client.post('/device/fcm/', data: {
        'token': token,
        'plataforma': platformLabel,
      });
    } catch (e) {
      debugPrint('[FCM] Falha ao registrar token: $e');
    }
  }

  @pragma('vm:entry-point')
  static Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
    try {
      await Firebase.initializeApp();
    } catch (_) {
      // Não interrompe o handler caso o Firebase já esteja inicializado.
    }
  }

  static Future<void> _onForegroundMessage(RemoteMessage message) async {
    final notification = message.notification;
    final title = notification?.title ?? message.data['title']?.toString() ?? 'Vai Paquetá';
    final body = notification?.body ?? message.data['body']?.toString() ?? '';
    if (body.isEmpty) return;
    await NotificationService.showRideAvailable(
      id: message.hashCode,
      title: title,
      body: body,
      payload: message.data['payload']?.toString(),
      vibrate: true,
      playSound: true,
    );
  }

  static void _onOpenedMessage(RemoteMessage message) {
    debugPrint('[FCM] Notificação aberta: ${message.data}');
  }
}
