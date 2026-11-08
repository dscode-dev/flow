import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_state.dart';
import '../../../core/config/environment.dart';
import '../../../core/network/http_client.dart';
import '../domain/experience.dart';
import '../domain/experience_issue.dart';

typedef Authorize = Future<T> Function<T>(
  Future<T> Function(String access) action, {
  bool replaySafe,
});

/// Lifetime boundary shared by list, editor, detail and decoded covers.
class ExperienceAccess extends ChangeNotifier {
  ExperienceAccess(this.auth) {
    _changed();
    auth.addListener(_changed);
  }
  final AuthController auth;
  String? ownerId;
  int generation = 0;
  void _changed() {
    final state = auth.value;
    final next =
        {
          AuthStatus.authenticated,
          AuthStatus.refreshing,
          AuthStatus.initializing,
        }.contains(state.status)
        ? state.user?.id
        : null;
    if (next != ownerId) {
      ownerId = next;
      generation++;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    auth.removeListener(_changed);
    super.dispose();
  }
}

class CoverAuthorization {
  const CoverAuthorization(this.mediaId, this.url, this.fields, this.expiresAt);
  final String mediaId;
  final Uri url;
  final Map<String, String> fields;
  final DateTime expiresAt;
  factory CoverAuthorization.fromJson(Map<String, dynamic> j) {
    final u = j['upload'] as Map<String, dynamic>;
    final url = Uri.parse(u['url'] as String);
    if (u['method'] != 'POST' ||
        !url.hasAuthority ||
        !{'https', 'http'}.contains(url.scheme) ||
        url.userInfo.isNotEmpty) {
      throw const FormatException('Autorização inválida');
    }
    return CoverAuthorization(
      j['media_id'] as String,
      url,
      Map<String, String>.from(u['fields'] as Map),
      instant(u['expires_at'])!,
    );
  }
  @override
  String toString() => 'CoverAuthorization(redacted)';
}

class VerifiedCover {
  const VerifiedCover(
    this.id,
    this.contentType,
    this.size,
    this.width,
    this.height,
    this.sha256,
  );
  final String id, contentType, sha256;
  final int size, width, height;
  factory VerifiedCover.fromJson(Map<String, dynamic> j) {
    if (j['status'] != 'READY') throw const ExperienceIssue('media_not_ready');
    return VerifiedCover(
      j['id'] as String,
      j['content_type'] as String,
      j['size_bytes'] as int,
      j['width'] as int,
      j['height'] as int,
      j['sha256'] as String,
    );
  }
}

abstract interface class ExperiencesRepository {
  Future<Map<String, dynamic>> radarDocument(
    Map<String, dynamic> query, {
    CancelToken? cancel,
  });
  Future<Map<String, dynamic>> homeDocument(
    Map<String, dynamic> query, {
    CancelToken? cancel,
  });
  Future<List<ExperienceCategory>> categories({CancelToken? cancel});
  Future<ExperiencePage> mine({
    String? cursor,
    ExperienceStatus? status,
    CancelToken? cancel,
  });
  Future<Experience> get(String id, {CancelToken? cancel});
  Future<Experience> create(
    ExperienceInput input,
    String key, {
    CancelToken? cancel,
  });
  Future<Experience> update(
    Experience current,
    ExperienceInput input, {
    CancelToken? cancel,
  });
  Future<Experience> transition(
    Experience current,
    String action, {
    CancelToken? cancel,
  });
  Future<CoverAuthorization> initiate(
    String contentType,
    int size,
    String key, {
    CancelToken? cancel,
  });
  Future<VerifiedCover> confirm(String id, {CancelToken? cancel});
  Future<Uint8List> cover(String id, {CancelToken? cancel});
}

class DioExperiencesRepository implements ExperiencesRepository {
  DioExperiencesRepository(
    this.dio,
    this.authorize, {
    this.access,
    this.allowHttpStorage = false,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now {
    access?.addListener(cancelPending);
  }
  final Dio dio;
  final Authorize authorize;
  final ExperienceAccess? access;
  final bool allowHttpStorage;
  final DateTime Function() now;
  DateTime? _retryUntil;
  final _pending = <CancelToken>{};
  void cancelPending() {
    _retryUntil = null;
    for (final c in _pending.toList()) {
      c.cancel();
    }
  }

  void dispose() {
    access?.removeListener(cancelPending);
    cancelPending();
  }

  Future<Response<dynamic>> _call(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    CancelToken? cancel,
    ResponseType? responseType,
  }) async {
    if (_retryUntil case final until? when now().isBefore(until)) {
      throw ExperienceIssue(
        'rate_limited',
        status: 429,
        retryAfter: until.difference(now()),
      );
    }
    final token = cancel ?? CancelToken();
    final generation = access?.generation;
    _pending.add(token);
    try {
      return await authorize((bearer) async {
        if (token.isCancelled || (access != null && access!.ownerId == null)) {
          throw const ExperienceIssue('canceled');
        }
        try {
          final response = await dio.request<dynamic>(
            path,
            data: body,
            queryParameters: query,
            cancelToken: token,
            options: Options(
              method: method,
              responseType: responseType,
              headers: {'Authorization': 'Bearer $bearer', ...?headers},
            ),
          );
          if (access != null && generation != access!.generation) {
            throw const ExperienceIssue('canceled');
          }
          return response;
        } on DioException catch (e) {
          final issue = experienceIssue(e);
          if (issue.status == 429) {
            _retryUntil = now().add(
              issue.retryAfter ?? const Duration(seconds: 60),
            );
          }
          throw issue;
        }
      }, replaySafe: method == 'GET');
    } on AuthIssue catch (e) {
      if (e.code == 'onboarding_required' && access != null) {
        await access!.auth.revalidate();
      }
      rethrow;
    } on FormatException {
      throw const ExperienceIssue('unexpected');
    } on TypeError {
      throw const ExperienceIssue('unexpected');
    } finally {
      _pending.remove(token);
    }
  }

  Future<Experience> _experience(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    CancelToken? cancel,
  }) async {
    final r = await _call(
      method,
      path,
      body: body,
      headers: headers,
      cancel: cancel,
    );
    try {
      return Experience.fromJson(
        r.data as Map<String, dynamic>,
        etag: r.headers.value('etag'),
      );
    } on FormatException {
      throw const ExperienceIssue('unexpected');
    } on TypeError {
      throw const ExperienceIssue('unexpected');
    }
  }

  @override
  Future<Map<String, dynamic>> radarDocument(
    Map<String, dynamic> query, {
    CancelToken? cancel,
  }) async =>
      (await _call(
            'GET',
            'v1/radar/experiences',
            query: query,
            cancel: cancel,
          )).data
          as Map<String, dynamic>;
  @override
  Future<Map<String, dynamic>> homeDocument(
    Map<String, dynamic> query, {
    CancelToken? cancel,
  }) async =>
      (await _call('GET', 'v1/home', query: query, cancel: cancel)).data
          as Map<String, dynamic>;
  @override
  Future<List<ExperienceCategory>> categories({CancelToken? cancel}) async =>
      (((await _call('GET', 'v1/experience-categories', cancel: cancel)).data
                  as Map)['items']
              as List)
          .map((j) => ExperienceCategory.fromJson(j as Map<String, dynamic>))
          .toList();
  @override
  Future<ExperiencePage> mine({
    String? cursor,
    ExperienceStatus? status,
    CancelToken? cancel,
  }) async => ExperiencePage.fromJson(
    (await _call(
          'GET',
          'v1/me/experiences',
          cancel: cancel,
          query: {'limit': 20, 'cursor': ?cursor, 'status': ?status?.wire},
        )).data
        as Map<String, dynamic>,
  );
  @override
  Future<Experience> get(String id, {CancelToken? cancel}) => _experience(
    'GET',
    'v1/experiences/${Uri.encodeComponent(id)}',
    cancel: cancel,
  );
  @override
  Future<Experience> create(
    ExperienceInput input,
    String key, {
    CancelToken? cancel,
  }) => _experience(
    'POST',
    'v1/experiences',
    body: input.toJson(),
    headers: {'Idempotency-Key': key},
    cancel: cancel,
  );
  @override
  Future<Experience> update(
    Experience current,
    ExperienceInput input, {
    CancelToken? cancel,
  }) => _experience(
    'PUT',
    'v1/experiences/${current.id}',
    body: input.toJson(),
    headers: {'If-Match': current.etag},
    cancel: cancel,
  );
  @override
  Future<Experience> transition(
    Experience current,
    String action, {
    CancelToken? cancel,
  }) {
    if (!{'publish', 'cancel', 'archive'}.contains(action)) {
      throw ArgumentError('Transição inválida');
    }
    return _experience(
      'POST',
      'v1/experiences/${current.id}/$action',
      body: <String, dynamic>{},
      headers: {'If-Match': current.etag},
      cancel: cancel,
    );
  }

  @override
  Future<CoverAuthorization> initiate(
    String contentType,
    int size,
    String key, {
    CancelToken? cancel,
  }) async {
    final authorization = CoverAuthorization.fromJson(
      (await _call(
            'POST',
            'v1/media/uploads',
            body: {'content_type': contentType, 'size_bytes': size},
            headers: {'Idempotency-Key': key},
            cancel: cancel,
          )).data
          as Map<String, dynamic>,
    );
    if (!allowHttpStorage && authorization.url.scheme != 'https') {
      throw const ExperienceIssue('media_unavailable');
    }
    return authorization;
  }

  @override
  Future<VerifiedCover> confirm(String id, {CancelToken? cancel}) async =>
      VerifiedCover.fromJson(
        (await _call(
              'POST',
              'v1/media/uploads/${Uri.encodeComponent(id)}/confirm',
              body: <String, dynamic>{},
              cancel: cancel,
            )).data
            as Map<String, dynamic>,
      );
  @override
  Future<Uint8List> cover(String id, {CancelToken? cancel}) async {
    final r = await _call(
      'GET',
      'v1/experiences/${Uri.encodeComponent(id)}/cover',
      cancel: cancel,
      responseType: ResponseType.bytes,
    );
    if (!{
          'image/jpeg',
          'image/png',
        }.contains(r.headers.value('content-type')) ||
        (r.data as List).length > 5 * 1024 * 1024) {
      throw const ExperienceIssue('media_invalid');
    }
    return Uint8List.fromList((r.data as List).cast<int>());
  }
}

ExperienceIssue experienceIssue(DioException e) {
  dynamic data = e.response?.data;
  // Byte endpoints still return the same JSON envelope on failure.
  if (data is List<int> && data.length < 32768) {
    try {
      data = jsonDecode(utf8.decode(data));
    } catch (_) {
      data = null;
    }
  }
  final envelope = data is Map ? data['error'] : null;
  final code = envelope is Map && envelope['code'] is String
      ? envelope['code'] as String
      : e.type == DioExceptionType.cancel
      ? 'canceled'
      : e.response?.statusCode == 401
      ? 'unauthorized'
      : e.response == null
      ? 'network'
      : 'unexpected';
  final requestId = envelope is Map ? envelope['request_id'] : null;
  final retry = int.tryParse(e.response?.headers.value('retry-after') ?? '');
  return ExperienceIssue(
    code,
    status: e.response?.statusCode,
    requestId:
        requestId is String &&
            RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(requestId)
        ? requestId
        : null,
    retryAfter: retry != null && retry > 0 ? Duration(seconds: retry) : null,
  );
}

final experienceAccessProvider = Provider<ExperienceAccess>((ref) {
  final access = ExperienceAccess(ref.watch(authControllerProvider));
  ref.onDispose(access.dispose);
  return access;
});
final experiencesRepositoryProvider = Provider<ExperiencesRepository>((ref) {
  final repo = DioExperiencesRepository(
    ref.watch(httpClientProvider),
    ref.watch(authControllerProvider).authorized,
    access: ref.watch(experienceAccessProvider),
    allowHttpStorage: ref.watch(environmentProvider).name != 'production',
  );
  ref.onDispose(repo.dispose);
  return repo;
});
