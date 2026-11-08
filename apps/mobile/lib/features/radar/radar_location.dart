import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../experiences/domain/experience.dart';
import '../experiences/domain/experience_issue.dart';

abstract interface class RadarLocation {
  Future<GeoPoint> locate();
  void cancel();
}

class ForegroundRadarLocation implements RadarLocation {
  StreamSubscription<Position>? _subscription;
  Timer? _timer;
  Completer<GeoPoint>? _pending;
  int _generation = 0;
  @override
  void cancel() {
    _generation++;
    _timer?.cancel();
    _subscription?.cancel();
    _subscription = null;
    final p = _pending;
    _pending = null;
    if (p != null && !p.isCompleted) {
      p.completeError(const ExperienceIssue('canceled'));
    }
  }

  @override
  Future<GeoPoint> locate() async {
    cancel();
    final generation = _generation;
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const ExperienceIssue('location_disabled');
    }
    var permission = await Geolocator.checkPermission();
    if (generation != _generation) throw const ExperienceIssue('canceled');
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (generation != _generation) throw const ExperienceIssue('canceled');
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever ||
        permission == LocationPermission.unableToDetermine) {
      throw const ExperienceIssue('location_denied');
    }
    final result = _pending = Completer<GeoPoint>();
    _timer = Timer(const Duration(seconds: 12), () {
      if (!result.isCompleted) {
        result.completeError(const ExperienceIssue('location_timeout'));
      }
    });
    // First fix only. Subscription is canceled after that fix, timeout, pause or account change.
    _subscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.low,
            distanceFilter: 1000,
          ),
        ).listen(
          (p) {
            if (!result.isCompleted) {
              result.complete(
                GeoPoint(
                  (p.latitude * 100).round() / 100,
                  (p.longitude * 100).round() / 100,
                ),
              );
            }
          },
          onError: (Object _) {
            if (!result.isCompleted) {
              result.completeError(
                const ExperienceIssue('location_unavailable'),
              );
            }
          },
        );
    try {
      return await result.future;
    } finally {
      if (generation == _generation) {
        _timer?.cancel();
        await _subscription?.cancel();
        _subscription = null;
        _pending = null;
      }
    }
  }
}

final radarLocationProvider = Provider<RadarLocation>((ref) {
  final l = ForegroundRadarLocation();
  ref.onDispose(l.cancel);
  return l;
});
