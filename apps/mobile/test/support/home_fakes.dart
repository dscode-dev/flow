import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flow_mobile/features/experiences/domain/experience.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';

import 'experience_fakes.dart';

Map<String, dynamic> homeExperience({
  String title = 'Encontro público real',
  String? cover,
}) => {
  ...const ExperienceInput(
    visibility: ExperienceVisibility.public,
    categoryId: 'music',
    timezone: 'America/Recife',
    venueName: 'Praça do encontro',
  ).toJson(),
  'title': title,
  'description': 'Descrição pública para teste.',
  'starts_at': '2026-11-08T18:00:00Z',
  'ends_at': '2026-11-08T21:00:00Z',
  'id': experienceId,
  'creator_user_id': 'other',
  'status': 'PUBLISHED',
  'version': 1,
  'phase': 'UPCOMING',
  'details_redacted': false,
  'cover_media_id': cover,
  'created_at': '2026-11-07T00:00:00Z',
  'updated_at': '2026-11-07T00:00:00Z',
  'published_at': '2026-11-07T00:00:00Z',
  'cancelled_at': null,
  'archived_at': null,
};
Map<String, dynamic> homeFixture({
  String? title,
  String? cover,
  int refreshSeconds = 60,
}) => {
  'as_of': '2026-11-07T12:00:00Z',
  'refresh_at': DateTime.utc(
    2026,
    11,
    7,
    12,
  ).add(Duration(seconds: refreshSeconds)).toIso8601String(),
  'soon_hours': 48,
  'default_radius_m': 25000,
  'section_limit': 6,
  'locality': null,
  'category_id': null,
  'categories': [
    {'id': 'music', 'name': 'Música', 'sort_order': 10},
  ],
  'sections': [
    for (final id in [
      'highlights',
      'live',
      'soon',
      'nearby',
      'contextual',
      'recent',
    ])
      {
        'id': id,
        'order': 'starts_at_asc_id_asc',
        'availability': id == 'nearby'
            ? 'locality_required'
            : id == 'highlights' && title != null
            ? 'available'
            : 'empty',
        'items': [
          if (id == 'highlights' && title != null)
            {
              'experience': homeExperience(title: title, cover: cover),
              'category_name': 'Música',
              'distance_m': null,
            },
        ],
      },
  ],
};

class HomeFixtureRepository extends FakeExperiencesRepository {
  Map<String, dynamic> document = homeFixture();
  final homeQueries = <Map<String, dynamic>>[];
  final cancellations = <CancelToken?>[];
  Completer<Map<String, dynamic>>? gate;
  int coverCalls = 0;
  @override
  Future<Map<String, dynamic>> homeDocument(
    Map<String, dynamic> query, {
    CancelToken? cancel,
  }) async {
    homeQueries.add({...query});
    cancellations.add(cancel);
    check();
    final pending = gate;
    gate = null;
    return pending != null ? pending.future : document;
  }

  @override
  Future<Uint8List> cover(String id, {CancelToken? cancel}) async {
    coverCalls++;
    throw const ExperienceIssue('not_found', status: 404);
  }
}
