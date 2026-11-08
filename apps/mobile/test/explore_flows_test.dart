import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flow_mobile/app.dart';
import 'package:flow_mobile/core/auth/auth_state.dart';
import 'package:flow_mobile/core/auth/models.dart';
import 'package:flow_mobile/core/network/http_client.dart';
import 'package:flow_mobile/core/navigation/router.dart';
import 'package:flow_mobile/features/experiences/data/experiences_repository.dart';
import 'package:flow_mobile/features/explore/discovery_controller.dart';
import 'package:flow_mobile/features/explore/discovery_model.dart';
import 'package:flow_mobile/features/explore/flow_playback.dart';
import 'package:flow_mobile/features/experiences/domain/experience.dart';
import 'package:flow_mobile/features/experiences/presentation/pages/experience_detail_page.dart';

import 'support/auth_fakes.dart';
import 'support/experience_fakes.dart';

const otherId = '019a1234-5678-7123-8123-123456789abd';
Map<String, dynamic> wire(String id) => {
  ...sampleExperience().input.toJson(),
  'id': id,
  'creator_user_id': 'user-1',
  'status': 'PUBLISHED',
  'phase': 'LIVE',
  'version': 1,
  'created_at': '2026-11-08T00:00:00Z',
  'updated_at': '2026-11-08T00:00:00Z',
  'details_redacted': false,
  'title': id == experienceId ? 'Música no parque' : 'Encontro de natureza',
  'visibility': 'PUBLIC',
  'category_id': 'nature',
  'starts_at': '2026-11-08T12:00:00Z',
  'ends_at': '2026-11-08T15:00:00Z',
  'timezone': 'America/Recife',
  'venue_name': 'Parque',
};
Map<String, dynamic> flowWire(String id, {bool video = false}) => {
  'experience': wire(id),
  'presentation_version': 1,
  'image_kind': 'cover',
  'has_video': video,
  'duration_ms': video ? 1000 : null,
  'image_url': 'v1/flows/$id/content?ticket=test-only',
  'video_url': video ? 'v1/flows/$id/content?ticket=test-only' : null,
  'media_expires_at': '2026-11-08T13:00:30Z',
};

class DiscoveryFixture extends FakeExperiencesRepository {
  final calls = <Map<String, dynamic>>[];
  bool videos = false;
  bool empty = false;
  bool failed = false;
  bool paginate = false;
  @override
  Future<Map<String, dynamic>> discoveryRequest(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    CancelToken? cancel,
  }) async {
    calls.add({'method': method, 'path': path, ...?query, 'body': ?body});
    if (failed) throw StateError('test network boundary');
    if (path.endsWith('/flow')) {
      return {
        'experience_id': experienceId,
        'version': 1,
        'enabled': false,
        'unlisted_consent_at': null,
        'image_asset_id': null,
        'video_asset_id': null,
      };
    }
    if (path.startsWith('v1/flows/')) {
      return flowWire(path.split('/')[2], video: videos);
    }
    return {
      'items': empty
          ? []
          : path == 'v1/flows'
          ? (paginate && query?['cursor'] != null
                ? [flowWire(otherId, video: videos)]
                : [
                    flowWire(experienceId, video: videos),
                    if (!paginate) flowWire(otherId, video: videos),
                  ])
          : [wire(experienceId)],
      'next_cursor': paginate && path == 'v1/flows' && query?['cursor'] == null
          ? 'next-page'
          : null,
      'as_of': '2026-11-08T13:00:00Z',
      'valid_until': '2026-11-08T13:01:00Z',
      'window_hours': 48,
    };
  }
}

class PlayerProbe {
  int active = 0, maxActive = 0, created = 0, disposed = 0, plays = 0;
  Completer<void>? first;
}

class PlayerDouble implements FlowPlayer {
  PlayerDouble(this.probe) {
    probe.created++;
  }
  final PlayerProbe probe;
  @override
  Future<void> initialize() async {
    if (probe.created == 1 && probe.first != null) await probe.first!.future;
  }

  @override
  Future<void> play() async {
    probe.active++;
    probe.plays++;
    if (probe.active > probe.maxActive) probe.maxActive = probe.active;
  }

  @override
  Future<void> pause() async {
    if (probe.active > 0) probe.active--;
  }

  @override
  Future<void> dispose() async {
    await pause();
    probe.disposed++;
  }

  @override
  Widget view() => const Center(child: Text('Native video boundary'));
}

Future<ProviderContainer> mount(
  WidgetTester tester,
  DiscoveryFixture repo, {
  PlayerProbe? players,
  String path = '/explore',
}) async {
  final rig = Rig();
  await rig.login(completed: true);
  rig.api.serverUser = completeUser;
  rig.auth.lifecycle(false);
  final container = ProviderContainer(
    overrides: [
      authControllerProvider.overrideWithValue(rig.auth),
      httpClientProvider.overrideWithValue(
        Dio(BaseOptions(baseUrl: 'https://test.invalid/')),
      ),
      experiencesRepositoryProvider.overrideWithValue(repo),
      flowPlayerFactoryProvider.overrideWithValue(
        (_) => PlayerDouble(players ?? PlayerProbe()),
      ),
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
  container.read(routerProvider).go(path);
  await tester.pumpAndSettle();
  return container;
}

void main() {
  test(
    'pager descarta resposta antiga, deduplica cursor e limpa a conta',
    () async {
      final rig = Rig();
      await rig.login(completed: true);
      final access = ExperienceAccess(rig.auth);
      final pending = <Completer<DiscoveryPage<String>>>[];
      final cancels = <CancelToken?>[];
      final pager = DiscoveryPager<String>(access, (q, {cancel}) {
        cancels.add(cancel);
        final c = Completer<DiscoveryPage<String>>();
        pending.add(c);
        return c.future;
      }, (v) => v);
      final now = DateTime.utc(2026, 11, 8);
      DiscoveryPage<String> page(List<String> items, String? cursor) =>
          DiscoveryPage(
            items,
            cursor,
            now,
            now.add(const Duration(minutes: 1)),
          );
      pager.change({'q': 'antiga'});
      pager.change({'q': 'nova'});
      expect(cancels.first!.isCancelled, true);
      pending[1].complete(page(['a'], 'next'));
      await Future<void>.delayed(Duration.zero);
      pending[0].complete(page(['old'], null));
      await Future<void>.delayed(Duration.zero);
      expect(pager.items, ['a']);
      final more = pager.load(more: true);
      await pager.load(more: true);
      expect(pending.length, 3);
      pending[2].complete(page(['a', 'b'], null));
      await more;
      expect(pager.items, ['a', 'b']);
      rig.auth.value = const AuthState(
        AuthStatus.authenticated,
        user: FlowUser('another-user', false, 'Outra pessoa', 'outra_pessoa'),
      );
      expect(pager.items, isEmpty);
      expect(pager.query, isEmpty);
      pager.dispose();
      access.dispose();
      rig.auth.dispose();
    },
  );
  test(
    'player serializa inicialização/dispose e nunca toca dois vídeos',
    () async {
      final probe = PlayerProbe()..first = Completer<void>();
      final playback = FlowPlayback((_) => PlayerDouble(probe));
      final one = playback.open(
        Uri.parse('https://test.invalid/one'),
        autoplay: true,
      );
      await Future<void>.delayed(Duration.zero);
      final two = playback.open(
        Uri.parse('https://test.invalid/two'),
        autoplay: true,
      );
      probe.first!.complete();
      await one;
      await two;
      expect(probe.created, 2);
      expect(probe.disposed, 1);
      expect(probe.maxActive, 1);
      await playback.close();
      expect(probe.active, 0);
      expect(probe.disposed, 2);
      playback.dispose();
    },
  );
  testWidgets(
    'Explorar posiciona Flows antes da busca; debounce e categorias',
    (tester) async {
      final repo = DiscoveryFixture();
      final c = await mount(tester, repo);
      expect(find.text('Ver todos'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Flows')).dy,
        lessThan(tester.getTopLeft(find.byType(TextField)).dy),
      );
      final before = repo.calls
          .where((v) => v['path'] == 'v1/explore/experiences')
          .length;
      await tester.enterText(find.byType(TextField), 'mus');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.enterText(find.byType(TextField), 'musica');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        repo.calls.where((v) => v['path'] == 'v1/explore/experiences').length,
        before + 1,
      );
      expect(
        repo.calls.lastWhere((v) => v['path'] == 'v1/explore/experiences')['q'],
        'musica',
      );
      await tester.tap(find.text('Natureza'));
      await tester.pumpAndSettle();
      expect(c.read(explorePagerProvider).query['category_id'], 'nature');
      await tester.tap(find.text('Ver todos'));
      await tester.pumpAndSettle();
      expect(find.byType(PageView), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('viewer pagina, pausa no background e preserva detalhes/índice', (
    tester,
  ) async {
    final repo = DiscoveryFixture()
      ..videos = true
      ..paginate = true;
    final probe = PlayerProbe();
    final container = await mount(tester, repo, players: probe, path: '/flows');
    expect(probe.active, 1);
    await tester.drag(find.byType(PageView), const Offset(0, -650));
    await tester.pumpAndSettle();
    expect(repo.calls.any((v) => v['cursor'] == 'next-page'), true);
    expect(probe.maxActive, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(probe.active, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(probe.active, 1);
    await tester.tap(find.text('Ver detalhes').last);
    await tester.pumpAndSettle();
    expect(probe.active, 0);
    expect(find.byType(ExperienceDetailPage), findsOneWidget);
    container.read(routerProvider).pop();
    await tester.pumpAndSettle();
    expect(probe.active, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(probe.active, 0);
    container.read(flowsPagerProvider).pause();
    container.read(authControllerProvider).lifecycle(false);
  });
  testWidgets('estados vazio/erro e layout 320px, texto200%, claro/escuro', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final repo = DiscoveryFixture()..empty = true;
    final c = await mount(tester, repo);
    await tester.scrollUntilVisible(
      find.textContaining('Nenhuma experiência encontrada'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.textContaining('Nenhuma experiência encontrada'),
      findsOneWidget,
    );
    repo.empty = false;
    repo.failed = true;
    await c.read(explorePagerProvider).load();
    await tester.pumpAndSettle();
    expect(c.read(explorePagerProvider).issue, isNotNull);
    repo.failed = false;
    await c.read(explorePagerProvider).load();
    await tester.pumpAndSettle();
    for (final brightness in Brightness.values) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'gestão exige consentimento público de UNLISTED e envia versão própria',
    (tester) async {
      final repo = DiscoveryFixture()
        ..current = sampleExperience(
          creator: 'user',
          input: const ExperienceInput(
            title: 'Experiência por link',
            visibility: ExperienceVisibility.unlisted,
          ),
        );
      await mount(tester, repo, path: '/experiences/$experienceId/flow');
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Salvar apresentação'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Salvar apresentação'));
      await tester.pumpAndSettle();
      final saved =
          repo.calls.lastWhere((v) => v['method'] == 'PUT')['body'] as Map;
      expect(saved['unlisted_consent'], true);
      expect(saved['enabled'], true);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
