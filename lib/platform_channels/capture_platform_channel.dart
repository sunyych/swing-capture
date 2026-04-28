import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

sealed class NativeCaptureEvent {
  const NativeCaptureEvent();

  factory NativeCaptureEvent.fromMap(Map<Object?, Object?> map) {
    final type = map['type'] as String? ?? '';
    return switch (type) {
      'pose' => NativePoseEvent.fromMap(map),
      'camera_state' => NativeCameraStateEvent.fromMap(map),
      'buffer_state' => NativeBufferStateEvent.fromMap(map),
      'error' => NativeCaptureErrorEvent.fromMap(map),
      _ => NativeCaptureUnknownEvent(type),
    };
  }
}

class NativeCaptureUnknownEvent extends NativeCaptureEvent {
  const NativeCaptureUnknownEvent(this.type);

  final String type;
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
  });

  factory NativeBufferStateEvent.fromMap(Map<Object?, Object?> map) {
    return NativeBufferStateEvent(
      isBuffering: map['buffering'] as bool? ?? false,
      completedSegmentCount: (map['completedSegmentCount'] as num?)?.toInt(),
      segmentSliceMs: (map['segmentSliceMs'] as num?)?.toInt(),
    );
  }

  final bool isBuffering;
  final int? completedSegmentCount;
  final int? segmentSliceMs;
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

/// Method-channel contract for the native camera, ring buffer, and gallery pipeline.
class CapturePlatformChannel {
  const CapturePlatformChannel();

  static const MethodChannel _methodChannel = MethodChannel(
    'swingcapture/capture',
  );
  static const EventChannel _eventChannel = EventChannel(
    'swingcapture/capture_events',
  );

  Stream<NativeCaptureEvent> captureEvents() {
    if (!Platform.isAndroid) {
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
    if (!Platform.isAndroid) {
      return;
    }
    await _methodChannel.invokeMethod<void>('startPreview');
  }

  Future<void> stopPreview() async {
    if (!Platform.isAndroid) {
      return;
    }
    await _methodChannel.invokeMethod<void>('stopPreview');
  }

  Future<void> startDetection() async {
    if (!Platform.isAndroid) {
      return;
    }
    await _methodChannel.invokeMethod<void>('startDetection');
  }

  Future<void> stopDetection() async {
    if (!Platform.isAndroid) {
      return;
    }
    await _methodChannel.invokeMethod<void>('stopDetection');
  }

  Future<void> startBuffering({
    required int preRollMs,
    required int postRollMs,
  }) async {
    if (!Platform.isAndroid) {
      return;
    }
    await _methodChannel.invokeMethod<void>('startBuffering', {
      'preRollMs': preRollMs,
      'postRollMs': postRollMs,
    });
  }

  Future<void> stopBuffering() async {
    if (!Platform.isAndroid) {
      return;
    }
    await _methodChannel.invokeMethod<void>('stopBuffering');
  }

  Future<String?> saveBufferedClip({
    required String outputPath,
    required int triggerEpochMs,
    required int preRollMs,
    required int postRollMs,
  }) async {
    if (!Platform.isAndroid) {
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
    if (!Platform.isAndroid) {
      return null;
    }
    return _methodChannel.invokeMethod<Map<dynamic, dynamic>>('switchCamera');
  }

  Future<void> setZoomRatio(double ratio) async {
    if (!Platform.isAndroid) {
      return;
    }
    await _methodChannel.invokeMethod<void>('setZoomRatio', ratio);
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
}
