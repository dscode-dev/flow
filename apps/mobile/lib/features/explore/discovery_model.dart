import '../experiences/domain/experience.dart';

class FlowItem {
  const FlowItem(
    this.experience,
    this.imageKind,
    this.hasVideo,
    this.imageUrl,
    this.videoUrl,
    this.expiresAt,
  );
  final Experience experience;
  final String imageKind, imageUrl;
  final bool hasVideo;
  final String? videoUrl;
  final DateTime expiresAt;
  factory FlowItem.fromJson(Map<String, dynamic> j) => FlowItem(
    Experience.fromJson(j['experience'] as Map<String, dynamic>),
    j['image_kind'] as String,
    j['has_video'] as bool,
    j['image_url'] as String,
    j['video_url'] as String?,
    instant(j['media_expires_at'])!,
  );
}

class DiscoveryPage<T> {
  const DiscoveryPage(this.items, this.cursor, this.asOf, this.validUntil);
  final List<T> items;
  final String? cursor;
  final DateTime asOf, validUntil;
  static DiscoveryPage<T> parse<T>(
    Map<String, dynamic> j,
    T Function(Map<String, dynamic>) decode,
  ) => DiscoveryPage(
    (j['items'] as List).map((v) => decode(v as Map<String, dynamic>)).toList(),
    j['next_cursor'] as String?,
    instant(j['as_of'])!,
    instant(j['valid_until'])!,
  );
}

class FlowPresentation {
  const FlowPresentation(
    this.version,
    this.enabled,
    this.consentAt,
    this.imageId,
    this.videoId,
  );
  final int version;
  final bool enabled;
  final DateTime? consentAt;
  final String? imageId, videoId;
  factory FlowPresentation.fromJson(Map<String, dynamic> j) => FlowPresentation(
    j['version'] as int,
    j['enabled'] as bool,
    instant(j['unlisted_consent_at']),
    j['image_asset_id'] as String?,
    j['video_asset_id'] as String?,
  );
}

class FlowAsset {
  const FlowAsset(this.id, this.status, this.contentType, this.failure);
  final String id, status, contentType;
  final String? failure;
  bool get processing => status == 'PROCESSING';
  factory FlowAsset.fromJson(Map<String, dynamic> j) => FlowAsset(
    j['id'] as String,
    j['status'] as String,
    j['content_type'] as String,
    j['failure_code'] as String?,
  );
}
