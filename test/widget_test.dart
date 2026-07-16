import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:swingcapture/app/app.dart';
import 'package:swingcapture/app/providers.dart';
import 'package:swingcapture/core/models/capture_record.dart';
import 'package:swingcapture/core/models/capture_settings.dart';
import 'package:swingcapture/features/history/data/history_repository.dart';
import 'package:swingcapture/features/performance/data/startup_performance_repository.dart';
import 'package:swingcapture/features/performance/domain/startup_performance_benchmark.dart';
import 'package:swingcapture/features/settings/data/settings_repository.dart';

class _FakeHistoryRepository implements HistoryRepository {
  @override
  Future<void> deleteRecord(String id) async {}

  @override
  Future<List<CaptureRecord>> listRecords() async => const [];

  @override
  Future<void> saveRecord(CaptureRecord record) async {}
}

class _FakeSettingsRepository implements SettingsRepository {
  @override
  Future<CaptureSettings> loadSettings() async => CaptureSettings.defaults();

  @override
  Future<void> saveSettings(CaptureSettings settings) async {}
}

class _FakeStartupPerformanceRepository
    implements StartupPerformanceRepository {
  _FakeStartupPerformanceRepository({required this.shouldShow});

  bool shouldShow;
  bool hidden = false;

  @override
  Future<bool> shouldShowStartupPerformanceModal() async => shouldShow;

  @override
  Future<void> setStartupPerformanceModalHidden(bool hidden) async {
    this.hidden = hidden;
    shouldShow = !hidden;
  }
}

class _FakeStartupPerformanceBenchmark extends StartupPerformanceBenchmark {
  const _FakeStartupPerformanceBenchmark();

  @override
  Future<StartupPerformanceReport> run() async {
    return StartupPerformanceReport(
      recordingCapability: null,
      poseDetection: const PoseDetectionBenchmarkResult(
        framesProcessed: 600,
        candidatesDetected: 1200,
        selectedFrames: 600,
        elapsed: Duration(milliseconds: 8),
        fps: 75000,
        averageCandidatesPerFrame: 2,
      ),
      poseProcessing: const PoseProcessingBenchmarkResult(
        framesProcessed: 1200,
        elapsed: Duration(milliseconds: 10),
        fps: 120000,
        detectedEvents: 0,
        averageCompleteness: 1,
      ),
      elapsed: const Duration(milliseconds: 10),
    );
  }
}

Widget _buildApp({
  required StartupPerformanceRepository startupPerformanceRepository,
}) {
  return ProviderScope(
    overrides: [
      historyRepositoryProvider.overrideWithValue(_FakeHistoryRepository()),
      settingsRepositoryProvider.overrideWithValue(_FakeSettingsRepository()),
      startupPerformanceRepositoryProvider.overrideWithValue(
        startupPerformanceRepository,
      ),
      startupPerformanceBenchmarkProvider.overrideWithValue(
        const _FakeStartupPerformanceBenchmark(),
      ),
    ],
    child: const MotionCaptureApp(),
  );
}

void main() {
  testWidgets('renders bottom navigation tabs', (tester) async {
    await tester.pumpWidget(
      _buildApp(
        startupPerformanceRepository: _FakeStartupPerformanceRepository(
          shouldShow: false,
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Capture'), findsWidgets);
    expect(find.text('History'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
  });

  testWidgets('startup performance modal can be hidden', (tester) async {
    final repository = _FakeStartupPerformanceRepository(shouldShow: true);

    await tester.pumpWidget(
      _buildApp(startupPerformanceRepository: repository),
    );

    await tester.pumpAndSettle();

    expect(find.text('Performance tests'), findsOneWidget);
    expect(find.text('Recording profile'), findsOneWidget);
    expect(find.text('Pose detection'), findsOneWidget);
    expect(find.text('Pose processing'), findsOneWidget);

    await tester.tap(find.text('Don\'t show test content'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(repository.hidden, isTrue);
    expect(find.text('Performance tests'), findsNothing);
  });

  testWidgets('startup performance modal fits compact screens', (tester) async {
    final repository = _FakeStartupPerformanceRepository(shouldShow: true);
    tester.view.physicalSize = const Size(393, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _buildApp(startupPerformanceRepository: repository),
    );

    await tester.pumpAndSettle();

    expect(find.text('Performance tests'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
