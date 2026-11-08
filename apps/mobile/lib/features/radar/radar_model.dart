import '../experiences/domain/experience.dart';

class RadarBounds {
  const RadarBounds(this.west, this.south, this.east, this.north);
  final double west, south, east, north;
  double get width => east >= west ? east - west : 360 - west + east;
  bool get valid =>
      [west, south, east, north].every((v) => v.isFinite) &&
      west >= -180 &&
      west <= 180 &&
      east >= -180 &&
      east <= 180 &&
      south >= -85.051129 &&
      north <= 85.051129 &&
      north > south &&
      width > 0;
  String get wire =>
      [west, south, east, north].map((v) => v.toStringAsFixed(6)).join(',');
  @override
  String toString() => 'RadarBounds(redacted)';
}

class RadarCamera {
  const RadarCamera(this.center, this.zoom);
  final GeoPoint center;
  final double zoom;
  @override
  String toString() => 'RadarCamera(redacted)';
}

class RadarFilters {
  const RadarFilters({
    this.category,
    this.phase,
    this.from,
    this.until,
    this.center,
    this.radiusM,
  });
  final String? category, phase;
  final DateTime? from, until;
  final GeoPoint? center;
  final int? radiusM;
  Map<String, dynamic> get query => {
    'category_id': ?category,
    'phase': ?phase,
    'from': ?from?.toUtc().toIso8601String(),
    'until': ?until?.toUtc().toIso8601String(),
    if (center != null && radiusM != null) ...{
      'latitude': (center!.latitude * 100).round() / 100,
      'longitude': (center!.longitude * 100).round() / 100,
      'radius_m': radiusM,
    },
  };
  bool get active => query.isNotEmpty;
}

class RadarMarker {
  const RadarMarker({
    required this.id,
    required this.title,
    required this.categoryId,
    required this.categoryName,
    required this.point,
    required this.startsAt,
    required this.endsAt,
    required this.timezone,
    required this.venue,
    required this.phase,
    required this.version,
    required this.externalTicket,
    this.coverId,
  });
  final String id, title, categoryId, categoryName, timezone, venue, phase;
  final GeoPoint point;
  final DateTime startsAt, endsAt;
  final BigInt version;
  final bool externalTicket;
  final String? coverId;
  factory RadarMarker.fromJson(Map<String, dynamic> j) => RadarMarker(
    id: j['id'] as String,
    title: j['title'] as String,
    categoryId: j['category_id'] as String,
    categoryName: j['category_name'] as String,
    point: GeoPoint.fromJson(j['location'] as Map<String, dynamic>),
    startsAt: instant(j['starts_at'])!,
    endsAt: instant(j['ends_at'])!,
    timezone: j['timezone'] as String,
    venue: j['venue_name'] as String,
    phase: j['phase'] as String,
    version: BigInt.parse(j['version'].toString()),
    externalTicket: j['external_ticket'] as bool,
    coverId: j['cover_media_id'] as String?,
  );
}

class RadarDocument {
  const RadarDocument(
    this.asOf,
    this.validUntil,
    this.items,
    this.truncated,
    this.minZoom,
    this.maxSpan,
  );
  final DateTime asOf, validUntil;
  final List<RadarMarker> items;
  final bool truncated;
  final int minZoom, maxSpan;
  factory RadarDocument.fromJson(Map<String, dynamic> j) {
    final items = (j['items'] as List)
        .map((m) => RadarMarker.fromJson(m as Map<String, dynamic>))
        .toList();
    if (items.length > 200 ||
        items.any((m) => !{'LIVE', 'UPCOMING'}.contains(m.phase))) {
      throw const FormatException('Marcadores inválidos');
    }
    return RadarDocument(
      instant(j['as_of'])!,
      instant(j['valid_until'])!,
      items,
      j['truncated'] as bool,
      j['min_zoom'] as int,
      j['max_span_degrees'] as int,
    );
  }
}
