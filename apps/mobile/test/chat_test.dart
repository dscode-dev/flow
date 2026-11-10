import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flow_mobile/features/event_space/chat_controller.dart';
import 'package:flow_mobile/features/event_space/chat_socket.dart';
import 'package:flow_mobile/features/social/social_repository.dart';
import 'package:flow_mobile/features/experiences/data/experiences_repository.dart';

import 'support/auth_fakes.dart';

import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';

import 'support/experience_fakes.dart';
import 'event_space_test.dart' as space;
import 'social_test.dart' as social;

Map<String, dynamic> message({
  String id = social.pid,
  String seq = '1',
  String body = 'Conversa do encontro',
  String? client,
}) => {
  'id': id,
  'sequence': seq,
  'experience_id': experienceId,
  'client_message_id': client,
  'body': body,
  'author': {'user_id': social.uid, 'display_name': 'Rafa', 'handle': 'rafa'},
  'removed': false,
  'can_delete': true,
  'can_moderate': true,
  'created_at': '2026-11-10T12:00:00Z',
};

class SocketFixture implements ChatSocket {
  final input = StreamController<Map<String, dynamic>>.broadcast();
  final sent = <Map<String, dynamic>>[];
  bool closed = false;
  @override
  Stream<Map<String, dynamic>> get frames => input.stream;
  @override
  void send(Map<String, dynamic> f) {
    sent.add(f);
  }

  void event(String type, Map<String, dynamic> payload) {
    input.add({'version': 1, 'type': type, 'payload': payload});
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  Future<void> dispose() => input.close();
}

class ChatFixture extends space.SpaceFixture {
  List<Map<String, dynamic>> history = [message()];
  bool pages = true, expiredAfter = false;
  int recoveryAttempts = 0;
  @override
  Future<Map<String, dynamic>> discoveryRequest(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    CancelToken? cancel,
  }) async {
    if (method == 'GET' && path.endsWith('/chat/messages')) {
      if (query?['after'] != null) {
        recoveryAttempts++;
        if (expiredAfter) {
          expiredAfter = false;
          throw const ExperienceIssue('invalid_request', status: 400);
        }
      }
      calls.add({'path': path, 'method': method, 'query': query});
      return {
        'items': query?['cursor'] == null
            ? history
            : [message(id: 'older', seq: '0', body: 'Primeira conversa')],
        'next_cursor':
            query?['after'] == null && query?['cursor'] == null && pages
            ? 'previous'
            : null,
        'resume_cursor': 'after',
        'capabilities': {
          'can_read': true,
          'can_write': write,
          'can_moderate': moderator,
        },
        'reset': false,
      };
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
  testWidgets(
    'aba Chat carrega histórico, envia pendente, ACK e pagina sem duplicar',
    (t) async {
      final repo = ChatFixture();
      final socket = SocketFixture();
      addTearDown(socket.dispose);
      await social.mount(
        t,
        repo,
        '/experiences/$experienceId/space',
        chatConnector: (_, _) async => socket,
      );
      await social.tap(t, 'Chat');
      expect(find.text('Conversa do encontro'), findsOneWidget);
      await social.tap(t, 'Carregar mensagens anteriores');
      expect(find.text('Primeira conversa'), findsOneWidget);
      await t.enterText(find.byType(TextField).last, 'Vamos nos encontrar');
      await t.ensureVisible(find.byTooltip('Enviar mensagem'));
      await t.tap(find.byTooltip('Enviar mensagem'));
      await t.pump();
      await t.pump();
      expect(find.text('Enviando…'), findsOneWidget);
      final p = socket.sent.last['payload'] as Map;
      final ack = message(
        id: 'new',
        seq: '2',
        body: 'Vamos nos encontrar',
        client: p['client_message_id'] as String,
      );
      socket.event('chat.message.ack', ack);
      socket.event('chat.message.created', ack);
      await t.pumpAndSettle();
      expect(find.text('Enviando…'), findsNothing);
      expect(find.text('Vamos nos encontrar'), findsOneWidget);
      await social.tap(t, 'Mural');
      socket.event('chat.message.created', message(id: 'third', seq: '3'));
      await t.pumpAndSettle();
      expect(find.text('Chat •'), findsOneWidget);
      await social.unmount(t);
      expect(socket.closed, true);
    },
  );
  testWidgets('chat só leitura, remoção, revogação, background e retomada', (
    t,
  ) async {
    final r = ChatFixture()..write = false;
    final sockets = <SocketFixture>[];
    final (c, rig) = await social.mount(
      t,
      r,
      '/experiences/$experienceId/space',
      chatConnector: (_, _) async {
        final s = SocketFixture();
        sockets.add(s);
        return s;
      },
    );
    addTearDown(() async {
      for (final s in sockets) {
        await s.dispose();
      }
    });
    await social.tap(t, 'Chat');
    expect(find.byTooltip('Enviar mensagem'), findsNothing);
    sockets.last.event('chat.message.removed', {
      ...message(),
      'removed': true,
      'author': null,
      'body': null,
      'change_sequence': '2',
    });
    await t.pumpAndSettle();
    expect(find.text('Mensagem removida'), findsOneWidget);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump();
    expect(sockets.last.closed, true);
    expect(c.read(chatControllerProvider(experienceId)).messages, isEmpty);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    rig.auth.lifecycle(false);
    expect(sockets.length, 2);
    sockets.last.event('chat.access.revoked', {'code': 'not_found'});
    await t.pumpAndSettle();
    expect(find.text('Conversa do encontro'), findsNothing);
    expect(c.read(chatControllerProvider(experienceId)).messages, isEmpty);
    await social.unmount(t);
  });
  testWidgets(
    'envio permanece acessível em 320px, texto ampliado, tema escuro e teclado',
    (t) async {
      final repo = ChatFixture()..pages = false;
      final socket = SocketFixture();
      addTearDown(socket.dispose);
      addTearDown(() {
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
        t.view.resetViewInsets();
        t.platformDispatcher.clearTextScaleFactorTestValue();
        t.platformDispatcher.clearPlatformBrightnessTestValue();
      });
      await social.mount(
        t,
        repo,
        '/experiences/$experienceId/space',
        chatConnector: (_, _) async => socket,
      );
      await social.tap(t, 'Chat');
      t.view.physicalSize = const Size(320, 800);
      t.view.devicePixelRatio = 1;
      t.platformDispatcher.textScaleFactorTestValue = 2;
      t.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      t.view.viewInsets = const FakeViewPadding(bottom: 280);
      await t.pumpAndSettle();
      expect(find.byTooltip('Enviar mensagem').hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
      await social.unmount(t);
    },
  );
  testWidgets(
    'queda reconecta com backoff e descarta cursor expirado sem repetir socket',
    (t) async {
      final repo = ChatFixture()..pages = false;
      final sockets = <SocketFixture>[];
      final (container, _) = await social.mount(
        t,
        repo,
        '/experiences/$experienceId/space',
        chatConnector: (_, _) async {
          final s = SocketFixture();
          sockets.add(s);
          return s;
        },
      );
      addTearDown(() async {
        for (final s in sockets) {
          await s.dispose();
        }
      });
      await social.tap(t, 'Chat');
      repo.expiredAfter = true;
      sockets.single.input.addError(StateError('network'));
      await t.pump();
      expect(
        container.read(chatControllerProvider(experienceId)).messages,
        isEmpty,
      );
      await t.pump(const Duration(seconds: 2));
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 3));
      await t.pumpAndSettle();
      expect(repo.recoveryAttempts, 1);
      expect(sockets.length, 2);
      expect(
        container.read(chatControllerProvider(experienceId)).connected,
        true,
      );
      await social.unmount(t);
    },
  );
  test('ACK perdido reconcilia UUID após rede; eventos antigos não ressuscitam removida; logout limpa', () async {
    final rig = Rig();
    await rig.login(completed: true);
    rig.auth.lifecycle(false);
    final access = ExperienceAccess(rig.auth), r = ChatFixture();
    final transport = Dio();
    final sockets = <SocketFixture>[];
    final c = ChatController(
      experienceId,
      SocialRepository(r, transport, 'https://test.invalid/'),
      access,
      (_) async {
        final s = SocketFixture();
        sockets.add(s);
        return s;
      },
      Uri.parse('https://test.invalid/'),
    );
    await c.start();
    c.send('ACK incerto');
    final pending = c.pending.values.single;
    final m = message(
      id: 'persisted',
      seq: '2',
      body: 'ACK incerto',
      client: pending['client_message_id'] as String,
    );
    r.history = [m];
    await c.reconnect();
    expect(c.pending, isEmpty);
    expect(c.messages.length, 1);
    expect(sockets.first.closed, true);
    sockets.last.event('chat.message.removed', {
      ...m,
      'removed': true,
      'body': null,
      'author': null,
      'change_sequence': '5',
    });
    sockets.last.event('chat.message.created', {...m, 'change_sequence': '2'});
    await Future<void>.delayed(Duration.zero);
    expect(c.messages['persisted']!['removed'], true);
    c.send('Falha de envio');
    final id = c.pending.keys.single;
    sockets.last.event('chat.error', {
      'code': 'rate_limited',
      'client_message_id': id,
    });
    await Future<void>.delayed(Duration.zero);
    expect(c.pending[id]!['state'], 'failed');
    await rig.auth.signOut();
    expect(c.messages, isEmpty);
    expect(c.pending, isEmpty);
    expect(c.active, false);
    c.dispose();
    access.dispose();
    rig.auth.dispose();
    transport.close(force: true);
    for (final s in sockets) {
      await s.dispose();
    }
  });
}
