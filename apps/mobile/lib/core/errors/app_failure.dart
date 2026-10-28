import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

enum AppFailure {
  network('Verifique sua conexão e tente novamente.'),
  unauthorized('Sua sessão precisa ser renovada.'),
  unavailable('Serviço indisponível. Tente novamente em instantes.'),
  unexpected('Não foi possível concluir a operação.');

  const AppFailure(this.message);
  final String message;
  static AppFailure fromDio(DioException error) {
    if (error.response?.statusCode == 401) return unauthorized;
    if ((error.response?.statusCode ?? 0) >= 500) return unavailable;
    if ({
      DioExceptionType.connectionError,
      DioExceptionType.connectionTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.sendTimeout,
    }.contains(error.type)) {
      return network;
    }
    return unexpected;
  }
}

// Apenas classificação local; nunca serializar exceção, payload, token ou URL.
void reportFailure(AppFailure failure) {
  if (kDebugMode) debugPrint('flow_failure:${failure.name}');
}
