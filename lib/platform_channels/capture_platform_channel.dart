import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../core/models/capture_settings.dart';

const Set<String> _nativeHighSpeedEventTypes = {
  'CameraReady',
  'CaptureStarted',
  'CaptureStopped',
  'MotionDetected',
  'ClipSaved',
  'ProfileFallback',
};

sealed class NativeCaptureEvent {
  const NativeCaptureEvent();

  factory NativeCaptureEvent.fromMap(Map<Object?, Object?> map) {
    final type = map['type'] as String? ?? '';
    if (_nativeHighSpeedEventTypes.contains(type)) {
      return NativeHighSpeedEvent.fromMap(map);
    }
    return switch (type) {
      'pose' => NativePoseEvent.fromMap(map),
      'camera_state' => NativeCameraStateEvent.fromMap(map),
      'buffer_state' => NativeBufferStateEvent.fromMap(map),
      'rtmp_state' => NativeRtmpStateEvent.fromMap(map),
      'video_import_progress' => NativeVideoImportProgressEvent.fromMap(map),
      'error' => NativeCaptureErrorEvent.fromMap(map),
      'Error' => NativeCaptureErrorEvent.fromMap(map),
      _ => NativeCaptureUnknownEvent(type),
    };
  }
}

class NativeCaptureUnknownEvent extends NativeCaptureEvent {
  const NativeCaptureUnknownEvent(this.type);

  final String type;
}

class NativeHighSpeedEvent extends NativeCaptureEvent {
  const NativeHighSpeedEvent({required this.name, required this.payload});

  factory NativeHighSpeedEvent.fromMap(Map<Object?, Object?> map) {
    final payload = <String, Object?>{};
    for (final entry in map.entries) {
      final key = entry.key;
      if (key is String && key != 'type') {
        payload[key] = entry.value;
      }
    }
    return NativeHighSpeedEvent(
      name: map['type'] as String? ?? '',
      payload: Map.unmodifiable(payload),
    );
  }

  final String name;
  final Map<String, Object?> payload;

  String? get clipPath => payload['path'] as String?;
  int? get timestampMs => (payload['timestampMs'] as num?)?.toInt();
  double? get motionScore => (payload['motionScore'] as num?)?.toDouble();
}

class NativePosePoint {
  const NativePosePoint({
    required this.name,
    required this.x,
    required this.y,
    required this.confidence,
  });

  factory NativePosePoint.fromMap(Map<Object?, Object?> map) {
    return NativePosePoint(
      name: map['name'] as String? ?? '',
      x: (map['x'] as num?)?.toDouble() ?? 0,
      y: (map['y'] as num?)?.toDouble() ?? 0,
      confidence: (map['confidence'] as num?)?.toDouble() ?? 0,
    );
  }

  final String name;
  final double x;
  final double y;
  final double confidence;
}

class NativePoseEvent extends NativeCaptureEvent {
  const NativePoseEvent({required this.timestamp, required this.points});

  factory NativePoseEvent.fromMap(Map<Object?, Object?> map) {
    final landmarks = (map['landmarks'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<Object?, Object?>>()
        .map(NativePosePoint.fromMap)
        .toList(growable: false);
    return NativePoseEvent(
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        (map['timestampMs'] as num?)?.toInt() ?? 0,
      ),
      points: landmarks,
    );
  }

  final DateTime timestamp;
  final List<NativePosePoint> points;
}

class NativeVideoPickResult {
  const NativeVideoPickResult({
    required this.videoPath,
    required this.durationMs,
    this.displayName,
  });

  factory NativeVideoPickResult.fromMap(Map<dynamic, dynamic> map) {
    return NativeVideoPickResult(
      videoPath: map['videoPath'] as String? ?? '',
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      displayName: map['displayName'] as String?,
    );
  }

  final String videoPath;
  final int durationMs;
  final String? displayName;
}

class NativeVideoMetadataResult {
  const NativeVideoMetadataResult({required this.durationMs, this.frameRate});

  factory NativeVideoMetadataResult.fromMap(Map<dynamic, dynamic> map) {
    return NativeVideoMetadataResult(
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      frameRate: (map['frameRate'] as num?)?.toDouble(),
    );
  }

  final int durationMs;
  final double? frameRate;
}

class NativeStartupBufferTestResult {
  const NativeStartupBufferTestResult({
    required this.outputPath,
    required this.durationMs,
    required this.targetFps,
    required this.sizeBytes,
    required this.frameCount,
    this.achievedFps,
  });

  factory NativeStartupBufferTestResult.fromMap(Map<dynamic, dynamic> map) {
    return NativeStartupBufferTestResult(
      outputPath: map['outputPath'] as String? ?? '',
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      targetFps: (map['targetFps'] as num?)?.toInt() ?? 0,
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
      frameCount: (map['frameCount'] as num?)?.toInt() ?? 0,
      achievedFps: (map['achievedFps'] as num?)?.toDouble(),
    );
  }

  final String outputPath;
  final int durationMs;
  final int targetFps;
  final int sizeBytes;
  final int frameCount;
  final double? achievedFps;
}

class NativeVideoPoseFrame {
  const NativeVideoPoseFrame({required this.offsetMs, required this.points});

  factory NativeVideoPoseFrame.fromMap(Map<dynamic, dynamic> map) {
    final rawLandmarks = map['landmarks'];
    final landmarks = <NativePosePoint>[];
    if (rawLandmarks is List) {
      for (final item in rawLandmarks) {
        if (item is Map) {
          landmarks.add(NativePosePoint.fromMap(item.cast<Object?, Object?>()));
        }
      }
    }
    return NativeVideoPoseFrame(
      offsetMs: (map['offsetMs'] as num?)?.toInt() ?? 0,
      points: landmarks,
    );
  }

  final int offsetMs;
  final List<NativePosePoint> points;
}

class NativeVideoPoseExtractionResult {
  const NativeVideoPoseExtractionResult({
    required this.durationMs,
    required this.frameCount,
    required this.poseFrameCount,
    required this.frames,
  });

  factory NativeVideoPoseExtractionResult.fromMap(Map<dynamic, dynamic> map) {
    final rawFrames = map['frames'];
    final frames = <NativeVideoPoseFrame>[];
    if (rawFrames is List) {
      for (final item in rawFrames) {
        if (item is Map) {
          frames.add(NativeVideoPoseFrame.fromMap(item));
        }
      }
    }
    return NativeVideoPoseExtractionResult(
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      frameCount: (map['frameCount'] as num?)?.toInt() ?? frames.length,
      poseFrameCount:
          (map['poseFrameCount'] as num?)?.toInt() ??
          frames.where((frame) => frame.points.isNotEmpty).length,
      frames: frames,
    );
  }

  final int durationMs;
  final int frameCount;
  final int poseFrameCount;
  final List<NativeVideoPoseFrame> frames;
}

class NativeVideoImportProgressEvent extends NativeCaptureEvent {
  const NativeVideoImportProgressEvent({
    required this.jobId,
    required this.phase,
    required this.progress,
    required this.processedFrames,
    this.totalFrames,
    this.message,
  });

  factory NativeVideoImportProgressEvent.fromMap(Map<Object?, Object?> map) {
    return NativeVideoImportProgressEvent(
      jobId: map['jobId'] as String? ?? '',
      phase: map['phase'] as String? ?? 'processing',
      progress: ((map['progress'] as num?)?.toDouble() ?? 0)
          .clamp(0, 1)
          .toDouble(),
      processedFrames: (map['processedFrames'] as num?)?.toInt() ?? 0,
      totalFrames: (map['totalFrames'] as num?)?.toInt(),
      message: map['message'] as String?,
    );
  }

  final String jobId;
  final String phase;
  final double progress;
  final int processedFrames;
  final int? totalFrames;
  final String? message;
}

class NativeCameraStateEvent extends NativeCaptureEvent {
  const NativeCameraStateEvent({
    required this.lensDirection,
    required this.minZoom,
    required this.maxZoom,
    required this.zoom,
  });

  factory NativeCameraStateEvent.fromMap(Map<Object?, Object?> map) {
    return NativeCameraStateEvent(
      lensDirection: map['lensDirection'] as String? ?? 'back',
      minZoom: (map['minZoom'] as num?)?.toDouble() ?? 1,
      maxZoom: (map['maxZoom'] as num?)?.toDouble() ?? 1,
      zoom: (map['zoom'] as num?)?.toDouble() ?? 1,
    );
  }

  final String lensDirection;
  final double minZoom;
  final double maxZoom;
  final double zoom;
}

class NativeBufferStateEvent extends NativeCaptureEvent {
  const NativeBufferStateEvent({
    required this.isBuffering,
    this.completedSegmentCount,
    this.segmentSliceMs,
    this.queueFrameCapacity,
    this.queueDurationMs,
    this.bufferedFrameCount,
    this.bufferedDurationMs,
    this.bufferedBytes,
    this.targetFps,
    this.profileWidth,
    this.profileHeight,
    this.achievedFps,
    this.highSpeed,
    this.segmentRecording = false,
    this.segmentStarting = false,
  });

  factory NativeBufferStateEvent.fromMap(Map<Object?, Object?> map) {
    final explicitTarget = (map['targetFps'] as num?)?.toDouble();
    final legacyNominal = map['nominalTargetFps'] as num?;
    final target =
        explicitTarget ??
        (legacyNominal != null && legacyNominal.toInt() >= 0
            ? legacyNominal.toDouble()
            : null);
    final legacyHigh = map['highFpsEnabled'] as bool?;
    return NativeBufferStateEvent(
      isBuffering: map['buffering'] as bool? ?? false,
      completedSegmentCount: (map['completedSegmentCount'] as num?)?.toInt(),
      segmentSliceMs: (map['segmentSliceMs'] as num?)?.toInt(),
      queueFrameCapacity: (map['queueFrameCapacity'] as num?)?.toInt(),
      queueDurationMs: (map['queueDurationMs'] as num?)?.toInt(),
      bufferedFrameCount: (map['bufferedFrameCount'] as num?)?.toInt(),
      bufferedDurationMs: (map['bufferedDurationMs'] as num?)?.toInt(),
      bufferedBytes: (map['bufferedBytes'] as num?)?.toInt(),
      targetFps: target,
      profileWidth: (map['profileWidth'] as num?)?.toInt(),
      profileHeight: (map['profileHeight'] as num?)?.toInt(),
      achievedFps: (map['achievedFps'] as num?)?.toDouble(),
      highSpeed: map['highSpeed'] as bool? ?? legacyHigh,
      segmentRecording:
          map['segmentRecording'] as bool? ??
          map['buffering'] as bool? ??
          false,
      segmentStarting: map['segmentStarting'] as bool? ?? false,
    );
  }

  final bool isBuffering;
  final int? completedSegmentCount;
  final int? segmentSliceMs;
  final int? queueFrameCapacity;
  final int? queueDurationMs;
  final int? bufferedFrameCount;
  final int? bufferedDurationMs;
  final int? bufferedBytes;

  /// Nominal target fps from native (may exceed what the device achieves).
  final double? targetFps;

  /// Active high-speed recording profile dimensions, when native has selected one.
  final int? profileWidth;
  final int? profileHeight;

  /// FPS measured from encoded sample presentation timestamps.
  final double? achievedFps;

  /// High-speed / non-standard rolling-buffer profile is active.
  final bool? highSpeed;

  /// True only after native has an active recording segment.
  final bool segmentRecording;

  /// True while native is opening/configuring the next recording segment.
  final bool segmentStarting;
}

/// RTMP publish lifecycle from native (Android RootEncoder / iOS HaishinKit).
class NativeRtmpStateEvent extends NativeCaptureEvent {
  const NativeRtmpStateEvent({
    required this.state,
    this.bitrateBps,
    this.droppedVideoFrames,
    this.message,
  });

  factory NativeRtmpStateEvent.fromMap(Map<Object?, Object?> map) {
    return NativeRtmpStateEvent(
      state: map['state'] as String? ?? 'idle',
      bitrateBps: (map['bitrateBps'] as num?)?.toInt(),
      droppedVideoFrames: (map['droppedVideoFrames'] as num?)?.toInt(),
      message: map['message'] as String?,
    );
  }

  /// idle | connecting | live | reconnecting | error | stopped
  final String state;
  final int? bitrateBps;
  final int? droppedVideoFrames;
  final String? message;
}

class NativeCaptureErrorEvent extends NativeCaptureEvent {
  const NativeCaptureErrorEvent({required this.code, required this.message});

  factory NativeCaptureErrorEvent.fromMap(Map<Object?, Object?> map) {
    return NativeCaptureErrorEvent(
      code: map['code'] as String? ?? 'unknown',
      message: map['message'] as String? ?? 'Unknown native capture error.',
    );
  }

  final String code;
  final String message;
}

class NativeHighSpeedFpsRange {
  const NativeHighSpeedFpsRange({required this.lower, required this.upper});

  factory NativeHighSpeedFpsRange.fromMap(Map<dynamic, dynamic> map) {
    return NativeHighSpeedFpsRange(
      lower: (map['lower'] as num?)?.toInt() ?? 0,
      upper: (map['upper'] as num?)?.toInt() ?? 0,
    );
  }

  final int lower;
  final int upper;
}

class NativeHighSpeedSizeCapability {
  const NativeHighSpeedSizeCapability({
    required this.width,
    required this.height,
    required this.fpsRanges,
    required this.fps,
  });

  factory NativeHighSpeedSizeCapability.fromMap(Map<dynamic, dynamic> map) {
    return NativeHighSpeedSizeCapability(
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      fpsRanges: (map['fpsRanges'] as List<dynamic>? ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .map(NativeHighSpeedFpsRange.fromMap)
          .toList(growable: false),
      fps:
          (map['fps'] as List<dynamic>? ?? const [])
              .whereType<num>()
              .map((value) => value.toInt())
              .toSet()
              .toList()
            ..sort(),
    );
  }

  final int width;
  final int height;
  final List<NativeHighSpeedFpsRange> fpsRanges;
  final List<int> fps;
}

class NativeHighSpeedCameraCapability {
  const NativeHighSpeedCameraCapability({
    required this.cameraId,
    required this.lensDirection,
    required this.supportsHighSpeed,
    required this.highSpeedVideoSizes,
    required this.highSpeedFpsRanges,
  });

  factory NativeHighSpeedCameraCapability.fromMap(Map<dynamic, dynamic> map) {
    return NativeHighSpeedCameraCapability(
      cameraId: map['cameraId'] as String? ?? '',
      lensDirection: map['lensDirection'] as String? ?? 'camera',
      supportsHighSpeed: map['supportsHighSpeed'] as bool? ?? false,
      highSpeedVideoSizes:
          (map['highSpeedVideoSizes'] as List<dynamic>? ?? const [])
              .whereType<Map<dynamic, dynamic>>()
              .map(NativeHighSpeedSizeCapability.fromMap)
              .toList(growable: false),
      highSpeedFpsRanges:
          (map['highSpeedFpsRanges'] as List<dynamic>? ?? const [])
              .whereType<Map<dynamic, dynamic>>()
              .map(NativeHighSpeedFpsRange.fromMap)
              .toList(growable: false),
    );
  }

  final String cameraId;
  final String lensDirection;
  final bool supportsHighSpeed;
  final List<NativeHighSpeedSizeCapability> highSpeedVideoSizes;
  final List<NativeHighSpeedFpsRange> highSpeedFpsRanges;
}

class NativeHighSpeedConfig {
  const NativeHighSpeedConfig({
    required this.cameraId,
    required this.lensDirection,
    required this.width,
    required this.height,
    required this.fps,
    required this.codec,
    this.bitrateBps,
    this.orientationHintDegrees,
  });

  factory NativeHighSpeedConfig.fromMap(Map<dynamic, dynamic> map) {
    return NativeHighSpeedConfig(
      cameraId: map['cameraId'] as String? ?? '',
      lensDirection: map['lensDirection'] as String? ?? 'camera',
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      fps: (map['fps'] as num?)?.toInt() ?? 0,
      codec: map['codec'] as String? ?? 'video/avc',
      bitrateBps: (map['bitrateBps'] as num?)?.toInt(),
      orientationHintDegrees: (map['orientationHintDegrees'] as num?)?.toInt(),
    );
  }

  final String cameraId;
  final String lensDirection;
  final int width;
  final int height;
  final int fps;
  final String codec;
  final int? bitrateBps;
  final int? orientationHintDegrees;
}

class NativeHighSpeedCapabilities {
  const NativeHighSpeedCapabilities({
    required this.cameras,
    required this.supportsHighSpeed,
    required this.rollingSeconds,
    required this.codec,
    this.preferred,
  });

  factory NativeHighSpeedCapabilities.fromMap(Map<dynamic, dynamic> map) {
    final preferredMap = map['preferred'];
    return NativeHighSpeedCapabilities(
      cameras: (map['cameras'] as List<dynamic>? ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .map(NativeHighSpeedCameraCapability.fromMap)
          .toList(growable: false),
      supportsHighSpeed: map['supportsHighSpeed'] as bool? ?? false,
      rollingSeconds: (map['rollingSeconds'] as num?)?.toInt() ?? 4,
      codec: map['codec'] as String? ?? 'video/avc',
      preferred:
          preferredMap is Map<dynamic, dynamic> && preferredMap.isNotEmpty
          ? NativeHighSpeedConfig.fromMap(preferredMap)
          : null,
    );
  }

  final List<NativeHighSpeedCameraCapability> cameras;
  final bool supportsHighSpeed;
  final int rollingSeconds;
  final String codec;
  final NativeHighSpeedConfig? preferred;
}

class NativeSavedHighSpeedClip {
  const NativeSavedHighSpeedClip({
    required this.path,
    required this.displayName,
    required this.sizeBytes,
    required this.createdAt,
  });

  factory NativeSavedHighSpeedClip.fromMap(Map<dynamic, dynamic> map) {
    return NativeSavedHighSpeedClip(
      path: map['path'] as String? ?? '',
      displayName: map['displayName'] as String? ?? '',
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (map['createdAtEpochMs'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  final String path;
  final String displayName;
  final int sizeBytes;
  final DateTime createdAt;
}

class NativeRecordingLensCapability {
  const NativeRecordingLensCapability({
    required this.label,
    required this.maxFps,
    required this.supportedFps,
    this.lensDirection,
  });

  factory NativeRecordingLensCapability.fromMap(Map<dynamic, dynamic> map) {
    final supported =
        (map['supportedFps'] as List<dynamic>? ?? const [])
            .whereType<num>()
            .map((value) => value.toInt())
            .toSet()
            .toList()
          ..sort();
    final maxFps =
        (map['maxFps'] as num?)?.toInt() ??
        (supported.isEmpty ? 30 : supported.last);
    return NativeRecordingLensCapability(
      label: map['cameraLabel'] as String? ?? 'camera',
      maxFps: maxFps,
      supportedFps: supported.isEmpty ? <int>[30] : supported,
      lensDirection: map['lensDirection'] as String?,
    );
  }

  final String label;
  final int maxFps;
  final List<int> supportedFps;
  final String? lensDirection;

  String get summary {
    final fps = maxFps <= 30 ? '30 fps' : '$maxFps fps';
    return '$label $fps';
  }
}

class NativeRecordingCapability {
  const NativeRecordingCapability({
    required this.maxFps,
    required this.recommendedFpsMode,
    required this.supportedFps,
    required this.source,
    this.lensCapabilities = const [],
    this.cameraLabel,
    this.message,
  });

  factory NativeRecordingCapability.fromMap(Map<dynamic, dynamic> map) {
    final supported =
        (map['supportedFps'] as List<dynamic>? ?? const [])
            .whereType<num>()
            .map((value) => value.toInt())
            .toSet()
            .toList()
          ..sort();
    final maxFps =
        (map['maxFps'] as num?)?.toInt() ??
        (supported.isEmpty ? 30 : supported.last);
    final rawMode = map['recommendedVideoFpsMode'] as String?;
    final rawLensCapabilities = map['lensCapabilities'];
    final lensCapabilities = <NativeRecordingLensCapability>[];
    if (rawLensCapabilities is List) {
      for (final item in rawLensCapabilities) {
        if (item is Map) {
          lensCapabilities.add(NativeRecordingLensCapability.fromMap(item));
        }
      }
    }
    return NativeRecordingCapability(
      maxFps: maxFps,
      recommendedFpsMode: rawMode == null
          ? recommendedVideoFpsModeForFps(maxFps)
          : videoFpsModeFromWire(rawMode),
      supportedFps: supported.isEmpty ? <int>[30] : supported,
      source: map['source'] as String? ?? 'native',
      lensCapabilities: lensCapabilities,
      cameraLabel: map['cameraLabel'] as String?,
      message: map['message'] as String?,
    );
  }

  final int maxFps;
  final VideoFpsMode recommendedFpsMode;
  final List<int> supportedFps;
  final String source;
  final List<NativeRecordingLensCapability> lensCapabilities;
  final String? cameraLabel;
  final String? message;

  String get summary {
    final fps = maxFps <= 30 ? '30 fps' : '$maxFps fps';
    final camera = cameraLabel == null || cameraLabel!.isEmpty
        ? ''
        : ' ${cameraLabel!}';
    return '$fps$camera';
  }

  String? get lensSummary {
    if (lensCapabilities.isEmpty) {
      return null;
    }
    return lensCapabilities.map((capability) => capability.summary).join(', ');
  }
}

/// Method-channel contract for the native camera, ring buffer, gallery, and RTMP.
class CapturePlatformChannel {
  const CapturePlatformChannel();

  static const MethodChannel _methodChannel = MethodChannel(
    'swingcapture/capture',
  );
  static const EventChannel _eventChannel = EventChannel(
    'swingcapture/capture_events',
  );

  static bool get _useNativeEvents => Platform.isAndroid || Platform.isIOS;

  Stream<NativeCaptureEvent> captureEvents() {
    if (!_useNativeEvents) {
      return const Stream<NativeCaptureEvent>.empty();
    }
    return _eventChannel.receiveBroadcastStream().map((dynamic event) {
      if (event is Map<Object?, Object?>) {
        return NativeCaptureEvent.fromMap(event);
      }
      return const NativeCaptureUnknownEvent('invalid_payload');
    });
  }

  /// When true (Android only), volume up/down are captured for trigger action and
  /// do not change system volume. Call with false when leaving the Capture tab.
  Future<void> setVolumeKeysConsumed(bool consume) async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _methodChannel.invokeMethod<void>('setVolumeKeysConsumed', consume);
    } on MissingPluginException {
      // Older native builds without the hook.
    }
  }

  Future<void> startPreview() async {
    if (!_useNativeEvents) {
      return;
    }
    await _methodChannel.invokeMethod<void>('startPreview');
  }

  Future<NativeRecordingCapability?> queryRecordingCapability() async {
    if (!_useNativeEvents) {
      return null;
    }
    try {
      final result = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
        'queryRecordingCapability',
      );
      if (result == null) {
        return null;
      }
      return NativeRecordingCapability.fromMap(result);
    } on MissingPluginException {
      return null;
    }
  }

  Future<NativeHighSpeedCapabilities?> getCapabilities() async {
    if (!Platform.isAndroid) {
      return null;
    }
    final result = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'getCapabilities',
    );
    if (result == null) {
      return null;
    }
    return NativeHighSpeedCapabilities.fromMap(result);
  }

  Future<NativeHighSpeedConfig?> startCapture({
    int? fps,
    int? width,
    int? height,
    int rollingSeconds = 4,
    double sensitivity = 0.55,
    bool debug = false,
  }) async {
    if (!Platform.isAndroid) {
      return null;
    }
    final result = await _methodChannel
        .invokeMethod<Map<dynamic, dynamic>>('startCapture', {
          'fps': ?fps,
          'width': ?width,
          'height': ?height,
          'rollingSeconds': rollingSeconds,
          'sensitivity': sensitivity,
          'debug': debug,
        });
    if (result == null) {
      return null;
    }
    return NativeHighSpeedConfig.fromMap(result);
  }

  Future<void> stopCapture() async {
    if (!Platform.isAndroid) {
      return;
    }
    await _methodChannel.invokeMethod<void>('stopCapture');
  }

  Future<void> setSensitivity(double sensitivity) async {
    if (!Platform.isAndroid) {
      return;
    }
    await _methodChannel.invokeMethod<void>('setSensitivity', sensitivity);
  }

  Future<List<NativeSavedHighSpeedClip>> getSavedClips() async {
    if (!Platform.isAndroid) {
      return const [];
    }
    final result = await _methodChannel.invokeMethod<List<dynamic>>(
      'getSavedClips',
    );
    return (result ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .map(NativeSavedHighSpeedClip.fromMap)
        .toList(growable: false);
  }

  Future<void> stopPreview() async {
    if (!_useNativeEvents) {
      return;
    }
    await _methodChannel.invokeMethod<void>('stopPreview');
  }

  Future<void> startDetection() async {
    if (!_useNativeEvents) {
      return;
    }
    await _methodChannel.invokeMethod<void>('startDetection');
  }

  Future<void> stopDetection() async {
    if (!_useNativeEvents) {
      return;
    }
    await _methodChannel.invokeMethod<void>('stopDetection');
  }

  Future<void> startBuffering({
    required int preRollMs,
    required int postRollMs,
    required String videoFpsMode,
  }) async {
    if (!_useNativeEvents) {
      return;
    }
    await _methodChannel.invokeMethod<void>('startBuffering', {
      'preRollMs': preRollMs,
      'postRollMs': postRollMs,
      'videoFpsMode': videoFpsMode,
    });
  }

  Future<void> stopBuffering() async {
    if (!_useNativeEvents) {
      return;
    }
    await _methodChannel.invokeMethod<void>('stopBuffering');
  }

  Future<NativeStartupBufferTestResult?> runStartupBufferTest({
    required int durationMs,
    required String videoFpsMode,
  }) async {
    if (!_useNativeEvents) {
      return null;
    }
    final result = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'runStartupBufferTest',
      {'durationMs': durationMs, 'videoFpsMode': videoFpsMode},
    );
    if (result == null) {
      return null;
    }
    return NativeStartupBufferTestResult.fromMap(result);
  }

  Future<String?> saveBufferedClip({
    required String outputPath,
    required int triggerEpochMs,
    required int preRollMs,
    required int postRollMs,
  }) async {
    if (!_useNativeEvents) {
      return null;
    }
    return _methodChannel.invokeMethod<String>('saveBufferedClip', {
      'outputPath': outputPath,
      'triggerEpochMs': triggerEpochMs,
      'preRollMs': preRollMs,
      'postRollMs': postRollMs,
    });
  }

  Future<Map<dynamic, dynamic>?> switchCamera() async {
    if (!_useNativeEvents) {
      return null;
    }
    return _methodChannel.invokeMethod<Map<dynamic, dynamic>>('switchCamera');
  }

  Future<void> setZoomRatio(double ratio) async {
    if (!_useNativeEvents) {
      return;
    }
    await _methodChannel.invokeMethod<void>('setZoomRatio', ratio);
  }

  Future<void> startRtmpStream({
    required String url,
    required int idleBitrateBps,
    required int swingBitrateBps,
  }) async {
    if (!_useNativeEvents) {
      return;
    }
    try {
      await _methodChannel.invokeMethod<void>('startRtmpStream', {
        'url': url,
        'idleBitrateBps': idleBitrateBps,
        'swingBitrateBps': swingBitrateBps,
      });
    } on MissingPluginException {
      // Stub build.
    }
  }

  Future<void> stopRtmpStream() async {
    if (!_useNativeEvents) {
      return;
    }
    try {
      await _methodChannel.invokeMethod<void>('stopRtmpStream');
    } on MissingPluginException {
      // Stub build.
    }
  }

  Future<void> setRtmpSwingBitrate({required bool swingActive}) async {
    if (!_useNativeEvents) {
      return;
    }
    try {
      await _methodChannel.invokeMethod<void>('setRtmpSwingBitrate', {
        'swingActive': swingActive,
      });
    } on MissingPluginException {
      // Stub build.
    }
  }

  Future<void> sendSwingMarker({
    required String phase,
    required String swingId,
    required double weight,
    required int triggerEpochMs,
    required int preRollMs,
    required int postRollMs,
    double? score,
    int? endedAtEpochMs,
  }) async {
    if (!_useNativeEvents) {
      return;
    }
    try {
      await _methodChannel.invokeMethod<void>('sendSwingMarker', {
        'phase': phase,
        'swingId': swingId,
        'weight': weight,
        'triggerEpochMs': triggerEpochMs,
        'preRollMs': preRollMs,
        'postRollMs': postRollMs,
        'score': ?score,
        'endedAtEpochMs': ?endedAtEpochMs,
      });
    } on MissingPluginException {
      // Stub build.
    }
  }

  Future<void> publishSwingClip({
    required String url,
    required String filePath,
    required String swingId,
    required double weight,
  }) async {
    if (!_useNativeEvents) {
      return;
    }
    try {
      await _methodChannel.invokeMethod<void>('publishSwingClip', {
        'url': url,
        'filePath': filePath,
        'swingId': swingId,
        'weight': weight,
      });
    } on MissingPluginException {
      // Stub build.
    }
  }

  Future<String?> saveClip({
    required String sourcePath,
    required String outputPath,
    required int triggerMs,
    required int preRollMs,
    required int postRollMs,
  }) async {
    return _methodChannel.invokeMethod<String>('saveClip', {
      'sourcePath': sourcePath,
      'outputPath': outputPath,
      'triggerMs': triggerMs,
      'preRollMs': preRollMs,
      'postRollMs': postRollMs,
    });
  }

  Future<List<dynamic>> getAlbums() async {
    final albums = await _methodChannel.invokeMethod<List<dynamic>>(
      'getAlbums',
    );
    return albums ?? const [];
  }

  Future<void> createAlbumIfNeeded(String albumName) async {
    await _methodChannel.invokeMethod<void>('createAlbumIfNeeded', {
      'albumName': albumName,
    });
  }

  Future<void> saveToGallery(String filePath) async {
    await _methodChannel.invokeMethod<void>('saveToGallery', {
      'filePath': filePath,
    });
  }

  Future<NativeVideoPickResult?> pickVideoFromLibrary({
    required String destinationDirectory,
    required String filePrefix,
  }) async {
    if (!_useNativeEvents) {
      return null;
    }
    final result = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'pickVideoFromLibrary',
      {'destinationDirectory': destinationDirectory, 'filePrefix': filePrefix},
    );
    if (result == null) {
      return null;
    }
    return NativeVideoPickResult.fromMap(result);
  }

  Future<NativeVideoMetadataResult?> readVideoMetadata(String videoPath) async {
    if (!_useNativeEvents || videoPath.isEmpty) {
      return null;
    }
    final result = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'readVideoMetadata',
      {'videoPath': videoPath},
    );
    if (result == null) {
      return null;
    }
    return NativeVideoMetadataResult.fromMap(result);
  }

  Future<NativeVideoPoseExtractionResult> extractPoseFramesFromVideo({
    required String videoPath,
    double targetFps = 12,
    int maxFrames = 1800,
    String? jobId,
  }) async {
    if (!_useNativeEvents) {
      throw UnsupportedError('Video pose extraction requires Android or iOS.');
    }
    final result = await _methodChannel
        .invokeMethod<Map<dynamic, dynamic>>('extractPoseFramesFromVideo', {
          'videoPath': videoPath,
          'targetFps': targetFps,
          'maxFrames': maxFrames,
          'jobId': ?jobId,
        });
    if (result == null) {
      throw StateError('Native video pose extraction returned no result.');
    }
    return NativeVideoPoseExtractionResult.fromMap(result);
  }
}
