import 'package:shared_preferences/shared_preferences.dart';

abstract class StartupPerformanceRepository {
  Future<bool> shouldShowStartupPerformanceModal();
  Future<void> setStartupPerformanceModalHidden(bool hidden);
}

class SharedPrefsStartupPerformanceRepository
    implements StartupPerformanceRepository {
  const SharedPrefsStartupPerformanceRepository(this._prefs);

  static const String _hideStartupPerformanceModalKey =
      'hide_startup_performance_modal';

  final SharedPreferences _prefs;

  @override
  Future<bool> shouldShowStartupPerformanceModal() async {
    return !(_prefs.getBool(_hideStartupPerformanceModalKey) ?? false);
  }

  @override
  Future<void> setStartupPerformanceModalHidden(bool hidden) async {
    await _prefs.setBool(_hideStartupPerformanceModalKey, hidden);
  }
}
