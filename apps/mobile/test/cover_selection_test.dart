import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:flow_mobile/features/experiences/data/cover_upload.dart';
import 'package:flow_mobile/features/experiences/domain/experience_issue.dart';

void main() {
  test(
    'normalização aplica orientação e remove metadados antes da assinatura S3',
    () async {
      final photo = image.Image(width: 40, height: 20);
      photo.exif.imageIfd.orientation = 6;
      photo.exif.imageIfd.make = 'PRIVATE_METADATA';
      final prepared = await CoverSelection.prepare(image.encodeJpg(photo));
      final normalized = image.decodeJpg(prepared.bytes)!;
      expect(normalized.width, 20);
      expect(normalized.height, 40);
      expect(normalized.exif.imageIfd.make, isNull);
      expect(normalized.exif.imageIfd.orientation, isNot(6));
      expect(prepared.contentType, 'image/jpeg');
    },
  );
  test('tipos não suportados, bytes inválidos, excesso de bytes e dimensões são recusados', () async {
    for (final bytes in [
      Uint8List.fromList([1, 2, 3]),
      Uint8List(5 * 1024 * 1024 + 1),
      image.encodePng(image.Image(width: 4097, height: 1)),
    ]) {
      await expectLater(
        CoverSelection.validate(bytes),
        throwsA(
          isA<ExperienceIssue>().having((e) => e.code, 'code', 'media_invalid'),
        ),
      );
    }
  });
}
