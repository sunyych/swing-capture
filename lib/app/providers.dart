import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../core/models/capture_settings.dart';
import '../features/capture/presentation/controllers/capture_controller.dart';
import '../features/history/data/history_repository.dart';
import '../features/history/presentation/controllers/history_controller.dart';
import '../features/performance/data/startup_performance_repository.dart';
import '../features/performance/domain/startup_performance_benchmark.dart';
import '../features/settings/data/settings_repository.dart';
import '../features/settings/presentation/controllers/settings_controller.dart';

final appTabProvider = StateProvider<int>((ref) => 0);

final historyRepositoryProvider = Provider<HistoryRepository>((ref) {
  throw UnimplementedError('historyRepositoryProvider must be overridden.');
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  throw UnimplementedError('settingsRepositoryProvider must be overridden.');
});

final startupPerformanceRepositoryProvider =
    Provider<StartupPerformanceRepository>((ref) {
      throw UnimplementedError(
        'startupPerformanceRepositoryProvider must be overridden.',
      );
    });

final startupPerformanceBenchmarkProvider =
    Provider<StartupPerformanceBenchmark>(
      (ref) => const StartupPerformanceBenchmark(),
    );

final settingsControllerProvider =
    AsyncNotifierProvider<SettingsController, CaptureSettings>(
      SettingsController.new,
    );

final historyControllerProvider =
    AsyncNotifierProvider<HistoryController, List<CaptureRecordViewModel>>(
      HistoryController.new,
    );

final captureControllerProvider =
    NotifierProvider.autoDispose<CaptureController, CaptureSessionState>(
      CaptureController.new,
    );
