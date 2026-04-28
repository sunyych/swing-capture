import '../../../core/models/capture_settings.dart';

abstract class SettingsRepository {
  Future<CaptureSettings> loadSettings();
  Future<void> saveSettings(CaptureSettings settings);
}
