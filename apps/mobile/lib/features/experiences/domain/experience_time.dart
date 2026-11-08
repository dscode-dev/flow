import 'package:timezone/data/latest.dart' as data;
import 'package:timezone/timezone.dart' as tz;

abstract final class ExperienceTime {
  static bool _ready = false;
  static void initialize() {
    if (!_ready) {
      data.initializeTimeZones();
      _ready = true;
    }
  }

  static tz.Location zone(String name) {
    initialize();
    return tz.getLocation(name);
  }

  static List<String> get zones {
    initialize();
    return tz.timeZoneDatabase.locations.keys
        .where((v) => v == 'UTC' || v.contains('/'))
        .toList()
      ..sort();
  }

  static tz.TZDateTime local(DateTime instant, String name) =>
      tz.TZDateTime.from(instant.toUtc(), zone(name));

  /// Enumerate offsets from the IANA zone, then round-trip wall components.
  /// Zero candidates is a DST gap; two candidates require explicit choice.
  static List<DateTime> candidates(String name, DateTime wall) {
    final location = zone(name);
    final civil = DateTime.utc(
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
    );
    final found = <int, DateTime>{};
    for (final offset in location.zones.map((v) => v.offset).toSet()) {
      final utc = civil.subtract(offset);
      final result = tz.TZDateTime.from(utc, location);
      if (result.year == civil.year &&
          result.month == civil.month &&
          result.day == civil.day &&
          result.hour == civil.hour &&
          result.minute == civil.minute) {
        found[utc.millisecondsSinceEpoch] = utc;
      }
    }
    return found.values.toList()..sort();
  }

  static String display(DateTime? instant, String? name) {
    if (instant == null) return 'Data a definir';
    if (name == null) {
      return '${instant.toUtc().toIso8601String()} · fuso a definir';
    }
    try {
      final value = local(instant, name);
      String two(int n) => n.toString().padLeft(2, '0');
      return '${two(value.day)}/${two(value.month)}/${value.year} · ${two(value.hour)}:${two(value.minute)} · $name';
    } catch (_) {
      return 'Fuso não disponível neste aplicativo';
    }
  }
}
