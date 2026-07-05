class AppConstants {
  const AppConstants._();

  /// Prints one `[PoseJson] {...}` line per pose frame in [CaptureController]
  /// (full landmarks + completeness / gather / stage). Set to false to reduce
  /// log noise in release builds.
  static const bool verbosePoseJsonLog = true;

  static const String historyBoxName = 'capture_history';
  static const String motionCaptureAlbum = 'MotionCapture';
  static const double defaultPreRollSeconds = 2.0;
  static const double defaultPostRollSeconds = 2.0;
  static const int defaultCooldownMs = 1800;
  static const Duration hitterStableDuration = Duration(milliseconds: 1000);

  /// RTMP live video bitrate when idle (between swing markers).
  static const int rtmpIdleVideoBitrateBps = 2_500_000;

  /// RTMP live video bitrate boost during a detected swing window.
  static const int rtmpSwingVideoBitrateBps = 4_500_000;
}
