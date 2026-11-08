import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../domain/experience_issue.dart';
import 'experiences_repository.dart';

class CoverSelection {
  const CoverSelection(this.bytes, this.contentType);
  final Uint8List bytes;
  final String contentType;
  static Future<CoverSelection> read(XFile file) async {
    if (await file.length() > 5 * 1024 * 1024) {
      throw const ExperienceIssue('media_invalid');
    }
    return prepare(await file.readAsBytes());
  }

  static Future<CoverSelection> prepare(Uint8List bytes) async {
    final selection = await validate(bytes);
    final normalized = await compute(_normalizeCover, selection);
    return validate(normalized.bytes);
  }

  static Future<CoverSelection> validate(Uint8List bytes) async {
    final png =
        bytes.length >= 8 &&
        bytes[0] == 137 &&
        bytes[1] == 80 &&
        bytes[2] == 78 &&
        bytes[3] == 71;
    final jpeg =
        bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255;
    if ((!png && !jpeg) || bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
      throw const ExperienceIssue('media_invalid');
    }
    ui.Codec? codec;
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width > 4096 ||
          descriptor.height > 4096 ||
          descriptor.width * descriptor.height > 12000000) {
        throw const ExperienceIssue('media_invalid');
      }
      codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final valid =
          image.width <= 4096 &&
          image.height <= 4096 &&
          image.width * image.height <= 12000000;
      image.dispose();
      if (!valid) throw const ExperienceIssue('media_invalid');
    } catch (_) {
      throw const ExperienceIssue('media_invalid');
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
    return CoverSelection(bytes, png ? 'image/png' : 'image/jpeg');
  }
}

// Native picker implementations can preserve EXIF orientation (notably Android).
// Bake pixels before the server removes metadata. CPU work stays off the UI isolate.
CoverSelection _normalizeCover(CoverSelection selection) {
  final decoded = selection.contentType == 'image/png'
      ? image.decodePng(selection.bytes, frame: 0)
      : image.decodeJpg(selection.bytes);
  if (decoded == null) throw const ExperienceIssue('media_invalid');
  final baked = image.bakeOrientation(decoded);
  baked.exif = image.ExifData();
  baked.iccProfile = null;
  baked.textData?.clear();
  return CoverSelection(
    selection.contentType == 'image/png'
        ? image.encodePng(baked)
        : image.encodeJpg(baked, quality: 90),
    selection.contentType,
  );
}

/// One logical image intent. Authorization/confirmation survives transient errors
/// within the editor. Only an explicit restart creates a new upload key.
class CoverUpload {
  CoverUpload(
    this.repository,
    this.storage,
    this.selection, {
    String? key,
    DateTime Function()? now,
  }) : key = key ?? const Uuid().v4(),
       now = now ?? DateTime.now;
  final ExperiencesRepository repository;
  // Deliberately isolated storage transport: no API interceptors or credentials.
  final Dio storage;
  final CoverSelection selection;
  final String key;
  final DateTime Function() now;
  CoverAuthorization? authorization;
  VerifiedCover? verified;
  bool sent = false;
  Future<VerifiedCover>? _flight;
  Future<VerifiedCover> run(
    CancelToken cancel, {
    void Function(String)? progress,
  }) {
    if (verified case final cover?) return Future.value(cover);
    return _flight ??= _run(
      cancel,
      progress,
    ).whenComplete(() => _flight = null);
  }

  Future<VerifiedCover> _run(
    CancelToken cancel,
    void Function(String)? progress,
  ) async {
    progress?.call('Autorizando envio…');
    authorization ??= await repository.initiate(
      selection.contentType,
      selection.bytes.length,
      key,
      cancel: cancel,
    );
    final auth = authorization!;
    if (!sent) {
      if (!now().toUtc().isBefore(auth.expiresAt)) {
        throw const ExperienceIssue('upload_expired');
      }
      progress?.call('Enviando capa…');
      final form = FormData();
      form.fields.addAll(auth.fields.entries);
      form.files.add(
        MapEntry(
          'file',
          MultipartFile.fromBytes(
            selection.bytes,
            filename: selection.contentType == 'image/png'
                ? 'cover.png'
                : 'cover.jpg',
            contentType: DioMediaType.parse(selection.contentType),
          ),
        ),
      );
      try {
        await storage.postUri<dynamic>(
          auth.url,
          data: form,
          cancelToken: cancel,
          options: Options(followRedirects: false, headers: {'Accept': '*/*'}),
        );
        sent = true;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          throw const ExperienceIssue('canceled');
        }
        if (!now().toUtc().isBefore(auth.expiresAt) ||
            e.response?.statusCode == 403) {
          throw const ExperienceIssue('upload_expired');
        }
        throw const ExperienceIssue('media_unavailable');
      }
    }
    progress?.call('Verificando imagem…');
    verified = await repository.confirm(auth.mediaId, cancel: cancel);
    if (verified!.id != auth.mediaId) {
      throw const ExperienceIssue('media_invalid');
    }
    return verified!;
  }
}

Dio createStorageTransport() => Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    sendTimeout: const Duration(seconds: 60),
    receiveTimeout: const Duration(seconds: 30),
    followRedirects: false,
  ),
);
