import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flow_mobile/app.dart';
import 'package:flow_mobile/core/auth/auth_state.dart';
import 'package:flow_mobile/core/navigation/router.dart';
import 'package:flow_mobile/features/experiences/data/experiences_repository.dart';
import 'package:flow_mobile/features/experiences/domain/experience.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';
import 'package:flow_mobile/features/experiences/presentation/pages/experience_detail_page.dart';
import 'package:flow_mobile/features/experiences/presentation/pages/my_experiences_page.dart';
import 'package:flow_mobile/features/home/home_controller.dart';
import 'package:flow_mobile/features/home/home_page.dart';

import 'support/auth_fakes.dart';
import 'support/home_fakes.dart';

Future<ProviderContainer> mountHome(
  WidgetTester tester,
  HomeFixtureRepository repo,
) async {
  final rig = Rig();
  await rig.login(completed: true);
  rig.auth.lifecycle(false);
  final container = ProviderContainer(
    overrides: [
      authControllerProvider.overrideWithValue(rig.auth),
      experiencesRepositoryProvider.overrideWithValue(repo),
    ],
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
  testWidgets(
    'região manual consulta centro aproximado; categoria indisponível pode ser limpa',
    (tester) async {
      final repo = HomeFixtureRepository();
      final container = await mountHome(tester, repo);
      await tester.tap(find.text('Escolher região'));
      await tester.pumpAndSettle();
      final fields = find.descendant(
        of: find.byType(RegionForm),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), 'Minha região');
      await tester.enterText(fields.at(1), '-8,0476');
      await tester.enterText(fields.at(2), '-34,877');
      await tester.enterText(fields.at(3), '10');
      await tester.ensureVisible(find.text('Usar região'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Usar região'));
      await tester.pumpAndSettle();
      expect(repo.homeQueries.last, {
        'latitude': -8.05,
        'longitude': -34.88,
        'radius_m': 10000,
      });
      expect(find.text('Minha região'), findsOneWidget);
      repo.failure = const ExperienceIssue('invalid_request', status: 400);
      await container.read(homeControllerProvider).selectCategory('music');
      await tester.pumpAndSettle();
      expect(find.text('Limpar categoria'), findsOneWidget);
      repo.failure = null;
      await tester.tap(find.text('Limpar categoria'));
      await tester.pumpAndSettle();
      expect(repo.homeQueries.last.containsKey('category_id'), false);
      final semantics = tester.ensureSemantics();
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      semantics.dispose();
      container.read(homeControllerProvider).pause();
    },
  );
  testWidgets(
    'carregamento, vazio sem conteúdo fictício, erro e retry são reais',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      final repo = HomeFixtureRepository()..gate = pending;
      // Loading animation intentionally does not settle while awaiting the API.
      final rig = Rig();
      await rig.login(completed: true);
      rig.auth.lifecycle(false);
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWithValue(rig.auth),
          experiencesRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(() {
        container.dispose();
        rig.auth.dispose();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: const FlowApp()),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Buscando encontros…'), findsOneWidget);
      pending.complete(homeFixture());
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Ainda não há experiências públicas'),
        findsOneWidget,
      );
      expect(find.text('Destaques'), findsNothing);
      repo.failure = const ExperienceIssue('network');
      await tester.tap(find.byTooltip('Atualizar início'));
      await tester.pumpAndSettle();
      expect(find.text('Tentar novamente'), findsOneWidget);
      repo.failure = null;
      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();
      expect(repo.homeQueries.length, 3);
      container.read(homeControllerProvider).pause();
    },
  );
  testWidgets(
    'card navega ao detalhe existente, gestão continua acessível e logout limpa tudo',
    (tester) async {
      final repo = HomeFixtureRepository()
        ..document = homeFixture(title: 'Passeio público');
      repo.current = Experience.fromJson(
        homeExperience(title: 'Passeio público'),
      );
      final container = await mountHome(tester, repo);
      await tester.scrollUntilVisible(
        find.byType(HomeExperienceCard),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Passeio público'));
      await tester.pumpAndSettle();
      expect(find.byType(ExperienceDetailPage), findsOneWidget);
      expect(find.text('Descrição pública para teste.'), findsOneWidget);
      container.read(routerProvider).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Minhas experiências'));
      await tester.pumpAndSettle();
      expect(find.byType(MyExperiencesPage), findsOneWidget);
      await tester.tap(find.byTooltip('Sair da conta'));
      await tester.pumpAndSettle();
      expect(find.text('Continuar com telefone'), findsOneWidget);
      expect(container.read(homeControllerProvider).value.document, isNull);
    },
  );
  testWidgets(
    'capa negada revalida uma vez por versão sem loop; fase renova pelo relógio do servidor',
    (tester) async {
      final repo = HomeFixtureRepository()
        ..document = homeFixture(
          title: 'Capa indisponível',
          cover: 'media-fixture',
          refreshSeconds: 5,
        );
      final container = await mountHome(tester, repo);
      await tester.scrollUntilVisible(
        find.byType(HomeExperienceCard),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(repo.homeQueries.length, 2);
      expect(repo.coverCalls, 1);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(repo.homeQueries.length, 3);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(container.read(homeControllerProvider).value.document, isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(repo.homeQueries.length, 4);
      container.read(authControllerProvider).lifecycle(false);
      container.read(homeControllerProvider).pause();
    },
  );
  testWidgets(
    'Home e região cabem em 320px, texto 200%, temas e movimento reduzido',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      final repo = HomeFixtureRepository()
        ..document = homeFixture(
          title: 'Um título público para ler com texto ampliado',
        );
      final container = await mountHome(tester, repo);
      for (final brightness in Brightness.values) {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byType(HomeExperienceCard),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.text('Escolher região'),
          -300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Escolher região'));
        await tester.pumpAndSettle();
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        await tester.pumpAndSettle();
        expect(find.byType(RegionForm), findsOneWidget);
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        container.read(routerProvider).pop();
        await tester.pumpAndSettle();
      }
      container.read(homeControllerProvider).pause();
    },
  );
}
