import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/providers.dart';
import '../../../../core/models/capture_settings.dart';

class SettingsController extends AsyncNotifier<CaptureSettings> {
  @override
  Future<CaptureSettings> build() async {
    final repository = ref.watch(settingsRepositoryProvider);
    return repository.loadSettings();
  }

  Future<void> updateSettings(CaptureSettings next) async {
    state = AsyncData(next);
    await ref.read(settingsRepositoryProvider).saveSettings(next);
  }
}
