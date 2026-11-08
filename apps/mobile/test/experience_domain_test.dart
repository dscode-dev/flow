import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flow_mobile/features/experiences/domain/experience.dart';
import 'package:flow_mobile/features/experiences/domain/experience_time.dart';
import 'package:flow_mobile/features/experiences/presentation/widgets/experience_widgets.dart';

void main() {
  test(
    'DST recusa lacuna e exige escolha na hora repetida, inclusive meia hora',
    () {
      expect(
        ExperienceTime.candidates(
          'America/New_York',
          DateTime.utc(2027, 3, 14, 2, 30),
        ),
        isEmpty,
      );
      final repeated = ExperienceTime.candidates(
        'America/New_York',
        DateTime.utc(2026, 11, 1, 1, 30),
      );
      expect(repeated, [
        DateTime.utc(2026, 11, 1, 5, 30),
        DateTime.utc(2026, 11, 1, 6, 30),
      ]);
      final half = ExperienceTime.candidates(
        'Australia/Lord_Howe',
        DateTime.utc(2026, 4, 5, 1, 45),
      );
      expect(half.length, 2);
      expect(half.last.difference(half.first), const Duration(minutes: 30));
      expect(
        ExperienceTime.candidates(
          'Pacific/Apia',
          DateTime.utc(2011, 12, 30, 12),
        ),
        isEmpty,
      );
    },
  );
  test('IANA preserva instantes na edição, atravessa meia-noite e independe do aparelho', () {
    final begin = ExperienceTime.candidates(
      'America/Recife',
      DateTime.utc(2026, 11, 7, 23, 30),
    ).single;
    final end = ExperienceTime.candidates(
      'America/Recife',
      DateTime.utc(2026, 11, 8, 1, 30),
    ).single;
    expect(begin, DateTime.utc(2026, 11, 8, 2, 30));
    expect(end.difference(begin), const Duration(hours: 2));
    final input = ExperienceInput(
      startsAt: begin,
      endsAt: end,
      timezone: 'America/Recife',
      location: const GeoPoint(-8.123456, -34.987654),
    );
    final restored = ExperienceInput.fromJson(input.toJson());
    expect(restored.startsAt, begin);
    expect(restored.timezone, 'America/Recife');
    expect(restored.location!.longitude, -34.987654);
    expect(
      ExperienceTime.display(begin, input.timezone),
      contains('07/11/2026 · 23:30'),
    );
    expect(() => ExperienceTime.zone('Local'), throwsA(anything));
  });
  test(
    'documento completo conserva nulos, campos protegidos e versão int64',
    () {
      final payload = <String, dynamic>{
        ...const ExperienceInput().toJson(),
        'id': 'id',
        'creator_user_id': 'owner',
        'status': 'DRAFT',
        'phase': null,
        'details_redacted': false,
        'created_at': '2026-11-07T00:00:00Z',
        'updated_at': '2026-11-07T00:00:00Z',
        'published_at': null,
        'cancelled_at': null,
        'archived_at': null,
      };
      final decoded = jsonDecode(
        jsonEncode(
          payload,
        ).replaceFirst('"id":"id"', '"version":9223372036854775806,"id":"id"'),
      ) as Map<String, dynamic>;
      final e = Experience.fromJson(decoded, etag: '"9223372036854775806"');
      expect(e.version.toString(), '9223372036854775806');
      expect(e.etag, '"9223372036854775806"');
      expect(e.input.toJson().keys.length, 13);
      expect(e.input.toJson()['visibility'], 'PRIVATE');
      expect(e.input.toJson()['location'], isNull);
      expect(e.input.toJson().containsKey('status'), false);
      expect(
        () => Experience.fromJson(decoded, etag: 'W/"1"'),
        throwsFormatException,
      );
    },
  );
  test(
    'ticket exige saída HTTPS segura, nunca execução ou página embutida',
    () {
      for (final url in [
        'javascript:alert(1)',
        'http://tickets.flow.invalid/',
        'https://user@tickets.flow.invalid/',
        'https://127.0.0.1/',
        'https://localhost/',
        'https://tickets.flow.invalid/#secret',
        'https://tickets.flow.invalid:444/',
      ]) {
        expect(safeTicketUri(url), isNull);
      }
      expect(safeTicketUri('https://tickets.flow.invalid/e?id=123'), isNotNull);
    },
  );
}
