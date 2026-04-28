import 'dart:io';

import '../../../core/models/capture_record.dart';

/// Removes video and thumbnail files for a capture from disk.
Future<void> deleteCaptureFiles(CaptureRecord record) async {
  try {
    final video = File(record.videoPath);
    if (await video.exists()) {
      await video.delete();
    }
  } catch (_) {}
  if (record.thumbnailPath.isNotEmpty) {
    try {
      final thumb = File(record.thumbnailPath);
      if (await thumb.exists()) {
        await thumb.delete();
      }
    } catch (_) {}
  }
  final poseJsonPath = record.poseJsonPath;
  if (poseJsonPath == null || poseJsonPath.isEmpty) {
    return;
  }
  try {
    final poseJson = File(poseJsonPath);
    if (await poseJson.exists()) {
      await poseJson.delete();
    }
  } catch (_) {}
}
