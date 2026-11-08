import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../experiences/application/experience_controllers.dart'
    show safeExperienceIssue;
import '../experiences/data/experiences_repository.dart';
import '../experiences/domain/experience_issue.dart';
import 'home_model.dart';

class HomeState {
  const HomeState({this.document, this.issue, this.loading = false});
  final HomeDocument? document;
  final AuthIssue? issue;
  final bool loading;
}

class HomeController extends ValueNotifier<HomeState> {
  HomeController(this.repository, this.access) : super(const HomeState()) {
    access.addListener(_accountChanged);
  }
  final ExperiencesRepository repository;
  final ExperienceAccess access;
  DiscoveryRegion? region;
  String? category;
  CancelToken? _cancel;
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false, _active = false;
  void _accountChanged() {
    region = null;
    category = null;
    pause();
  }

  void pause() {
    _active = false;
    _timer?.cancel();
    _cancel?.cancel();
    _generation++;
    if (!_disposed) value = const HomeState();
  }

  Future<void> selectRegion(DiscoveryRegion? next) {
    region = next;
    return load(replace: true);
  }

  Future<void> selectCategory(String? next) {
    category = next;
    return load(replace: true);
  }

  Future<void> load({bool replace = false}) async {
    if (_disposed || access.ownerId == null) return;
    if (value.loading && !replace) return;
    _active = true;
    _timer?.cancel();
    _cancel?.cancel();
    final g = ++_generation;
    final cancel = _cancel = CancelToken();
    final elapsed = Stopwatch()..start();
    // Clear cards while validating: stale phase/access is never presented as live.
    value = const HomeState(loading: true);
    try {
      final document = HomeDocument.fromJson(
        await repository.homeDocument({
          ...?region?.query,
          'category_id': ?category,
        }, cancel: cancel),
      );
      if (_disposed || g != _generation) return;
      value = HomeState(document: document);
      // Relative server time avoids depending on an incorrectly set device clock.
      var delay =
          document.refreshAt.difference(document.asOf) - elapsed.elapsed;
      if (delay < const Duration(seconds: 1)) {
        delay = const Duration(seconds: 1);
      }
      if (delay > const Duration(minutes: 1)) {
        delay = const Duration(minutes: 1);
      }
      _timer = Timer(delay, () {
        if (_active) load();
      });
    } catch (e) {
      if (_disposed || g != _generation) return;
      value = HomeState(issue: safeExperienceIssue(e));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    pause();
    region = null;
    category = null;
    access.removeListener(_accountChanged);
    super.dispose();
  }
}

// Retain filters when navigating to details/management, never across accounts.
final homeControllerProvider = Provider<HomeController>((ref) {
  final controller = HomeController(
    ref.watch(experiencesRepositoryProvider),
    ref.watch(experienceAccessProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
