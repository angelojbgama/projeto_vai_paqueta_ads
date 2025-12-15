import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../core/api_config.dart';

class ApiClient {
  ApiClient._internal() {
    _dio = Dio(BaseOptions(
      baseUrl: ApiConfig.baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
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

    // Permite certificados do loca.lt (self-signed) apenas em ambiente não-web.
    if (!kIsWeb) {
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

  static Dio get client => _instance._dio;
}
