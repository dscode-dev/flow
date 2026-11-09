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
import 'package:flow_mobile/features/experiences/domain/experience.dart';
import 'package:flow_mobile/features/experiences/application/experience_controllers.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';
import 'package:flow_mobile/features/participation/participation_repository.dart';
import 'package:flow_mobile/features/participation/participation_store.dart';

import 'support/auth_fakes.dart';
import 'support/experience_fakes.dart';

Map<String, dynamic> fresh() => {
  'as_of': '2026-11-08T12:00:00Z',
  'valid_until': '2026-11-08T12:01:00Z',
};

class ParticipationFixture extends FakeExperiencesRepository {
  final calls = <Map<String, dynamic>>[];
  String state = 'NONE', mode = 'FREE';
  bool interested = false,
      owner = false,
      full = false,
      checked = false,
      invitation = true,
      empty = false;
  bool paginate = false;
  Object? networkFailure;
  Completer<Map<String, dynamic>>? gate;
  Map<String, dynamic> summary() => {
    ...fresh(),
    'experience_id': experienceId,
    'mode': mode,
    'state': state,
    'interested': interested,
    'version': 1,
    'is_owner': owner,
    'eligible': true,
    'capacity': 1,
    'remaining': state == 'CONFIRMED' ? 0 : 1,
    'confirmed_count': state == 'CONFIRMED' ? 1 : 0,
    'checked_in': checked,
    'checkin_open': true,
    'external_ticket': true,
    'invitation': null,
    'actions': owner
        ? ['manage']
        : [
            interested ? 'uninterest' : 'interest',
            if (state == 'NONE') mode == 'FREE' ? 'confirm' : 'request',
            if (state == 'PENDING' || state == 'CONFIRMED') 'cancel',
            if (state == 'CONFIRMED' && !checked) 'checkin_credential',
          ],
  };
  Map<String, dynamic> settings() => {
    ...fresh(),
    'mode': mode,
    'capacity': 1,
    'confirmed_count': state == 'CONFIRMED' ? 1 : 0,
    'version': 1,
    'experience_version': 2,
    'visibility': 'PUBLIC',
    'can_manage': true,
    'can_configure': true,
  };
  Map<String, dynamic> person() => {
    'user_id': 'other',
    'display_name': 'Rafa',
    'handle': 'rafa_flow',
    'state': state,
    'interested': false,
    'blocked': false,
    'version': 1,
    'updated_at': '2026-11-08T12:00:00Z',
    'checked_in': checked,
  };
  Map<String, dynamic> agenda() => {
    'experience_id': experienceId,
    'title': 'Encontro na praça',
    'starts_at': '2026-11-08T13:00:00Z',
    'timezone': 'America/Recife',
    'venue_name': 'Praça',
    'experience_status': 'PUBLISHED',
    'accessible': true,
    'state': state,
    'effective_state': state,
    'invitation_id': 'invite-test',
    'invitation_state': 'PENDING',
    'checked_in': checked,
    'external_ticket': true,
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
      'headers': headers,
      'query': query,
    });
    if (networkFailure != null) throw networkFailure!;
    if (method == 'GET' && gate != null) return gate!.future;
    if (method != 'GET') {
      if (full && (path.endsWith('/confirm') || path.endsWith('/approve'))) {
        throw const ExperienceIssue('capacity_full', status: 409);
      }
      if (path.endsWith('/interest')) interested = method == 'PUT';
      if (path.endsWith('/confirm') ||
          path.endsWith('/approve') ||
          path.endsWith('/accept')) {
        state = 'CONFIRMED';
      }
      if (path.endsWith('/request')) state = 'PENDING';
      if (path.endsWith('/cancel')) state = 'CANCELLED';
      if (path.endsWith('/accept') || path.endsWith('/decline')) {
        invitation = false;
      }
      if (path.endsWith('/participation-settings')) {
        mode = (body as Map)['mode'] as String;
        return settings();
      }
      if (path.endsWith('/check-in-credential')) {
        return {
          ...fresh(),
          'code': 'ABCDEFGHIJKLMNOP',
          'expires_at': '2026-11-08T12:02:00Z',
        };
      }
      if (path.endsWith('/validate')) {
        checked = true;
        return {
          'id': 'presence',
          'user_id': 'other',
          'display_name': 'Rafa',
          'checked_at': '2026-11-08T12:00:01Z',
        };
      }
      return summary();
    }
    if (path == 'v1/me/agenda') {
      if (paginate) {
        return {
          ...fresh(),
          'items': query?['cursor'] == null
              ? [agenda()]
              : [
                  agenda(),
                  {
                    ...agenda(),
                    'experience_id': '019a1234-5678-7123-8123-123456789abd',
                  },
                ],
          'next_cursor': query?['cursor'] == null ? 'next-page' : null,
        };
      }
      return {
        ...fresh(),
        'items': empty
            ? []
            : query?['section'] == 'invitations'
            ? (invitation ? [agenda()] : [])
            : [agenda()],
        'next_cursor': null,
      };
    }
    if (path.endsWith('/participation-settings')) return settings();
    if (path.endsWith('/participants')) {
      return {
        ...fresh(),
        'items': empty || query?['state'] != null && query?['state'] != state
            ? []
            : [person()],
        'next_cursor': null,
      };
    }
    if (path.endsWith('/invitations')) {
      return {...fresh(), 'items': [], 'next_cursor': null};
    }
    return summary();
  }
}

Future<ProviderContainer> mountParticipation(
  WidgetTester tester,
  ParticipationFixture repo,
  String path,
) async {
  final rig = Rig();
  await rig.login(completed: true);
  rig.api.serverUser = completeUser;
  rig.auth.lifecycle(false);
  repo.current = sampleExperience(
    creator: repo.owner ? 'user' : 'creator',
    status: ExperienceStatus.published,
    input: const ExperienceInput(
      title: 'Encontro na praça',
      visibility: ExperienceVisibility.public,
      description: 'Um encontro para conversar.',
      externalTicketUrl: 'https://tickets.example/',
    ),
  );
  final container = ProviderContainer(
    overrides: [
      authControllerProvider.overrideWithValue(rig.auth),
      httpClientProvider.overrideWithValue(
        Dio(BaseOptions(baseUrl: 'https://test.invalid/')),
      ),
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
  container.read(routerProvider).go(path);
  await tester.pumpAndSettle();
  return container;
}

Future<void> tapVisible(WidgetTester tester, String label) async {
  final target = find.text(label);
  final f = target;
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      f,
      180,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(target.last);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'store descarta leitura antiga, preserva chave após timeout e limpa sessão',
    () async {
      final rig = Rig();
      await rig.login(completed: true);
      final access = ExperienceAccess(rig.auth);
      final repo = ParticipationFixture();
      final store = ParticipationStore(
        ParticipationRepository(repo),
        access,
        'v1/me/agenda',
      );
      final pending = Completer<Map<String, dynamic>>();
      repo.gate = pending;
      final old = store.load();
      repo.gate = null;
      await store.select({'section': 'interests'});
      pending.complete({
        'items': [
          {'experience_id': 'stale'},
        ],
      });
      await old;
      expect(store.rows.first['experience_id'], experienceId);
      repo.paginate = true;
      await store.load();
      await store.load(more: true);
      expect(store.rows.length, 2);
      repo.networkFailure = const ExperienceIssue('network');
      expect(
        await store.command(
          'POST',
          'v1/experiences/$experienceId/participation/confirm',
        ),
        false,
      );
      final first = repo.calls.last['headers'] as Map;
      repo.networkFailure = null;
      expect(
        await store.command(
          'POST',
          'v1/experiences/$experienceId/participation/confirm',
        ),
        true,
      );
      final retry =
          repo.calls.where((c) => c['method'] == 'POST').last['headers'] as Map;
      expect(retry['Idempotency-Key'], first['Idempotency-Key']);
      await rig.auth.signOut();
      expect(store.document, isNull);
      expect(store.transient, isNull);
      store.dispose();
      access.dispose();
      rig.auth.dispose();
    },
  );
  testWidgets('detalhes distinguem interesse, confirmação e cancelamento', (
    tester,
  ) async {
    final repo = ParticipationFixture();
    await mountParticipation(tester, repo, '/experiences/$experienceId');
    await tapVisible(tester, 'Tenho interesse');
    expect(repo.interested, true);
    expect(repo.state, 'NONE');
    await tapVisible(tester, 'Vou participar');
    expect(repo.state, 'CONFIRMED');
    expect(find.text('Participação confirmada'), findsOneWidget);
    await tapVisible(tester, 'Cancelar solicitação/participação');
    await tapVisible(tester, 'Cancelar participação');
    expect(repo.state, 'CANCELLED');
    expect(repo.interested, true);
    expect(find.textContaining('não comprovam pagamento'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'solicitação mostra conflito de lotação sem confirmação fictícia',
    (tester) async {
      final repo = ParticipationFixture()..full = true;
      await mountParticipation(tester, repo, '/experiences/$experienceId');
      await tapVisible(tester, 'Vou participar');
      expect(repo.state, 'NONE');
      expect(find.textContaining('Não há vagas agora'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('agenda recebe convite, aceita e navega para detalhes', (
    tester,
  ) async {
    final repo = ParticipationFixture();
    final container = await mountParticipation(tester, repo, '/agenda');
    await tapVisible(tester, 'Convites');
    await tapVisible(tester, 'Aceitar convite');
    expect(repo.state, 'CONFIRMED');
    expect(repo.invitation, false);
    await tapVisible(tester, 'Próximas');
    await tapVisible(tester, 'Ver experiência');
    await tester.scrollUntilVisible(
      find.text('Sua participação'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Sua participação'), findsOneWidget);
    container.read(routerProvider).pop();
    await tester.pumpAndSettle();
    expect(find.text('Minha Agenda'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'criador aprova, edita capacidade com ETag e convida sem contatos',
    (tester) async {
      final repo = ParticipationFixture()
        ..owner = true
        ..state = 'PENDING';
      await mountParticipation(
        tester,
        repo,
        '/experiences/$experienceId/participants',
      );
      await tapVisible(tester, 'Aprovar');
      expect(repo.state, 'CONFIRMED');
      await tapVisible(tester, 'Salvar modalidade e capacidade');
      final save = repo.calls.lastWhere((c) => c['method'] == 'PUT');
      expect((save['headers'] as Map)['If-Match'], '"1-2"');
      await tapVisible(tester, 'Convites');
      await tapVisible(tester, 'Enviar convite');
      final field = find.widgetWithText(
        TextField,
        '@handle ou identificador do usuário',
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, '@rafa_flow');
      await tapVisible(tester, 'Enviar convite');
      expect(
        (repo.calls.lastWhere((c) => c['method'] == 'POST')['body']
            as Map)['handle'],
        '@rafa_flow',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'check-in temporário limpa código no background e valida no organizador',
    (tester) async {
      final repo = ParticipationFixture()..state = 'CONFIRMED';
      final participantContainer = await mountParticipation(
        tester,
        repo,
        '/experiences/$experienceId/check-in',
      );
      await tapVisible(tester, 'Gerar meu código');
      expect(find.text('ABCD-EFGH-IJKL-MNOP'), findsOneWidget);
      await tester.pump(const Duration(seconds: 121));
      expect(find.text('ABCD-EFGH-IJKL-MNOP'), findsNothing);
      await tapVisible(tester, 'Consultar situação atual');
      await tapVisible(tester, 'Gerar meu código');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.text('ABCD-EFGH-IJKL-MNOP'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      participantContainer.read(authControllerProvider).lifecycle(false);
      await tester.pumpWidget(const SizedBox());
      final owner = ParticipationFixture()..owner = true;
      await mountParticipation(
        tester,
        owner,
        '/experiences/$experienceId/check-in',
      );
      await tester.enterText(find.byType(TextField), 'ABCD-EFGH-IJKL-MNOP');
      await tapVisible(tester, 'Validar presença');
      expect(find.text('Presença confirmada'), findsOneWidget);
      expect(find.text('Participante: Rafa'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('agenda vazia/erro em 320px, texto200%, claro e escuro', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.platformDispatcher.clearPlatformBrightnessTestValue();
    });
    final repo = ParticipationFixture()..empty = true;
    await mountParticipation(tester, repo, '/agenda');
    expect(find.text('Nenhuma experiência nesta seção.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    repo.networkFailure = const ExperienceIssue('network');
    await tapVisible(tester, 'Tentar novamente');
    expect(
      find.text(participationMessage(const ExperienceIssue('network'))),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('detalhe privado expira e limpa pixels no background', (
    tester,
  ) async {
    final repo = ParticipationFixture();
    final c = await mountParticipation(
      tester,
      repo,
      '/experiences/$experienceId',
    );
    repo.current = sampleExperience(
      creator: 'creator',
      status: ExperienceStatus.published,
      input: const ExperienceInput(
        title: 'Encontro reservado',
        description: 'Conteúdo privado autorizado.',
        visibility: ExperienceVisibility.private,
      ),
    );
    await c.read(experienceDetailProvider(experienceId)).load();
    await tester.pumpAndSettle();
    expect(find.text('Encontro reservado'), findsOneWidget);
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    expect(find.text('Encontro reservado'), findsNothing);
    await c.read(experienceDetailProvider(experienceId)).load();
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('Encontro reservado'), findsNothing);
    c.read(authControllerProvider).lifecycle(false);
    await tester.pumpWidget(const SizedBox());
  });
}
