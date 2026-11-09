import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../experiences/data/experiences_repository.dart';
import '../experiences/domain/experience_issue.dart';
import '../explore/discovery_repository.dart';
import '../explore/discovery_model.dart';
import '../explore/flow_upload.dart';
import '../participation/participation_repository.dart';
import '../participation/participation_store.dart';

/// Central session/refresh/error boundary and the existing isolated S3 transport.
class SocialRepository extends ParticipationRepository
    implements FlowUploadTarget {
  SocialRepository(super.experiences, this.transport, this.baseUrl);
  @override
  final Dio transport;
  final String baseUrl;
  @override
  Future<CoverAuthorization> initiate(
    String eid,
    String ct,
    int size,
    String key,
    CancelToken cancel,
  ) async => CoverAuthorization.fromJson(
    await request(
      'POST',
      'v1/social/media',
      body: {'content_type': ct, 'size_bytes': size},
      headers: {'Idempotency-Key': key},
      cancel: cancel,
    ),
  );
  @override
  Future<FlowAsset> confirm(String eid, String id, CancelToken cancel) async =>
      FlowAsset.fromJson(
        await request(
          'POST',
          'v1/social/media/$id/confirm',
          body: <String, dynamic>{},
          cancel: cancel,
        ),
      );
  Future<FlowAsset> asset(String id, CancelToken cancel) async =>
      FlowAsset.fromJson(
        await request('GET', 'v1/social/media/$id', cancel: cancel),
      );
  Uri mediaUri(String relative) {
    final raw = Uri.parse(relative), base = Uri.parse(baseUrl);
    final resolved = base.resolveUri(raw);
    if (raw.hasScheme ||
        raw.hasAuthority ||
        raw.hasFragment ||
        !RegExp(
          r'^v1/social/(posts/[0-9a-fA-F-]{36}/media|media)/[0-9a-fA-F-]{36}/content$',
        ).hasMatch(raw.path) ||
        raw.queryParametersAll.length != 1 ||
        raw.queryParametersAll['ticket']?.length != 1 ||
        resolved.origin != base.origin) {
      throw const ExperienceIssue('media_invalid');
    }
    return resolved;
  }

  Future<Uint8List> image(String relative, CancelToken cancel) async {
    try {
      final r = await transport.getUri<List<int>>(
        mediaUri(relative),
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: false,
        ),
      );
      if (!{
            'image/jpeg',
            'image/png',
          }.contains(r.headers.value('content-type')) ||
          r.data == null ||
          r.data!.length > 5 * 1024 * 1024) {
        throw const ExperienceIssue('media_invalid');
      }
      return Uint8List.fromList(r.data!);
    } on DioException catch (e) {
      throw experienceIssue(e);
    }
  }
}

final socialRepositoryProvider = Provider<SocialRepository>((ref) {
  final media = ref.watch(discoveryRepositoryProvider);
  return SocialRepository(
    ref.watch(experiencesRepositoryProvider),
    media.transport,
    media.baseUrl,
  );
});

// Reuse the proven route-scoped cursor/TTL/cancellation/ambiguous-command store.
/// Pagination must not renew authorization for previously loaded rows. This
/// absolute route window also cancels in-flight pages when it expires.
class SocialStore extends ParticipationStore {
  SocialStore(super.repository, super.access, super.path);
  Timer? _window;
  bool _closed = false;
  @override
  Future<void> load({bool more = false}) {
    if (!more && !busy && !_closed) {
      _window?.cancel();
      _window = Timer(const Duration(seconds: 30), () {
        if (!_closed) pause();
      });
    }
    return super.load(more: more);
  }

  @override
  void pause() {
    _window?.cancel();
    super.pause();
  }

  @override
  void dispose() {
    _closed = true;
    _window?.cancel();
    super.dispose();
  }
}

final socialStoreProvider = Provider.autoDispose
    .family<ParticipationStore, String>((ref, path) {
      final store = SocialStore(
        ref.watch(socialRepositoryProvider),
        ref.watch(experienceAccessProvider),
        path,
      );
      ref.onDispose(store.dispose);
      return store;
    });
String socialMessage(Object? e) {
  final code = e is AuthIssue ? e.code : '';
  return switch (code) {
    'social_content_invalid' =>
      'Confira o texto, a mídia e os limites da publicação.',
    'not_found' => 'Conteúdo indisponível ou sem acesso.',
    'media_not_ready' =>
      'A mídia precisa estar pronta e pertencer à sua conta.',
    'version_conflict' => 'A publicação mudou. Atualize antes de editar.',
    _ =>
      e is AuthIssue
          ? e.message
          : 'Não foi possível concluir agora. Tente novamente.',
  };
}
