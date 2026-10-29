// Executed only through make identity-mobile-contract, against real Go/PG.
// Provider proofs are signed fixture tokens from an isolated test-only bridge.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flow_mobile/core/auth/auth_state.dart';
import 'package:flow_mobile/core/auth/identity_api.dart';
import 'package:flow_mobile/core/auth/models.dart';
import 'package:flow_mobile/core/auth/social_provider.dart';

import 'support/auth_fakes.dart' show MemoryStore;

class ContractProofs implements SocialProvider {
  ContractProofs(this.http);
  final Dio http;
  @override
  Future<void> checkAvailability(String provider) async {}
  @override
  Future<bool> appleAuthorized(String user) async => true;
  @override
  Future<SocialProof> authenticate(String provider, String nonce) async {
    final reply = await http.post<Map<String, dynamic>>(
      '__fixture/proof',
      data: {'Provider': provider, 'Nonce': nonce},
    );
    return SocialProof(reply.data!['token'] as String);
  }
}

class ObservedApi extends DioIdentityApi {
  ObservedApi(super.dio);
  LoginResult? last;
  int rotations = 0;
  @override
  Future<LoginResult> login(
    AuthChallenge challenge,
    String credential,
    String provider,
  ) async {
    return last = await super.login(challenge, credential, provider);
  }

  @override
  Future<LoginResult> refresh(String refresh) async {
    rotations++;
    return last = await super.refresh(refresh);
  }
}

void main() {
  const origin = String.fromEnvironment('FLOW_IDENTITY_CONTRACT_URL');
  test(
    'Flutter Dio/controller ↔ Go HTTP/OpenAPI/PostgreSQL; upstreams são fixtures',
    () async {
      final http = Dio(
        BaseOptions(
          baseUrl: origin,
          followRedirects: false,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      addTearDown(() => http.close(force: true));
      final api = ObservedApi(http);
      final store = MemoryStore();
      final proofs = ContractProofs(http);
      var auth = AuthController(api, store, proofs);
      addTearDown(() => auth.dispose());
      await auth.restore();
      await auth.signInSocial('GOOGLE');
      expect(auth.value.status, AuthStatus.onboardingRequired);
      final googleUser = auth.value.user!.id;
      await auth.completeOnboarding('Ana de teste', 'ana_contract');
      expect(auth.value.status, AuthStatus.authenticated);
      expect(
        (await auth.authorized(api.me, replaySafe: true)).handle,
        'ana_contract',
      );
      final stored = StoredSession.decode(store.data!);
      final before = api.rotations;
      await Future.wait(List.generate(8, (_) => auth.refresh()));
      expect(api.rotations - before, 1);
      expect(StoredSession.decode(store.data!).refresh != stored.refresh, true);
      expect(
        (await auth.authorized(api.me, replaySafe: true)).id == googleUser,
        true,
      );

      // A real replay revokes the family in PostgreSQL, including the newer access.
      await expectLater(
        api.refresh(stored.refresh),
        throwsA(
          isA<AuthIssue>().having((e) => e.code, 'code', 'invalid_credential'),
        ),
      );
      await auth.revalidate();
      expect(auth.value.status, AuthStatus.sessionExpired);
      expect(store.data, isNull);

      // Returning identity is the same account and keeps server-confirmed onboarding.
      await auth.signInSocial('GOOGLE');
      expect(auth.value.status, AuthStatus.authenticated);
      expect(auth.value.user!.id == googleUser, true);
      auth.dispose();
      auth = AuthController(api, store, proofs);
      await auth.restore();
      expect(auth.value.status, AuthStatus.authenticated);
      expect(auth.value.user!.id == googleUser, true);

      // Backend access expiry forces 401; logout rotates once, then obtains 204.
      await http.post<void>(
        '__fixture/expire-access',
        data: {'User': googleUser},
      );
      final oldAccess = api.last!.access;
      final beforeExit = api.rotations;
      await auth.signOut();
      expect(api.rotations - beforeExit, 1);
      expect(auth.value.notice, isNull);
      expect(store.data, isNull);
      await expectLater(
        api.me(oldAccess),
        throwsA(isA<AuthIssue>().having((e) => e.status, 'status', 401)),
      );
      await expectLater(
        api.me(api.last!.access),
        throwsA(isA<AuthIssue>().having((e) => e.status, 'status', 401)),
      );

      await auth.signInSocial('APPLE');
      expect(auth.value.status, AuthStatus.onboardingRequired);
      final appleUser = auth.value.user!.id;
      expect(
        appleUser != googleUser,
        true,
      ); // Same fixture email never merges accounts.
      await http.post<void>('__fixture/suspend', data: {'User': appleUser});
      await auth.revalidate();
      expect(auth.value.status, AuthStatus.restricted);
      expect(store.data, isNull);

      // Actual Go phone contract, with Twilio replaced ONLY at its test HTTP boundary.
      final phone = await api.challenge(phone: '+5511999999999');
      expect(phone.nonce, isNull);
      expect(phone.resendAt.isAfter(DateTime.now()), true);
      await expectLater(
        api.challenge(phone: '+5511999999999'),
        throwsA(isA<AuthIssue>().having((e) => e.code, 'code', 'rate_limited')),
      );
      await expectLater(
        api.login(phone, '000000', 'PHONE'),
        throwsA(
          isA<AuthIssue>().having((e) => e.code, 'code', 'invalid_credential'),
        ),
      );
      final phoneLogin = await api.login(phone, '123456', 'PHONE');
      expect(phoneLogin.user.onboardingRequired, true);
      await expectLater(
        api.login(phone, '123456', 'PHONE'),
        throwsA(
          isA<AuthIssue>().having((e) => e.code, 'code', 'invalid_credential'),
        ),
      );
      await api.logout(phoneLogin.access);
      // If native storage fails after login, the real newly-issued session is revoked.
      final brokenStore = MemoryStore()..failWrite = true;
      final rejected = AuthController(api, brokenStore, proofs);
      try {
        await rejected.signInSocial('GOOGLE');
        expect(rejected.value.issue?.code, 'storage');
        await expectLater(
          api.me(api.last!.access),
          throwsA(isA<AuthIssue>().having((e) => e.status, 'status', 401)),
        );
      } finally {
        rejected.dispose();
      }
      await expectLater(
        api.me(phoneLogin.access),
        throwsA(isA<AuthIssue>().having((e) => e.status, 'status', 401)),
      );
    },
    skip: origin.isEmpty
        ? 'Use make identity-mobile-contract; sem fornecedor real.'
        : false,
  );
}
