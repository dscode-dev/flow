import 'package:dio/dio.dart';

import 'dart:async';

import 'package:flow_mobile/features/event_space/chat_socket.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:flow_mobile/features/experiences/data/experiences_repository.dart';
import 'package:flow_mobile/features/experiences/data/cover_upload.dart';
import 'package:flow_mobile/features/experiences/domain/experience.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';
import 'package:flow_mobile/features/social/social_repository.dart';

void main() {
  const origin = String.fromEnvironment('FLOW_CHAT_CONTRACT_URL');
  test('Flutter/Dio ↔ Go/OpenAPI/PostgreSQL: Chat WebSocket real: persistência, ACK, recuperação e revogação', () async {
    final dio = Dio(BaseOptions(baseUrl: origin, followRedirects: false));
    final storage = createStorageTransport();
    addTearDown(() => dio.close(force: true));
    addTearDown(() => storage.close(force: true));
    final owner = (await dio.get<Map<String, dynamic>>('__fixture/session'))
            .data!,
        member = (await dio.get<Map<String, dynamic>>(
          '__fixture/session',
          queryParameters: {'actor': 'participant'},
        )).data!;
    Future<T> authorize<T>(
      Future<T> Function(String) fn, {
      bool replaySafe = false,
    }) => fn(owner['access'] as String);
    Future<T> participant<T>(
      Future<T> Function(String) fn, {
      bool replaySafe = false,
    }) => fn(member['access'] as String);
    final api = DioExperiencesRepository(dio, authorize),
        other = DioExperiencesRepository(dio, participant);
    addTearDown(api.dispose);
    addTearDown(other.dispose);
    final a = SocialRepository(api, storage, origin),
        b = SocialRepository(other, storage, origin);
    Map<String, dynamic> key() => {'Idempotency-Key': const Uuid().v4()};
    Future<void> denied(Future<dynamic> response) => expectLater(
      response,
      throwsA(isA<ExperienceIssue>().having((e) => e.status, 'status', 404)),
    );
    var e = await api.create(
      ExperienceInput(
        title: 'Espaço integrado PR08',
        description: 'Uma experiência privada para integração real.',
        categoryId: (await api.categories()).first.id,
        visibility: ExperienceVisibility.private,
        startsAt: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
        endsAt: DateTime.now().toUtc().add(const Duration(hours: 2)),
        timezone: 'America/Recife',
        location: const GeoPoint(-8.0476, -34.877),
        venueName: 'Praça de integração',
      ),
      const Uuid().v4(),
    );
    e = await api.transition(e, 'publish');
    final base = 'v1/experiences/${e.id}';
    final space = '$base/space';
    await denied(b.request('GET', space));
    final invite = await a.request(
      'POST',
      '$base/invitations',
      body: {'user_id': member['user_id']},
      headers: key(),
    );
    await denied(b.request('GET', space));
    await b.request(
      'POST',
      'v1/invitations/${invite['id']}/accept',
      body: {},
      headers: key(),
    );
    final summary = await b.request('GET', space);
    expect(summary['capabilities'], containsPair('can_write', true));

    final cp = '$space/chat';
    final page = await b.request('GET', '$cp/messages');
    final http = Uri.parse(origin).resolve('$cp/socket');
    var socket = await connectChat(
      http.replace(scheme: 'ws'),
      member['access'] as String,
    );
    final frames = StreamController<Map<String, dynamic>>.broadcast();
    var subscription = socket.frames.listen(frames.add);
    addTearDown(() async {
      await subscription.cancel();
      await socket.close();
      await frames.close();
    });
    void send(String type, Map<String, dynamic> payload) => socket.send({
      'message_id': const Uuid().v4(),
      'type': type,
      'version': 1,
      'sent_at': DateTime.now().toUtc().toIso8601String(),
      'payload': payload,
    });
    Future<Map<String, dynamic>> next(String type) => frames.stream
        .firstWhere((f) => f['type'] == type)
        .timeout(const Duration(seconds: 5));
    var joined = next('chat.joined');
    send('chat.join', {'cursor': page['resume_cursor']});
    await joined;
    final client = const Uuid().v4();
    final body = {
      'client_message_id': client,
      'body': 'Conversa privada integrada pelo WebSocket',
    };
    var ackFuture = next('chat.message.ack');
    send('chat.message.send', body);
    final ack = await ackFuture;
    final message = (ack['payload'] as Map).cast<String, dynamic>();
    expect(message['sequence'], '1');
    expect(
      ((await a.request('GET', '$cp/messages'))['items'] as List).single['id'],
      message['id'],
    );
    await subscription.cancel();
    await socket.close();
    socket = await connectChat(
      http.replace(scheme: 'ws'),
      member['access'] as String,
    );
    subscription = socket.frames.listen(frames.add);
    joined = next('chat.joined');
    send('chat.join', {'cursor': page['resume_cursor']});
    await joined;
    ackFuture = next('chat.message.ack');
    send('chat.message.send', body);
    expect(((await ackFuture)['payload'] as Map)['id'], message['id']);
    final recovery = await b.request(
      'GET',
      '$cp/messages',
      query: {'after': page['resume_cursor']},
    );
    expect((recovery['items'] as List).length, 1);
    await a.request(
      'POST',
      'v1/social/reports',
      body: {
        'target_type': 'CHAT_MESSAGE',
        'target_id': message['id'],
        'reason': 'PRIVACY',
      },
      headers: key(),
    );
    final removedFuture = next('chat.message.removed');
    await a.request(
      'DELETE',
      '$cp/messages/${message['id']}',
      body: {'reason': 'SAFETY'},
    );
    expect(((await removedFuture)['payload'] as Map)['body'], isNull);
    final revoked = next('chat.access.revoked');
    await a.request(
      'POST',
      '$base/participants/${member['user_id']}/remove',
      body: {'reason': 'SAFETY'},
      headers: key(),
    );
    await revoked;
    await denied(b.request('GET', '$cp/messages'));
  }, skip: origin.isEmpty ? 'Execute make chat-mobile-contract' : false);
}
