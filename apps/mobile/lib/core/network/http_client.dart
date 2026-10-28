import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/environment.dart';
import '../errors/app_failure.dart';

final httpClientProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      baseUrl: ref.watch(environmentProvider).apiBaseUrl.toString(),
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
      headers: {'Accept': 'application/json'},
      followRedirects: false,
    ),
  );
  dio.interceptors.add(
    InterceptorsWrapper(
      onError: (error, handler) {
        reportFailure(AppFailure.fromDio(error));
        handler.next(error);
      },
    ),
  );
  ref.onDispose(() => dio.close(force: true));
  return dio;
});
