enum ExperienceStatus {
  draft('DRAFT', 'Rascunho'),
  published('PUBLISHED', 'Publicada'),
  cancelled('CANCELLED', 'Cancelada'),
  archived('ARCHIVED', 'Arquivada'),
  unknown('', 'Indisponível');

  const ExperienceStatus(this.wire, this.label);
  final String wire, label;
  static ExperienceStatus parse(String value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => unknown);
}

enum ExperienceVisibility {
  private('PRIVATE', 'Privada', 'Somente você pode ver os detalhes.'),
  unlisted(
    'UNLISTED',
    'Por link',
    'Por padrão, qualquer conta com o link poderá ver o local após publicar. Você pode permitir descoberta pública nos Flows separadamente.',
  ),
  public(
    'PUBLIC',
    'Pública',
    'Contas do Flow poderão descobrir a experiência e ver o local.',
  ),
  unknown('', 'Indisponível', 'Audiência desconhecida.');

  const ExperienceVisibility(this.wire, this.label, this.explanation);
  final String wire, label, explanation;
  static ExperienceVisibility parse(String value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => unknown);
}

class GeoPoint {
  const GeoPoint(this.latitude, this.longitude);
  final double latitude, longitude;
  factory GeoPoint.fromJson(Map<String, dynamic> j) => GeoPoint(
    (j['latitude'] as num).toDouble(),
    (j['longitude'] as num).toDouble(),
  );
  Map<String, dynamic> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
  };
}

DateTime? instant(dynamic value) =>
    value == null ? null : DateTime.parse(value as String).toUtc();

/// Complete replacement document; null is intentional, never PATCH semantics.
class ExperienceInput {
  const ExperienceInput({
    this.title = '',
    this.description = '',
    this.categoryId,
    this.visibility = ExperienceVisibility.private,
    this.startsAt,
    this.endsAt,
    this.timezone,
    this.location,
    this.venueName = '',
    this.address = '',
    this.capacity,
    this.externalTicketUrl,
    this.coverMediaId,
  });
  final String title, description, venueName, address;
  final String? categoryId, timezone, externalTicketUrl, coverMediaId;
  final ExperienceVisibility visibility;
  final DateTime? startsAt, endsAt;
  final GeoPoint? location;
  final int? capacity;
  factory ExperienceInput.fromJson(Map<String, dynamic> j) => ExperienceInput(
    title: j['title'] as String? ?? '',
    description: j['description'] as String? ?? '',
    categoryId: j['category_id'] as String?,
    visibility: ExperienceVisibility.parse(
      j['visibility'] as String? ?? 'PRIVATE',
    ),
    startsAt: instant(j['starts_at']),
    endsAt: instant(j['ends_at']),
    timezone: j['timezone'] as String?,
    location: j['location'] == null
        ? null
        : GeoPoint.fromJson(j['location'] as Map<String, dynamic>),
    venueName: j['venue_name'] as String? ?? '',
    address: j['address'] as String? ?? '',
    capacity: j['capacity'] as int?,
    externalTicketUrl: j['external_ticket_url'] as String?,
    coverMediaId: j['cover_media_id'] as String?,
  );
  Map<String, dynamic> toJson() => {
    'title': title,
    'description': description,
    'category_id': categoryId,
    'visibility': visibility.wire,
    'starts_at': startsAt?.toUtc().toIso8601String(),
    'ends_at': endsAt?.toUtc().toIso8601String(),
    'timezone': timezone,
    'location': location?.toJson(),
    'venue_name': venueName,
    'address': address,
    'capacity': capacity,
    'external_ticket_url': externalTicketUrl,
    'cover_media_id': coverMediaId,
  };
  ExperienceInput withCover(String? id) =>
      ExperienceInput.fromJson({...toJson(), 'cover_media_id': id});
}

class Experience {
  Experience({
    required this.id,
    required this.creatorId,
    required this.input,
    required this.status,
    required this.version,
    required this.etag,
    required this.detailsRedacted,
    required this.createdAt,
    required this.updatedAt,
    this.phase,
    this.publishedAt,
    this.cancelledAt,
    this.archivedAt,
  });
  final String id, creatorId, etag;
  final ExperienceInput input;
  final ExperienceStatus status;
  final BigInt version;
  final bool detailsRedacted;
  final String? phase;
  final DateTime createdAt, updatedAt;
  final DateTime? publishedAt, cancelledAt, archivedAt;
  factory Experience.fromJson(Map<String, dynamic> j, {String? etag}) {
    final raw = j['version'];
    if (raw is! int || raw < 1) throw const FormatException('Versão inválida');
    final version = BigInt.parse(raw.toString());
    final tag = etag ?? '"$version"';
    if (tag != '"$version"') throw const FormatException('ETag inválido');
    return Experience(
      id: j['id'] as String,
      creatorId: j['creator_user_id'] as String,
      input: ExperienceInput.fromJson(j),
      status: ExperienceStatus.parse(j['status'] as String),
      version: version,
      etag: tag,
      detailsRedacted: j['details_redacted'] as bool,
      phase: j['phase'] as String?,
      createdAt: instant(j['created_at'])!,
      updatedAt: instant(j['updated_at'])!,
      publishedAt: instant(j['published_at']),
      cancelledAt: instant(j['cancelled_at']),
      archivedAt: instant(j['archived_at']),
    );
  }
  String get displayTitle =>
      input.title.isEmpty ? 'Experiência sem título' : input.title;
  // These are presentation hints. Every command is authorized again by Go.
  bool get editable =>
      !detailsRedacted &&
      (status == ExperienceStatus.draft ||
          (status == ExperienceStatus.published && phase != 'ENDED'));
  bool get cancelSuggested =>
      status == ExperienceStatus.draft ||
      (status == ExperienceStatus.published && phase != 'ENDED');
  bool get archiveSuggested =>
      status == ExperienceStatus.draft ||
      status == ExperienceStatus.cancelled ||
      (status == ExperienceStatus.published && phase == 'ENDED');
}

class ExperienceCategory {
  const ExperienceCategory(this.id, this.name, this.sortOrder);
  final String id, name;
  final int sortOrder;
  factory ExperienceCategory.fromJson(Map<String, dynamic> j) =>
      ExperienceCategory(
        j['id'] as String,
        j['name'] as String,
        j['sort_order'] as int,
      );
}

class ExperiencePage {
  const ExperiencePage(this.items, this.nextCursor);
  final List<Experience> items;
  final String? nextCursor;
  factory ExperiencePage.fromJson(Map<String, dynamic> j) => ExperiencePage(
    (j['items'] as List)
        .map((v) => Experience.fromJson(v as Map<String, dynamic>))
        .toList(),
    j['next_cursor'] as String?,
  );
}
