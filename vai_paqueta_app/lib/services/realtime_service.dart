import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/api_config.dart';
import '../core/driver_settings.dart';
import 'api_client.dart';
import 'auth_storage.dart';
import 'ws_channel_factory.dart';

enum RealtimeRole { driver, passenger }

class RealtimeService {
  RealtimeService({
    required this.role,
    required this.onEvent,
    this.onConnected,
    this.onDisconnected,
  });

  final RealtimeRole role;
  final void Function(Map<String, dynamic> event) onEvent;
  final VoidCallback? onConnected;
  final VoidCallback? onDisconnected;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  Timer? _handshakeTimer;
  bool _connected = false;
  bool _connecting = false;
  bool _shouldReconnect = true;
  int _attempt = 0;

  static const int _jwtGraceSeconds = 30;

  bool get isConnected => _connected;

  Future<void> connect() async {
    if (_connecting || _connected) return;
    _connecting = true;
    String? token = await AuthStorage.getAccessToken();
    if (_shouldRefreshToken(token)) {
      final refreshed = await ApiClient.refreshAccessToken();
      if (refreshed != null && refreshed.isNotEmpty) {
        token = refreshed;
      } else {
        token = await AuthStorage.getAccessToken();
      }
    }
    if (token == null || token.isEmpty) {
      _connecting = false;
      return;
    }
    final uri = _buildUri(token);
    final origin = _buildOrigin();
    if (kDebugMode) {
      debugPrint('[WS] connecting to $uri (origin: ${origin ?? "none"})');
    }
    _channel = connectWebSocket(
      uri,
      headers: {
        if (origin != null) 'Origin': origin,
        'Authorization': 'Bearer $token',
      },
    );
    _subscription = _channel!.stream.listen(
      _handleMessage,
      onError: (_) => _handleDisconnect(),
      onDone: _handleDisconnect,
      cancelOnError: true,
    );
    _handshakeTimer?.cancel();
    _handshakeTimer = Timer(RealtimeSettings.handshakeTimeout, () {
      if (!_connected) {
        _handleDisconnect();
      }
    });
    _connecting = false;
  }

  void disconnect({bool reconnect = false}) {
    _shouldReconnect = reconnect;
    _handshakeTimer?.cancel();
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    if (_connected) {
      _connected = false;
      onDisconnected?.call();
    }
  }

  void send(Map<String, dynamic> payload) {
    if (_channel == null) return;
    _channel!.sink.add(jsonEncode(payload));
  }

  void sendPing({
    required double latitude,
    required double longitude,
    double? precisaoM,
    int? corridaId,
    double? bearing,
  }) {
    send({
      'type': 'ping',
      'latitude': latitude,
      'longitude': longitude,
      if (precisaoM != null) 'precisao_m': precisaoM,
      if (corridaId != null) 'corrida_id': corridaId,
      if (bearing != null) 'bearing': bearing,
    });
  }

  void sendSync() {
    send({'type': 'sync'});
  }

  void subscribeRide(int rideId) {
    send({'type': 'subscribe_ride', 'ride_id': rideId});
  }

  void unsubscribeRide(int rideId) {
    send({'type': 'unsubscribe_ride', 'ride_id': rideId});
  }

  Uri _buildUri(String? token) {
    final base = ApiConfig.baseOrigin;
    final baseUri = Uri.parse(base);
    final scheme = baseUri.scheme == 'https' ? 'wss' : 'ws';
    final pathBase = baseUri.path.endsWith('/') ? baseUri.path : '${baseUri.path}/';
    final wsPath = role == RealtimeRole.driver ? 'ws/driver/' : 'ws/passenger/';
    final port = baseUri.hasPort && baseUri.port > 0 ? baseUri.port : null;
    return Uri(
      scheme: scheme,
      host: baseUri.host,
      port: port,
      path: '$pathBase$wsPath',
      queryParameters: token != null && token.isNotEmpty ? {'token': token} : null,
    );
  }

  String? _buildOrigin() {
    final base = ApiConfig.baseOrigin;
    if (base.isEmpty) return null;
    final baseUri = Uri.parse(base);
    if (baseUri.host.isEmpty) return null;
    final scheme = baseUri.scheme == 'https' ? 'https' : 'http';
    final port = baseUri.hasPort && baseUri.port > 0 ? baseUri.port : null;
    return Uri(scheme: scheme, host: baseUri.host, port: port).toString();
  }

  bool _shouldRefreshToken(String? token) {
    if (token == null || token.isEmpty) return true;
    final exp = _extractJwtExp(token);
    if (exp == null) return true;
    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    return exp <= now + _jwtGraceSeconds;
  }

  int? _extractJwtExp(String token) {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    try {
      final normalized = base64Url.normalize(parts[1]);
      final payload = utf8.decode(base64Url.decode(normalized));
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        final exp = decoded['exp'];
        if (exp is int) return exp;
        if (exp is num) return exp.toInt();
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  void _handleMessage(dynamic message) {
    if (message is! String) return;
    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map<String, dynamic>) {
        data = decoded;
      }
    } catch (_) {}
    if (data == null) return;
    final type = data['type']?.toString();
    if (type == 'connected') {
      _connected = true;
      _handshakeTimer?.cancel();
      _attempt = 0;
      onConnected?.call();
      return;
    }
    onEvent(data);
  }

  void _handleDisconnect() {
    if (_channel == null) return;
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
    _handshakeTimer?.cancel();
    if (_connected) {
      _connected = false;
      onDisconnected?.call();
    }
    if (_shouldReconnect) {
      _attempt += 1;
      final delaySeconds = min(
        RealtimeSettings.reconnectMaxSeconds,
        RealtimeSettings.reconnectBaseSeconds + _attempt * RealtimeSettings.reconnectStepSeconds,
      );
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
        if (_shouldReconnect) {
          unawaited(connect());
        }
      });
    }
  }
}
