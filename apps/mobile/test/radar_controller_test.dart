import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flow_mobile/features/experiences/data/experiences_repository.dart';
import 'package:flow_mobile/features/experiences/domain/experience.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';
import 'package:flow_mobile/features/radar/radar_config.dart';
import 'package:flow_mobile/features/radar/radar_controller.dart';
import 'package:flow_mobile/features/radar/radar_map.dart';
import 'package:flow_mobile/features/radar/radar_model.dart';

import 'support/auth_fakes.dart';
import 'support/radar_fakes.dart';

void main() {
  test(
    'configuração pública, bounds e GeoJSON não inventam contagens ou métricas',
    () {
      expect(const RadarConfig().available, false);
      expect(const RadarConfig(token: 'sk_private').available, false);
      expect(
        const RadarConfig(
          token: 'pk.fixture_only_not_a_real_token',
          lightStyle: 'https://untrusted.invalid/style',
        ).available,
        false,
      );
      expect(const RadarBounds(179, -1, -179, 1).width, 2);
      final page = RadarDocument.fromJson(
        radarFixture(items: true, truncated: true),
      );
      final json = radarGeoJson(page.items);
      final features = json['features'] as List;
      expect(features.length, 1);
      expect(
        (features.single as Map)['properties']['experience_id'],
        page.items.single.id,
      );
      expect(
        (features.single as Map)['properties'].containsKey('point_count'),
        false,
      );
      expect((features.single as Map)['geometry']['coordinates'], [
        -34.88,
        -8.05,
      ]);
      final query = const RadarFilters(
        center: GeoPoint(-8.0476, -34.877),
        radiusM: 10000,
      ).query;
      expect(query['latitude'], -8.05);
      expect(query['longitude'], -34.88);
    },
  );
  test('consulta obsoleta é cancelada, limite é explícito, logout apaga câmera e filtros', () async {
    final rig = Rig();
    await rig.login(completed: true);
    final access = ExperienceAccess(rig.auth);
    final repo = RadarFixtureRepository();
    final radar = RadarController(repo, access);
    addTearDown(() {
      radar.dispose();
      access.dispose();
      rig.auth.dispose();
    });
    radar.viewport(
      const RadarBounds(-35, -8.2, -34.7, -7.9),
      const RadarCamera(GeoPoint(-8.05, -34.88), 10),
    );
    final old = Completer<Map<String, dynamic>>();
    repo.gate = old;
    final first = radar.refresh(force: true);
    await radar.refresh(force: true);
    expect(repo.radarQueries.length, 1);
    radar.viewport(
      const RadarBounds(179, -1, -179, 1),
      const RadarCamera(GeoPoint(0, 180), 10),
    );
    repo.document = radarFixture(truncated: true);
    await radar.refresh(force: true);
    expect(repo.radarCancellations.first!.isCancelled, true);
    old.complete(radarFixture(items: true));
    await first;
    expect(radar.value.document!.items, isEmpty);
    expect(radar.value.document!.truncated, true);
    expect(radar.metrics.obsolete, 1);
    final count = repo.radarQueries.length;
    await radar.refresh();
    expect(repo.radarQueries.length, count);
    await radar.setFilters(
      const RadarFilters(phase: 'LIVE', category: 'nature'),
    );
    expect(repo.radarQueries.last['phase'], 'LIVE');
    await rig.auth.signOut();
    expect(radar.camera, isNull);
    expect(radar.bounds, isNull);
    expect(radar.filters.active, false);
    expect(radar.value.document, isNull);
  });
  testWidgets(
    'debounce, amplitude, vencimento sem polling e recuperação de rede',
    (tester) async {
      final rig = Rig();
      await rig.login(completed: true);
      rig.auth.lifecycle(false);
      final access = ExperienceAccess(rig.auth);
      final repo = RadarFixtureRepository()
        ..document = radarFixture(items: true, seconds: 2);
      final radar = RadarController(repo, access);
      addTearDown(() {
        radar.dispose();
        access.dispose();
        rig.auth.dispose();
      });
      radar.viewport(
        const RadarBounds(-35, -8.2, -34.7, -7.9),
        const RadarCamera(GeoPoint(-8.05, -34.88), 10),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(repo.radarQueries, isEmpty);
      radar.moving();
      await tester.pump(const Duration(milliseconds: 400));
      expect(repo.radarQueries, isEmpty);
      radar.viewport(
        const RadarBounds(-35, -8.3, -34.7, -7.9),
        const RadarCamera(GeoPoint(-8.05, -34.88), 10),
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(repo.radarQueries.length, 1);
      expect(radar.value.document!.items.length, 1);
      await tester.pump(const Duration(seconds: 3));
      expect(radar.value.expired, true);
      expect(radar.value.document, isNull);
      expect(repo.radarQueries.length, 1);
      repo.failure = const ExperienceIssue('network');
      await radar.refresh(force: true);
      expect(radar.value.issue!.code, 'network');
      radar.viewport(
        const RadarBounds(-180, -85, 180, 85),
        const RadarCamera(GeoPoint(0, 0), 1),
      );
      await radar.refresh(force: true);
      expect(radar.value.issue!.code, 'radar_area_too_large');
      expect(repo.radarQueries.length, 2);
      radar.pause();
    },
  );
}
