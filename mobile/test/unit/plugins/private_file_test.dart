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
      'favorite': true,
    });

    final restored = PrivateFile.fromJson(jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);

    expect(restored.file, original.file);
    expect(restored.originalPath, '/storage/emulated/0/DCIM/Camera/IMG_1.jpg');
    expect(restored.name, 'IMG_1.jpg');
    expect(restored.mime, 'image/jpeg');
    expect(restored.takenAt, DateTime.fromMillisecondsSinceEpoch(1730000000000));
    expect(restored.isVideo, isFalse);
    expect(restored.isFavorite, isTrue);
    expect(restored.toAsset().isFavorite, isTrue);
  });

  test('dates are read from common camera, screenshot and download names', () {
    expect(privateDateFromName('IMG_20240513_181502.jpg'), DateTime(2024, 5, 13, 18, 15, 2));
    expect(privateDateFromName('Screenshot_20231101-093012_Chrome.jpg'), DateTime(2023, 11, 1, 9, 30, 12));
    expect(privateDateFromName('PXL_20220704_120000123.mp4'), DateTime(2022, 7, 4, 12, 0, 0));
    expect(privateDateFromName('video_2021-12-25_10-11-12.mp4'), DateTime(2021, 12, 25, 10, 11, 12));
    expect(privateDateFromName('received_1700000000000.jpeg'), DateTime.fromMillisecondsSinceEpoch(1700000000000));
    expect(privateDateFromName('cat.png'), isNull);
  });
}
