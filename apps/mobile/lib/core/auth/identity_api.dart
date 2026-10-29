import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/http_client.dart';
import 'models.dart';

abstract interface class IdentityApi {
  void cancelPending();
  Future<AuthChallenge> challenge({String? phone, String? provider});
  Future<LoginResult> login(
    AuthChallenge challenge,
    String credential,
    String provider,
  );
  Future<LoginResult> refresh(String refresh);
  Future<FlowUser> me(String access);
  Future<FlowUser> onboarding(String access, String name, String handle);
  Future<void> logout(String access);
}

class DioIdentityApi implements IdentityApi {
  DioIdentityApi(this.dio, {DateTime Function()? now})
    : now = now ?? DateTime.now;
  final Dio dio;
  final _pending = <CancelToken>{};
  @override
  void cancelPending() {
    for (final token in _pending.toList()) {
      token.cancel();
    }
  }

  final DateTime Function() now;
  Map<String, String> get device => {
    'platform': defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
    'app_version': '0.1.0',
  };
  Future<Map<String, dynamic>> _call(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? access,
  }) async {
    final cancellation = CancelToken();
    _pending.add(cancellation);
    // No retries: in particular, refresh and consumed proofs are single-use.
    try {
      final response = await dio.request<dynamic>(
        path,
        data: body,
        cancelToken: cancellation,
        options: Options(
          method: method,
          headers: access == null ? null : {'Authorization': 'Bearer $access'},
        ),
      );
      return response.data == null || response.data == ''
          ? <String, dynamic>{}
          : response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      final data = e.response?.data;
      final envelope = data is Map ? data['error'] : null;
      final retry = int.tryParse(
        e.response?.headers.value('retry-after') ?? '',
      );
      final code = envelope is Map && envelope['code'] is String
          ? envelope['code'] as String
          : (e.response?.statusCode == 401
                ? 'unauthorized'
                : e.response?.statusCode == 403
                ? 'account_restricted'
                : e.type == DioExceptionType.cancel
                ? 'canceled'
                : e.response == null
                ? 'network'
                : 'unexpected');
      // Untrusted server messages/details are intentionally not displayed/logged.
      throw AuthIssue(
        code,
        status: e.response?.statusCode,
        requestId:
            envelope is Map &&
                envelope['request_id'] is String &&
                RegExp(r'^[a-zA-Z0-9_-]{1,100}$')
                    .hasMatch(envelope['request_id'] as String)
            ? envelope['request_id'] as String
            : null,
        retryAfter: retry != null && retry > 0
            ? Duration(seconds: retry)
            : null,
      );
    } on FormatException {
      throw const AuthIssue('unexpected');
    } on TypeError {
      throw const AuthIssue('unexpected');
    } finally {
      _pending.remove(cancellation);
    }
  }

  @override
  Future<AuthChallenge> challenge({String? phone, String? provider}) async =>
      AuthChallenge.fromJson(
        await _call(
          'POST',
          phone != null
              ? 'v1/auth/phone/challenges'
              : 'v1/auth/oidc/challenges',
          body: {'phone': ?phone, 'provider': ?provider, 'purpose': 'login'},
        ),
        now(),
      );
  @override
  Future<LoginResult> login(
    AuthChallenge challenge,
    String credential,
    String provider,
  ) async => LoginResult.fromJson(
    await _call(
      'POST',
      'v1/auth/${provider == 'PHONE' ? 'phone/verify' : provider.toLowerCase()}',
      body: {
        'challenge_id': challenge.id,
        provider == 'PHONE' ? 'code' : 'id_token': credential,
        'device': device,
      },
    ),
    now(),
  );
  @override
  Future<LoginResult> refresh(String refresh) async => LoginResult.fromJson(
    await _call('POST', 'v1/auth/refresh', body: {'refresh_token': refresh}),
    now(),
  );
  @override
  Future<FlowUser> me(String access) async =>
      FlowUser.fromJson(await _call('GET', 'v1/me', access: access));
  @override
  Future<FlowUser> onboarding(
    String access,
    String name,
    String handle,
  ) async => FlowUser.fromJson(
    await _call(
      'PATCH',
      'v1/me/onboarding',
      access: access,
      body: {'display_name': name, 'handle': handle},
    ),
  );
  @override
  Future<void> logout(String access) async {
    await _call('POST', 'v1/auth/logout', access: access);
  }
}

final identityApiProvider = Provider<IdentityApi>(
  (ref) => DioIdentityApi(ref.watch(httpClientProvider)),
);
