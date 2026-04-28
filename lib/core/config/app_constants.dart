class AppConstants {
  const AppConstants._();

  /// Prints one `[PoseJson] {...}` line per pose frame in [CaptureController]
  /// (full landmarks + completeness / gather / stage). Set to false to reduce
  /// log noise in release builds.
  static const bool verbosePoseJsonLog = true;

  static const String historyBoxName = 'capture_history';
  static const String swingCaptureAlbum = 'SwingCapture';
  static const double defaultPreRollSeconds = 2.0;
  static const double defaultPostRollSeconds = 2.0;
  static const int defaultCooldownMs = 1800;
  static const Duration hitterStableDuration = Duration(milliseconds: 1000);
}
