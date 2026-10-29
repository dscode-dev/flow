import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/secure_store.dart';
import 'identity_api.dart';
import 'models.dart';
import 'social_provider.dart';

enum AuthStatus {
  initializing,
  unauthenticated,
  authenticating,
  challengePending,
  onboardingRequired,
  authenticated,
  refreshing,
  sessionExpired,
  restricted,
  error,
}

class AuthState {
  const AuthState(
    this.status, {
    this.user,
    this.issue,
    this.challenge,
    this.busy = false,
    this.retryAt,
    this.notice,
  });
  final AuthStatus status;
  final FlowUser? user;
  final AuthIssue? issue;
  final AuthChallenge? challenge;
  final bool busy;
  final DateTime? retryAt;
  final String? notice;
  bool get protected =>
      status == AuthStatus.authenticated ||
      status == AuthStatus.onboardingRequired;
}

class AuthController extends ValueNotifier<AuthState> {
  AuthController(this.api, this.store, this.social, {DateTime Function()? now})
    : now = now ?? DateTime.now,
      super(const AuthState(AuthStatus.initializing));
  final IdentityApi api;
  final SecureStore store;
  final SocialProvider social;
  final DateTime Function() now;
  LoginResult? _session;
  StoredSession? _stored;
  String? _phone;
  AuthChallenge? _challenge;
  DateTime? _retryAt, _verifyRetryAt;
  int _generation = 0;
  bool _disposed = false, _foreground = true, _onboardingBusy = false;
  Future<void> _writes = Future<void>.value();
  Future<void>? _refreshFlight;
  Timer? _expiry;
  void _emit(AuthState state) {
    if (!_disposed) value = state;
  }

  bool _current(int g) => !_disposed && g == _generation;
  Future<void> _write(Future<void> Function() action) {
    final next = _writes.then((_) => action());
    _writes = next.catchError((Object _) {});
    return next;
  }

  Future<void> _save(String data, int generation) => _write(() async {
    if (!_current(generation)) throw const AuthIssue('canceled');
    await store.writeSession(data);
  });
  AuthIssue _issue(Object e) =>
      e is AuthIssue ? e : const AuthIssue('unexpected');
  bool get canRequest =>
      !value.busy &&
      !{
        AuthStatus.error,
        AuthStatus.restricted,
        AuthStatus.authenticated,
        AuthStatus.onboardingRequired,
        AuthStatus.refreshing,
      }.contains(value.status) &&
      (_retryAt == null || !now().isBefore(_retryAt!));
  bool get canVerify =>
      !value.busy &&
      (_verifyRetryAt == null || !now().isBefore(_verifyRetryAt!));
  bool get canSubmit =>
      !value.busy && (_retryAt == null || !now().isBefore(_retryAt!));
  void _failure(Object error, {AuthStatus? status}) {
    final issue = _issue(error);
    if (issue.code == 'rate_limited') {
      _retryAt = now().add(issue.retryAfter ?? const Duration(seconds: 60));
    }
    _emit(
      AuthState(
        status ??
            (_challenge == null
                ? AuthStatus.unauthenticated
                : AuthStatus.challengePending),
        issue: issue,
        challenge: _challenge,
        retryAt: _retryAt,
      ),
    );
  }

  Future<void> restore() async {
    if (value.busy) return;
    final g = ++_generation;
    _emit(const AuthState(AuthStatus.initializing, busy: true));
    try {
      final raw = await _writes.then((_) => store.readSession());
      if (!_current(g)) return;
      if (raw == null) {
        _emit(const AuthState(AuthStatus.unauthenticated));
        return;
      }
      try {
        _stored = StoredSession.decode(raw);
      } catch (_) {
        await _end(
          AuthStatus.sessionExpired,
          const AuthIssue('session_expired'),
        );
        return;
      }
      if (!now().isBefore(_stored!.until)) {
        await _end(
          AuthStatus.sessionExpired,
          const AuthIssue('session_expired'),
        );
        return;
      }
      await refresh();
      if (_current(g) && _stored?.appleUser != null) await _checkApple(g);
    } catch (_) {
      if (_current(g)) {
        _emit(const AuthState(AuthStatus.error, issue: AuthIssue('storage')));
      }
    }
  }

  Future<void> startPhone(String phone) async {
    if (!canRequest) return;
    final g = ++_generation;
    _emit(
      AuthState(
        _challenge == null
            ? AuthStatus.authenticating
            : AuthStatus.challengePending,
        busy: true,
        challenge: _challenge,
        retryAt: _retryAt,
      ),
    );
    // Also bound retries on ambiguous send failures. Never auto-resend.
    _retryAt = now().add(const Duration(seconds: 60));
    try {
      final challenge = await api.challenge(phone: phone);
      if (!_current(g)) return;
      _phone = phone;
      _challenge = challenge;
      _verifyRetryAt = null;
      _retryAt = challenge.resendAt;
      _emit(
        AuthState(
          AuthStatus.challengePending,
          challenge: challenge,
          retryAt: _retryAt,
        ),
      );
    } catch (e) {
      if (_current(g)) {
        _challenge = null;
        _failure(e);
      }
    }
  }

  Future<void> resendPhone() async {
    if (_phone != null) await startPhone(_phone!);
  }

  Future<void> verifyPhone(String code) async {
    final challenge = _challenge;
    if (!canVerify || challenge == null) return;
    if (!now().isBefore(challenge.expiresAt)) {
      _failure(const AuthIssue('invalid_credential'));
      return;
    }
    final g = ++_generation;
    _emit(
      AuthState(
        AuthStatus.challengePending,
        challenge: challenge,
        busy: true,
        retryAt: _retryAt,
      ),
    );
    try {
      final result = await api.login(challenge, code, 'PHONE');
      await _accept(result, g);
    } catch (e) {
      if (_current(g)) {
        // A timeout may have consumed the proof. Clear it; require a fresh challenge.
        if (e is AuthIssue && e.code == 'rate_limited') {
          _verifyRetryAt = now().add(
            e.retryAfter ?? const Duration(seconds: 60),
          );
        }
        if (e is! AuthIssue || e.code == 'network') {
          _challenge = null;
        }
        if (e is AuthIssue && e.code == 'account_restricted') {
          await _end(AuthStatus.restricted, e);
        } else {
          _failure(e);
        }
      }
    }
  }

  Future<void> signInSocial(String provider) async {
    if (!canRequest) return;
    final g = ++_generation;
    _challenge = null;
    _emit(const AuthState(AuthStatus.authenticating, busy: true));
    try {
      await social.checkAvailability(provider);
      if (!_current(g)) return;
      final challenge = await api.challenge(provider: provider);
      if (!_current(g)) return;
      final nonce = challenge.nonce;
      if (nonce == null || nonce.isEmpty) throw const AuthIssue('unexpected');
      final proof = await social.authenticate(provider, nonce);
      if (!_current(g)) return;
      if (!now().isBefore(challenge.expiresAt)) {
        throw const AuthIssue('invalid_credential');
      }
      final result = await api.login(challenge, proof.token, provider);
      await _accept(result, g, appleUser: proof.appleUser);
    } catch (e) {
      if (_current(g)) {
        if (e is AuthIssue && e.code == 'account_restricted') {
          await _end(AuthStatus.restricted, e);
        } else {
          _failure(e);
        }
      }
    }
  }

  Future<void> _accept(LoginResult result, int g, {String? appleUser}) async {
    if (!_current(g)) {
      try {
        await api.logout(result.access);
      } catch (_) {
        /* best effort for a discarded login */
      }
      return;
    }
    final saved = StoredSession(
      result.refresh,
      result.sessionId,
      result.sessionUntil,
      appleUser: appleUser,
    );
    try {
      await _save(saved.encode(), g);
    } catch (_) {
      if (_current(g)) await _end(AuthStatus.error, const AuthIssue('storage'));
      return;
    }
    if (!_current(g)) return;
    _session = result;
    _stored = saved;
    _challenge = null;
    _phone = null;
    _retryAt = null;
    _publishUser(result.user);
  }

  void _publishUser(FlowUser user) {
    _emit(
      AuthState(
        user.onboardingRequired
            ? AuthStatus.onboardingRequired
            : AuthStatus.authenticated,
        user: user,
        busy: _onboardingBusy,
      ),
    );
    _schedule();
  }

  void _schedule() {
    _expiry?.cancel();
    if (!_foreground || _session == null) return;
    final ttl = _session!.accessUntil.difference(now());
    final accessAt = _session!.accessUntil.subtract(
      Duration(milliseconds: (ttl.inMilliseconds ~/ 10).clamp(0, 20000)),
    );
    final at = accessAt.isBefore(_session!.sessionUntil)
        ? accessAt
        : _session!.sessionUntil;
    final delay = at.difference(now());
    _expiry = Timer(delay.isNegative ? Duration.zero : delay, () {
      unawaited(refresh());
    });
  }

  Future<void> refresh() {
    final existing = _refreshFlight;
    if (existing != null) return existing;
    final flight = _rotate();
    _refreshFlight = flight;
    return flight.whenComplete(() {
      if (identical(_refreshFlight, flight)) _refreshFlight = null;
    });
  }

  Future<void> _rotate() async {
    final stored = _stored;
    if (stored == null) return;
    final g = _generation;
    _expiry?.cancel();
    if (!now().isBefore(stored.until)) {
      await _end(AuthStatus.sessionExpired, const AuthIssue('session_expired'));
      return;
    }
    _emit(AuthState(AuthStatus.refreshing, user: value.user, busy: true));
    try {
      // Crash-safe journal: after this write no restart can replay the old secret.
      await _save('{"v":1,"pending":true}', g);
      if (!_current(g)) return;
      final result = await api.refresh(stored.refresh);
      if (!_current(g)) return;
      if (result.sessionId != stored.sessionId) {
        throw const AuthIssue('unexpected');
      }
      await _accept(result, g, appleUser: stored.appleUser);
    } catch (e) {
      if (_current(g)) {
        await _end(
          e is AuthIssue && e.code == 'account_restricted'
              ? AuthStatus.restricted
              : AuthStatus.sessionExpired,
          e is AuthIssue && e.code == 'account_restricted'
              ? e
              : const AuthIssue('session_expired'),
        );
      }
    }
  }

  Future<T> authorized<T>(
    Future<T> Function(String access) action, {
    bool replaySafe = false,
  }) async {
    final g = _generation;
    if (_refreshFlight != null) await _refreshFlight;
    if (_session == null || !_current(g)) throw const AuthIssue('unauthorized');
    if (!now().isBefore(_session!.accessUntil)) await refresh();
    if (_session == null || !_current(g)) throw const AuthIssue('unauthorized');
    if (!now().isBefore(_session!.sessionUntil)) {
      await _end(AuthStatus.sessionExpired, const AuthIssue('session_expired'));
      throw const AuthIssue('unauthorized');
    }
    final access = _session!.access;
    try {
      final result = await action(access);
      if (!_current(g)) throw const AuthIssue('canceled');
      return result;
    } on AuthIssue catch (e) {
      if (!_current(g)) rethrow;
      if (e.code == 'account_restricted') {
        await _end(AuthStatus.restricted, e);
        rethrow;
      }
      if (e.status != 401 && e.code != 'unauthorized') rethrow;
      // A late 401 from an older access token must reuse the already rotated pair.
      if (_session?.access == access) await refresh();
      if (!replaySafe || _session == null || !_current(g)) {
        throw const AuthIssue('unauthorized');
      }
      try {
        final result = await action(_session!.access);
        if (!_current(g)) throw const AuthIssue('canceled');
        return result;
      } on AuthIssue catch (second) {
        if (_current(g) &&
            (second.status == 401 ||
                second.code == 'unauthorized' ||
                second.code == 'account_restricted')) {
          await _end(
            second.code == 'account_restricted'
                ? AuthStatus.restricted
                : AuthStatus.sessionExpired,
            second,
          );
        }
        rethrow;
      }
    }
  }

  Future<void> completeOnboarding(String name, String handle) async {
    if (!canSubmit || _onboardingBusy || _session == null) return;
    _onboardingBusy = true;
    final g = _generation;
    final user = value.user;
    _emit(AuthState(AuthStatus.onboardingRequired, user: user, busy: true));
    try {
      final result = await authorized(
        (access) =>
            api.onboarding(access, name.trim(), handle.trim().toLowerCase()),
      );
      if (_current(g)) {
        _onboardingBusy = false;
        _publishUser(result);
      }
    } catch (e) {
      if (_current(g) && _session != null) {
        final issue = _issue(e);
        if (issue.code == 'rate_limited') {
          _retryAt = now().add(issue.retryAfter ?? const Duration(seconds: 60));
        }
        _emit(
          AuthState(
            AuthStatus.onboardingRequired,
            retryAt: _retryAt,
            user: user,
            issue: _issue(e),
          ),
        );
      }
    } finally {
      _onboardingBusy = false;
    }
  }

  Future<void> revalidate() async {
    if (value.busy || _session == null) return;
    final g = _generation;
    _emit(AuthState(AuthStatus.initializing, user: value.user, busy: true));
    try {
      final user = await authorized(api.me, replaySafe: true);
      if (_current(g) && await _checkApple(g)) _publishUser(user);
    } catch (e) {
      if (_current(g) && _session != null) {
        _emit(AuthState(AuthStatus.error, issue: _issue(e)));
      }
    }
  }

  Future<bool> _checkApple(int g) async {
    final appleUser = _stored?.appleUser;
    if (appleUser == null) return true;
    try {
      if (!await social.appleAuthorized(appleUser)) {
        if (_current(g)) {
          await signOut(
            notice: 'Sua autorização Apple terminou. Entre novamente.',
          );
        }
        return false;
      }
    } catch (_) {
      // Unable to check is not proof of revocation. Backend remains authoritative.
    }
    return _current(g);
  }

  void lifecycle(bool foreground) {
    _foreground = foreground;
    _expiry?.cancel();
    if (foreground) unawaited(revalidate());
  }

  Future<void> signOut({String? notice}) async {
    final access = _session?.access;
    final g = ++_generation;
    api.cancelPending();
    _expiry?.cancel();
    _session = null;
    _stored = null;
    _phone = null;
    _challenge = null;
    _retryAt = null;
    _emit(const AuthState(AuthStatus.initializing, busy: true));
    var cleared = true;
    try {
      await _write(store.clearSession);
    } catch (_) {
      cleared = false;
    }
    var revoked = access == null;
    if (access != null) {
      try {
        await api.logout(access);
        revoked = true;
      } on AuthIssue catch (e) {
        revoked = e.status == 401 || e.code == 'unauthorized';
      } catch (_) {
        /* local exit still clears memory */
      }
    }
    if (!_current(g)) return;
    _emit(
      cleared
          ? AuthState(
              AuthStatus.unauthenticated,
              notice:
                  notice ??
                  (revoked
                      ? null
                      : 'Sessão removida deste aparelho. A revogação no servidor não pôde ser confirmada.'),
            )
          : const AuthState(AuthStatus.error, issue: AuthIssue('storage')),
    );
  }

  Future<void> _end(AuthStatus status, AuthIssue issue) async {
    final g = ++_generation;
    _emit(const AuthState(AuthStatus.initializing, busy: true));
    _expiry?.cancel();
    _session = null;
    _stored = null;
    _challenge = null;
    _phone = null;
    try {
      await _write(store.clearSession);
    } catch (_) {
      if (_current(g)) {
        _emit(const AuthState(AuthStatus.error, issue: AuthIssue('storage')));
      }
      return;
    }
    if (_current(g)) _emit(AuthState(status, issue: issue));
  }

  void backToWelcome() {
    if (value.busy ||
        value.status == AuthStatus.error ||
        value.status == AuthStatus.restricted) {
      return;
    }
    ++_generation;
    _challenge = null;
    _phone = null;
    _emit(AuthState(AuthStatus.unauthenticated, retryAt: _retryAt));
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    api.cancelPending();
    _expiry?.cancel();
    super.dispose();
  }
}

final authControllerProvider = Provider<AuthController>((ref) {
  final controller = AuthController(
    ref.watch(identityApiProvider),
    ref.watch(secureStoreProvider),
    ref.watch(socialProvider),
  );
  ref.onDispose(controller.dispose);
  unawaited(controller.restore());
  return controller;
});
