import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'experience.dart';

/// Provider boundary for an approved geocoder. No provider/configuration exists
/// yet. Manual confirmation never requires the device location or background GPS.
class LocationSuggestion {
  const LocationSuggestion(this.label, this.point);
  final String label;
  final GeoPoint point;
}

abstract interface class LocationSearch {
  bool get available;
  Future<List<LocationSuggestion>> search(String query);
}

class UnconfiguredLocationSearch implements LocationSearch {
  @override
  bool get available => false;
  @override
  Future<List<LocationSuggestion>> search(String query) =>
      Future.error(StateError('Provedor de localização não configurado'));
}

final locationSearchProvider = Provider<LocationSearch>(
  (ref) => UnconfiguredLocationSearch(),
);
