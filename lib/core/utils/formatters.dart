import 'package:intl/intl.dart';

class Formatters {
  const Formatters._();

  static final DateFormat historyDateFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

  static String formatFileTimestamp(DateTime value) {
    final base = DateFormat('yyyyMMdd_HHmmss').format(value);
    final microsecondPart = value.millisecond * 1000 + value.microsecond;
    return '${base}_${microsecondPart.toString().padLeft(6, '0')}';
  }

  static String formatDurationMs(int durationMs) {
    final totalSeconds = (durationMs / 1000).round();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  static String formatVideoFps(double? fps) {
    if (fps == null || fps <= 0 || fps.isNaN || fps.isInfinite) {
      return 'Unavailable';
    }
    final rounded = fps.roundToDouble();
    final value = (fps - rounded).abs() < 0.05
        ? rounded.toStringAsFixed(0)
        : fps.toStringAsFixed(2);
    return '$value fps';
  }
}
