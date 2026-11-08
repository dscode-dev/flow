import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flow_mobile/features/experiences/domain/experience.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';
import 'package:flow_mobile/features/radar/radar_location.dart';

import 'experience_fakes.dart';

Map<String, dynamic> radarFixture({
  bool items = false,
  bool truncated = false,
  int seconds = 60,
}) => {
  'as_of': '2026-11-08T12:00:00Z',
  'valid_until': DateTime.utc(
    2026,
    11,
    8,
    12,
  ).add(Duration(seconds: seconds)).toIso8601String(),
  'limit': 100,
  'min_zoom': 4,
  'max_span_degrees': 30,
  'truncated': truncated,
  'items': [
    if (items)
      {
        'id': experienceId,
        'title': 'Encontro do Radar',
        'category_id': 'nature',
        'category_name': 'Natureza',
        'location': {'latitude': -8.05, 'longitude': -34.88},
        'starts_at': '2026-11-09T15:00:00Z',
        'ends_at': '2026-11-09T18:00:00Z',
        'timezone': 'America/Recife',
        'venue_name': 'Parque público',
        'cover_media_id': null,
        'version': 1,
        'phase': 'UPCOMING',
        'external_ticket': false,
      },
  ],
};

class RadarFixtureRepository extends FakeExperiencesRepository {
  Map<String, dynamic> document = radarFixture();
  final radarQueries = <Map<String, dynamic>>[],
      radarCancellations = <CancelToken?>[];
  Completer<Map<String, dynamic>>? gate;
  @override
  Future<Map<String, dynamic>> radarDocument(
    Map<String, dynamic> query, {
    CancelToken? cancel,
  }) async {
    radarQueries.add({...query});
    radarCancellations.add(cancel);
    check();
    final pending = gate;
    gate = null;
    return pending == null ? document : pending.future;
  }
}

class DeniedRadarLocation implements RadarLocation {
  int requests = 0, cancels = 0;
  @override
  Future<GeoPoint> locate() async {
    requests++;
    throw const ExperienceIssue('location_denied');
  }

  @override
  void cancel() {
    cancels++;
  }
}
