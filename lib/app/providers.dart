import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models/capture_settings.dart';
import '../features/capture/presentation/controllers/capture_controller.dart';
import '../features/history/data/history_repository.dart';
import '../features/history/presentation/controllers/history_controller.dart';
import '../features/settings/data/settings_repository.dart';
import '../features/settings/presentation/controllers/settings_controller.dart';

final appTabProvider = StateProvider<int>((ref) => 0);

final historyRepositoryProvider = Provider<HistoryRepository>((ref) {
  throw UnimplementedError('historyRepositoryProvider must be overridden.');
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  throw UnimplementedError('settingsRepositoryProvider must be overridden.');
});

final settingsControllerProvider =
    AsyncNotifierProvider<SettingsController, CaptureSettings>(
      SettingsController.new,
    );

final historyControllerProvider =
    AsyncNotifierProvider<HistoryController, List<CaptureRecordViewModel>>(
      HistoryController.new,
    );

final captureControllerProvider =
    AutoDisposeNotifierProvider<CaptureController, CaptureSessionState>(
      CaptureController.new,
    );
