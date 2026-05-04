import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/models/capture_settings.dart';
import '../../capture/domain/patterns/capture_model_catalog.dart';
import 'settings_repository.dart';

class SharedPrefsSettingsRepository implements SettingsRepository {
  const SharedPrefsSettingsRepository(this._prefs);

  final SharedPreferences _prefs;

  static const String _preRollKey = 'pre_roll_seconds';
  static const String _postRollKey = 'post_roll_seconds';
  static const String _cooldownKey = 'swing_cooldown_ms';
  static const String _captureModelIdKey = 'capture_model_id';
  static const String _legacyActionPatternIdKey = 'action_pattern_id';
  static const String _debugSkeletonKey = 'show_debug_skeleton';
  static const String _autoRecordKey = 'auto_record_on_ready';
  static const String _autoSaveKey = 'auto_save_to_gallery';
  /// Canonical storage for [CaptureSettings.videoFpsMode] (`fps120`, `fps240`, …).
  static const String _videoFpsModeKey = 'video_fps_mode';
  /// Legacy enum-name storage from earlier builds (`fps120`, `fps60`, …).
  static const String _legacyVideoFpsPreferenceKey = 'video_fps_preference';
  static const String _rtmpUrlKey = 'rtmp_url';
  static const String _rtmpEnabledKey = 'rtmp_enabled';

  VideoFpsMode _loadVideoFpsMode() {
    final wired = _prefs.getString(_videoFpsModeKey);
    if (wired != null && wired.isNotEmpty) {
      return videoFpsModeFromWire(wired);
    }
    final legacy = _prefs.getString(_legacyVideoFpsPreferenceKey);
    return switch (legacy) {
      'fps120' => VideoFpsMode.high120,
      'fps240' => VideoFpsMode.high240,
      'maxSupported' => VideoFpsMode.maxSupported,
      'fps60' => VideoFpsMode.standard,
      _ => VideoFpsMode.standard,
    };
  }

  @override
  Future<CaptureSettings> loadSettings() async {
    final defaults = CaptureSettings.defaults();
    final storedModelId =
        _prefs.getString(_captureModelIdKey) ??
        _prefs.getString(_legacyActionPatternIdKey);
    return CaptureSettings(
      preRollSeconds: _prefs.getDouble(_preRollKey) ?? defaults.preRollSeconds,
      postRollSeconds:
          _prefs.getDouble(_postRollKey) ?? defaults.postRollSeconds,
      swingCooldownMs: _prefs.getInt(_cooldownKey) ?? defaults.swingCooldownMs,
      captureModelId: CaptureModelCatalog.migrateLegacySelection(
        storedModelId ?? defaults.captureModelId,
      ),
      showDebugSkeleton:
          _prefs.getBool(_debugSkeletonKey) ?? defaults.showDebugSkeleton,
      autoRecordOnReady:
          _prefs.getBool(_autoRecordKey) ?? defaults.autoRecordOnReady,
      autoSaveToGallery:
          _prefs.getBool(_autoSaveKey) ?? defaults.autoSaveToGallery,
      videoFpsMode: _loadVideoFpsMode(),
      rtmpUrl: _prefs.getString(_rtmpUrlKey) ?? '',
      rtmpEnabled: _prefs.getBool(_rtmpEnabledKey) ?? false,
    );
  }

  @override
  Future<void> saveSettings(CaptureSettings settings) async {
    await _prefs.setDouble(_preRollKey, settings.preRollSeconds);
    await _prefs.setDouble(_postRollKey, settings.postRollSeconds);
    await _prefs.setInt(_cooldownKey, settings.swingCooldownMs);
    await _prefs.setString(_captureModelIdKey, settings.captureModelId);
    await _prefs.setBool(_debugSkeletonKey, settings.showDebugSkeleton);
    await _prefs.setBool(_autoRecordKey, settings.autoRecordOnReady);
    await _prefs.setBool(_autoSaveKey, settings.autoSaveToGallery);
    await _prefs.setString(_videoFpsModeKey, settings.videoFpsMode.wireValue);
    await _prefs.setString(_rtmpUrlKey, settings.rtmpUrl);
    await _prefs.setBool(_rtmpEnabledKey, settings.rtmpEnabled);
    await _prefs.remove(_legacyVideoFpsPreferenceKey);
    await _prefs.remove(_legacyActionPatternIdKey);
    await _prefs.remove('custom_action_pattern_json');
    await _prefs.remove('trigger_action_key_id');
  }
}
