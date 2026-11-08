import '../experiences/domain/experience.dart';

class DiscoveryRegion {
  const DiscoveryRegion(this.name, this.point, this.radiusM);
  final String name;
  final GeoPoint point;
  final int radiusM;
  Map<String, dynamic> get query => {
    'latitude': point.latitude,
    'longitude': point.longitude,
    'radius_m': radiusM,
  };
  static DiscoveryRegion? parse(
    String name,
    String latitude,
    String longitude,
    String radiusKm,
  ) {
    final lat = double.tryParse(latitude.replaceAll(',', '.'));
    final lng = double.tryParse(longitude.replaceAll(',', '.'));
    final radius = double.tryParse(radiusKm.replaceAll(',', '.'));
    final label = name.trim();
    if (label.isEmpty ||
        label.runes.length > 60 ||
        RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]').hasMatch(label) ||
        lat == null ||
        !lat.isFinite ||
        lat < -90 ||
        lat > 90 ||
        lng == null ||
        !lng.isFinite ||
        lng < -180 ||
        lng > 180 ||
        radius == null ||
        !radius.isFinite ||
        radius < 1 ||
        radius > 100) {
      return null;
    }
    return DiscoveryRegion(
      label,
      GeoPoint((lat * 100).round() / 100, (lng * 100).round() / 100),
      (radius * 1000).round(),
    );
  }

  @override
  String toString() => 'DiscoveryRegion(redacted)';
}

class HomeItem {
  const HomeItem(this.experience, this.categoryName, this.distanceM);
  final Experience experience;
  final String categoryName;
  final int? distanceM;
  factory HomeItem.fromJson(Map<String, dynamic> j) => HomeItem(
    Experience.fromJson(j['experience'] as Map<String, dynamic>),
    j['category_name'] as String,
    j['distance_m'] as int?,
  );
}

class HomeSection {
  const HomeSection(this.id, this.order, this.availability, this.items);
  final String id, order, availability;
  final List<HomeItem> items;
  factory HomeSection.fromJson(Map<String, dynamic> j) => HomeSection(
    j['id'] as String,
    j['order'] as String,
    j['availability'] as String,
    (j['items'] as List)
        .map((e) => HomeItem.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
  String get title => switch (id) {
    'highlights' => 'Destaques',
    'live' => 'Acontecendo agora',
    'soon' => 'Começa em breve',
    'nearby' => 'Perto de você',
    'contextual' => 'Para você',
    'recent' => 'Em destaque',
    _ => '',
  };
  String subtitle(HomeDocument home) => switch (id) {
    'highlights' => 'O próximo encontro público na agenda geral.',
    'live' => 'Já começaram · todas as regiões.',
    'soon' => 'Nas próximas ${home.soonHours} horas · todas as regiões.',
    'nearby' => 'Por distância ao centro da região escolhida.',
    'contextual' =>
      'Descoberta contextual por agenda${home.categoryId == null ? '' : ' e categoria'}${home.hasLocality ? ' na sua região' : ''}.',
    'recent' => 'Criadas recentemente · todas as regiões.',
    _ => '',
  };
}

class HomeDocument {
  const HomeDocument({
    required this.asOf,
    required this.refreshAt,
    required this.soonHours,
    required this.defaultRadiusM,
    required this.sections,
    this.categories = const [],
    this.categoryId,
    this.hasLocality = false,
  });
  final DateTime asOf, refreshAt;
  final int soonHours, defaultRadiusM;
  final String? categoryId;
  final bool hasLocality;
  final List<ExperienceCategory> categories;
  final List<HomeSection> sections;
  bool get isEmpty => sections.every((s) => s.items.isEmpty);
  factory HomeDocument.fromJson(Map<String, dynamic> j) {
    final sections = (j['sections'] as List)
        .map((s) => HomeSection.fromJson(s as Map<String, dynamic>))
        .toList();
    if (sections.length > 6 || sections.any((s) => s.items.length > 8)) {
      throw const FormatException('Home excede limites');
    }
    return HomeDocument(
      asOf: instant(j['as_of'])!,
      refreshAt: instant(j['refresh_at'])!,
      soonHours: j['soon_hours'] as int,
      defaultRadiusM: j['default_radius_m'] as int,
      sections: sections,
      categories: (j['categories'] as List)
          .map((c) => ExperienceCategory.fromJson(c as Map<String, dynamic>))
          .toList(),
      categoryId: j['category_id'] as String?,
      hasLocality: j['locality'] != null,
    );
  }
}
