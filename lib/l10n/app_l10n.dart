import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

/// Holds the active [AppLocalizations] for code without a [BuildContext]
/// (e.g. controllers). Updated from [MaterialApp.builder].
class AppL10n {
  AppL10n._();

  static AppLocalizations? _current;

  static AppLocalizations get current {
    final value = _current;
    if (value == null) {
      throw StateError('AppL10n is not loaded yet.');
    }
    return value;
  }

  static bool get isLoaded => _current != null;

  static void load(AppLocalizations value) {
    _current = value;
  }

  static AppLocalizations of(BuildContext context) =>
      AppLocalizations.of(context);
}
