import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../experiences/data/experiences_repository.dart';
import '../experiences/domain/experience_issue.dart';
import 'participation_repository.dart';

/// Route-scoped data. No participant/check-in data survives account/background.
/// Writes are never automatically replayed; ambiguous retries keep the same key.
class ParticipationStore extends ChangeNotifier {
  ParticipationStore(this.repository, this.access, this.path) {
    access.addListener(_account);
  }
  final ParticipationRepository repository;
  final ExperienceAccess access;
  final String path;
  Map<String, dynamic>? document, transient;
  Map<String, dynamic> query = {};
  Object? issue;
  bool loading = false, moreLoading = false, busy = false, expired = false;
  bool _disposed = false, _foreground = true;
  int _revision = 0;
  CancelToken? _cancel;
  Timer? _ttl, _secretTTL;
  final _keys = <String, String>{};
  List<Map<String, dynamic>> get rows =>
      ((document?['items'] as List?) ?? []).cast<Map<String, dynamic>>();
  String? get cursor => document?['next_cursor'] as String?;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _account() {
    _keys.clear();
    pause();
    _foreground = true;
  }

  void pause() {
    _foreground = false;
    _revision++;
    _cancel?.cancel();
    _ttl?.cancel();
    _secretTTL?.cancel();
    document = null;
    transient = null;
    issue = null;
    expired = true;
    loading = false;
    moreLoading = false;
    busy = false;
    _notify();
  }

  Future<void> resume() async {
    _foreground = true;
    await load();
  }

  Future<void> select(Map<String, dynamic> next) async {
    query = next;
    await load();
  }

  void _freshness(
    Map<String, dynamic> value, {
    bool secret = false,
    Duration elapsed = Duration.zero,
  }) {
    final start = DateTime.tryParse(value['as_of'] as String? ?? '');
    final end = DateTime.tryParse(
      (secret ? value['expires_at'] : value['valid_until']) as String? ?? '',
    );
    final interval = start != null && end != null
        ? end.difference(start)
        : const Duration(seconds: 60);
    final duration = interval - elapsed;
    final bounded = duration.isNegative
        ? Duration.zero
        : duration > Duration(seconds: secret ? 300 : 60)
        ? Duration(seconds: secret ? 300 : 60)
        : duration;
    if (secret) {
      _secretTTL?.cancel();
      _secretTTL = Timer(bounded, () {
        transient = null;
        _notify();
      });
    } else {
      _ttl?.cancel();
      _ttl = Timer(bounded, () {
        document = null;
        expired = true;
        _notify();
      });
    }
  }

  Future<void> load({bool more = false}) async {
    if (_disposed ||
        !_foreground ||
        access.ownerId == null ||
        busy ||
        more && (cursor == null || loading || moreLoading)) {
      return;
    }
    if (!more) {
      _revision++;
      _cancel?.cancel();
      loading = true;
      moreLoading = false;
      document = null;
      _ttl?.cancel();
    } else {
      moreLoading = true;
    }
    final revision = _revision, generation = access.generation;
    final token = _cancel = CancelToken();
    final next = more ? cursor : null;
    final watch = Stopwatch()..start();
    issue = null;
    expired = false;
    _notify();
    try {
      final result = await repository.request(
        'GET',
        path,
        query: {...query, 'cursor': ?next},
        cancel: token,
      );
      if (_disposed ||
          revision != _revision ||
          generation != access.generation ||
          !_foreground) {
        return;
      }
      if (more) {
        final seen = <String>{};
        final combined = [
          ...rows,
          ...((result['items'] as List?) ?? []).cast<Map<String, dynamic>>(),
        ];
        result['items'] = combined
            .where(
              (r) =>
                  seen.add('${r['experience_id'] ?? r['user_id'] ?? r['id']}'),
            )
            .toList();
      }
      document = result;
      if (!more) _keys.clear();
      _freshness(result, elapsed: watch.elapsed);
    } catch (e) {
      if (!_disposed &&
          revision == _revision &&
          generation == access.generation &&
          _foreground) {
        issue = e;
      }
    } finally {
      if (!_disposed && revision == _revision) {
        loading = false;
        moreLoading = false;
        _notify();
      }
    }
  }

  Future<bool> command(
    String method,
    String endpoint, {
    Map<String, dynamic> body = const {},
    String? etag,
    bool credential = false,
    bool keepResult = false,
    bool reload = true,
  }) async {
    if (_disposed || busy || !_foreground || access.ownerId == null) {
      return false;
    }
    _revision++;
    _cancel?.cancel();
    loading = false;
    moreLoading = false;
    busy = true;
    issue = null;
    transient = null;
    _secretTTL?.cancel();
    _notify();
    final revision = _revision, generation = access.generation;
    final token = _cancel = CancelToken();
    final intent = '$method:$endpoint:${jsonEncode(body)}';
    if (_keys.length > 16) _keys.remove(_keys.keys.first);
    final key = credential || etag != null
        ? null
        : _keys.putIfAbsent(intent, () => const Uuid().v4());
    var success = false;
    final watch = Stopwatch()..start();
    try {
      final result = await repository.request(
        method,
        endpoint,
        body: body,
        headers: {'Idempotency-Key': ?key, 'If-Match': ?etag},
        cancel: token,
      );
      if (_disposed ||
          revision != _revision ||
          generation != access.generation ||
          !_foreground) {
        return false;
      }
      _keys.remove(intent);
      success = true;
      if (keepResult) {
        transient = result;
        _freshness(result, secret: true, elapsed: watch.elapsed);
      }
    } catch (e) {
      if (!_disposed &&
          revision == _revision &&
          generation == access.generation &&
          _foreground) {
        issue = e;
        document = null;
        expired = true;
        if (e is AuthIssue &&
            !{
              'network',
              'canceled',
              'temporarily_unavailable',
            }.contains(e.code)) {
          _keys.remove(intent);
        }
      }
    } finally {
      if (!_disposed && revision == _revision) {
        busy = false;
        _notify();
      }
    }
    if (success && reload) await load();
    return success;
  }

  @override
  void dispose() {
    _disposed = true;
    access.removeListener(_account);
    _cancel?.cancel();
    _ttl?.cancel();
    _secretTTL?.cancel();
    _keys.clear();
    document = null;
    transient = null;
    super.dispose();
  }
}

final participationStoreProvider = Provider.autoDispose
    .family<ParticipationStore, String>((ref, path) {
      final store = ParticipationStore(
        ref.watch(participationRepositoryProvider),
        ref.watch(experienceAccessProvider),
        path,
      );
      ref.onDispose(store.dispose);
      return store;
    });
