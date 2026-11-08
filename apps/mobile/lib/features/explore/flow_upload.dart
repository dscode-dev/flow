import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import '../experiences/data/experiences_repository.dart';
import '../experiences/domain/experience_issue.dart';
import 'discovery_model.dart';
import 'discovery_repository.dart';

class FlowUpload {
  FlowUpload(this.repo, this.eid, this.bytes, this.contentType)
    : key = const Uuid().v4();
  final DiscoveryRepository repo;
  final String eid, contentType, key;
  final Uint8List bytes;
  CoverAuthorization? authorization;
  bool sent = false;
  FlowAsset? confirmed;
  Future<FlowAsset>? _flight;
  Future<FlowAsset> run(CancelToken cancel) =>
      _flight ??= _run(cancel).whenComplete(() => _flight = null);
  Future<FlowAsset> _run(CancelToken cancel) async {
    if (confirmed != null) return confirmed!;
    authorization ??= await repo.initiate(
      eid,
      contentType,
      bytes.length,
      key,
      cancel,
    );
    final auth = authorization!;
    if (!sent) {
      if (DateTime.now().toUtc().isAfter(auth.expiresAt)) {
        throw const ExperienceIssue('upload_expired');
      }
      final data = FormData();
      data.fields.addAll(auth.fields.entries);
      data.files.add(
        MapEntry(
          'file',
          MultipartFile.fromBytes(
            bytes,
            filename: 'presentation',
            contentType: DioMediaType.parse(contentType),
          ),
        ),
      );
      try {
        await repo.transport.postUri<dynamic>(
          auth.url,
          data: data,
          cancelToken: cancel,
          options: Options(followRedirects: false, headers: {'Accept': '*/*'}),
        );
        sent = true;
      } on DioException catch (e) {
        throw experienceIssue(e);
      }
    }
    return confirmed = await repo.confirm(eid, auth.mediaId, cancel);
  }
}
