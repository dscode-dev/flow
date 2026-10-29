import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:sign_in_with_apple_platform_interface/sign_in_with_apple_platform_interface.dart';
import 'package:flow_mobile/core/auth/models.dart';
import 'package:flow_mobile/core/auth/social_provider.dart';

class GoogleBoundary extends GoogleSignInPlatform {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
  InitParameters? initParameters;
  int initializations = 0, signOuts = 0;
  Object? error;
  @override
  Future<void> init(InitParameters params) async {
    initParameters = params;
    initializations++;
  }

  @override
  Future<void> signOut(SignOutParams params) async {
    signOuts++;
  }

  @override
  Future<AuthenticationResults> authenticate(
    AuthenticateParameters params,
  ) async {
    if (error != null) throw error!;
    return const AuthenticationResults(
      user: GoogleSignInUserData(
        email: 'unused@example.test',
        id: 'unused-sub',
      ),
      authenticationTokens: AuthenticationTokenData(idToken: 'signed-id-token'),
    );
  }
}

class AppleBoundary extends SignInWithApplePlatform {
  String? receivedNonce;
  List<AppleIDAuthorizationScopes>? receivedScopes;
  Object? error;
  bool wrongState = false;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<AuthorizationCredentialAppleID> getAppleIDCredential({
    required List<AppleIDAuthorizationScopes> scopes,
    WebAuthenticationOptions? webAuthenticationOptions,
    String? nonce,
    String? state,
  }) async {
    receivedNonce = nonce;
    receivedScopes = scopes;
    if (error != null) throw error!;
    return AuthorizationCredentialAppleID(
      userIdentifier: 'native-user',
      givenName: null,
      familyName: null,
      email: null,
      identityToken: 'signed-apple-token',
      authorizationCode: 'unused-code',
      state: wrongState ? 'foreign-state' : state,
    );
  }

  @override
  Future<CredentialState> getCredentialState(String userIdentifier) async =>
      CredentialState.revoked;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });
  test('Google oficial usa novo adapter e nonce em cada tentativa, sem scopes extras', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final boundaries = <GoogleBoundary>[];
    final social = NativeSocialProvider(
      serverId: 'approved-client',
      googleFactory: () {
        final sdk = GoogleBoundary();
        boundaries.add(sdk);
        return sdk;
      },
    );
    expect(
      (await social.authenticate('GOOGLE', 'nonce-one')).token,
      'signed-id-token',
    );
    await social.authenticate('GOOGLE', 'nonce-two');
    expect(boundaries.length, 2);
    expect(boundaries.map((s) => s.initParameters!.nonce), [
      'nonce-one',
      'nonce-two',
    ]);
    expect(
      boundaries.every((s) => s.initializations == 1 && s.signOuts == 2),
      true,
    );
  });
  test(
    'Google distingue cancelamento, configuração e indisponibilidade',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      for (final pair in [
        (GoogleSignInExceptionCode.canceled, 'canceled'),
        (
          GoogleSignInExceptionCode.clientConfigurationError,
          'provider_configuration',
        ),
        (GoogleSignInExceptionCode.uiUnavailable, 'provider_unavailable'),
      ]) {
        final sdk = GoogleBoundary()
          ..error = GoogleSignInException(code: pair.$1);
        final social = NativeSocialProvider(
          serverId: 'approved-server',
          iosId: 'approved-ios',
          iosConfigurationCheck: (_) async => true,
          googleFactory: () => sdk,
        );
        await expectLater(
          social.authenticate('GOOGLE', 'nonce'),
          throwsA(isA<AuthIssue>().having((e) => e.code, 'code', pair.$2)),
        );
        expect(sdk.signOuts, 2);
      }
    },
  );
  test(
    'callback iOS ausente é detectado antes de abrir o SDK Google',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      var opened = false;
      final social = NativeSocialProvider(
        serverId: 'approved-server',
        iosId: 'approved-ios',
        iosConfigurationCheck: (_) async => false,
        googleFactory: () {
          opened = true;
          return GoogleBoundary();
        },
      );
      await expectLater(
        social.authenticate('GOOGLE', 'nonce'),
        throwsA(
          isA<AuthIssue>().having(
            (e) => e.code,
            'code',
            'provider_configuration',
          ),
        ),
      );
      expect(opened, false);
    },
  );
  test(
    'configuração ausente e Apple no Android falham antes de login nativo',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final social = NativeSocialProvider(serverId: '');
      await expectLater(
        social.authenticate('GOOGLE', 'nonce'),
        throwsA(
          isA<AuthIssue>().having(
            (e) => e.code,
            'code',
            'provider_configuration',
          ),
        ),
      );
      await expectLater(
        social.authenticate('APPLE', 'nonce'),
        throwsA(
          isA<AuthIssue>().having((e) => e.code, 'code', 'apple_unavailable'),
        ),
      );
    },
  );
  test('Apple mantém nonce final, confere state e dispensa nome/e-mail/código OAuth', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final previous = SignInWithApplePlatform.instance;
    addTearDown(() {
      SignInWithApplePlatform.instance = previous;
    });
    final sdk = AppleBoundary();
    SignInWithApplePlatform.instance = sdk;
    final social = NativeSocialProvider(appleEnabled: true);
    final proof = await social.authenticate('APPLE', 'already-sha256-hex');
    expect(sdk.receivedNonce, 'already-sha256-hex');
    expect(sdk.receivedScopes, isEmpty);
    expect(proof.token, 'signed-apple-token');
    expect(proof.appleUser, 'native-user');
    expect(await social.appleAuthorized('native-user'), false);
    sdk.wrongState = true;
    await expectLater(
      social.authenticate('APPLE', 'new-nonce'),
      throwsA(
        isA<AuthIssue>().having((e) => e.code, 'code', 'invalid_credential'),
      ),
    );
    sdk.error = const SignInWithAppleAuthorizationException(
      code: AuthorizationErrorCode.canceled,
      message: 'not displayed',
    );
    await expectLater(
      social.authenticate('APPLE', 'new-nonce'),
      throwsA(isA<AuthIssue>().having((e) => e.code, 'code', 'canceled')),
    );
  });
}
