import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flow_mobile/core/auth/auth_state.dart';
import 'package:flow_mobile/core/auth/models.dart';
import 'package:flow_mobile/core/navigation/router.dart';

import 'support/auth_fakes.dart';

Future<void> flush() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late Rig r;
  setUp(() {
    r = Rig();
  });
  tearDown(() {
    r.auth.dispose();
  });
  test('inicialização sem sessão permite welcome sem rede', () async {
    await r.auth.restore();
    expect(r.auth.value.status, AuthStatus.unauthenticated);
    expect(r.api.refreshCalls, 0);
  });
  test(
    'login passa nonce exato e mantém credencial externa fora do armazenamento',
    () async {
      await r.login();
      expect(r.social.receivedNonce, 'server-single-use-nonce');
      expect(r.api.lastCredential, 'provider-id-token');
      expect(r.auth.value.status, AuthStatus.onboardingRequired);
      expect(r.store.data, isNot(contains('provider-id-token')));
      expect(r.store.data, isNot(contains('fa_new')));
      expect(r.store.data, isNot(contains('display_name')));
    },
  );
  test('cancelamento e configuração inválida não estabelecem sessão', () async {
    for (final code in [
      'canceled',
      'provider_configuration',
      'provider_unavailable',
    ]) {
      r.social.error = AuthIssue(code);
      await r.login();
      expect(r.auth.value.issue?.code, code);
      expect(r.api.loginCalls, 0);
      expect(r.store.data, isNull);
    }
  });
  test('duplo toque social faz uma única prova', () async {
    r.api.loginGate = Completer<LoginResult>();
    final first = r.auth.signInSocial('GOOGLE');
    await flush();
    await r.auth.signInSocial('GOOGLE');
    expect(r.api.challengeCalls, 1);
    r.api.loginGate!.complete(result());
    await first;
  });
  test('refresh concorrente e 401 atrasado fazem uma só rotação', () async {
    await r.login(completed: true);
    r.api.refreshGate = Completer<LoginResult>();
    var attempts = 0;
    Future<int> operation(String access) async {
      attempts++;
      if (access == 'fa_new') {
        throw const AuthIssue('unauthorized', status: 401);
      }
      return 42;
    }

    final futures = List.generate(
      6,
      (_) => r.auth.authorized(operation, replaySafe: true),
    );
    await flush();
    expect(r.api.refreshCalls, 1);
    expect(jsonDecode(r.store.data!)['pending'], true);
    r.api.refreshGate!.complete(
      result(
        access: 'fa_rotated',
        refresh: 'fr_rotated.secret',
        user: completeUser,
      ),
    );
    expect(await Future.wait(futures), everyElement(42));
    expect(r.api.refreshCalls, 1);
    expect(attempts, 12);
    expect(StoredSession.decode(r.store.data!).refresh, 'fr_rotated.secret');
  });
  test(
    'novo access só fica disponível depois da persistência rotacionada',
    () async {
      await r.login();
      r.api.refreshGate = Completer<LoginResult>();
      final rotating = r.auth.refresh();
      await flush();
      r.store.writeGate = Completer<void>();
      r.api.refreshGate!.complete(
        result(access: 'fa_rotated', refresh: 'fr_rotated.secret'),
      );
      await flush();
      var sent = false;
      final protected = r.auth.authorized((access) async {
        sent = true;
        return access;
      });
      await flush();
      expect(sent, false);
      r.store.writeGate!.complete();
      await rotating;
      expect(await protected, 'fa_rotated');
    },
  );
  test(
    'timeout ambíguo não repete refresh e reinício não o recupera',
    () async {
      await r.login();
      r.api.refreshError = const AuthIssue('network');
      await Future.wait([r.auth.refresh(), r.auth.refresh()]);
      expect(r.api.refreshCalls, 1);
      expect(r.auth.value.status, AuthStatus.sessionExpired);
      expect(r.store.data, isNull);
      await r.auth.restore();
      expect(r.api.refreshCalls, 1);
    },
  );
  test(
    'journal interrompido, JSON inválido e sessão expirada falham fechados',
    () async {
      for (final raw in [
        '{"v":1,"pending":true}',
        'invalid-json',
        StoredSession(
          'fr_old.secret',
          'session',
          instant.subtract(const Duration(seconds: 1)),
        ).encode(),
      ]) {
        r.store.data = raw;
        await r.auth.restore();
        expect(r.auth.value.status, AuthStatus.sessionExpired);
        expect(r.api.refreshCalls, 0);
        expect(r.store.data, isNull);
      }
    },
  );
  test(
    'restauração renova e retoma onboarding pela resposta do servidor',
    () async {
      r.store.data = StoredSession(
        'fr_old.secret',
        'session',
        instant.add(const Duration(days: 1)),
      ).encode();
      await r.auth.restore();
      expect(r.api.lastRefresh, 'fr_old.secret');
      expect(r.auth.value.status, AuthStatus.onboardingRequired);
      expect(StoredSession.decode(r.store.data!).refresh, 'fr_new.secret');
    },
  );
  test('falha de armazenamento nunca libera área autenticada', () async {
    r.store.failWrite = true;
    await r.login();
    expect(r.auth.value.status, AuthStatus.error);
    expect(r.auth.value.issue?.code, 'storage');
    expect(r.api.logoutCalls, 1);
    expect(r.store.data, isNull);
    r.store.failRead = true;
    await r.auth.restore();
    expect(r.auth.value.status, AuthStatus.error);
  });
  test('falha na limpeza impede novo login até limpeza explícita', () async {
    await r.login();
    r.store.failClear = true;
    await r.auth.signOut();
    expect(r.auth.value.status, AuthStatus.error);
    expect(authRedirect(r.auth.value, '/app'), '/session');
    r.store.failClear = false;
    await r.auth.signOut();
    expect(r.store.data, isNull);
    expect(r.auth.value.status, AuthStatus.unauthenticated);
  });
  test(
    'logout offline remove segredos e informa revogação não confirmada',
    () async {
      await r.login();
      r.api.logoutError = const AuthIssue('network');
      await r.auth.signOut();
      expect(r.store.data, isNull);
      expect(r.auth.value.notice, contains('não pôde ser confirmada'));
      expect(r.auth.value.status, AuthStatus.unauthenticated);
    },
  );
  test('resposta de login atrasada não revive sessão após saída', () async {
    r.api.loginGate = Completer<LoginResult>();
    final login = r.auth.signInSocial('GOOGLE');
    await flush();
    await r.auth.signOut();
    r.api.loginGate!.complete(result());
    await login;
    expect(r.auth.value.status, AuthStatus.unauthenticated);
    expect(r.store.data, isNull);
  });
  test('logout durante refresh não permite gravar o token atrasado', () async {
    await r.login();
    r.api.refreshGate = Completer<LoginResult>();
    final refresh = r.auth.refresh();
    await flush();
    await r.auth.signOut();
    r.api.refreshGate!.complete(result(refresh: 'fr_late.secret'));
    await refresh;
    expect(r.store.data, isNull);
    expect(r.auth.value.status, AuthStatus.unauthenticated);
  });
  test(
    'onboarding só termina após confirmação e erro mantém formulário',
    () async {
      await r.login();
      r.api.onboardingError = const AuthIssue('handle_unavailable');
      await r.auth.completeOnboarding('Ana', 'ana_flow');
      expect(r.auth.value.status, AuthStatus.onboardingRequired);
      expect(r.auth.value.issue?.code, 'handle_unavailable');
      r.api.onboardingError = null;
      r.api.onboardingGate = Completer<FlowUser>();
      final submit = r.auth.completeOnboarding('Ana', 'ana_flow');
      await flush();
      expect(r.auth.value.busy, true);
      expect(r.auth.value.status, AuthStatus.onboardingRequired);
      r.api.onboardingGate!.complete(completeUser);
      await submit;
      expect(r.auth.value.status, AuthStatus.authenticated);
    },
  );
  test('restrição 403 e revogação 401 descartam sessão', () async {
    await r.login();
    r.api.meError = const AuthIssue('account_restricted', status: 403);
    await r.auth.revalidate();
    expect(r.auth.value.status, AuthStatus.restricted);
    expect(r.store.data, isNull);
    await r.auth.signOut();
    await r.login();
    r.api.meError = const AuthIssue('unauthorized', status: 401);
    r.api.refreshError = const AuthIssue('unauthorized', status: 401);
    await r.auth.revalidate();
    expect(r.auth.value.status, AuthStatus.sessionExpired);
    expect(r.store.data, isNull);
  });
  test('revogação Apple ao retornar encerra sessão Flow', () async {
    await r.login(provider: 'APPLE');
    r.social.authorized = false;
    await r.auth.revalidate();
    expect(r.auth.value.status, AuthStatus.unauthenticated);
    expect(r.api.logoutCalls, 1);
    expect(r.store.data, isNull);
  });
  test('expiração absoluta não envia refresh', () async {
    await r.login();
    r.clock = instant.add(const Duration(days: 31));
    await r.auth.refresh();
    expect(r.api.refreshCalls, 0);
    expect(r.auth.value.status, AuthStatus.sessionExpired);
  });
  test(
    'OTP respeita cooldown, expiração e erro sem simular validação',
    () async {
      await r.auth.restore();
      await r.auth.startPhone('+5581999999999');
      await r.auth.resendPhone();
      expect(r.api.challengeCalls, 1);
      r.api.loginError = const AuthIssue('invalid_credential');
      await r.auth.verifyPhone('123456');
      expect(r.auth.value.status, AuthStatus.challengePending);
      expect(r.auth.value.issue?.code, 'invalid_credential');
      r.clock = instant.add(const Duration(minutes: 6));
      await r.auth.verifyPhone('123456');
      expect(r.api.loginCalls, 1);
      await r.auth.resendPhone();
      expect(r.api.challengeCalls, 2);
    },
  );
  test('429 usa Retry-After sem retry automático', () async {
    r.api.challengeError = const AuthIssue(
      'rate_limited',
      retryAfter: Duration(seconds: 120),
    );
    await r.auth.startPhone('+5581999999999');
    expect(r.auth.value.retryAt, instant.add(const Duration(seconds: 120)));
    await r.auth.startPhone('+5581999999999');
    expect(r.api.challengeCalls, 1);
  });
  test(
    'logout concorrente compartilha conclusão antes de permitir nova sessão',
    () async {
      await r.login();
      r.api.logoutGate = Completer<void>();
      final oldLogout = r.auth.signOut();
      await flush();
      final secondLogout = r.auth.signOut();
      expect(identical(secondLogout, oldLogout), true);
      await r.login(completed: true);
      expect(r.auth.value.busy, true);
      r.api.logoutGate!.complete();
      await Future.wait([oldLogout, secondLogout]);
      await r.login(completed: true);
      expect(r.auth.value.status, AuthStatus.authenticated);
      expect(r.store.data, isNotNull);
    },
  );
  test(
    '429 na prova bloqueia confirmações sem impedir leitura do erro',
    () async {
      await r.auth.restore();
      await r.auth.startPhone('+5581999999999');
      r.api.loginError = const AuthIssue(
        'rate_limited',
        retryAfter: Duration(seconds: 120),
      );
      await r.auth.verifyPhone('123456');
      await r.auth.verifyPhone('123456');
      expect(r.api.loginCalls, 1);
      expect(r.auth.canVerify, false);
      r.clock = instant.add(const Duration(seconds: 121));
      expect(r.auth.canVerify, true);
    },
  );
  test('escrita protegida não é repetida automaticamente após 401', () async {
    await r.login();
    var calls = 0;
    await expectLater(
      r.auth.authorized((access) async {
        calls++;
        throw const AuthIssue('unauthorized', status: 401);
      }),
      throwsA(isA<AuthIssue>()),
    );
    expect(calls, 1);
    expect(r.api.refreshCalls, 1);
  });
  test(
    'resposta tardia de access anterior usa a rotação já persistida',
    () async {
      await r.login();
      final delayed = Completer<void>();
      var firstCall = true;
      final request = r.auth.authorized((access) async {
        if (firstCall) {
          firstCall = false;
          await delayed.future;
          throw const AuthIssue('unauthorized', status: 401);
        }
        return access;
      }, replaySafe: true);
      await flush();
      r.api.next = result(access: 'fa_rotated');
      await r.auth.refresh();
      delayed.complete();
      expect(await request, 'fa_rotated');
      expect(r.api.refreshCalls, 1);
    },
  );
  test(
    'falha de limpeza bloqueia tentativa programática de novo login',
    () async {
      await r.login();
      r.store.failClear = true;
      await r.auth.signOut();
      final count = r.api.challengeCalls;
      await r.auth.signInSocial('GOOGLE');
      expect(r.api.challengeCalls, count);
      expect(r.auth.value.status, AuthStatus.error);
    },
  );
  test(
    'PR-01.C: refresh reentrante registra single-flight antes de notificar',
    () async {
      await r.login();
      var entered = false;
      Future<void>? nested;
      r.auth.addListener(() {
        if (r.auth.value.status == AuthStatus.refreshing && !entered) {
          entered = true;
          nested = r.auth.refresh();
        }
      });
      await r.auth.refresh();
      await nested;
      expect(r.api.refreshCalls, 1);
    },
  );
  test('PR-01.C: 401 no logout não comprova revogação remota', () async {
    await r.login();
    r.api.logoutError = const AuthIssue('unauthorized', status: 401);
    r.api.refreshError = const AuthIssue('invalid_credential', status: 401);
    await r.auth.signOut();
    expect(r.store.data, isNull);
    expect(r.auth.value.notice, contains('não pôde ser confirmada'));
  });
  test(
    'PR-01.C: logout com access expirado renova uma vez antes de revogar',
    () async {
      await r.login();
      r.clock = instant.add(const Duration(minutes: 11));
      r.api.next = result(
        access: 'fa_for_logout',
        refresh: 'fr_for_logout.secret',
      );
      await r.auth.signOut();
      expect(r.api.refreshCalls, 1);
      expect(r.api.logoutCalls, 1);
      expect(r.store.data, isNull);
      expect(
        r.store.writes.any((data) => data.contains('fr_for_logout.secret')),
        false,
      );
      expect(r.auth.value.notice, isNull);
    },
  );
  test(
    'PR-01.C: revalidação não publica perfil depois de intenção de saída',
    () async {
      await r.login();
      var queued = false, exiting = false, republished = false;
      Future<void>? exit;
      r.auth.addListener(() {
        if (!queued && r.auth.value.status == AuthStatus.initializing) {
          queued = true;
          scheduleMicrotask(
            () => scheduleMicrotask(
              () => scheduleMicrotask(() {
                exiting = true;
                exit = r.auth.signOut();
              }),
            ),
          );
        }
        if (exiting && r.auth.value.protected) republished = true;
      });
      await r.auth.revalidate();
      await flush();
      await exit;
      expect(republished, false);
      expect(r.auth.value.status, AuthStatus.unauthenticated);
    },
  );
  test('PR-01.C: notificação Apple em foreground consulta estado e encerra só sessão Apple', () async {
    await r.login(completed: true);
    r.social.authorized = false;
    await r.auth.appleCredentialChanged();
    expect(r.auth.value.status, AuthStatus.authenticated);
    await r.auth.signOut();
    await r.login(provider: 'APPLE');
    await r.auth.appleCredentialChanged();
    expect(r.auth.value.status, AuthStatus.unauthenticated);
    expect(r.store.data, isNull);
  });
  test('PR-01.C: logout não reutiliza refresh em voo nem trata seu 401 como confirmação', () async {
    await r.login();
    r.api.refreshGate = Completer<LoginResult>();
    final rotating = r.auth.refresh();
    await flush();
    r.api.logoutError = const AuthIssue('unauthorized', status: 401);
    await r.auth.signOut();
    expect(r.api.refreshCalls, 1);
    expect(r.auth.value.notice, contains('não pôde ser confirmada'));
    r.api.refreshGate!.complete(result());
    await rotating;
    expect(r.store.data, isNull);
  });
  test('PR-01.C: limpeza falha impede renovar token para logout', () async {
    await r.login();
    r.clock = instant.add(const Duration(minutes: 11));
    r.store.failClear = true;
    await r.auth.signOut();
    expect(r.api.refreshCalls, 0);
    expect(r.auth.value.issue?.code, 'storage');
    expect(r.store.data, isNotNull);
  });
  test('PR-01.C: onboarding atrasado de sessão anterior não bloqueia nem libera nova submissão', () async {
    await r.login();
    final oldGate = Completer<FlowUser>();
    r.api.onboardingGate = oldGate;
    final oldSubmit = r.auth.completeOnboarding('Ana', 'ana_old');
    await flush();
    await r.auth.signOut();
    await r.login();
    expect(r.auth.value.busy, false);
    final newGate = Completer<FlowUser>();
    r.api.onboardingGate = newGate;
    final newSubmit = r.auth.completeOnboarding('Ana', 'ana_new');
    await flush();
    oldGate.complete(completeUser);
    await oldSubmit;
    await r.auth.refresh();
    expect(r.auth.value.busy, true);
    newGate.complete(completeUser);
    await newSubmit;
    expect(r.auth.value.status, AuthStatus.authenticated);
  });
  test('matriz de guards evita acesso prematuro e redirects externos', () {
    for (final status in AuthStatus.values) {
      final state = AuthState(
        status,
        challenge: status == AuthStatus.challengePending
            ? serverChallenge()
            : null,
      );
      final destination = authRedirect(state, '/app');
      expect(destination == null, status == AuthStatus.authenticated);
    }
    expect(
      authRedirect(
        const AuthState(AuthStatus.unauthenticated),
        '//evil.example',
      ),
      '/welcome',
    );
    expect(
      authRedirect(const AuthState(AuthStatus.onboardingRequired), '/welcome'),
      '/onboarding',
    );
    expect(
      authRedirect(const AuthState(AuthStatus.authenticated), '/onboarding'),
      '/app',
    );
  });
}
