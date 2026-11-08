import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../experiences/application/experience_controllers.dart'
    show safeExperienceIssue;
import '../experiences/data/experiences_repository.dart';
import '../experiences/domain/experience.dart';
import '../experiences/domain/experience_issue.dart';
import 'radar_model.dart';

class RadarState {
  const RadarState({
    this.document,
    this.issue,
    this.loading = false,
    this.expired = false,
    this.moving = false,
    this.mapError,
  });
  final RadarDocument? document;
  final AuthIssue? issue;
  final bool loading, expired, moving;
  final String? mapError;
}

class RadarMetrics {
  int? queryMs, returned, pinsFrameMs;
  int canceled = 0, obsolete = 0, mapErrors = 0;
  void clear() {
    queryMs = null;
    returned = null;
    pinsFrameMs = null;
    canceled = 0;
    obsolete = 0;
    mapErrors = 0;
  }
}

class RadarController extends ValueNotifier<RadarState> {
  RadarController(this.repository, this.access) : super(const RadarState()) {
    access.addListener(_accountChanged);
  }
  final ExperiencesRepository repository;
  final ExperienceAccess access;
  final metrics = RadarMetrics();
  bool mapLoading = true;
  RadarCamera? camera;
  int cameraCommand = 0;
  void center(GeoPoint point, {double zoom = 11}) {
    camera = RadarCamera(point, zoom.clamp(0, 22));
    cameraCommand++;
    moving();
    notifyListeners();
  }

  RadarBounds? bounds;
  RadarFilters filters = const RadarFilters();
  List<ExperienceCategory> categories = [];
  String? selectedId;
  String? _lastKey;
  CancelToken? _cancel;
  Timer? _debounce, _expiry;
  int _generation = 0;
  bool _disposed = false, _active = true;
  int minZoom = 4, maxSpan = 30;
  bool _catalogLoading = false;
  void _accountChanged() {
    pause();
    camera = null;
    bounds = null;
    filters = const RadarFilters();
    categories = [];
    selectedId = null;
    _lastKey = null;
    metrics.clear();
    mapLoading = true;
  }

  void _invalidate() {
    _generation++;
    _debounce?.cancel();
    _expiry?.cancel();
    if (_cancel != null && !_cancel!.isCancelled) {
      metrics.canceled++;
      _cancel!.cancel();
    }
    _cancel = null;
  }

  void pause() {
    _active = false;
    _invalidate();
    _lastKey = null;
    selectedId = null;
    if (!_disposed) value = const RadarState();
  }

  void resume() {
    _active = true;
    if (bounds != null) refresh(force: true);
  }

  void moving() {
    if (!_active) return;
    if (value.moving) {
      _debounce?.cancel();
      return;
    }
    _invalidate();
    _lastKey = null;
    selectedId = null;
    value = const RadarState(moving: true);
  }

  void viewport(RadarBounds next, RadarCamera position) {
    if (_disposed || !_active || access.ownerId == null) return;
    camera = position;
    bounds = next;
    final key = jsonEncode(query);
    if (_lastKey == key && (value.loading || value.document != null)) return;
    _invalidate();
    _lastKey = null;
    value = const RadarState(moving: true);
    _debounce = Timer(const Duration(milliseconds: 350), () => refresh());
  }

  Map<String, dynamic> get query => {
    'bbox': bounds!.wire,
    'zoom': camera!.zoom.toStringAsFixed(2),
    ...filters.query,
  };
  Future<void> catalog() async {
    if (_catalogLoading || categories.isNotEmpty || access.ownerId == null) {
      return;
    }
    _catalogLoading = true;
    final g = access.generation;
    try {
      final c = await repository.categories();
      if (!_disposed && g == access.generation) categories = c;
    } catch (_) {
      /* Retry via filters action; never fabricate categories. */
    } finally {
      _catalogLoading = false;
    }
  }

  Future<void> setFilters(RadarFilters next) async {
    filters = next;
    _lastKey = null;
    await refresh(force: true);
  }

  Future<void> refresh({bool force = false}) async {
    if (_disposed ||
        !_active ||
        access.ownerId == null ||
        bounds == null ||
        camera == null) {
      return;
    }
    final b = bounds!;
    if (!b.valid ||
        camera!.zoom < minZoom ||
        b.width > maxSpan ||
        b.north - b.south > maxSpan) {
      _invalidate();
      value = const RadarState(
        issue: ExperienceIssue('radar_area_too_large', status: 400),
      );
      return;
    }
    final key = jsonEncode(query);
    if (_lastKey == key && value.loading) return;
    if (!force &&
        _lastKey == key &&
        (value.loading || value.document != null)) {
      return;
    }
    _invalidate();
    final g = _generation;
    final ownerGeneration = access.generation;
    final cancel = _cancel = CancelToken();
    _lastKey = key;
    final elapsed = Stopwatch()..start();
    value = const RadarState(loading: true);
    try {
      final doc = RadarDocument.fromJson(
        await repository.radarDocument(query, cancel: cancel),
      );
      if (_disposed || g != _generation) {
        if (ownerGeneration == access.generation && !_disposed) {
          metrics.obsolete++;
        }
        return;
      }
      minZoom = doc.minZoom;
      maxSpan = doc.maxSpan;
      metrics.queryMs = elapsed.elapsedMilliseconds;
      metrics.returned = doc.items.length;
      _cancel = null;
      var duration = doc.validUntil.difference(doc.asOf) - elapsed.elapsed;
      if (duration <= Duration.zero) {
        _lastKey = null;
        value = const RadarState(expired: true);
        return;
      }
      value = RadarState(document: doc);
      if (duration > const Duration(minutes: 1)) {
        duration = const Duration(minutes: 1);
      }
      _expiry = Timer(duration, () {
        if (!_disposed) {
          _lastKey = null;
          selectedId = null;
          value = const RadarState(expired: true);
        }
      });
    } catch (e) {
      if (!_disposed && g == _generation) {
        _lastKey = null;
        _cancel = null;
        value = RadarState(issue: safeExperienceIssue(e));
      }
    }
  }

  void mapFailed() {
    if (_disposed) return;
    metrics.mapErrors++;
    mapLoading = false;
    _invalidate();
    _lastKey = null;
    value = const RadarState(
      mapError: 'Não foi possível carregar o mapa. Confira a conexão e a configuração do Mapbox.',
    );
  }

  void mapReady() {
    if (_disposed) return;
    mapLoading = false;
    if (value.mapError != null) {
      value = const RadarState();
    } else {
      notifyListeners();
    }
  }

  void mapReloading() {
    mapLoading = true;
    value = const RadarState();
  }

  void select(String? id) {
    selectedId = id;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    pause();
    access.removeListener(_accountChanged);
    super.dispose();
  }
}

final radarControllerProvider = Provider<RadarController>((ref) {
  final c = RadarController(
    ref.watch(experiencesRepositoryProvider),
    ref.watch(experienceAccessProvider),
  );
  ref.onDispose(c.dispose);
  return c;
});
