import 'dart:async';

import 'package:flow_mobile/core/auth/auth_state.dart';
import 'package:flow_mobile/core/auth/identity_api.dart';
import 'package:flow_mobile/core/auth/models.dart';
import 'package:flow_mobile/core/auth/social_provider.dart';
import 'package:flow_mobile/core/storage/secure_store.dart';

final instant = DateTime.utc(2026, 10, 29, 12);
const newUser = FlowUser('user', true, '', null);
const completeUser = FlowUser('user', false, 'Ana', 'ana_flow');
LoginResult result({
  String refresh = 'fr_new.secret',
  String access = 'fa_new',
  FlowUser user = newUser,
  DateTime? until,
}) => LoginResult(
  access,
  refresh,
  'session',
  instant.add(const Duration(minutes: 10)),
  until ?? instant.add(const Duration(days: 30)),
  user,
);
AuthChallenge serverChallenge() => AuthChallenge(
  'challenge',
  instant.add(const Duration(minutes: 5)),
  instant.add(const Duration(seconds: 60)),
  'server-single-use-nonce',
);

class MemoryStore implements SecureStore {
  String? data;
  bool failRead = false, failWrite = false, failClear = false;
  final writes = <String>[];
  Completer<void>? writeGate;
  @override
  Future<String?> readSession() async {
    if (failRead) throw StateError('read');
    return data;
  }

  @override
  Future<void> writeSession(String value) async {
    writes.add(value);
    await writeGate?.future;
    if (failWrite) throw StateError('write');
    data = value;
  }

  @override
  Future<void> clearSession() async {
    if (failClear) throw StateError('clear');
    data = null;
  }
}

class FakeApi implements IdentityApi {
  @override
  void cancelPending() {}
  int refreshCalls = 0,
      loginCalls = 0,
      challengeCalls = 0,
      logoutCalls = 0,
      meCalls = 0;
  String? lastRefresh, lastCredential, lastPhone;
  LoginResult next = result();
  Object? refreshError,
      loginError,
      challengeError,
      logoutError,
      onboardingError,
      meError;
  Completer<LoginResult>? refreshGate, loginGate;
  Completer<FlowUser>? onboardingGate;
  Completer<void>? logoutGate;
  FlowUser serverUser = newUser;
  @override
  Future<AuthChallenge> challenge({String? phone, String? provider}) async {
    challengeCalls++;
    lastPhone = phone;
    if (challengeError != null) throw challengeError!;
    return serverChallenge();
  }

  @override
  Future<LoginResult> login(
    AuthChallenge challenge,
    String credential,
    String provider,
  ) async {
    loginCalls++;
    lastCredential = credential;
    if (loginError != null) throw loginError!;
    return loginGate?.future ?? next;
  }

  @override
  Future<LoginResult> refresh(String refresh) async {
    refreshCalls++;
    lastRefresh = refresh;
    if (refreshError != null) throw refreshError!;
    return refreshGate?.future ?? next;
  }

  @override
  Future<FlowUser> me(String access) async {
    meCalls++;
    if (meError != null) throw meError!;
    return serverUser;
  }

  @override
  Future<FlowUser> onboarding(String access, String name, String handle) async {
    if (onboardingError != null) throw onboardingError!;
    return onboardingGate?.future ?? completeUser;
  }

  @override
  Future<void> logout(String access) async {
    logoutCalls++;
    if (logoutCalls == 1) await logoutGate?.future;
    if (logoutError != null) throw logoutError!;
  }
}

class FakeSocial implements SocialProvider {
  @override
  Future<void> checkAvailability(String provider) async {}
  Object? error;
  bool authorized = true;
  String? receivedNonce;
  int calls = 0;
  @override
  Future<SocialProof> authenticate(String provider, String nonce) async {
    calls++;
    receivedNonce = nonce;
    if (error != null) throw error!;
    return SocialProof(
      'provider-id-token',
      appleUser: provider == 'APPLE' ? 'apple-native-user' : null,
    );
  }

  @override
  Future<bool> appleAuthorized(String user) async => authorized;
}

class Rig {
  final api = FakeApi();
  final store = MemoryStore();
  final social = FakeSocial();
  DateTime clock = instant;
  late final auth = AuthController(api, store, social, now: () => clock);
  Future<void> login({
    bool completed = false,
    String provider = 'GOOGLE',
  }) async {
    api.next = result(user: completed ? completeUser : newUser);
    await auth.signInSocial(provider);
  }
}
