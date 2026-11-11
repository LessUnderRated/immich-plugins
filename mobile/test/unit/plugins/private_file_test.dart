import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/private_files.repository.dart';

void main() {
  test('private file entries survive a JSON round trip', () {
    final original = PrivateFile.fromJson({
      'file': '/storage/emulated/0/Pictures/.immich_private/IMG_1.jpg.private',
      'thumb': '/data/user/0/app/files/private_thumbs/IMG_1.jpg.private.jpg',
      'originalPath': '/storage/emulated/0/DCIM/Camera/IMG_1.jpg',
      'name': 'IMG_1.jpg',
      'mime': 'image/jpeg',
      'takenAt': 1730000000000,
      'width': 4000,
      'height': 3000,
      'video': false,
    });

    final restored = PrivateFile.fromJson(jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);

    expect(restored.file, original.file);
    expect(restored.originalPath, '/storage/emulated/0/DCIM/Camera/IMG_1.jpg');
    expect(restored.name, 'IMG_1.jpg');
    expect(restored.mime, 'image/jpeg');
    expect(restored.takenAt, DateTime.fromMillisecondsSinceEpoch(1730000000000));
    expect(restored.isVideo, isFalse);
  });
}
