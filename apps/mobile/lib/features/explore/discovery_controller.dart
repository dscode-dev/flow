import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../experiences/data/experiences_repository.dart';
import '../experiences/domain/experience.dart';
import '../experiences/domain/experience_issue.dart';
import '../experiences/application/experience_controllers.dart'
    show safeExperienceIssue;
import 'discovery_model.dart';
import 'discovery_repository.dart';

class DiscoveryPager<T> extends ChangeNotifier {
  DiscoveryPager(this.access, this.fetch, this.id) {
    access.addListener(clear);
  }
  final ExperienceAccess access;
  final Future<DiscoveryPage<T>> Function(
    Map<String, dynamic>, {
    CancelToken? cancel,
  })
  fetch;
  final String Function(T) id;
  List<T> items = [];
  Map<String, dynamic> query = {};
  String? cursor;
  AuthIssue? issue;
  bool loading = false, moreLoading = false, expired = false, disposed = false;
  int generation = 0;
  CancelToken? _cancel;
  Timer? _debounce, _expiry;
  String? _flightKey;
  Stopwatch? _age;
  Duration? _ttl;
  void clear() {
    generation++;
    _cancel?.cancel();
    _debounce?.cancel();
    _expiry?.cancel();
    items = [];
    query = {};
    cursor = null;
    issue = null;
    loading = false;
    moreLoading = false;
    expired = false;
    _flightKey = null;
    if (!disposed) notifyListeners();
  }

  void change(Map<String, dynamic> next, {bool debounce = false}) {
    if (jsonEncode(next) == jsonEncode(query) &&
        !expired &&
        (loading || items.isNotEmpty)) {
      return;
    }
    generation++;
    _cancel?.cancel();
    _expiry?.cancel();
    _debounce?.cancel();
    query = Map.of(next);
    items = [];
    cursor = null;
    issue = null;
    expired = false;
    _flightKey = null;
    loading = debounce;
    moreLoading = false;
    notifyListeners();
    if (debounce) {
      _debounce = Timer(const Duration(milliseconds: 350), () => load());
    } else {
      load();
    }
  }

  Future<void> load({bool more = false}) async {
    if (disposed || access.ownerId == null || (more && cursor == null)) return;
    final key = jsonEncode({...query, if (more) 'cursor': cursor});
    if (_flightKey == key) return;
    _debounce?.cancel();
    _cancel?.cancel();
    final c = _cancel = CancelToken();
    _flightKey = key;
    final g = ++generation;
    if (more) {
      moreLoading = true;
    } else {
      loading = true;
      items = [];
      cursor = null;
      _expiry?.cancel();
    }
    issue = null;
    expired = false;
    notifyListeners();
    final watch = Stopwatch()..start();
    try {
      final page = await fetch({
        ...query,
        if (more) 'cursor': cursor,
      }, cancel: c);
      if (disposed || g != generation) return;
      final remaining = page.validUntil.difference(page.asOf) - watch.elapsed;
      if (remaining <= Duration.zero) {
        items = [];
        cursor = null;
        expired = true;
      } else {
        final seen = items.map(id).toSet();
        items = [
          if (more) ...items,
          ...page.items.where((v) => seen.add(id(v))),
        ];
        cursor = page.cursor;
        // Continuations can shorten freshness, never extend older rows.
        var ttl = remaining > const Duration(minutes: 1)
            ? const Duration(minutes: 1)
            : remaining;
        if (more && _age != null && _ttl != null) {
          final old = _ttl! - _age!.elapsed;
          if (old < ttl) ttl = old;
        }
        _age = Stopwatch()..start();
        _ttl = ttl;
        _expiry?.cancel();
        if (ttl <= Duration.zero) {
          expire();
        } else {
          _expiry = Timer(ttl, expire);
        }
      }
    } catch (e) {
      if (!disposed && g == generation) {
        issue = safeExperienceIssue(e);
        if (!more) {
          items = [];
          cursor = null;
        }
      }
    } finally {
      if (!disposed && g == generation) {
        loading = false;
        moreLoading = false;
        _flightKey = null;
        notifyListeners();
      }
    }
  }

  void expire() {
    generation++;
    _cancel?.cancel();
    _expiry?.cancel();
    _flightKey = null;
    items = [];
    cursor = null;
    loading = false;
    moreLoading = false;
    expired = true;
    if (!disposed) notifyListeners();
  }

  void pause() {
    _debounce?.cancel();
    expire();
  }

  @override
  void dispose() {
    disposed = true;
    clear();
    access.removeListener(clear);
    super.dispose();
  }
}

final explorePagerProvider = Provider<DiscoveryPager<Experience>>((ref) {
  final p = DiscoveryPager<Experience>(
    ref.watch(experienceAccessProvider),
    ref.watch(discoveryRepositoryProvider).search,
    (e) => e.id,
  );
  ref.onDispose(p.dispose);
  return p;
});
final flowsPagerProvider = Provider<DiscoveryPager<FlowItem>>((ref) {
  final p = DiscoveryPager<FlowItem>(
    ref.watch(experienceAccessProvider),
    ref.watch(discoveryRepositoryProvider).flows,
    (f) => f.experience.id,
  );
  ref.onDispose(p.dispose);
  return p;
});
