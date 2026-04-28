import 'dart:convert';
import 'dart:io';

import '../../../../core/models/action_event.dart';
import '../domain/models/pose_frame.dart';

/// Persists a standardized pose-skeleton clip JSON next to a saved video.
///
/// The schema is designed for later manual labeling, detector training,
/// reward-model / preference learning, and downstream coaching-model inputs.
class PoseClipJsonService {
  const PoseClipJsonService();

  static const String schemaId = 'swingcapture.pose_skeleton_clip.v1';
  static const int schemaVersion = 1;

  Future<String> writeClipJson({
    required String outputPath,
    required String clipId,
    required String videoPath,
    required String capturePipeline,
    required String cameraFacing,
    required DateTime clipStartAt,
    required DateTime clipEndAt,
    required ActionEvent event,
    required List<PoseFrame> frames,
  }) async {
    final file = File(outputPath);
    final parent = file.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }

    final payload = buildPayload(
      clipId: clipId,
      videoPath: videoPath,
      capturePipeline: capturePipeline,
      cameraFacing: cameraFacing,
      clipStartAt: clipStartAt,
      clipEndAt: clipEndAt,
      event: event,
      frames: frames,
    );

    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(payload), encoding: utf8);
    return file.path;
  }

  Map<String, dynamic> buildPayload({
    required String clipId,
    required String videoPath,
    required String capturePipeline,
    required String cameraFacing,
    required DateTime clipStartAt,
    required DateTime clipEndAt,
    required ActionEvent event,
    required List<PoseFrame> frames,
  }) {
    final sortedFrames = List<PoseFrame>.from(frames)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final durationMs = clipEndAt
        .difference(clipStartAt)
        .inMilliseconds
        .clamp(0, 60000);

    return {
      'schema': schemaId,
      'schemaVersion': schemaVersion,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'capture': {
        'clipId': clipId,
        'videoPath': videoPath,
        'capturePipeline': capturePipeline,
        'cameraFacing': cameraFacing,
        'normalization': 'preview_normalized_xy',
        'landmarkSet': 'swingcapture_13',
        'landmarkOrder': [
          for (final landmark in PoseLandmark.values) landmark.name,
        ],
        'bones': [
          for (final bone in kPoseBones)
            {'from': bone.a.name, 'to': bone.b.name},
        ],
      },
      'event': {
        'label': event.label,
        'category': event.category,
        'triggeredAt': event.triggeredAt.toUtc().toIso8601String(),
        'score': _r4(event.score),
        'reason': event.reason,
        'preRollMs': event.preRollMs,
        'postRollMs': event.postRollMs,
        'requestedWindowStartAt': event.resolvedWindowStartAt
            .toUtc()
            .toIso8601String(),
        'requestedWindowEndAt': event.resolvedWindowEndAt
            .toUtc()
            .toIso8601String(),
        'clipStartAt': clipStartAt.toUtc().toIso8601String(),
        'clipEndAt': clipEndAt.toUtc().toIso8601String(),
        'durationMs': durationMs,
      },
      'frames': [
        for (var i = 0; i < sortedFrames.length; i++)
          _framePayload(
            frame: sortedFrames[i],
            index: i,
            clipStartAt: clipStartAt,
          ),
      ],
    };
  }

  Map<String, dynamic> _framePayload({
    required PoseFrame frame,
    required int index,
    required DateTime clipStartAt,
  }) {
    final entries = frame.landmarks.entries.toList()
      ..sort((a, b) => a.key.name.compareTo(b.key.name));
    final landmarks = <String, Map<String, num>>{};
    for (final entry in entries) {
      final point = entry.value;
      landmarks[entry.key.name] = {
        'x': _r4(point.x),
        'y': _r4(point.y),
        'confidence': _r4(point.confidence),
      };
    }

    return {
      'index': index,
      'timestamp': frame.timestamp.toUtc().toIso8601String(),
      'offsetMs': frame.timestamp.difference(clipStartAt).inMilliseconds,
      'complete': _r4(frame.completenessScore()),
      'hasPose': frame.landmarks.isNotEmpty,
      'lmCount': frame.landmarks.length,
      'lm': landmarks,
    };
  }

  static double _r4(double value) => (value * 10000).round() / 10000;
}
