import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in_android/google_sign_in_android.dart';
import 'package:google_sign_in_ios/google_sign_in_ios.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'models.dart';

class SocialProof {
  const SocialProof(this.token, {this.appleUser});
  final String token;
  final String? appleUser;
  @override
  String toString() => 'SocialProof(redacted)';
}

abstract interface class SocialProvider {
  Future<void> checkAvailability(String provider);
  Future<SocialProof> authenticate(String provider, String nonce);
  Future<bool> appleAuthorized(String user);
}

class NativeSocialProvider implements SocialProvider {
  NativeSocialProvider({
    this.serverId = const String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID'),
    this.iosId = const String.fromEnvironment('GOOGLE_IOS_CLIENT_ID'),
    this.appleEnabled = const bool.fromEnvironment('APPLE_SIGN_IN_ENABLED'),
    this.googleFactory,
    this.iosConfigurationCheck,
  });
  final String serverId, iosId;
  final bool appleEnabled;
  final GoogleSignInPlatform Function()? googleFactory;
  final Future<bool> Function(String clientId)? iosConfigurationCheck;
  bool _busy = false;
  @override
  Future<void> checkAvailability(String provider) async {
    try {
      if (kIsWeb ||
          !{
            TargetPlatform.iOS,
            TargetPlatform.android,
          }.contains(defaultTargetPlatform)) {
        throw const AuthIssue('provider_configuration');
      }
      if (provider == 'APPLE') {
        if (defaultTargetPlatform != TargetPlatform.iOS) {
          throw const AuthIssue('apple_unavailable');
        }
        if (!appleEnabled) throw const AuthIssue('provider_configuration');
        if (!await SignInWithApple.isAvailable()) {
          throw const AuthIssue('apple_unavailable');
        }
        return;
      }
      if (provider != 'GOOGLE') throw const AuthIssue('invalid_request');
      if (serverId.isEmpty ||
          (defaultTargetPlatform == TargetPlatform.iOS && iosId.isEmpty)) {
        throw const AuthIssue('provider_configuration');
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final check =
            iosConfigurationCheck ??
            (String clientId) async =>
                await const MethodChannel('flow/auth_configuration')
                    .invokeMethod<bool>('googleIosReady', clientId) ??
                false;
        if (!await check(iosId)) {
          throw const AuthIssue('provider_configuration');
        }
      }
    } on AuthIssue {
      rethrow;
    } catch (_) {
      throw const AuthIssue('provider_configuration');
    }
  }

  @override
  Future<SocialProof> authenticate(String provider, String nonce) async {
    if (_busy) throw const AuthIssue('unexpected');
    _busy = true;
    try {
      await checkAvailability(provider);
      if (provider == 'APPLE') {
        final random = Random.secure();
        final state = base64UrlEncode(
          List<int>.generate(32, (_) => random.nextInt(256)),
        );
        final result = await SignInWithApple.getAppleIDCredential(
          scopes: const [],
          nonce: nonce,
          state: state,
        ); // nonce already hashed by backend.
        if (result.state != state ||
            result.identityToken == null ||
            result.identityToken!.isEmpty) {
          throw const AuthIssue('invalid_credential');
        }
        return SocialProof(
          result.identityToken!,
          appleUser: result.userIdentifier,
        );
      }
      // The official singleton only accepts nonce at its once-only initialize.
      // Fresh official federated adapter, initialized once per serialized attempt.
      final GoogleSignInPlatform sdk =
          (googleFactory ??
          () => defaultTargetPlatform == TargetPlatform.android
              ? GoogleSignInAndroid()
              : GoogleSignInIOS())();
      await sdk.init(
        InitParameters(
          nonce: nonce,
          serverClientId: serverId,
          clientId: iosId.isEmpty ? null : iosId,
        ),
      );
      try {
        await sdk.signOut(const SignOutParams());
        final result = await sdk.authenticate(const AuthenticateParameters());
        final token = result.authenticationTokens.idToken;
        if (token == null || token.isEmpty) {
          throw const AuthIssue('invalid_credential');
        }
        return SocialProof(token);
      } finally {
        // Clear native account/token cache without revoking provider consent.
        try {
          await sdk.signOut(const SignOutParams());
        } catch (_) {
          /* no logging */
        }
      }
    } on GoogleSignInException catch (e) {
      throw AuthIssue(
        e.code == GoogleSignInExceptionCode.canceled
            ? 'canceled'
            : {
                GoogleSignInExceptionCode.clientConfigurationError,
                GoogleSignInExceptionCode.providerConfigurationError,
              }.contains(e.code)
            ? 'provider_configuration'
            : 'provider_unavailable',
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      throw AuthIssue(
        e.code == AuthorizationErrorCode.canceled
            ? 'canceled'
            : 'provider_unavailable',
      );
    } on AuthIssue {
      rethrow;
    } catch (_) {
      throw const AuthIssue('provider_unavailable');
    } finally {
      _busy = false;
    }
  }

  @override
  Future<bool> appleAuthorized(String user) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return true;
    final status = await SignInWithApple.getCredentialState(user);
    return status != CredentialState.revoked &&
        status != CredentialState.notFound;
  }
}

final socialProvider = Provider<SocialProvider>(
  (ref) => NativeSocialProvider(),
);
