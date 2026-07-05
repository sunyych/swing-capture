import '../config/app_constants.dart';

/// Target frame rate for rolling buffer / recording (device may fall back).
enum VideoFpsMode {
  /// ~30 fps via quality presets (no explicit high-speed profile).
  standard,

  /// High-speed capture at ~60 fps when hardware supports it.
  high60,

  /// High-speed capture at ~120 fps when hardware supports it.
  high120,

  /// High-speed capture at ~240 fps when hardware supports it.
  high240,

  /// Request the best profile the device exposes (bitrate scaled up; fps target relaxed).
  maxSupported,
}

extension VideoFpsModeWire on VideoFpsMode {
  /// Serialized value for prefs and native method-channel payloads.
  String get wireValue => switch (this) {
    VideoFpsMode.standard => 'standard',
    VideoFpsMode.high60 => 'fps60',
    VideoFpsMode.high120 => 'fps120',
    VideoFpsMode.high240 => 'fps240',
    VideoFpsMode.maxSupported => 'maxSupported',
  };

  /// Nominal fps used for UI hints and bitrates (not a guarantee).
  int get nominalTargetFps => switch (this) {
    VideoFpsMode.standard => 30,
    VideoFpsMode.high60 => 60,
    VideoFpsMode.high120 => 120,
    VideoFpsMode.high240 => 240,
    VideoFpsMode.maxSupported => 240,
  };
}

VideoFpsMode videoFpsModeFromWire(String? raw) => switch (raw) {
  'fps60' => VideoFpsMode.high60,
  'fps120' => VideoFpsMode.high120,
  'fps240' => VideoFpsMode.high240,
  'maxSupported' => VideoFpsMode.maxSupported,
  _ => VideoFpsMode.standard,
};

VideoFpsMode recommendedVideoFpsModeForFps(int maxFps) {
  if (maxFps >= 240) {
    return VideoFpsMode.high240;
  }
  if (maxFps >= 120) {
    return VideoFpsMode.high120;
  }
  if (maxFps >= 60) {
    return VideoFpsMode.high60;
  }
  return VideoFpsMode.standard;
}

extension VideoFpsModeIosCapture on VideoFpsMode {
  /// Optional `CameraController` capture fps (`null` = plugin / OS default).
  int? get iosCaptureFps => switch (this) {
    VideoFpsMode.standard => null,
    VideoFpsMode.high60 => 60,
    VideoFpsMode.high120 => 120,
    VideoFpsMode.high240 => 240,
    VideoFpsMode.maxSupported => 240,
  };

  /// Optional video encoder bitrate (bits per second). High FPS needs more headroom.
  int? get iosVideoBitrate => switch (this) {
    VideoFpsMode.standard => null,
    VideoFpsMode.high60 => 16_000_000,
    VideoFpsMode.high120 => 28_000_000,
    VideoFpsMode.high240 => 52_000_000,
    VideoFpsMode.maxSupported => 56_000_000,
  };
}

enum DualCameraRole { disabled, detector, recorder }

extension DualCameraRoleWire on DualCameraRole {
  String get wireValue => switch (this) {
    DualCameraRole.disabled => 'disabled',
    DualCameraRole.detector => 'detector',
    DualCameraRole.recorder => 'recorder',
  };

  String get label => switch (this) {
    DualCameraRole.disabled => 'Single phone',
    DualCameraRole.detector => 'Detector phone',
    DualCameraRole.recorder => 'Recorder phone',
  };

  bool get isActive => this != DualCameraRole.disabled;
}

DualCameraRole dualCameraRoleFromWire(String? raw) => switch (raw) {
  'detector' => DualCameraRole.detector,
  'recorder' => DualCameraRole.recorder,
  _ => DualCameraRole.disabled,
};

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
    required this.videoFpsMode,
    required this.autoSelectBestFps,
    required this.dualCameraRole,
    this.autoRecordThreshold = 0.7,
    this.activeModelVersion = 'hybrid_v1',
    this.enableHybridLearning = true,
    this.rtmpUrl = '',
    this.rtmpEnabled = false,
  });

  final double preRollSeconds;
  final double postRollSeconds;
  final int swingCooldownMs;
  final String captureModelId;
  final bool showDebugSkeleton;
  final bool autoRecordOnReady;
  final bool autoSaveToGallery;
  final VideoFpsMode videoFpsMode;
  final bool autoSelectBestFps;
  final DualCameraRole dualCameraRole;
  final double autoRecordThreshold;
  final String activeModelVersion;
  final bool enableHybridLearning;

  /// RTMP/RTMPS publish URL (may embed user:pass@ and stream key in path). Empty when unused.
  final String rtmpUrl;

  /// When true and [rtmpUrl] is non-empty, native code starts live RTMP when capture session runs.
  final bool rtmpEnabled;

  factory CaptureSettings.defaults() {
    return const CaptureSettings(
      preRollSeconds: AppConstants.defaultPreRollSeconds,
      postRollSeconds: AppConstants.defaultPostRollSeconds,
      swingCooldownMs: AppConstants.defaultCooldownMs,
      captureModelId: 'swing_tf_balance_20260423',
      showDebugSkeleton: true,
      autoRecordOnReady: true,
      autoSaveToGallery: true,
      videoFpsMode: VideoFpsMode.standard,
      autoSelectBestFps: true,
      dualCameraRole: DualCameraRole.disabled,
      autoRecordThreshold: 0.7,
      activeModelVersion: 'hybrid_v1',
      enableHybridLearning: true,
      rtmpUrl: '',
      rtmpEnabled: false,
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
    VideoFpsMode? videoFpsMode,
    bool? autoSelectBestFps,
    DualCameraRole? dualCameraRole,
    double? autoRecordThreshold,
    String? activeModelVersion,
    bool? enableHybridLearning,
    String? rtmpUrl,
    bool? rtmpEnabled,
  }) {
    return CaptureSettings(
      preRollSeconds: preRollSeconds ?? this.preRollSeconds,
      postRollSeconds: postRollSeconds ?? this.postRollSeconds,
      swingCooldownMs: swingCooldownMs ?? this.swingCooldownMs,
      captureModelId: captureModelId ?? this.captureModelId,
      showDebugSkeleton: showDebugSkeleton ?? this.showDebugSkeleton,
      autoRecordOnReady: autoRecordOnReady ?? this.autoRecordOnReady,
      autoSaveToGallery: autoSaveToGallery ?? this.autoSaveToGallery,
      videoFpsMode: videoFpsMode ?? this.videoFpsMode,
      autoSelectBestFps: autoSelectBestFps ?? this.autoSelectBestFps,
      dualCameraRole: dualCameraRole ?? this.dualCameraRole,
      autoRecordThreshold: autoRecordThreshold ?? this.autoRecordThreshold,
      activeModelVersion: activeModelVersion ?? this.activeModelVersion,
      enableHybridLearning: enableHybridLearning ?? this.enableHybridLearning,
      rtmpUrl: rtmpUrl ?? this.rtmpUrl,
      rtmpEnabled: rtmpEnabled ?? this.rtmpEnabled,
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
      'videoFpsMode': videoFpsMode.wireValue,
      'autoSelectBestFps': autoSelectBestFps,
      'dualCameraRole': dualCameraRole.wireValue,
      'autoRecordThreshold': autoRecordThreshold,
      'activeModelVersion': activeModelVersion,
      'enableHybridLearning': enableHybridLearning,
      'rtmpUrl': rtmpUrl,
      'rtmpEnabled': rtmpEnabled,
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
      videoFpsMode: videoFpsModeFromWire(map['videoFpsMode'] as String?),
      autoSelectBestFps: map['autoSelectBestFps'] as bool? ?? true,
      dualCameraRole: dualCameraRoleFromWire(map['dualCameraRole'] as String?),
      autoRecordThreshold:
          (map['autoRecordThreshold'] as num?)?.toDouble() ?? 0.7,
      activeModelVersion: map['activeModelVersion'] as String? ?? 'hybrid_v1',
      enableHybridLearning: map['enableHybridLearning'] as bool? ?? true,
      rtmpUrl: map['rtmpUrl'] as String? ?? '',
      rtmpEnabled: map['rtmpEnabled'] as bool? ?? false,
    );
  }
}
