import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flow_mobile/app.dart';
import 'package:flow_mobile/core/config/environment.dart';
import 'package:flow_mobile/core/navigation/router.dart';

void main() {
  test('produção recusa HTTP, configuração ausente e credenciais na URL', () {
    expect(
      () => AppEnvironment.parse('production', 'http://api.example/'),
      throwsFormatException,
    );
    expect(
      () => AppEnvironment.parse('production', 'https://secret@api.example/'),
      throwsFormatException,
    );
    expect(() => AppEnvironment.parse('test', ''), throwsFormatException);
    expect(
      () => AppEnvironment.parse('test', 'https://api.example/v1'),
      throwsFormatException,
    );
    expect(
      AppEnvironment.parse(
        'production',
        'https://api.example/',
      ).apiBaseUrl.scheme,
      'https',
    );
  });
  testWidgets(
    'link desconhecido permite recuperação sem simular autenticação',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const FlowApp()),
      );
      await tester.pumpAndSettle();
      expect(find.text('Flow'), findsOneWidget);
      container.read(routerProvider).go('/link-inexistente');
      await tester.pumpAndSettle();
      expect(find.text('Este link não está disponível.'), findsOneWidget);
      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();
      expect(find.text('Novas experiências começam aqui.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('tema escuro e texto ampliado não causam overflow', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await tester.pumpWidget(const ProviderScope(child: FlowApp()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      Theme.of(tester.element(find.text('Flow'))).brightness,
      Brightness.dark,
    );
  });
}
