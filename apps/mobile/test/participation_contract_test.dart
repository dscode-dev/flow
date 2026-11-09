import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:flow_mobile/features/experiences/data/experiences_repository.dart';
import 'package:flow_mobile/features/experiences/domain/experience.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';
import 'package:flow_mobile/features/participation/participation_repository.dart';

void main() {
  const origin = String.fromEnvironment('FLOW_PARTICIPATION_CONTRACT_URL');
  test('Flutter/Dio ↔ Go/OpenAPI/PostgreSQL: convite privado, capacidade, agenda e check-in', () async {
    final dio = Dio(
      BaseOptions(
        baseUrl: origin,
        followRedirects: false,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
      ),
    );
    addTearDown(() => dio.close(force: true));
    final owner = (await dio.get<Map<String, dynamic>>('__fixture/session'))
        .data!;
    final other = (await dio.get<Map<String, dynamic>>(
      '__fixture/session',
      queryParameters: {'actor': 'participant'},
    )).data!;
    Future<T> authorize<T>(
      Future<T> Function(String) action, {
      bool replaySafe = false,
    }) => action(owner['access'] as String);
    Future<T> participantAuthorize<T>(
      Future<T> Function(String) action, {
      bool replaySafe = false,
    }) => action(other['access'] as String);
    final experiences = DioExperiencesRepository(dio, authorize),
        outsider = DioExperiencesRepository(dio, participantAuthorize);
    addTearDown(experiences.dispose);
    addTearDown(outsider.dispose);
    final creator = ParticipationRepository(experiences),
        participant = ParticipationRepository(outsider);
    final category = (await experiences.categories()).first.id;
    final now = DateTime.now().toUtc();
    var e = await experiences.create(
      ExperienceInput(
        title: 'Encontro integrado PR06',
        description: 'Uma experiência de integração real de participação.',
        categoryId: category,
        visibility: ExperienceVisibility.private,
        startsAt: now.subtract(const Duration(minutes: 5)),
        endsAt: now.add(const Duration(hours: 2)),
        timezone: 'America/Recife',
        location: const GeoPoint(-8.0476, -34.877),
        venueName: 'Praça de integração',
        capacity: 1,
        externalTicketUrl: 'https://tickets.example/experiencia',
      ),
      const Uuid().v4(),
    );
    e = await experiences.transition(e, 'publish');
    final base = 'v1/experiences/${e.id}';
    Map<String, dynamic> key() => {'Idempotency-Key': const Uuid().v4()};
    Future<Map<String, dynamic>> post(
      ParticipationRepository repo,
      String path, {
      Map<String, dynamic> body = const {},
    }) => repo.request('POST', path, body: body, headers: key());
    await expectLater(
      outsider.get(e.id),
      throwsA(isA<ExperienceIssue>().having((e) => e.status, 'status', 404)),
    );
    var settings = await creator.request('GET', '$base/participation-settings');
    expect(settings['mode'], 'INVITE');
    final invite = await post(
      creator,
      '$base/invitations',
      body: {'user_id': other['user_id']},
    );
    expect(invite['state'], 'PENDING');
    expect((await outsider.get(e.id)).id, e.id);
    final agenda = await participant.request(
      'GET',
      'v1/me/agenda',
      query: {'section': 'invitations'},
    );
    expect((agenda['items'] as List).single['experience_id'], e.id);
    await post(participant, 'v1/invitations/${invite['id']}/accept');
    var status = await participant.request('GET', '$base/participation');
    expect(status['state'], 'CONFIRMED');
    expect(status['remaining'], 0);
    expect(status['external_ticket'], true);
    final receipt = await participant.request(
      'POST',
      '$base/check-in-credential',
      body: {},
    );
    expect((receipt['code'] as String).length, 16);
    final checked = await post(
      creator,
      '$base/check-ins/validate',
      body: {'code': receipt['code']},
    );
    expect(checked['user_id'], other['user_id']);
    status = await participant.request('GET', '$base/participation');
    expect(status['checked_in'], true);
    await expectLater(
      post(
        creator,
        '$base/check-ins/validate',
        body: {'code': receipt['code']},
      ),
      throwsA(
        isA<ExperienceIssue>().having(
          (e) => e.code,
          'code',
          'checkin_code_used',
        ),
      ),
    );
    final roster = await creator.request(
      'GET',
      '$base/participants',
      query: {'state': 'CONFIRMED'},
    );
    expect((roster['items'] as List).single['checked_in'], true);
    await post(creator, '$base/participants/${other['user_id']}/remove');
    await expectLater(
      outsider.get(e.id),
      throwsA(isA<ExperienceIssue>().having((e) => e.status, 'status', 404)),
    );
    final history = await participant.request(
      'GET',
      'v1/me/agenda',
      query: {'section': 'history'},
    );
    expect((history['items'] as List).single['accessible'], false);
    expect((history['items'] as List).single['starts_at'], isNull);
    // PUBLIC approval mode also uses the real repository and owner ETag.
    e = await experiences.create(
      ExperienceInput(
        title: 'Aprovação integrada PR06',
        description: 'Solicitação e aprovação reais na mesma API.',
        categoryId: category,
        visibility: ExperienceVisibility.public,
        startsAt: now.add(const Duration(hours: 1)),
        endsAt: now.add(const Duration(hours: 2)),
        timezone: 'America/Recife',
        location: const GeoPoint(-8.0476, -34.877),
        venueName: 'Praça',
      ),
      const Uuid().v4(),
    );
    e = await experiences.transition(e, 'publish');
    final public = 'v1/experiences/${e.id}';
    settings = await creator.request('GET', '$public/participation-settings');
    await creator.request(
      'PUT',
      '$public/participation-settings',
      body: {'mode': 'APPROVAL', 'capacity': 1},
      headers: {
        'If-Match':
            '"${settings['version']}-${settings['experience_version']}"',
      },
    );
    await post(participant, '$public/participation/request');
    await post(creator, '$public/participants/${other['user_id']}/approve');
    final upcoming = await participant.request(
      'GET',
      'v1/me/agenda',
      query: {'section': 'upcoming'},
    );
    expect((upcoming['items'] as List).single['state'], 'CONFIRMED');
    await post(participant, '$public/participation/cancel');
    status = await participant.request('GET', '$public/participation');
    expect(status['remaining'], 1);
  }, skip: origin.isEmpty);
}
