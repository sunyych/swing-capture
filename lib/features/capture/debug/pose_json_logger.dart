import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../domain/models/pose_frame.dart';

/// One-line JSON for sharing / correlating pose streams (grep `PoseJson`).
class PoseJsonLogger {
  PoseJsonLogger._();

  /// Compact landmark map: name -> [x, y, confidence] with 3–4 decimal places.
  static Map<String, List<num>> _landmarksMap(PoseFrame frame) {
    final entries = frame.landmarks.entries.toList()
      ..sort((a, b) => a.key.name.compareTo(b.key.name));
    final out = <String, List<num>>{};
    for (final e in entries) {
      final p = e.value;
      out[e.key.name] = [
        _r4(p.x),
        _r4(p.y),
        _r2(p.confidence),
      ];
    }
    return out;
  }

  static double _r2(double v) => (v * 100).round() / 100;
  static double _r4(double v) => (v * 10000).round() / 10000;

  /// [wallMs] = epoch millis for correlation with device logs.
  static String buildLine({
    required PoseFrame frame,
    required int wallMs,
    required String stage,
    required double completeness,
    required bool hasHitter,
    required bool gatherAllowsSwing,
    int? stableMs,
    bool detected = false,
    String? detectLabel,
    double? detectScore,
    String? detectReason,
  }) {
    return jsonEncode({
      'tag': 'PoseJson',
      'wallMs': wallMs,
      'stage': stage,
      'complete': _r2(completeness),
      'hasHitter': hasHitter,
      'gatherOk': gatherAllowsSwing,
      'detected': detected,
      if (detectLabel != null) 'detectLabel': detectLabel,
      if (detectScore != null) 'detectScore': _r2(detectScore),
      if (detectReason != null) 'detectReason': detectReason,
      if (stableMs != null) 'stableMs': stableMs,
      'lmCount': frame.landmarks.length,
      'lm': _landmarksMap(frame),
    });
  }

  static void printLine(String line) {
    debugPrint('[PoseJson] $line');
  }
}
