import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

/// Generates a lightweight thumbnail for local history presentation.
class VideoThumbnailService {
  const VideoThumbnailService();

  Future<String> generateThumbnail({
    required String videoPath,
    required String clipId,
  }) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final thumbnailDirectory = Directory('${directory.path}/thumbnails');
      if (!await thumbnailDirectory.exists()) {
        await thumbnailDirectory.create(recursive: true);
      }

      final thumbnailPath = await VideoThumbnail.thumbnailFile(
        video: videoPath,
        thumbnailPath: '${thumbnailDirectory.path}/thumb_$clipId.jpg',
        imageFormat: ImageFormat.JPEG,
        quality: 70,
        maxWidth: 640,
      );

      return thumbnailPath ?? '';
    } catch (_) {
      return '';
    }
  }
}
