import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/app/providers.dart';
import 'package:swingcapture/core/models/capture_record.dart';
import 'package:swingcapture/core/models/capture_settings.dart';
import 'package:swingcapture/features/history/data/history_repository.dart';
import 'package:swingcapture/features/settings/data/settings_repository.dart';

class _MemoryHistoryRepository implements HistoryRepository {
  final List<CaptureRecord> _records = [];

  @override
  Future<void> deleteRecord(String id) async {
    _records.removeWhere((record) => record.id == id);
  }

  @override
  Future<List<CaptureRecord>> listRecords() async {
    return List<CaptureRecord>.from(_records)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<void> saveRecord(CaptureRecord record) async {
    _records.removeWhere((item) => item.id == record.id);
    _records.add(record);
  }
}

class _FakeSettingsRepository implements SettingsRepository {
  @override
  Future<CaptureSettings> loadSettings() async => CaptureSettings.defaults();

  @override
  Future<void> saveSettings(CaptureSettings settings) async {}
}

void main() {
  test('manual capture save persists and refreshes history list', () async {
    final historyRepository = _MemoryHistoryRepository();
    final container = ProviderContainer(
      overrides: [
        historyRepositoryProvider.overrideWithValue(historyRepository),
        settingsRepositoryProvider.overrideWithValue(_FakeSettingsRepository()),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(historyControllerProvider.future), isEmpty);

    final captureController = container.read(
      captureControllerProvider.notifier,
    );
    captureController.setPermissions(
      hasCameraPermission: true,
      hasMicrophonePermission: true,
    );

    await captureController.saveManualCapture(
      videoPath: '/tmp/test-swing.mp4',
      durationMs: 1800,
      thumbnailPath: '/tmp/test-swing.jpg',
      locationLabel: 'San Diego, CA',
    );

    final items = await container.read(historyControllerProvider.future);
    expect(items, hasLength(1));
    expect(items.first.record.videoPath, '/tmp/test-swing.mp4');
    expect(items.first.subtitle, 'San Diego, CA');
  });

  test('history refresh pulls in repository changes', () async {
    final historyRepository = _MemoryHistoryRepository();
    final container = ProviderContainer(
      overrides: [
        historyRepositoryProvider.overrideWithValue(historyRepository),
        settingsRepositoryProvider.overrideWithValue(_FakeSettingsRepository()),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(historyControllerProvider.future), isEmpty);

    await historyRepository.saveRecord(
      CaptureRecord(
        id: 'seed-record',
        videoPath: '/tmp/seed.mp4',
        thumbnailPath: '',
        createdAt: DateTime(2026, 4, 13, 10, 30),
        durationMs: 1200,
        albumName: 'SwingCapture',
        locationLabel: 'Los Angeles, CA',
      ),
    );

    await container.read(historyControllerProvider.notifier).refresh();

    final items = await container.read(historyControllerProvider.future);
    expect(items, hasLength(1));
    expect(items.first.record.id, 'seed-record');
  });
}
