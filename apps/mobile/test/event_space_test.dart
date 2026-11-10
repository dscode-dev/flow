import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flow_mobile/core/navigation/router.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';
import 'package:flow_mobile/features/social/social_repository.dart';

import 'social_test.dart' as social;
import 'support/experience_fakes.dart';

import 'package:flow_mobile/features/experiences/domain/experience.dart';

const base = 'v1/experiences/$experienceId/space';

class SpaceFixture extends social.SocialFixture {
  bool allowed = true,
      write = true,
      moderator = false,
      denied = false,
      offline = false;
  @override
  Map<String, dynamic> post([String id = social.pid]) => {
    ...super.post(id),
    'context': 'EVENT_SPACE',
    'visibility': 'SPACE',
    'experience_id': experienceId,
    'experience_title': 'Encontro no parque',
    'can_interact': write,
    'can_context_moderate': moderator,
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
    if (path.startsWith(base) || path.endsWith('/participation')) {
      calls.add({
        'method': method,
        'path': path,
        'body': body,
        'headers': headers,
      });
      if (offline) throw const ExperienceIssue('network');
      if (denied) throw const ExperienceIssue('not_found', status: 404);
      if (method != 'GET') return {'id': experienceId};
      if (path == base) {
        return {
          ...social.fresh(),
          'experience_id': experienceId,
          'title': 'Encontro no parque',
          'description': 'Uma tarde para conversar.',
          'starts_at': '2026-11-09T12:00:00Z',
          'phase': write ? 'LIVE' : 'ENDED',
          'role': moderator ? 'CREATOR' : 'PARTICIPANT',
          'my_state': allowed ? 'CONFIRMED' : 'NONE',
          'participant_count': allowed ? 2 : null,
          'capabilities': {
            'can_read': allowed,
            'can_write': allowed && write,
            'can_moderate': moderator,
            'can_manage_roles': moderator,
            'can_manage_participation': moderator,
          },
        };
      }
      if (path.endsWith('/participation')) {
        return {
          ...social.fresh(),
          'state': 'NONE',
          'capabilities': <String, dynamic>{},
          'external_ticket': false,
        };
      }
      final items = path.endsWith('/feed')
          ? [post()]
          : path.endsWith('/gallery')
          ? [
              {'id': social.uid, 'post_id': social.pid, 'post': post()},
            ]
          : path.endsWith('/participants')
          ? [
              {...person(), 'role': 'PARTICIPANT'},
            ]
          : <Map<String, dynamic>>[];
      return {...social.fresh(), 'items': items, 'next_cursor': null};
    }
    return super.discoveryRequest(
      method,
      path,
      body: body,
      query: query,
      headers: headers,
      cancel: cancel,
    );
  }
}

void main() {
  testWidgets('detalhes abrem o espaço real no tema escuro e permitem voltar', (
    t,
  ) async {
    t.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
    final r = SpaceFixture()
      ..current = sampleExperience(status: ExperienceStatus.published);
    final (c, _) = await social.mount(t, r, '/experiences/$experienceId');
    await t.scrollUntilVisible(
      find.text('Abrir Event Space'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await social.tap(t, 'Abrir Event Space');
    expect(find.text('Event Space'), findsOneWidget);
    expect(find.text('Um encontro memorável'), findsOneWidget);
    c.read(routerProvider).pop();
    await t.pumpAndSettle();
    expect(
      c.read(routerProvider).routeInformationProvider.value.uri.path,
      '/experiences/$experienceId',
    );
    await t.scrollUntilVisible(
      find.text('Abrir Event Space'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Abrir Event Space'), findsOneWidget);
    expect(t.takeException(), isNull);
    await social.unmount(t);
  });

  testWidgets(
    'prévia pública e acesso privado negado nunca carregam conteúdo',
    (t) async {
      final r = SpaceFixture()..allowed = false;
      await social.mount(t, r, '/experiences/$experienceId/space');
      expect(find.text('Encontro no parque'), findsOneWidget);
      expect(r.calls.any((c) => c['path'] == '$base/feed'), false);
      expect(find.text('Publicar no espaço'), findsNothing);
      r.denied = true;
      await t.tap(find.byTooltip('Atualizar espaço'));
      await t.pumpAndSettle();
      expect(find.text('Encontro no parque'), findsNothing);
      expect(find.text('Um encontro memorável'), findsNothing);
      await social.unmount(t);
    },
  );
  testWidgets(
    'mural compartilha card, curte, abre detalhe e compõe contexto privado',
    (t) async {
      final r = SpaceFixture();
      final (c, _) = await social.mount(
        t,
        r,
        '/experiences/$experienceId/space',
      );
      expect(find.text('Um encontro memorável'), findsOneWidget);
      await social.tap(t, '0 curtidas');
      expect(r.liked, true);
      await social.tap(t, 'Publicar no espaço');
      expect(find.text('Quem pode ver?'), findsNothing);
      await t.enterText(find.byType(TextField).first, 'Registro no espaço');
      await social.tap(t, 'Publicar');
      final call = r.calls.lastWhere(
        (c) => c['method'] == 'POST' && c['path'] == 'v1/social/posts',
      );
      expect(call['body'], containsPair('context', 'EVENT_SPACE'));
      expect(call['body'], containsPair('visibility', 'SPACE'));
      expect(call['body'], containsPair('experience_id', experienceId));
      expect(
        c.read(routerProvider).routeInformationProvider.value.uri.path,
        '/experiences/$experienceId/space',
      );
      await social.unmount(t);
    },
  );
  testWidgets(
    'comentário usa moderação contextual no detalhe Social existente',
    (t) async {
      final r = SpaceFixture()
        ..moderator = true
        ..comments = 1;
      await social.mount(t, r, '/social/posts/${social.pid}');
      await t.ensureVisible(find.byTooltip('Ações do comentário'));
      await t.tap(find.byTooltip('Ações do comentário'));
      await t.pumpAndSettle();
      await social.tap(t, 'Ocultar comentário no espaço');
      await social.tap(t, 'Privacidade');
      expect(
        r.calls.any(
          (c) =>
              c['path'] == '$base/moderation' &&
              (c['body'] as Map)['target_type'] == 'COMMENT' &&
              (c['body'] as Map)['reason'] == 'PRIVACY',
        ),
        true,
      );
      await social.unmount(t);
    },
  );
  testWidgets('galeria reutiliza player sem autoplay e descarta ao mudar aba', (
    t,
  ) async {
    final r = SpaceFixture()..video = true;
    final players = <social.TestPlayer>[];
    await social.mount(
      t,
      r,
      '/experiences/$experienceId/space',
      players: players,
    );
    await social.tap(t, 'Mídia');
    expect(players, isEmpty);
    await social.tap(t, 'Abrir vídeo · até 15s');
    expect(players.single.plays, 0);
    await social.tap(t, 'Participantes');
    expect(players.single.disposed, true);
    expect(find.text('Rafa'), findsOneWidget);
    expect(find.textContaining('Participante'), findsWidgets);
    await social.unmount(t);
  });
  testWidgets('organizador modera com motivo e participantes sem transbordar', (
    t,
  ) async {
    final r = SpaceFixture()..moderator = true;
    await social.mount(t, r, '/experiences/$experienceId/space');
    await t.tap(find.byTooltip('Ações da publicação'));
    await t.pumpAndSettle();
    await social.tap(t, 'Ocultar no espaço');
    await social.tap(t, 'Confirmar');
    expect(
      r.calls.any(
        (c) =>
            c['path'] == '$base/moderation' &&
            (c['body'] as Map)['reason'] == 'SAFETY',
      ),
      true,
    );
    await social.tap(t, 'Participantes');
    t.view.physicalSize = const Size(320, 800);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = 2;
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
    t.platformDispatcher.clearTextScaleFactorTestValue();
    await social.unmount(t);
  });
  testWidgets(
    'memórias são somente leitura; perda de acesso, rede e sessão limpam conteúdo',
    (t) async {
      final r = SpaceFixture()..write = false;
      final (c, rig) = await social.mount(
        t,
        r,
        '/experiences/$experienceId/space',
      );
      expect(find.text('Memórias · experiência encerrada'), findsOneWidget);
      expect(find.text('Publicar no espaço'), findsNothing);
      r.allowed = false;
      await t.tap(find.byTooltip('Atualizar espaço'));
      await t.pumpAndSettle();
      expect(find.text('Um encontro memorável'), findsNothing);
      r.offline = true;
      await t.tap(find.byTooltip('Atualizar espaço'));
      await t.pumpAndSettle();
      expect(find.text('Encontro no parque'), findsNothing);
      r.offline = false;
      r.allowed = true;
      await t.tap(find.byTooltip('Atualizar espaço'));
      await t.pumpAndSettle();
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump();
      expect(c.read(socialStoreProvider(base)).document, isNull);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
      rig.auth.lifecycle(false);
      await rig.auth.signOut();
      await t.pumpAndSettle();
      expect(find.text('Um encontro memorável'), findsNothing);
      await social.unmount(t);
    },
  );
  testWidgets(
    'TTL absoluto remove autorização e páginas visíveis sem polling',
    (t) async {
      final r = SpaceFixture();
      await social.mount(t, r, '/experiences/$experienceId/space');
      final n = r.calls.length;
      await t.pump(const Duration(seconds: 31));
      await t.pump();
      expect(find.text('Um encontro memorável'), findsNothing);
      expect(r.calls.length, n);
      await social.unmount(t);
    },
  );
}
