import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flow_mobile/app.dart';
import 'package:flow_mobile/core/auth/auth_state.dart';
import 'package:flow_mobile/core/auth/models.dart';
import 'package:flow_mobile/core/navigation/router.dart';
import 'package:flow_mobile/features/experiences/data/experiences_repository.dart';
import 'package:flow_mobile/features/experiences/domain/experience.dart';
import 'package:flow_mobile/features/experiences/presentation/pages/experience_detail_page.dart';
import 'package:flow_mobile/features/radar/radar_config.dart';
import 'package:flow_mobile/features/radar/radar_controller.dart';
import 'package:flow_mobile/features/radar/radar_location.dart';
import 'package:flow_mobile/features/radar/radar_map.dart';
import 'package:flow_mobile/features/radar/radar_model.dart';

import 'support/auth_fakes.dart';
import 'support/experience_fakes.dart';
import 'support/radar_fakes.dart';

const testConfig = RadarConfig(token: 'pk.fixture_only_not_a_real_token');

class NativeMapBoundary extends StatefulWidget {
  const NativeMapBoundary(this.controller, this.onSelect, {super.key});
  final RadarController controller;
  final ValueChanged<String> onSelect;
  @override
  State<NativeMapBoundary> createState() => _NativeMapBoundaryState();
}

class _NativeMapBoundaryState extends State<NativeMapBoundary> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.controller.mapReady();
        widget.controller.viewport(
          const RadarBounds(-35, -8.2, -34.7, -7.9),
          const RadarCamera(GeoPoint(-8.05, -34.88), 10),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => Center(
    child: FilledButton(
      onPressed: () => widget.onSelect(experienceId),
      child: const Text('Selecionar pin de teste'),
    ),
  );
}

Future<ProviderContainer> mountRadar(
  WidgetTester tester,
  RadarFixtureRepository repo, {
  RadarConfig config = testConfig,
  DeniedRadarLocation? location,
  ValueChanged<bool>? constructed,
}) async {
  final rig = Rig();
  await rig.login(completed: true);
  rig.auth.lifecycle(false);
  final container = ProviderContainer(
    overrides: [
      authControllerProvider.overrideWithValue(rig.auth),
      experiencesRepositoryProvider.overrideWithValue(repo),
      radarConfigProvider.overrideWithValue(config),
      radarLocationProvider.overrideWithValue(
        location ?? DeniedRadarLocation(),
      ),
      radarMapBuilderProvider.overrideWithValue((controller, config, select) {
        constructed?.call(true);
        return NativeMapBoundary(controller, select);
      }),
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
  container.read(routerProvider).go('/radar');
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets(
    'troca de conta fecha filtros e remove critérios da conta anterior',
    (tester) async {
      var constructions = 0;
      final container = await mountRadar(
        tester,
        RadarFixtureRepository(),
        constructed: (_) => constructions++,
      );
      await tester.tap(find.text('Filtros'));
      await tester.pumpAndSettle();
      expect(find.text('Filtros do Radar'), findsOneWidget);
      final auth = container.read(authControllerProvider);
      auth.value = const AuthState(
        AuthStatus.authenticated,
        user: FlowUser('another-user', false, 'Outra pessoa', 'outra_pessoa'),
      );
      expect(container.read(radarControllerProvider).camera, isNull);
      await tester.pumpAndSettle();
      expect(find.text('Filtros do Radar'), findsNothing);
      expect(container.read(radarControllerProvider).filters.active, false);
      expect(constructions, 2);
      container.read(radarControllerProvider).pause();
    },
  );
  testWidgets('sem token não constrói SDK nem consulta uma área fictícia', (
    tester,
  ) async {
    final repo = RadarFixtureRepository();
    var builds = 0;
    await mountRadar(
      tester,
      repo,
      config: const RadarConfig(),
      constructed: (_) => builds++,
    );
    expect(find.textContaining('Radar indisponível'), findsOneWidget);
    expect(builds, 0);
    expect(repo.radarQueries, isEmpty);
  });
  testWidgets(
    'pin revalida prévia real e abre detalhes; retorno preserva câmera',
    (tester) async {
      final repo = RadarFixtureRepository()
        ..document = radarFixture(items: true, truncated: true);
      repo.current = sampleExperience(
        status: ExperienceStatus.published,
        phase: 'UPCOMING',
        input: ExperienceInput.fromJson({
          'title': 'Encontro do Radar',
          'description': 'Descrição real vinda da API de teste',
          'visibility': 'PUBLIC',
          'category_id': 'nature',
          'starts_at': '2026-11-09T15:00:00Z',
          'ends_at': '2026-11-09T18:00:00Z',
          'timezone': 'America/Recife',
          'venue_name': 'Parque público',
        }),
      );
      var constructions = 0;
      final container = await mountRadar(
        tester,
        repo,
        constructed: (_) => constructions++,
      );
      expect(find.textContaining('Há mais experiências'), findsOneWidget);
      final camera = container.read(radarControllerProvider).camera;
      await tester.tap(find.text('Selecionar pin de teste'));
      await tester.pumpAndSettle();
      expect(find.text('Encontro do Radar'), findsOneWidget);
      await tester.ensureVisible(find.text('Ver detalhes'));
      await tester.tap(find.text('Ver detalhes'));
      await tester.pumpAndSettle();
      expect(find.byType(ExperienceDetailPage), findsOneWidget);
      expect(find.text('Descrição real vinda da API de teste'), findsOneWidget);
      container.read(routerProvider).pop();
      await tester.pumpAndSettle();
      expect(container.read(radarControllerProvider).camera, same(camera));
      expect(constructions, 1);
      container.read(radarControllerProvider).pause();
    },
  );
  testWidgets(
    'GPS é explícito, negação mantém descoberta; filtro e logout limpam estado',
    (tester) async {
      final repo = RadarFixtureRepository();
      final location = DeniedRadarLocation();
      final container = await mountRadar(tester, repo, location: location);
      expect(location.requests, 0);
      await tester.tap(find.byTooltip('Usar minha região aproximada'));
      await tester.pumpAndSettle();
      expect(location.requests, 0);
      await tester.tap(find.text('Usar localização aproximada'));
      await tester.pumpAndSettle();
      expect(location.requests, 1);
      expect(find.textContaining('Localização não autorizada'), findsOneWidget);
      await tester.tap(find.text('Filtros'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Acontecendo agora'));
      await tester.ensureVisible(find.text('Aplicar filtros'));
      await tester.tap(find.text('Aplicar filtros'));
      await tester.pumpAndSettle();
      expect(repo.radarQueries.last['phase'], 'LIVE');
      await container.read(authControllerProvider).signOut();
      await tester.pumpAndSettle();
      expect(find.text('Continuar com telefone'), findsOneWidget);
      expect(container.read(radarControllerProvider).camera, isNull);
      expect(location.cancels, greaterThan(0));
    },
  );
  testWidgets(
    'Radar e filtros suportam texto 200%, 320px, temas e movimento reduzido',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      final container = await mountRadar(tester, RadarFixtureRepository());
      for (final brightness in Brightness.values) {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Filtros'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        container.read(routerProvider).pop();
        await tester.pumpAndSettle();
      }
      container.read(radarControllerProvider).pause();
    },
  );
}
