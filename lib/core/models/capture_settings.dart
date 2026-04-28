import '../config/app_constants.dart';

/// Runtime-configurable MVP settings persisted on device.
class CaptureSettings {
  const CaptureSettings({
    required this.preRollSeconds,
    required this.postRollSeconds,
    required this.swingCooldownMs,
    required this.captureModelId,
    required this.showDebugSkeleton,
    required this.autoRecordOnReady,
    required this.autoSaveToGallery,
  });

  final double preRollSeconds;
  final double postRollSeconds;
  final int swingCooldownMs;
  final String captureModelId;
  final bool showDebugSkeleton;
  final bool autoRecordOnReady;
  final bool autoSaveToGallery;

  factory CaptureSettings.defaults() {
    return const CaptureSettings(
      preRollSeconds: AppConstants.defaultPreRollSeconds,
      postRollSeconds: AppConstants.defaultPostRollSeconds,
      swingCooldownMs: AppConstants.defaultCooldownMs,
      captureModelId: 'swing_tf_balance_20260423',
      showDebugSkeleton: true,
      autoRecordOnReady: true,
      autoSaveToGallery: true,
    );
  }

  CaptureSettings copyWith({
    double? preRollSeconds,
    double? postRollSeconds,
    int? swingCooldownMs,
    String? captureModelId,
    bool? showDebugSkeleton,
    bool? autoRecordOnReady,
    bool? autoSaveToGallery,
  }) {
    return CaptureSettings(
      preRollSeconds: preRollSeconds ?? this.preRollSeconds,
      postRollSeconds: postRollSeconds ?? this.postRollSeconds,
      swingCooldownMs: swingCooldownMs ?? this.swingCooldownMs,
      captureModelId: captureModelId ?? this.captureModelId,
      showDebugSkeleton: showDebugSkeleton ?? this.showDebugSkeleton,
      autoRecordOnReady: autoRecordOnReady ?? this.autoRecordOnReady,
      autoSaveToGallery: autoSaveToGallery ?? this.autoSaveToGallery,
    );
  }

  Map<String, Object> toMap() {
    return {
      'preRollSeconds': preRollSeconds,
      'postRollSeconds': postRollSeconds,
      'swingCooldownMs': swingCooldownMs,
      'captureModelId': captureModelId,
      'showDebugSkeleton': showDebugSkeleton,
      'autoRecordOnReady': autoRecordOnReady,
      'autoSaveToGallery': autoSaveToGallery,
    };
  }

  factory CaptureSettings.fromMap(Map<String, Object?> map) {
    return CaptureSettings(
      preRollSeconds:
          (map['preRollSeconds'] as num?)?.toDouble() ??
          AppConstants.defaultPreRollSeconds,
      postRollSeconds:
          (map['postRollSeconds'] as num?)?.toDouble() ??
          AppConstants.defaultPostRollSeconds,
      swingCooldownMs:
          (map['swingCooldownMs'] as num?)?.toInt() ??
          AppConstants.defaultCooldownMs,
      captureModelId:
          map['captureModelId'] as String? ?? 'swing_tf_balance_20260423',
      showDebugSkeleton: map['showDebugSkeleton'] as bool? ?? true,
      autoRecordOnReady: map['autoRecordOnReady'] as bool? ?? true,
      autoSaveToGallery: map['autoSaveToGallery'] as bool? ?? true,
    );
  }
}
