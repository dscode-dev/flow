import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../experiences/domain/experience.dart';
import 'radar_model.dart';

class RadarConfig {
  const RadarConfig({
    this.token = '',
    this.lightStyle = 'mapbox://styles/mapbox/light-v11',
    this.darkStyle = 'mapbox://styles/mapbox/dark-v11',
    this.theme = 'system',
    this.latitude = 0,
    this.longitude = 0,
    this.zoom = 2,
  });
  final String token, lightStyle, darkStyle, theme;
  final double latitude, longitude, zoom;
  bool get available =>
      RegExp(r'^pk\.[A-Za-z0-9._-]{20,4096}$').hasMatch(token) &&
      [lightStyle, darkStyle].every(
        (s) =>
            RegExp(r'^mapbox://styles/[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+$')
                .hasMatch(s),
      ) &&
      {'system', 'light', 'dark'}.contains(theme) &&
      latitude.isFinite &&
      latitude >= -85.051129 &&
      latitude <= 85.051129 &&
      longitude.isFinite &&
      longitude >= -180 &&
      longitude <= 180 &&
      zoom.isFinite &&
      zoom >= 0 &&
      zoom <= 22;
  RadarCamera get initial => RadarCamera(GeoPoint(latitude, longitude), zoom);
  factory RadarConfig.fromDefines() => RadarConfig(
    token: const String.fromEnvironment('MAPBOX_PUBLIC_ACCESS_TOKEN'),
    lightStyle: const String.fromEnvironment(
      'MAPBOX_STYLE_LIGHT',
      defaultValue: 'mapbox://styles/mapbox/light-v11',
    ),
    darkStyle: const String.fromEnvironment(
      'MAPBOX_STYLE_DARK',
      defaultValue: 'mapbox://styles/mapbox/dark-v11',
    ),
    theme: const String.fromEnvironment('RADAR_THEME', defaultValue: 'system'),
    latitude:
        double.tryParse(
          const String.fromEnvironment(
            'RADAR_INITIAL_LATITUDE',
            defaultValue: '0',
          ),
        ) ??
        double.nan,
    longitude:
        double.tryParse(
          const String.fromEnvironment(
            'RADAR_INITIAL_LONGITUDE',
            defaultValue: '0',
          ),
        ) ??
        double.nan,
    zoom:
        double.tryParse(
          const String.fromEnvironment('RADAR_INITIAL_ZOOM', defaultValue: '2'),
        ) ??
        double.nan,
  );
  @override
  String toString() => 'RadarConfig(redacted)';
}

final radarConfigProvider = Provider<RadarConfig>(
  (ref) => RadarConfig.fromDefines(),
);
