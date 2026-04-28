import 'package:intl/intl.dart';

class Formatters {
  const Formatters._();

  static final DateFormat historyDateFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

  static String formatDurationMs(int durationMs) {
    final totalSeconds = (durationMs / 1000).round();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
