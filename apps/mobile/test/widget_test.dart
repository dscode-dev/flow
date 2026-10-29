import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flow_mobile/app.dart';
import 'package:flow_mobile/core/auth/auth_state.dart';
import 'package:flow_mobile/core/auth/models.dart';
import 'package:flow_mobile/core/config/environment.dart';
import 'package:flow_mobile/core/navigation/router.dart';
import 'package:flow_mobile/features/auth/legal_links.dart';

import 'support/auth_fakes.dart';

Future<ProviderContainer> mount(WidgetTester tester, Rig rig) async {
  final container = ProviderContainer(
    overrides: [authControllerProvider.overrideWithValue(rig.auth)],
  );
  addTearDown(() {
    container.dispose();
    rig.auth.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const FlowApp()),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  test('configuração recusa origem insegura e links legais não aprováveis', () {
    for (final raw in [
      'http://api.example/',
      'https://secret@api.example/',
      '',
      'https://api.example/v1',
    ]) {
      expect(
        () => AppEnvironment.parse('production', raw),
        throwsFormatException,
      );
    }
    expect(LegalLinks.approvedUri('http://legal.example/'), isNull);
    expect(LegalLinks.approvedUri('https://secret@legal.example/'), isNull);
    expect(LegalLinks.approvedUri('https://legal.example/terms'), isNotNull);
  });
  testWidgets(
    'welcome oferece somente os três métodos e guard protege deep link',
    (tester) async {
      final rig = Rig();
      await rig.auth.restore();
      final container = await mount(tester, rig);
      expect(find.text('Continuar com telefone'), findsOneWidget);
      expect(find.text('Continuar com Google'), findsOneWidget);
      expect(find.text('Continuar com Apple'), findsOneWidget);
      container.read(routerProvider).go('/app?returnTo=https://evil.example');
      await tester.pumpAndSettle();
      expect(find.text('Continuar com telefone'), findsOneWidget);
      expect(find.textContaining('Você entrou'), findsNothing);
      container.read(routerProvider).go('/unknown');
      await tester.pumpAndSettle();
      expect(find.text('Continuar com Google'), findsOneWidget);
    },
  );
  testWidgets('telefone normaliza E164 e OTP mostra erro genérico e cooldown', (
    tester,
  ) async {
    final rig = Rig();
    await rig.auth.restore();
    await mount(tester, rig);
    await tester.tap(find.text('Continuar com telefone'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Telefone com DDD'),
      '(81) 99999-9999',
    );
    await tester.ensureVisible(find.text('Solicitar código'));
    await tester.tap(find.text('Solicitar código'));
    await tester.pumpAndSettle();
    expect(rig.api.lastPhone, '+5581999999999');
    expect(find.text('Reenviar em 60 s'), findsOneWidget);
    rig.api.loginError = const AuthIssue('invalid_credential');
    await tester.enterText(find.byType(TextFormField), '123456');
    await tester.ensureVisible(find.text('Confirmar código'));
    await tester.tap(find.text('Confirmar código'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Não foi possível validar esta tentativa.'),
      findsOneWidget,
    );
    expect(find.textContaining('Código válido por'), findsOneWidget);
  });
  testWidgets('sessão restaurada exige onboarding e só abre shell confirmado', (
    tester,
  ) async {
    final rig = Rig();
    await rig.login();
    await mount(tester, rig);
    expect(find.text('Concluir perfil'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Nome de exibição'),
      'Ana',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Nome de usuário'),
      'ana_flow',
    );
    await tester.ensureVisible(find.text('Concluir perfil'));
    await tester.tap(find.text('Concluir perfil'));
    await tester.pumpAndSettle();
    expect(find.text('AMBIENTE DE DESENVOLVIMENTO'), findsOneWidget);
    await tester.ensureVisible(find.text('Sair da conta'));
    await tester.tap(find.text('Sair da conta'));
    await tester.pumpAndSettle();
    expect(find.text('Continuar com telefone'), findsOneWidget);
  });
  testWidgets(
    'claro/escuro, texto 200%, largura 320 e teclado não geram overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      final rig = Rig();
      await rig.auth.restore();
      final container = await mount(tester, rig);
      for (final brightness in Brightness.values) {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        for (final path in ['/welcome', '/phone']) {
          container.read(routerProvider).go(path);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      }
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
    },
  );
  testWidgets('welcome respeita alvos de toque e contraste de texto', (
    tester,
  ) async {
    final rig = Rig();
    await rig.auth.restore();
    await mount(tester, rig);
    final semantics = tester.ensureSemantics();
    try {
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    } finally {
      semantics.dispose();
    }
  });
}
