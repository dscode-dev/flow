import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:flow_mobile/features/experiences/data/experiences_repository.dart';
import 'package:flow_mobile/features/experiences/data/cover_upload.dart';
import 'package:flow_mobile/features/experiences/domain/experience.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';
import 'package:flow_mobile/features/social/social_repository.dart';

void main() {
  const origin = String.fromEnvironment('FLOW_EVENT_SPACE_CONTRACT_URL');
  test('Flutter/Dio ↔ Go/OpenAPI/PostgreSQL: Event Space privado, Social e revogação', () async {
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
    final created = await b.request(
      'POST',
      'v1/social/posts',
      body: {
        'context': 'EVENT_SPACE',
        'visibility': 'SPACE',
        'experience_id': e.id,
        'body': 'Uma memória contextual real',
        'media_ids': <String>[],
      },
      headers: key(),
    );
    final path = 'v1/social/posts/${created['id']}';
    expect(
      ((await a.request('GET', '$space/feed'))['items'] as List).single['id'],
      created['id'],
    );
    expect((await a.request('GET', 'v1/social/feed'))['items'], isEmpty);
    expect(
      ((await b.request('GET', '$space/participants'))['items'] as List).length,
      2,
    );
    await a.request('PUT', '$path/like', body: {}, headers: key());
    final comment = await a.request(
      'POST',
      '$path/comments',
      body: {'body': 'Comentário contextual integrado'},
      headers: key(),
    );
    expect((await b.request('GET', path))['comment_count'], 1);
    await a.request(
      'POST',
      '$space/moderation',
      body: {
        'target_type': 'COMMENT',
        'target_id': comment['id'],
        'action': 'HIDE',
        'reason': 'SAFETY',
      },
      headers: key(),
    );
    expect((await b.request('GET', '$path/comments'))['items'], isEmpty);
    await a.request(
      'POST',
      '$base/participants/${member['user_id']}/remove',
      body: {'reason': 'SAFETY'},
      headers: key(),
    );
    await denied(b.request('GET', path));
    await denied(b.request('GET', '$space/feed'));
    // The former participant keeps the ability to delete their own known content.
    await b.request('DELETE', path, body: {}, headers: key());
  }, skip: origin.isEmpty ? 'Execute make event-space-mobile-contract' : false);
}
