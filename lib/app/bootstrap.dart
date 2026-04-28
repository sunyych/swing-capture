import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config/app_constants.dart';
import '../features/history/data/hive_history_repository.dart';
import '../features/settings/data/shared_prefs_settings_repository.dart';
import 'providers.dart';

class AppBootstrap {
  const AppBootstrap({required this.overrides});

  final List<Override> overrides;

  static Future<AppBootstrap> initialize() async {
    await Hive.initFlutter();
    final historyBox = await Hive.openBox<Map>(AppConstants.historyBoxName);
    final prefs = await SharedPreferences.getInstance();

    final historyRepository = HiveHistoryRepository(historyBox);
    final settingsRepository = SharedPrefsSettingsRepository(prefs);

    return AppBootstrap(
      overrides: [
        historyRepositoryProvider.overrideWithValue(historyRepository),
        settingsRepositoryProvider.overrideWithValue(settingsRepository),
      ],
    );
  }
}
