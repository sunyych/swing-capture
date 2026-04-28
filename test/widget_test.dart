import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/app/app.dart';
import 'package:swingcapture/app/providers.dart';
import 'package:swingcapture/core/models/capture_record.dart';
import 'package:swingcapture/core/models/capture_settings.dart';
import 'package:swingcapture/features/history/data/history_repository.dart';
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

void main() {
  testWidgets('renders bottom navigation tabs', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          historyRepositoryProvider.overrideWithValue(_FakeHistoryRepository()),
          settingsRepositoryProvider.overrideWithValue(
            _FakeSettingsRepository(),
          ),
        ],
        child: const SwingCaptureApp(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Capture'), findsWidgets);
    expect(find.text('History'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
  });
}
