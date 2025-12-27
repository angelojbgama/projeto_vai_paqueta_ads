import 'dart:io';

import 'package:dio/dio.dart';

String friendlyError(Object error) {
  if (error is DioException) {
    return _dioErrorMessage(error);
  }
  if (error is String) {
    return error.trim().isNotEmpty ? error : 'Ocorreu um erro. Tente novamente.';
  }
  final msg = error.toString();
  if (msg.startsWith('Exception: ')) {
    return msg.substring('Exception: '.length);
  }
  return msg.trim().isNotEmpty ? msg : 'Ocorreu um erro. Tente novamente.';
}

String _dioErrorMessage(DioException error) {
  switch (error.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return 'Tempo esgotado. Verifique sua conexão e tente novamente.';
    case DioExceptionType.cancel:
      return 'Requisição cancelada.';
    case DioExceptionType.unknown:
      if (error.error is SocketException) {
        return 'Sem conexão com a internet.';
      }
      final msg = error.message;
      if (msg != null && msg.trim().isNotEmpty) {
        return msg;
      }
      return 'Falha de conexão. Tente novamente.';
    case DioExceptionType.badCertificate:
      return 'Falha de certificado. Verifique sua conexão.';
    case DioExceptionType.connectionError:
      return 'Falha de conexão. Tente novamente.';
    case DioExceptionType.badResponse:
      final status = error.response?.statusCode;
      final detail = _extractDetail(error.response?.data);
      if (detail != null && detail.isNotEmpty) {
        return detail;
      }
      if (status == 401) return 'Sessão expirada. Faça login novamente.';
      if (status == 403) return 'Ação não permitida para sua conta.';
      if (status == 404) return 'Recurso não encontrado.';
      if (status == 409) return 'Conflito na solicitação. Tente novamente.';
      if (status == 429) return 'Muitas tentativas. Aguarde alguns minutos.';
      if (status != null && status >= 500) {
        return 'Erro no servidor. Tente novamente mais tarde.';
      }
      return 'Não foi possível concluir. Verifique os dados e tente novamente.';
  }
}

String? _extractDetail(dynamic data) {
  if (data is Map) {
    final detail = data['detail'];
    if (detail is String && detail.trim().isNotEmpty) {
      return detail;
    }
  }
  if (data is List && data.isNotEmpty) {
    final first = data.first;
    if (first is String && first.trim().isNotEmpty) {
      return first;
    }
  }
  return null;
}
