import 'package:image/image.dart' as image;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:flow_mobile/features/experiences/data/experiences_repository.dart';
import 'package:flow_mobile/features/experiences/data/cover_upload.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';
import 'package:flow_mobile/features/explore/flow_upload.dart';
import 'package:flow_mobile/features/social/social_repository.dart';

void main() {
  const origin = String.fromEnvironment('FLOW_SOCIAL_CONTRACT_URL');
  test(
    'Flutter/Dio ↔ Go/OpenAPI/PostgreSQL/S3: Social real e revogação',
    () async {
      final dio = Dio(BaseOptions(baseUrl: origin, followRedirects: false));
      final transport = createStorageTransport();
      addTearDown(() => dio.close(force: true));
      addTearDown(() => transport.close(force: true));
      final owner = (await dio.get<Map<String, dynamic>>('__fixture/session'))
              .data!,
          other = (await dio.get<Map<String, dynamic>>(
            '__fixture/session',
            queryParameters: {'actor': 'participant'},
          )).data!;
      Future<T> authorize<T>(
        Future<T> Function(String) fn, {
        bool replaySafe = false,
      }) => fn(owner['access'] as String);
      Future<T> outsider<T>(
        Future<T> Function(String) fn, {
        bool replaySafe = false,
      }) => fn(other['access'] as String);
      final api = DioExperiencesRepository(dio, authorize),
          foreign = DioExperiencesRepository(dio, outsider);
      addTearDown(api.dispose);
      addTearDown(foreign.dispose);
      final a = SocialRepository(api, transport, origin),
          b = SocialRepository(foreign, transport, origin);
      Map<String, dynamic> key() => {'Idempotency-Key': const Uuid().v4()};
      // Verified tiny PNG source; pipeline remains asynchronous (tested separately with ffmpeg).
      final png = image.encodePng(image.Image(width: 3, height: 2));
      final upload = FlowUpload(a, '', png, 'image/png');
      final asset = await upload.run(CancelToken());
      expect(asset.status, 'PROCESSING');
      await expectLater(
        b.asset(asset.id, CancelToken()),
        throwsA(isA<ExperienceIssue>().having((e) => e.status, 'status', 404)),
      );
      final created = await a.request(
        'POST',
        'v1/social/posts',
        body: {
          'context': 'PERSONAL',
          'visibility': 'FOLLOWERS',
          'body': 'Registro integrado Social',
          'media_ids': <String>[],
        },
        headers: key(),
      );
      final path = 'v1/social/posts/${created['id']}';
      await expectLater(
        b.request('GET', path),
        throwsA(isA<ExperienceIssue>().having((e) => e.status, 'status', 404)),
      );
      await b.request(
        'PUT',
        'v1/social/profiles/${owner['user_id']}/follow',
        body: {},
        headers: key(),
      );
      expect(
        (await b.request('GET', path))['body'],
        'Registro integrado Social',
      );
      await b.request('PUT', '$path/like', body: {}, headers: key());
      await b.request('PUT', '$path/like', body: {}, headers: key());
      expect((await a.request('GET', path))['like_count'], 1);
      final comment = await b.request(
        'POST',
        '$path/comments',
        body: {'body': 'Comentário integrado'},
        headers: key(),
      );
      expect(
        ((await a.request('GET', '$path/comments'))['items'] as List)
            .single['id'],
        comment['id'],
      );
      await b.request(
        'POST',
        'v1/social/reports',
        body: {
          'target_type': 'POST',
          'target_id': created['id'],
          'reason': 'SPAM',
        },
        headers: key(),
      );
      final profile = await b.request(
        'GET',
        'v1/social/profiles/${owner['user_id']}',
      );
      expect(profile['following'], true);
      expect(profile['follower_count'], 1);
      await a.request(
        'PATCH',
        path,
        body: {'body': 'Texto atualizado'},
        headers: {...key(), 'If-Match': '"1"'},
      );
      expect((await b.request('GET', path))['body'], 'Texto atualizado');
      await a.request(
        'DELETE',
        '$path/comments/${comment['id']}',
        body: {},
        headers: key(),
      );
      expect((await b.request('GET', path))['comment_count'], 0);
      await b.request(
        'PUT',
        'v1/social/profiles/${owner['user_id']}/block',
        body: {},
        headers: key(),
      );
      await expectLater(
        b.request('GET', path),
        throwsA(isA<ExperienceIssue>().having((e) => e.status, 'status', 404)),
      );
      await b.request(
        'DELETE',
        'v1/social/profiles/${owner['user_id']}/block',
        body: {},
        headers: key(),
      );
      await expectLater(
        b.request('GET', path),
        throwsA(isA<ExperienceIssue>().having((e) => e.status, 'status', 404)),
      );
      await a.request('DELETE', path, body: {}, headers: key());
      await expectLater(
        a.request('GET', path),
        throwsA(isA<ExperienceIssue>().having((e) => e.status, 'status', 404)),
      );
    },
    skip: origin.isEmpty ? 'Execute make social-mobile-contract' : false,
  );
}
