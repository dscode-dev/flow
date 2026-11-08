import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flow_mobile/features/experiences/data/cover_upload.dart';
import 'package:flow_mobile/features/experiences/data/experiences_repository.dart';
import 'package:flow_mobile/features/experiences/domain/experience.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';

import 'support/experience_fakes.dart';
import 'support/auth_fakes.dart' show Rig;

import 'package:flow_mobile/core/auth/auth_state.dart';

class ExperienceBoundary implements HttpClientAdapter {
  ExperienceBoundary(this.respond);
  final ResponseBody Function(RequestOptions) respond;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    // Finalize multipart just as a real network adapter does.
    if (stream != null) await stream.drain<void>();
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonReply(Object value, {int status = 200, String? etag}) =>
    ResponseBody.fromString(
      jsonEncode(value),
      status,
      headers: {
        'content-type': ['application/json'],
        'etag': [etag ?? '"7"'],
      },
    );
Map<String, dynamic> representation(ExperienceInput input) => {
  ...input.toJson(),
  'id': experienceId,
  'creator_user_id': 'user',
  'status': 'DRAFT',
  'version': 7,
  'phase': null,
  'details_redacted': false,
  'created_at': '2026-11-07T00:00:00Z',
  'updated_at': '2026-11-07T00:00:00Z',
  'published_at': null,
  'cancelled_at': null,
  'archived_at': null,
};
Future<T> authorizeFixture<T>(
  Future<T> Function(String) action, {
  bool replaySafe = false,
}) => action('fa_fixture');

void main() {
  test('401 de escrita usa refresh central uma vez e não repete PUT; revogação limpa escopo', () async {
    final rig = Rig();
    await rig.login(completed: true);
    addTearDown(rig.auth.dispose);
    final access = ExperienceAccess(rig.auth);
    addTearDown(access.dispose);
    final boundary = ExperienceBoundary(
      (_) => jsonReply({
        'error': {
          'code': 'unauthorized',
          'message': 'ignorar',
          'request_id': 'request-safe',
        },
      }, status: 401),
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://api.flow.invalid/'))
      ..httpClientAdapter = boundary;
    addTearDown(() => dio.close(force: true));
    final repo = DioExperiencesRepository(
      dio,
      rig.auth.authorized,
      access: access,
    );
    addTearDown(repo.dispose);
    await expectLater(
      repo.update(sampleExperience(), const ExperienceInput()),
      throwsA(isA<AuthIssue>()),
    );
    expect(boundary.requests.length, 1);
    expect(rig.api.refreshCalls, 1);
    await expectLater(repo.get(experienceId), throwsA(isA<AuthIssue>()));
    expect(rig.auth.value.status, AuthStatus.sessionExpired);
    expect(access.ownerId, isNull);
  });
  test(
    'Retry-After bloqueia novas chamadas de rede até a janela passar',
    () async {
      var clock = DateTime.utc(2026, 11, 7);
      final boundary = ExperienceBoundary(
        (_) => ResponseBody.fromString(
          jsonEncode({
            'error': {
              'code': 'rate_limited',
              'message': 'ignorar',
              'request_id': 'request-safe',
            },
          }),
          429,
          headers: {
            'content-type': ['application/json'],
            'retry-after': ['120'],
          },
        ),
      );
      final dio = Dio(BaseOptions(baseUrl: 'https://api.flow.invalid/'))
        ..httpClientAdapter = boundary;
      addTearDown(() => dio.close(force: true));
      final repo = DioExperiencesRepository(
        dio,
        authorizeFixture,
        now: () => clock,
      );
      for (var i = 0; i < 2; i++) {
        await expectLater(
          repo.create(const ExperienceInput(), 'key'),
          throwsA(
            isA<AuthIssue>().having((e) => e.code, 'code', 'rate_limited'),
          ),
        );
      }
      expect(boundary.requests.length, 1);
      clock = clock.add(const Duration(seconds: 121));
      await expectLater(
        repo.create(const ExperienceInput(), 'key'),
        throwsA(isA<AuthIssue>()),
      );
      expect(boundary.requests.length, 2);
    },
  );
  test(
    'serialização exata, If-Match forte, Idempotency-Key e paginação',
    () async {
      const input = ExperienceInput(
        title: 'Plano',
        timezone: 'America/Recife',
        startsAt: null,
        capacity: 12,
      );
      final boundary = ExperienceBoundary(
        (o) => o.path == 'v1/me/experiences'
            ? jsonReply({
                'items': [representation(input)],
                'next_cursor': 'cursor-opaque',
              })
            : jsonReply(representation(input)),
      );
      final dio = Dio(BaseOptions(baseUrl: 'https://api.flow.invalid/'))
        ..httpClientAdapter = boundary;
      final repository = DioExperiencesRepository(dio, authorizeFixture);
      addTearDown(() => dio.close(force: true));
      final created = await repository.create(input, 'uuid-key');
      await repository.update(created, input.withCover(null));
      await repository.transition(created, 'publish');
      final page = await repository.mine(
        cursor: 'opaque',
        status: ExperienceStatus.draft,
      );
      expect(boundary.requests[0].headers['Idempotency-Key'], 'uuid-key');
      expect(boundary.requests[0].data, input.toJson());
      expect(boundary.requests[1].headers['If-Match'], '"7"');
      expect(boundary.requests[1].data['starts_at'], isNull);
      expect(boundary.requests[2].data, isEmpty);
      expect(boundary.requests[3].queryParameters, {
        'limit': 20,
        'cursor': 'opaque',
        'status': 'DRAFT',
      });
      expect(page.nextCursor, 'cursor-opaque');
      expect(
        boundary.requests.every(
          (r) => r.headers['Authorization'] == 'Bearer fa_fixture',
        ),
        true,
      );
    },
  );
  test(
    'conflito/expiração/quota usam envelope sanitizado e não repetem escrita',
    () async {
      final boundary = ExperienceBoundary(
        (_) => ResponseBody.fromString(
          jsonEncode({
            'error': {
              'code': 'version_conflict',
              'message': 'PRIVATE_PAYLOAD',
              'request_id': 'request-safe',
            },
          }),
          412,
          headers: {
            'content-type': ['application/json'],
            'retry-after': ['60'],
          },
        ),
      );
      final dio = Dio(BaseOptions(baseUrl: 'https://api.flow.invalid/'))
        ..httpClientAdapter = boundary;
      addTearDown(() => dio.close(force: true));
      final repository = DioExperiencesRepository(dio, authorizeFixture);
      await expectLater(
        repository.update(sampleExperience(), const ExperienceInput()),
        throwsA(
          isA<ExperienceIssue>()
              .having((e) => e.code, 'code', 'version_conflict')
              .having((e) => e.requestId, 'request', 'request-safe')
              .having(
                (e) => e.message,
                'mensagem',
                isNot(contains('PRIVATE_PAYLOAD')),
              ),
        ),
      );
      expect(boundary.requests.length, 1);
    },
  );
  test(
    'upload isolado preserva fields, não envia bearer e só associa após READY',
    () async {
      final fake = FakeExperiencesRepository();
      final storageBoundary = ExperienceBoundary((options) {
        expect(options.headers.containsKey('Authorization'), false);
        expect(options.headers.containsKey('Cookie'), false);
        expect(options.uri.host, 'storage.flow.invalid');
        final data = options.data as FormData;
        expect(Map.fromEntries(data.fields), {
          'policy': 'opaque-policy',
          'key': 'staging/key',
        });
        expect(data.files.single.key, 'file');
        fake.stages.add('storage');
        return ResponseBody.fromString('', 204);
      });
      final storage = createStorageTransport()
        ..httpClientAdapter = storageBoundary;
      addTearDown(() => storage.close(force: true));
      final upload = CoverUpload(
        fake,
        storage,
        CoverSelection(Uint8List.fromList([1, 2, 3]), 'image/png'),
      );
      final ready = await upload.run(CancelToken());
      expect(ready.id, 'media-1');
      await upload.run(CancelToken());
      expect(fake.stages, ['initiate', 'storage', 'confirm']);
      await fake.update(
        sampleExperience(),
        const ExperienceInput().withCover(ready.id),
      );
      expect(fake.stages.last, 'associate');
    },
  );
  test('autorização expirada não manda binário nem confirma; confirmação pode repetir sem reenviar', () async {
    final fake = FakeExperiencesRepository();
    final boundary = ExperienceBoundary(
      (_) => ResponseBody.fromString('', 204),
    );
    final storage = createStorageTransport()..httpClientAdapter = boundary;
    addTearDown(() => storage.close(force: true));
    final selection = CoverSelection(Uint8List(1), 'image/png');
    final expired = CoverUpload(
      fake,
      storage,
      selection,
      now: () => DateTime.now().toUtc().add(const Duration(days: 1)),
    );
    await expectLater(
      expired.run(CancelToken()),
      throwsA(
        isA<ExperienceIssue>().having((e) => e.code, 'code', 'upload_expired'),
      ),
    );
    expect(boundary.requests, isEmpty);
    expect(fake.stages, ['initiate']);
    fake.stages.clear();
    final upload = CoverUpload(fake, storage, selection)
      ..authorization = CoverAuthorization(
        'media-1',
        Uri.parse('https://storage.flow.invalid/'),
        {},
        DateTime.now().toUtc().add(const Duration(minutes: 5)),
      );
    fake.failure = const ExperienceIssue('media_unavailable', status: 503);
    await expectLater(
      upload.run(CancelToken()),
      throwsA(isA<ExperienceIssue>()),
    );
    fake.failure = null;
    await upload.run(CancelToken());
    expect(boundary.requests.length, 1);
    expect(fake.stages, ['confirm', 'confirm']);
  });
}
