import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flow_mobile/features/experiences/data/experiences_repository.dart';
import 'package:flow_mobile/features/experiences/domain/experience.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';

const experienceId = '019a1234-5678-7123-8123-123456789abc';
Experience sampleExperience({
  String id = experienceId,
  String creator = 'user-1',
  int version = 1,
  ExperienceInput input = const ExperienceInput(
    title: 'Encontro no parque',
    description: 'Uma tarde para conversar.',
  ),
  ExperienceStatus status = ExperienceStatus.draft,
  bool redacted = false,
  String? phase,
}) => Experience(
  id: id,
  creatorId: creator,
  input: input,
  status: status,
  version: BigInt.from(version),
  etag: '"$version"',
  detailsRedacted: redacted,
  phase: phase,
  createdAt: DateTime.utc(2026, 11, 7),
  updatedAt: DateTime.utc(2026, 11, 7),
);

class FakeExperiencesRepository implements ExperiencesRepository {
  List<Experience> items = [];
  Experience current = sampleExperience();
  AuthIssue? failure;
  final createdKeys = <String>[];
  final createdInputs = <ExperienceInput>[];
  final updates = <String>[];
  final cursors = <String?>[];
  final stages = <String>[];
  String? nextCursor;
  void check() {
    if (failure case final issue?) throw issue;
  }

  @override
  Future<List<ExperienceCategory>> categories({CancelToken? cancel}) async {
    check();
    return [const ExperienceCategory('nature', 'Natureza', 1)];
  }

  @override
  Future<ExperiencePage> mine({
    String? cursor,
    ExperienceStatus? status,
    CancelToken? cancel,
  }) async {
    cursors.add(cursor);
    check();
    return ExperiencePage(items, nextCursor);
  }

  @override
  Future<Experience> get(String id, {CancelToken? cancel}) async {
    check();
    return current;
  }

  @override
  Future<Experience> create(
    ExperienceInput input,
    String key, {
    CancelToken? cancel,
  }) async {
    createdKeys.add(key);
    createdInputs.add(input);
    check();
    return current = sampleExperience(input: input);
  }

  @override
  Future<Experience> update(
    Experience current,
    ExperienceInput input, {
    CancelToken? cancel,
  }) async {
    updates.add(current.etag);
    stages.add('associate');
    check();
    return this.current = sampleExperience(
      input: input,
      version: current.version.toInt() + 1,
    );
  }

  @override
  Future<Experience> transition(
    Experience current,
    String action, {
    CancelToken? cancel,
  }) async {
    check();
    return this.current = sampleExperience(
      input: current.input,
      status: switch (action) {
        'publish' => ExperienceStatus.published,
        'cancel' => ExperienceStatus.cancelled,
        _ => ExperienceStatus.archived,
      },
      version: current.version.toInt() + 1,
    );
  }

  @override
  Future<CoverAuthorization> initiate(
    String contentType,
    int size,
    String key, {
    CancelToken? cancel,
  }) async {
    stages.add('initiate');
    check();
    return CoverAuthorization(
      'media-1',
      Uri.parse('https://storage.flow.invalid/'),
      {'policy': 'opaque-policy', 'key': 'staging/key'},
      DateTime.now().toUtc().add(const Duration(minutes: 5)),
    );
  }

  @override
  Future<VerifiedCover> confirm(String id, {CancelToken? cancel}) async {
    stages.add('confirm');
    check();
    return const VerifiedCover('media-1', 'image/png', 68, 1, 1, 'digest');
  }

  @override
  Future<Uint8List> cover(String id, {CancelToken? cancel}) async {
    check();
    return Uint8List(0);
  }
}

class RevokedCoverRepository extends FakeExperiencesRepository {
  @override
  Future<Uint8List> cover(String id, {CancelToken? cancel}) async {
    failure = const ExperienceIssue('not_found', status: 404);
    throw failure!;
  }
}
