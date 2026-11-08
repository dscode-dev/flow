// Only make experiences-mobile-contract enables this test. Fixtures are minted
// in a Go integration binary, never in production routes or application code.
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:flow_mobile/core/auth/auth_state.dart';
import 'package:flow_mobile/core/auth/identity_api.dart';
import 'package:flow_mobile/core/auth/models.dart';
import 'package:flow_mobile/features/experiences/data/cover_upload.dart';
import 'package:flow_mobile/features/experiences/data/experiences_repository.dart';
import 'package:flow_mobile/features/experiences/domain/experience.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';
import 'package:flow_mobile/features/experiences/domain/experience_time.dart';
import 'package:flow_mobile/features/home/home_controller.dart';
import 'package:flow_mobile/features/home/home_model.dart';

import 'support/auth_fakes.dart' show MemoryStore, FakeSocial;

class FixtureIdentity extends DioIdentityApi {
  FixtureIdentity(super.dio, this.fixture);
  final Map<String, dynamic> fixture;
  @override
  Future<LoginResult> refresh(String refresh) async => LoginResult(
    fixture['access'] as String,
    'fr_fixture_reissued',
    fixture['session_id'] as String,
    DateTime.now().add(const Duration(minutes: 8)),
    DateTime.now().add(const Duration(minutes: 30)),
    await me(fixture['access'] as String),
  );
}

void main() {
  const origin = String.fromEnvironment('FLOW_EXPERIENCES_CONTRACT_URL');
  test(
    'Flutter/Dio ↔ Go/OpenAPI/PostGIS/S3: draft, capa real, conflito, audiência e lifecycle',
    () async {
      final http = Dio(
        BaseOptions(
          baseUrl: origin,
          followRedirects: false,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
      final storage = createStorageTransport();
      addTearDown(() => http.close(force: true));
      addTearDown(() => storage.close(force: true));
      final session = (await http.get<Map<String, dynamic>>(
        '__fixture/session',
      )).data!;
      final other = (await http.get<Map<String, dynamic>>(
        '__fixture/session',
        queryParameters: {'actor': 'other'},
      )).data!;
      final store = MemoryStore()
        ..data = StoredSession(
          'fr_fixture',
          session['session_id'] as String,
          DateTime.now().add(const Duration(minutes: 30)),
        ).encode();
      final auth = AuthController(
        FixtureIdentity(http, session),
        store,
        FakeSocial(),
      );
      addTearDown(auth.dispose);
      await auth.restore();
      expect(auth.value.status, AuthStatus.authenticated);
      final access = ExperienceAccess(auth);
      addTearDown(access.dispose);
      final repo = DioExperiencesRepository(
        http,
        auth.authorized,
        access: access,
        allowHttpStorage: true,
      );
      addTearDown(repo.dispose);
      Future<T> otherAuthorize<T>(
        Future<T> Function(String) action, {
        bool replaySafe = false,
      }) => action(other['access'] as String);
      final outsider = DioExperiencesRepository(http, otherAuthorize);
      addTearDown(outsider.dispose);
      final categories = await repo.categories();
      expect(categories, isNotEmpty);
      final category = categories.first.id;
      final key = const Uuid().v4();
      const partial = ExperienceInput(title: 'Rascunho Flutter integrado');
      var draft = await repo.create(partial, key);
      expect((await repo.create(partial, key)).id, draft.id);
      expect((await repo.mine()).items.any((e) => e.id == draft.id), true);
      await expectLater(
        outsider.get(draft.id),
        throwsA(isA<ExperienceIssue>().having((e) => e.status, 'status', 404)),
      );
      await expectLater(
        repo.transition(draft, 'publish'),
        throwsA(
          isA<ExperienceIssue>().having(
            (e) => e.code,
            'code',
            'experience_invalid',
          ),
        ),
      );

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawPaint(ui.Paint()..color = const ui.Color(0xff2556d8));
      final picture = recorder.endRecording();
      final image = await picture.toImage(64, 48);
      picture.dispose();
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!
          .buffer
          .asUint8List();
      image.dispose();
      final selection = await CoverSelection.validate(png);
      final upload = CoverUpload(repo, storage, selection);
      final ready = await upload.run(CancelToken());
      expect(ready.width, 64);
      expect(ready.height, 48);
      final start = DateTime.now().toUtc().add(const Duration(days: 3));
      final input = ExperienceInput(
        title: 'Encontro Flutter integrado',
        description: 'Experiência sintética para integração real.',
        categoryId: category,
        visibility: ExperienceVisibility.public,
        startsAt: start,
        endsAt: start.add(const Duration(hours: 2)),
        timezone: 'America/Recife',
        location: const GeoPoint(-8.123456, -34.987654),
        venueName: 'Local sintético de teste',
        address: 'Endereço sintético',
        capacity: 25,
        externalTicketUrl: 'https://tickets.flow.invalid/event',
        coverMediaId: ready.id,
      );
      final old = draft;
      draft = await repo.update(draft, input);
      await expectLater(
        repo.update(old, input),
        throwsA(
          isA<ExperienceIssue>().having(
            (e) => e.code,
            'code',
            'version_conflict',
          ),
        ),
      );
      expect((await repo.get(draft.id)).input.location!.longitude, -34.987654);
      expect((await repo.cover(draft.id)), isNotEmpty);
      expect(
        ExperienceTime.local(
          draft.input.startsAt!,
          draft.input.timezone!,
        ).toUtc(),
        start,
      );
      var published = await repo.transition(draft, 'publish');
      expect(published.status, ExperienceStatus.published);
      expect((await outsider.get(draft.id)).detailsRedacted, false);
      expect((await outsider.cover(draft.id)), isNotEmpty);
      final home = HomeController(repo, access);
      addTearDown(home.dispose);
      await home.load();
      expect(home.value.issue, isNull);
      expect(
        home.value.document!.sections
            .expand((s) => s.items)
            .any((e) => e.experience.id == draft.id),
        true,
      );
      expect(
        home.value.document!.sections
            .firstWhere((s) => s.id == 'nearby')
            .availability,
        'locality_required',
      );
      await home.selectRegion(
        DiscoveryRegion.parse('Região de integração', '-8.12', '-34.99', '10'),
      );
      expect(
        home.value.document!.sections
            .firstWhere((s) => s.id == 'nearby')
            .items
            .single
            .experience
            .id,
        draft.id,
      );
      await home.selectRegion(
        DiscoveryRegion.parse(
          'Outra região de integração',
          '-23.55',
          '-46.63',
          '10',
        ),
      );
      expect(
        home.value.document!.sections.firstWhere((s) => s.id == 'nearby').items,
        isEmpty,
      );
      final corrected = ExperienceInput.fromJson({
        ...published.input.toJson(),
        'title': 'Correção permitida',
      });
      published = await repo.update(published, corrected);
      final cancelled = await repo.transition(published, 'cancel');
      expect(cancelled.status, ExperienceStatus.cancelled);
      final redacted = await outsider.get(draft.id);
      expect(redacted.detailsRedacted, true);
      expect(redacted.input.location, isNull);
      expect(redacted.input.coverMediaId, isNull);
      expect(redacted.input.externalTicketUrl, isNull);
      await home.load();
      expect(
        home.value.document!.sections
            .expand((s) => s.items)
            .any((e) => e.experience.id == draft.id),
        false,
      );
      await expectLater(
        outsider.cover(draft.id),
        throwsA(isA<ExperienceIssue>().having((e) => e.status, 'status', 404)),
      );
      final archived = await repo.transition(cancelled, 'archive');
      expect(archived.status, ExperienceStatus.archived);
      await expectLater(
        repo.transition(archived, 'publish'),
        throwsA(
          isA<ExperienceIssue>().having(
            (e) => e.code,
            'code',
            'invalid_transition',
          ),
        ),
      );

      final unlisted = await repo.create(
        ExperienceInput.fromJson({...input.toJson(), 'visibility': 'UNLISTED'}),
        const Uuid().v4(),
      );
      final direct = await repo.transition(unlisted, 'publish');
      expect(
        (await outsider.get(direct.id)).input.visibility,
        ExperienceVisibility.unlisted,
      );
      final private = await repo.create(
        ExperienceInput.fromJson({...input.toJson(), 'visibility': 'PRIVATE'}),
        const Uuid().v4(),
      );
      await repo.transition(private, 'publish');
      await home.selectRegion(null);
      expect(home.value.document!.isEmpty, true);
      home.pause();
      await expectLater(
        outsider.get(private.id),
        throwsA(isA<ExperienceIssue>().having((e) => e.status, 'status', 404)),
      );
      await http.post<void>('__fixture/revoke');
      await expectLater(repo.homeDocument({}), throwsA(isA<AuthIssue>()));
      expect(auth.value.status, AuthStatus.sessionExpired);
      expect(access.ownerId, isNull);
      expect(store.data, isNull);
    },
    skip: origin.isEmpty
        ? 'Use make experiences-mobile-contract; requer Go/PostGIS/S3 reais.'
        : false,
  );
}
