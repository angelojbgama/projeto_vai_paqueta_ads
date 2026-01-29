import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../core/api_config.dart';
import '../core/driver_settings.dart';
import 'auth_storage.dart';

class ApiClient {
  ApiClient._internal() {
    _dio = Dio(BaseOptions(
      baseUrl: ApiConfig.baseUrl,
      connectTimeout: NetworkSettings.connectTimeout,
      receiveTimeout: NetworkSettings.receiveTimeout,
    ));
    _refreshDio = Dio(BaseOptions(
      baseUrl: ApiConfig.baseUrl,
      connectTimeout: NetworkSettings.connectTimeout,
      receiveTimeout: NetworkSettings.receiveTimeout,
    ));

    if (kDebugMode) {
      _dio.interceptors.add(
        LogInterceptor(
          request: true,
          requestBody: true,
          responseBody: true,
          responseHeader: false,
          error: true,
          logPrint: (obj) => debugPrint('[DIO] $obj'),
        ),
      );
    }

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await AuthStorage.getAccessToken();
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onResponse: (response, handler) async {
          final status = response.statusCode;
          final requestOptions = response.requestOptions;
          final path = requestOptions.path;
          final isRefresh = path.contains('/auth/token/refresh/');
          final isLogin = path.contains('/auth/login/');
          final isRegister = path.contains('/auth/register/');
          if (status == 401 && !isRefresh && !isLogin && !isRegister && requestOptions.extra['retry'] != true) {
            try {
              final newAccess = await _refreshToken();
              if (newAccess != null && newAccess.isNotEmpty) {
                requestOptions.headers['Authorization'] = 'Bearer $newAccess';
                requestOptions.extra['retry'] = true;
                final newResponse = await _dio.fetch(requestOptions);
                return handler.resolve(newResponse);
              }
            } catch (_) {
              // Falha ao renovar, segue com a resposta original.
            }
            await AuthStorage.clearTokens();
          }
          handler.next(response);
        },
        onError: (error, handler) async {
          final status = error.response?.statusCode;
          final requestOptions = error.requestOptions;
          final isRefresh = requestOptions.path.contains('/auth/token/refresh/');
          if (status == 401 && !isRefresh && requestOptions.extra['retry'] != true) {
            try {
              final newAccess = await _refreshToken();
              if (newAccess != null && newAccess.isNotEmpty) {
                requestOptions.headers['Authorization'] = 'Bearer $newAccess';
                requestOptions.extra['retry'] = true;
                final response = await _dio.fetch(requestOptions);
                return handler.resolve(response);
              }
            } catch (_) {
              // Falha ao renovar, segue para logout.
            }
            await AuthStorage.clearTokens();
          }
          return handler.next(error);
        },
      ),
    );

    // Permite certificados do loca.lt (self-signed) apenas em debug e não-web.
    if (!kIsWeb && kDebugMode) {
      _dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient();
          client.badCertificateCallback = (cert, host, port) {
            if (host.endsWith('loca.lt')) return true;
            return false;
          };
          return client;
        },
      );
    }
  }

  static final ApiClient _instance = ApiClient._internal();
  late final Dio _dio;
  late final Dio _refreshDio;
  Future<String?>? _refreshFuture;

  static Future<String?> refreshAccessToken() => _instance._refreshToken();

  Future<String?> _refreshToken() async {
    if (_refreshFuture != null) return _refreshFuture!;
    final refresh = await AuthStorage.getRefreshToken();
    if (refresh == null || refresh.isEmpty) return null;
    _refreshFuture = _refreshDio
        .post(
          '/auth/token/refresh/',
          data: {'refresh': refresh},
          options: Options(validateStatus: (_) => true),
        )
        .then((resp) async {
          if (resp.statusCode != 200 || resp.data is! Map) {
            await AuthStorage.clearTokens();
            return null;
          }
          final data = Map<String, dynamic>.from(resp.data as Map);
          final access = data['access'] as String?;
          final newRefresh = data['refresh'] as String?;
          if (access == null || access.isEmpty) {
            await AuthStorage.clearTokens();
            return null;
          }
          await AuthStorage.saveTokens(
            access: access,
            refresh: (newRefresh != null && newRefresh.isNotEmpty) ? newRefresh : refresh,
          );
          return access;
        })
        .whenComplete(() => _refreshFuture = null);
    return _refreshFuture!;
  }

  static Dio get client => _instance._dio;
}
