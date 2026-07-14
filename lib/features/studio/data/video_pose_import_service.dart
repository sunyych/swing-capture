import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';

import '../../../core/models/action_event.dart';
import '../../../core/models/capture_record.dart';
import '../../../core/services/video_thumbnail_service.dart';
import '../../../core/utils/formatters.dart';
import '../../../platform_channels/capture_platform_channel.dart';
import '../../capture/data/pose_clip_json_service.dart';
import '../../capture/domain/models/pose_frame.dart';
import '../../history/data/history_repository.dart';
import '../../history/domain/services/swing_tflite_inference_service.dart';

class VideoPoseImportResult {
  const VideoPoseImportResult({
    required this.record,
    required this.poseFrameCount,
    required this.totalFrameCount,
    this.modelResult,
  });

  final CaptureRecord record;
  final int poseFrameCount;
  final int totalFrameCount;
  final SwingTfliteInferenceResult? modelResult;
}

/// Imports a phone-library video, extracts on-device pose frames, writes the
/// standard pose JSON, and persists the clip as a training-ready history row.
class VideoPoseImportService {
  const VideoPoseImportService({
    CapturePlatformChannel channel = const CapturePlatformChannel(),
    PoseClipJsonService poseJsonService = const PoseClipJsonService(),
    VideoThumbnailService thumbnailService = const VideoThumbnailService(),
  }) : _channel = channel,
       _poseJsonService = poseJsonService,
       _thumbnailService = thumbnailService;

  static const double defaultTargetFps = 12;
  static const int defaultMaxFrames = 1800;

  final CapturePlatformChannel _channel;
  final PoseClipJsonService _poseJsonService;
  final VideoThumbnailService _thumbnailService;

  Future<VideoPoseImportResult?> importFromLibrary({
    required HistoryRepository repository,
    required SwingTfliteInferenceService inferenceService,
    bool scanWithModel = true,
    double targetFps = defaultTargetFps,
    int maxFrames = defaultMaxFrames,
    void Function(NativeVideoImportProgressEvent progress)? onProgress,
  }) async {
    final createdAt = DateTime.now();
    final clipTimestamp = Formatters.formatFileTimestamp(createdAt);
    final clipId = 'import_$clipTimestamp';
    final documents = await getApplicationDocumentsDirectory();
    final importDirectory = Directory('${documents.path}/imports');
    if (!await importDirectory.exists()) {
      await importDirectory.create(recursive: true);
    }

    final picked = await _channel.pickVideoFromLibrary(
      destinationDirectory: importDirectory.path,
      filePrefix: clipId,
    );
    if (picked == null || picked.videoPath.isEmpty) {
      return null;
    }
    final metadata = await _safeReadVideoMetadata(picked.videoPath);

    StreamSubscription<NativeCaptureEvent>? progressSubscription;
    if (onProgress != null) {
      progressSubscription = _channel.captureEvents().listen((event) {
        if (event is NativeVideoImportProgressEvent && event.jobId == clipId) {
          onProgress(event);
        }
      });
    }

    late final NativeVideoPoseExtractionResult extraction;
    try {
      extraction = await _channel.extractPoseFramesFromVideo(
        videoPath: picked.videoPath,
        targetFps: targetFps,
        maxFrames: maxFrames,
        jobId: clipId,
      );
    } finally {
      await progressSubscription?.cancel();
    }
    if (extraction.frames.isEmpty) {
      throw StateError('No frames were decoded from the imported video.');
    }

    final durationMs = _effectiveDurationMs(picked, extraction, metadata);
    final videoFps = _validVideoFps(metadata?.frameRate);
    final clipStartAt = createdAt;
    final clipEndAt = clipStartAt.add(Duration(milliseconds: durationMs));
    final frames = _poseFramesFromNative(extraction, clipStartAt);
    final event = _importEvent(
      clipStartAt: clipStartAt,
      clipEndAt: clipEndAt,
      poseFrameCount: extraction.poseFrameCount,
      totalFrameCount: extraction.frameCount,
    );
    final poseJsonPath = _poseJsonPathFor(picked.videoPath);

    await _writePoseJson(
      outputPath: poseJsonPath,
      clipId: clipId,
      videoPath: picked.videoPath,
      clipStartAt: clipStartAt,
      clipEndAt: clipEndAt,
      event: event,
      frames: frames,
      videoFps: videoFps,
    );

    SwingTfliteInferenceResult? modelResult;
    if (scanWithModel) {
      modelResult = await inferenceService.classifyPoseJson(poseJsonPath);
      await _writePoseJson(
        outputPath: poseJsonPath,
        clipId: clipId,
        videoPath: picked.videoPath,
        clipStartAt: clipStartAt,
        clipEndAt: clipEndAt,
        event: event,
        frames: frames,
        modelLabel: modelResult.label,
        modelConfidence: modelResult.confidence,
        videoFps: videoFps,
      );
    }

    final thumbnailPath = await _thumbnailService.generateThumbnail(
      videoPath: picked.videoPath,
      clipId: clipId,
    );
    final record = CaptureRecord(
      id: clipId,
      videoPath: picked.videoPath,
      thumbnailPath: thumbnailPath,
      createdAt: createdAt,
      durationMs: durationMs,
      albumName: 'Phone Library',
      videoFps: videoFps,
      poseJsonPath: poseJsonPath,
      reviewState: CaptureReviewState.needsReview,
      datasetState: CaptureDatasetState.extracted,
      modelLabel: modelResult?.label,
      modelConfidence: modelResult?.confidence,
      trainingState: TrainingLifecycleState.queued,
    );

    await repository.saveRecord(record);
    return VideoPoseImportResult(
      record: record,
      poseFrameCount: extraction.poseFrameCount,
      totalFrameCount: extraction.frameCount,
      modelResult: modelResult,
    );
  }

  Future<void> _writePoseJson({
    required String outputPath,
    required String clipId,
    required String videoPath,
    required DateTime clipStartAt,
    required DateTime clipEndAt,
    required ActionEvent event,
    required List<PoseFrame> frames,
    String? modelLabel,
    double? modelConfidence,
    double? videoFps,
  }) {
    return _poseJsonService.writeClipJson(
      outputPath: outputPath,
      clipId: clipId,
      videoPath: videoPath,
      capturePipeline: Platform.isIOS
          ? 'mobile_import_ios_vision_pose'
          : 'mobile_import_android_mlkit_pose',
      cameraFacing: 'unknown',
      clipStartAt: clipStartAt,
      clipEndAt: clipEndAt,
      event: event,
      frames: frames,
      reviewState: CaptureReviewState.needsReview.name,
      modelLabel: modelLabel,
      modelConfidence: modelConfidence,
      videoFps: videoFps,
    );
  }

  int _effectiveDurationMs(
    NativeVideoPickResult picked,
    NativeVideoPoseExtractionResult extraction,
    NativeVideoMetadataResult? metadata,
  ) {
    final candidates = [
      picked.durationMs,
      extraction.durationMs,
      metadata?.durationMs ?? 0,
    ].where((value) => value > 0).toList(growable: false);
    if (candidates.isEmpty) {
      return extraction.frames.last.offsetMs;
    }
    return candidates.reduce(math.max).toInt();
  }

  Future<NativeVideoMetadataResult?> _safeReadVideoMetadata(
    String videoPath,
  ) async {
    try {
      return _channel.readVideoMetadata(videoPath);
    } catch (_) {
      return null;
    }
  }

  double? _validVideoFps(double? fps) {
    if (fps == null || fps <= 0 || fps.isNaN || fps.isInfinite) {
      return null;
    }
    return fps;
  }

  ActionEvent _importEvent({
    required DateTime clipStartAt,
    required DateTime clipEndAt,
    required int poseFrameCount,
    required int totalFrameCount,
  }) {
    final durationMs = clipEndAt.difference(clipStartAt).inMilliseconds;
    final poseCoverage = totalFrameCount == 0
        ? 0.0
        : (poseFrameCount / totalFrameCount).clamp(0.0, 1.0).toDouble();
    return ActionEvent(
      label: 'imported_video',
      category: 'dataset',
      triggeredAt: clipStartAt.add(Duration(milliseconds: durationMs ~/ 2)),
      score: poseCoverage,
      preRollMs: 0,
      postRollMs: durationMs,
      reason: 'phone_library_pose_import',
      windowStartAt: clipStartAt,
      windowEndAt: clipEndAt,
    );
  }

  List<PoseFrame> _poseFramesFromNative(
    NativeVideoPoseExtractionResult extraction,
    DateTime clipStartAt,
  ) {
    return [
      for (final frame in extraction.frames)
        PoseFrame(
          timestamp: clipStartAt.add(Duration(milliseconds: frame.offsetMs)),
          landmarks: _landmarksFromNative(frame.points),
        ),
    ];
  }

  Map<PoseLandmark, PoseLandmarkPoint> _landmarksFromNative(
    List<NativePosePoint> points,
  ) {
    final landmarks = <PoseLandmark, PoseLandmarkPoint>{};
    for (final point in points) {
      final key = _landmarkForName(point.name);
      if (key == null) {
        continue;
      }
      landmarks[key] = PoseLandmarkPoint(
        x: point.x.clamp(0.0, 1.0).toDouble(),
        y: point.y.clamp(0.0, 1.0).toDouble(),
        confidence: point.confidence.clamp(0.0, 1.0).toDouble(),
      );
    }
    return landmarks;
  }

  PoseLandmark? _landmarkForName(String name) {
    for (final value in PoseLandmark.values) {
      if (value.name == name) {
        return value;
      }
    }
    return null;
  }

  String _poseJsonPathFor(String videoPath) {
    final dotIndex = videoPath.lastIndexOf('.');
    if (dotIndex <= 0) {
      return '$videoPath.pose.json';
    }
    return '${videoPath.substring(0, dotIndex)}.pose.json';
  }
}
