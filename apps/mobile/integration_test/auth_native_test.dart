// Native OS smoke, not real provider authentication. Run on a fresh simulator.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flow_mobile/app.dart';
import 'package:flow_mobile/core/auth/auth_state.dart';
import 'package:flow_mobile/core/config/environment.dart';
import 'package:flow_mobile/core/navigation/router.dart';
import 'package:flow_mobile/core/storage/secure_store.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Keychain/Keystore, journal interrompido, guards e configuração ausente',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          environmentProvider.overrideWithValue(
            AppEnvironment.parse('test', 'https://localhost/'),
          ),
        ],
      );
      final store = container.read(secureStoreProvider);
      // This test must only run on its own fresh simulator; no live account/session.
      expect(
        await store.readSession(),
        isNull,
        reason: 'Use um simulador limpo; não sobrescrever sessão existente.',
      );
      try {
        await store.writeSession('{"v":1,"pending":true}');
        expect(await store.readSession(), '{"v":1,"pending":true}');
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const FlowApp(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Continuar com telefone'), findsOneWidget);
        expect(await store.readSession(), isNull);
        expect(
          container.read(authControllerProvider).value.status,
          AuthStatus.sessionExpired,
        );
        container
            .read(routerProvider)
            .go('/app?returnTo=https://invalid.example');
        await tester.pumpAndSettle();
        expect(find.text('Continuar com telefone'), findsOneWidget);
        await tester.ensureVisible(find.text('Continuar com Google'));
        await tester.tap(find.text('Continuar com Google'));
        await tester.pumpAndSettle();
        expect(
          container.read(authControllerProvider).value.issue?.code,
          'provider_configuration',
        );
        // Native preflight must reject an unregistered callback before opening Google.
        if (Theme.of(tester.element(find.text('Flow'))).platform ==
            TargetPlatform.iOS) {
          expect(
            await const MethodChannel('flow/auth_configuration')
                .invokeMethod<bool>(
                  'googleIosReady',
                  '000000-test.apps.googleusercontent.com',
                ),
            false,
          );
        }
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        expect(container.read(authControllerProvider).value.protected, false);
        expect(tester.takeException(), isNull);
      } finally {
        await store.clearSession();
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      }
    },
  );
}
