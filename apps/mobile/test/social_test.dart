import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flow_mobile/app.dart';
import 'package:flow_mobile/core/auth/auth_state.dart';
import 'package:flow_mobile/core/network/http_client.dart';
import 'package:flow_mobile/core/navigation/router.dart';
import 'package:flow_mobile/features/experiences/data/experiences_repository.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';
import 'package:flow_mobile/features/social/social_repository.dart';
import 'package:flow_mobile/features/explore/flow_playback.dart';
import 'package:flow_mobile/features/participation/participation_store.dart';

import 'support/auth_fakes.dart';
import 'support/experience_fakes.dart';

const pid = '00000000-0000-7000-8000-000000000007',
    uid = '00000000-0000-7000-8000-000000000008';
Map<String, dynamic> fresh() => {
  'as_of': '2026-11-09T12:00:00Z',
  'valid_until': '2026-11-09T12:00:30Z',
};

class SocialFixture extends FakeExperiencesRepository {
  final calls = <Map<String, dynamic>>[];
  bool video = false;
  bool liked = false,
      following = false,
      empty = false,
      failWrite = false,
      paginate = false;
  int comments = 0;
  Completer<Map<String, dynamic>>? gate;
  Map<String, dynamic> person() => {
    'user_id': uid,
    'display_name': 'Rafa',
    'handle': 'rafa_flow',
  };
  Map<String, dynamic> post([String id = pid]) => {
    ...fresh(),
    'id': id,
    'author': person(),
    'context': 'PERSONAL',
    'experience_id': null,
    'experience_title': null,
    'visibility': 'PUBLIC',
    'body': 'Um encontro memorável',
    'created_at': '2026-11-09T11:00:00Z',
    'updated_at': '2026-11-09T11:00:00Z',
    'edited_at': null,
    'version': 1,
    'can_manage': true,
    'liked': liked,
    'like_count': liked ? 1 : 0,
    'comment_count': comments,
    'media': video
        ? [
            {
              'id': uid,
              'status': 'READY',
              'content_type': 'video/mp4',
              'duration_ms': 1000,
              'url': 'v1/social/posts/$pid/media/$uid/content?ticket=test',
              'expires_at': '2026-11-09T12:00:30Z',
            },
          ]
        : <Map<String, dynamic>>[],
  };
  @override
  Future<Map<String, dynamic>> discoveryRequest(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    CancelToken? cancel,
  }) async {
    calls.add({
      'method': method,
      'path': path,
      'body': body,
      'query': query,
      'headers': headers,
    });
    if (method != 'GET') {
      if (failWrite) throw const ExperienceIssue('network');
      if (path.endsWith('/like')) liked = method == 'PUT';
      if (path.endsWith('/follow')) following = method == 'PUT';
      if (path.endsWith('/comments')) comments++;
      return {'id': pid};
    }
    if (gate != null) return gate!.future;
    if (path == 'v1/social/limits') {
      return {
        'body_limit': 3000,
        'media_limit': 4,
        'edit_hours': 24,
        'video_seconds': 15,
      };
    }
    if (path == 'v1/social/profiles/$uid') {
      return {
        ...person(),
        ...fresh(),
        'post_count': 1,
        'follower_count': following ? 1 : 0,
        'following_count': 0,
        'is_self': false,
        'following': following,
        'follows_you': false,
      };
    }
    if (path == 'v1/social/posts/$pid') return post();
    if (path.endsWith('/comments')) {
      return {
        ...fresh(),
        'items': comments == 0
            ? []
            : [
                {
                  'id': 'comment',
                  'post_id': pid,
                  'author': person(),
                  'body': 'Comentário real',
                  'can_delete': true,
                  'created_at': '2026-11-09T12:00:00Z',
                },
              ],
        'next_cursor': null,
      };
    }
    if (path.endsWith('/followers') || path.endsWith('/following')) {
      return {
        ...fresh(),
        'items': [person()],
        'next_cursor': null,
      };
    }
    return {
      ...fresh(),
      'items': empty || query?['mode'] == 'FOLLOWING'
          ? []
          : [post(query?['cursor'] == null ? pid : 'next')],
      'next_cursor': paginate && query?['cursor'] == null ? 'next' : null,
    };
  }
}

Future<(ProviderContainer, Rig)> mount(
  WidgetTester tester,
  SocialFixture repo,
  String path, {
  List<TestPlayer>? players,
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
      if (players != null)
        flowPlayerFactoryProvider.overrideWithValue((uri) {
          final p = TestPlayer();
          players.add(p);
          return p;
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
  container.read(routerProvider).go(path);
  await tester.pumpAndSettle();
  return (container, rig);
}

Future<void> tap(WidgetTester t, String label) async {
  final f = find.text(label).last;
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

Future<void> unmount(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pumpAndSettle();
}

class TestPlayer implements FlowPlayer {
  bool disposed = false;
  int plays = 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> play() async {
    plays++;
  }

  @override
  Future<void> pause() async {}
  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Widget view() => const SizedBox();
}

void main() {
  testWidgets('feed real, abas, cursor, curtida e estado vazio', (t) async {
    final r = SocialFixture()..paginate = true;
    await mount(t, r, '/social');
    expect(find.text('Um encontro memorável'), findsOneWidget);
    await tap(t, 'Carregar mais');
    expect(find.text('Um encontro memorável'), findsNWidgets(2));
    await tap(t, '0 curtidas');
    expect(r.liked, true);
    await tap(t, 'Seguindo');
    expect(find.text('Ainda não há conteúdo por aqui.'), findsOneWidget);
    await unmount(t);
  });
  testWidgets(
    'composição conserva texto e chave após erro, confirma no servidor',
    (t) async {
      final r = SocialFixture();
      await mount(t, r, '/social');
      await tap(t, 'Publicar');
      final field = find.byType(TextField).first;
      await t.enterText(field, 'Meu momento preservado');
      r.failWrite = true;
      await tap(t, 'Publicar');
      expect(find.text('Meu momento preservado'), findsOneWidget);
      final key =
          (r.calls.where((c) => c['method'] == 'POST').last['headers']
              as Map)['Idempotency-Key'];
      r.failWrite = false;
      await tap(t, 'Publicar');
      final retry = r.calls.where((c) => c['method'] == 'POST').last;
      expect((retry['headers'] as Map)['Idempotency-Key'], key);
      expect((retry['body'] as Map)['body'], 'Meu momento preservado');
      expect(find.text('Social'), findsOneWidget);
      await unmount(t);
    },
  );
  testWidgets('detalhe envia comentário e denúncia com motivo', (t) async {
    final r = SocialFixture();
    await mount(t, r, '/social/posts/$pid');
    await t.enterText(find.byType(TextField), 'Comentário real');
    await tap(t, 'Comentar');
    expect(r.comments, 1);
    expect(find.text('Comentário real'), findsOneWidget);
    await t.ensureVisible(find.byTooltip('Ações da publicação'));
    await t.tap(find.byTooltip('Ações da publicação'));
    await t.pumpAndSettle();
    await tap(t, 'Denunciar publicação');
    await tap(t, 'Spam');
    expect(
      r.calls.any(
        (c) =>
            c['path'] == 'v1/social/reports' &&
            (c['body'] as Map)['reason'] == 'SPAM',
      ),
      true,
    );
    await unmount(t);
  });
  testWidgets('perfil segue, lista seguidores e bloqueia com confirmação', (
    t,
  ) async {
    final r = SocialFixture();
    final (c, _) = await mount(t, r, '/social/profiles/$uid');
    await tap(t, 'Seguir');
    expect(r.following, true);
    await tap(t, '1 seguidores');
    expect(find.text('Seguidores'), findsOneWidget);
    c.read(routerProvider).pop();
    await t.pumpAndSettle();
    await tap(t, 'Bloquear');
    await tap(t, 'Confirmar');
    expect(
      r.calls.any(
        (c) =>
            c['path'] == 'v1/social/profiles/$uid/block' &&
            c['method'] == 'PUT',
      ),
      true,
    );
    expect(find.text('Social'), findsOneWidget);
    await unmount(t);
  });
  test(
    'store cancela resposta antiga, deduplica e limpa sessão/background/TTL',
    () async {
      final rig = Rig();
      await rig.login(completed: true);
      rig.auth.lifecycle(false);
      final access = ExperienceAccess(rig.auth), r = SocialFixture();
      final repo = SocialRepository(r, Dio(), 'https://test.invalid/');
      final store = ParticipationStore(repo, access, 'v1/social/feed');
      final gate = Completer<Map<String, dynamic>>();
      r.gate = gate;
      final old = store.load();
      r.gate = null;
      await store.select({'mode': 'DISCOVER'});
      gate.complete({
        'items': [
          {'id': 'stale'},
        ],
      });
      await old;
      expect(store.rows.first['id'], pid);
      store.pause();
      expect(store.document, isNull);
      await store.resume();
      await rig.auth.signOut();
      expect(store.document, isNull);
      store.dispose();
      access.dispose();
      rig.auth.dispose();
      repo.transport.close(force: true);
    },
  );
  testWidgets(
    'background remove conteúdo; retomada revalida e texto ampliado não transborda',
    (t) async {
      final r = SocialFixture();
      final (container, rig) = await mount(t, r, '/social');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump();
      expect(
        container.read(socialStoreProvider('v1/social/feed')).document,
        isNull,
      );
      r.empty = true;
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
      rig.auth.lifecycle(false);
      expect(find.text('Um encontro memorável'), findsNothing);
      expect(find.text('Ainda não há conteúdo por aqui.'), findsOneWidget);
      t.platformDispatcher.textScaleFactorTestValue = 2;
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      t.platformDispatcher.clearTextScaleFactorTestValue();
      await unmount(t);
    },
  );
  test(
    'mídia somente mesma origem e pipeline nativo serializa descarte',
    () async {
      final r = SocialFixture(), dio = Dio();
      final repo = SocialRepository(r, dio, 'https://test.invalid/');
      expect(
        () => repo.mediaUri('https://else.invalid/x'),
        throwsA(isA<ExperienceIssue>()),
      );
      expect(
        () => repo.mediaUri(
          'v1/social/posts/$pid/media/$uid/content?ticket=x&ticket=y',
        ),
        throwsA(isA<ExperienceIssue>()),
      );
      final players = <TestPlayer>[];
      final p = FlowPlayback((uri) {
        final v = TestPlayer();
        players.add(v);
        return v;
      });
      await p.open(Uri.parse('https://test.invalid/one'), autoplay: false);
      expect(p.playing, false);
      await p.open(Uri.parse('https://test.invalid/two'), autoplay: false);
      expect(players.first.disposed, true);
      await p.close();
      expect(players.last.disposed, true);
      expect(p.source, isNull);
      p.dispose();
      dio.close(force: true);
    },
  );
  testWidgets(
    'vídeo Social só abre ao toque, fica sem autoplay e descarta ao navegar',
    (t) async {
      final r = SocialFixture()..video = true;
      final players = <TestPlayer>[];
      await mount(t, r, '/social', players: players);
      expect(players, isEmpty);
      await tap(t, 'Abrir vídeo · até 15s');
      expect(players.length, 1);
      expect(players.single.plays, 0);
      await t.tap(find.byTooltip('Reproduzir vídeo sem som'));
      await t.pumpAndSettle();
      expect(players.single.plays, 1);
      await t.ensureVisible(find.text('Rafa'));
      await t.pumpAndSettle();
      await t.tap(find.text('Rafa'));
      await t.pumpAndSettle();
      expect(players.single.disposed, true);
      await unmount(t);
    },
  );
  testWidgets(
    'paginar não renova a autorização dos posts de páginas anteriores',
    (t) async {
      final r = SocialFixture()..paginate = true;
      final (container, _) = await mount(t, r, '/social');
      await t.pump(const Duration(seconds: 20));
      await tap(t, 'Carregar mais');
      expect(
        container.read(socialStoreProvider('v1/social/feed')).rows.length,
        2,
      );
      await t.pump(const Duration(seconds: 11));
      expect(
        container.read(socialStoreProvider('v1/social/feed')).document,
        isNull,
      );
      expect(find.text('Um encontro memorável'), findsNothing);
      await unmount(t);
    },
  );
  testWidgets('composição exige confirmação antes de descartar rascunho', (
    t,
  ) async {
    final r = SocialFixture();
    await mount(t, r, '/social');
    await tap(t, 'Publicar');
    await t.enterText(find.byType(TextField).first, 'Rascunho');
    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();
    expect(find.text('Descartar rascunho?'), findsOneWidget);
    await tap(t, 'Continuar escrevendo');
    expect(find.text('Rascunho'), findsOneWidget);
    await unmount(t);
  });
}
