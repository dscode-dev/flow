import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flow_mobile/core/auth/identity_api.dart';
import 'package:flow_mobile/core/auth/models.dart';

import 'support/auth_fakes.dart';

class HttpBoundary implements HttpClientAdapter {
  HttpBoundary(this.answer);
  final ResponseBody Function(RequestOptions) answer;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return answer(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('envelope sanitizado preserva código/request_id/Retry-After e não repete request', () async {
    final boundary = HttpBoundary(
      (_) => ResponseBody.fromString(
        jsonEncode({
          'error': {
            'code': 'rate_limited',
            'message': 'UNTRUSTED_SECRET',
            'request_id': 'request-123',
          },
        }),
        429,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          'retry-after': ['120'],
        },
      ),
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/'))
      ..httpClientAdapter = boundary;
    final api = DioIdentityApi(dio);
    await expectLater(
      api.challenge(phone: '+5581999999999'),
      throwsA(
        isA<AuthIssue>()
            .having((e) => e.code, 'code', 'rate_limited')
            .having((e) => e.requestId, 'requestId', 'request-123')
            .having((e) => e.retryAfter, 'retry', const Duration(seconds: 120))
            .having(
              (e) => e.message,
              'message',
              isNot(contains('UNTRUSTED_SECRET')),
            ),
      ),
    );
    expect(boundary.requests.length, 1);
    final request = boundary.requests.single;
    expect(request.path, 'v1/auth/phone/challenges');
    expect(request.queryParameters, isEmpty);
    expect(request.data, {'phone': '+5581999999999', 'purpose': 'login'});
    expect(request.headers.containsKey('Authorization'), false);
  });
  test(
    'somente bearer Flow nas rotas protegidas; logout 204 sem JSON',
    () async {
      final boundary = HttpBoundary((_) => ResponseBody.fromString('', 204));
      final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/'))
        ..httpClientAdapter = boundary;
      await DioIdentityApi(dio).logout('fa_flow-access');
      expect(
        boundary.requests.single.headers['Authorization'],
        'Bearer fa_flow-access',
      );
      expect(boundary.requests.single.data, isNull);
    },
  );
  test('ID token e OTP usam campos diferentes e nunca Authorization', () async {
    final boundary = HttpBoundary(
      (_) => ResponseBody.fromString(
        jsonEncode({
          'error': {'code': 'invalid_credential', 'request_id': 'r'},
        }),
        401,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      ),
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://api.example.test/'))
      ..httpClientAdapter = boundary;
    final api = DioIdentityApi(dio);
    for (final provider in ['PHONE', 'GOOGLE', 'APPLE']) {
      await expectLater(
        api.login(serverChallenge(), 'proof', provider),
        throwsA(isA<AuthIssue>()),
      );
    }
    expect(boundary.requests.map((r) => r.path), [
      'v1/auth/phone/verify',
      'v1/auth/google',
      'v1/auth/apple',
    ]);
    expect(boundary.requests.first.data['code'], 'proof');
    expect(boundary.requests[1].data['id_token'], 'proof');
    expect(
      boundary.requests.every((r) => !r.headers.containsKey('Authorization')),
      true,
    );
    expect(boundary.requests.length, 3);
  });
}
