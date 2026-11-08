import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/http_client.dart';
import '../experiences/data/experiences_repository.dart';
import '../experiences/data/cover_upload.dart';
import '../experiences/domain/experience.dart';
import '../experiences/domain/experience_issue.dart';
import 'discovery_model.dart';

class DiscoveryRepository {
  DiscoveryRepository(this.api, this.baseUrl, this.transport);
  final ExperiencesRepository api;
  final String baseUrl;
  final Dio transport;
  Future<DiscoveryPage<Experience>> search(
    Map<String, dynamic> query, {
    CancelToken? cancel,
  }) async => DiscoveryPage.parse(
    await api.discoveryRequest(
      'GET',
      'v1/explore/experiences',
      query: query,
      cancel: cancel,
    ),
    Experience.fromJson,
  );
  Future<DiscoveryPage<FlowItem>> flows(
    Map<String, dynamic> query, {
    CancelToken? cancel,
  }) async => DiscoveryPage.parse(
    await api.discoveryRequest('GET', 'v1/flows', query: query, cancel: cancel),
    FlowItem.fromJson,
  );
  Future<FlowItem> flow(String id, {CancelToken? cancel}) async =>
      FlowItem.fromJson(
        await api.discoveryRequest(
          'GET',
          'v1/flows/${Uri.encodeComponent(id)}',
          cancel: cancel,
        ),
      );
  Future<FlowPresentation> presentation(
    String id, {
    CancelToken? cancel,
  }) async => FlowPresentation.fromJson(
    await api.discoveryRequest(
      'GET',
      'v1/experiences/$id/flow',
      cancel: cancel,
    ),
  );
  Future<FlowPresentation> save(
    String id,
    FlowPresentation current, {
    required bool enabled,
    required bool consent,
    String? image,
    String? video,
    CancelToken? cancel,
  }) async => FlowPresentation.fromJson(
    await api.discoveryRequest(
      'PUT',
      'v1/experiences/$id/flow',
      body: {
        'enabled': enabled,
        'unlisted_consent': consent,
        'image_asset_id': image,
        'video_asset_id': video,
      },
      headers: {'If-Match': '"${current.version}"'},
      cancel: cancel,
    ),
  );
  Future<CoverAuthorization> initiate(
    String eid,
    String ct,
    int size,
    String key,
    CancelToken cancel,
  ) async => CoverAuthorization.fromJson(
    await api.discoveryRequest(
      'POST',
      'v1/experiences/$eid/flow/media',
      body: {'content_type': ct, 'size_bytes': size},
      headers: {'Idempotency-Key': key},
      cancel: cancel,
    ),
  );
  Future<FlowAsset> confirm(String eid, String id, CancelToken cancel) async =>
      FlowAsset.fromJson(
        await api.discoveryRequest(
          'POST',
          'v1/experiences/$eid/flow/media/$id/confirm',
          body: <String, dynamic>{},
          cancel: cancel,
        ),
      );
  Future<FlowAsset> asset(String eid, String id, {CancelToken? cancel}) async =>
      FlowAsset.fromJson(
        await api.discoveryRequest(
          'GET',
          'v1/experiences/$eid/flow/media/$id',
          cancel: cancel,
        ),
      );
  Uri mediaUri(String relative) {
    final raw = Uri.parse(relative);
    final base = Uri.parse(baseUrl);
    final result = base.resolveUri(raw);
    if (raw.hasScheme ||
        raw.hasAuthority ||
        raw.hasFragment ||
        !RegExp(r'^v1/flows/[0-9a-fA-F-]{36}/content$').hasMatch(raw.path) ||
        raw.queryParametersAll.length != 1 ||
        raw.queryParametersAll['ticket']?.length != 1 ||
        result.origin != base.origin) {
      throw const ExperienceIssue('media_invalid');
    }
    return result;
  }

  Future<Uint8List> image(FlowItem item, CancelToken cancel) async {
    try {
      final r = await transport.getUri<List<int>>(
        mediaUri(item.imageUrl),
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

final discoveryRepositoryProvider = Provider<DiscoveryRepository>((ref) {
  final transport = createStorageTransport();
  ref.onDispose(() => transport.close(force: true));
  return DiscoveryRepository(
    ref.watch(experiencesRepositoryProvider),
    ref.watch(httpClientProvider).options.baseUrl,
    transport,
  );
});
