import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

class SwingTfliteInferenceResult {
  const SwingTfliteInferenceResult({
    required this.label,
    required this.confidence,
    required this.classProbabilities,
  });

  final String label;
  final double confidence;
  final Map<String, double> classProbabilities;
}

class SwingTfliteInferenceService {
  static const _modelAssetPath = 'assets/models/swing_classifier.tflite';
  static const _labelsAssetPath = 'assets/models/swing_classifier_labels.json';

  Interpreter? _interpreter;
  List<String> _classNames = const ['baseball_swing', 'other'];

  Future<void> close() async {
    _interpreter?.close();
    _interpreter = null;
  }

  Future<SwingTfliteInferenceResult> classifyPoseJson(
    String poseJsonPath,
  ) async {
    await _ensureLoaded();
    final payload =
        json.decode(File(poseJsonPath).readAsStringSync())
            as Map<String, dynamic>;
    final features = _extractFeaturesFromPosePayload(payload);
    final input = [features];
    final output = [List<double>.filled(_classNames.length, 0)];
    _interpreter!.run(input, output);
    final probs = output.first;
    var maxIdx = 0;
    for (var i = 1; i < probs.length; i++) {
      if (probs[i] > probs[maxIdx]) {
        maxIdx = i;
      }
    }
    final classProbs = <String, double>{};
    for (var i = 0; i < _classNames.length && i < probs.length; i++) {
      classProbs[_classNames[i]] = probs[i];
    }
    return SwingTfliteInferenceResult(
      label: _classNames[maxIdx],
      confidence: probs[maxIdx],
      classProbabilities: classProbs,
    );
  }

  Future<void> _ensureLoaded() async {
    if (_interpreter != null) return;
    final appDir = await getApplicationDocumentsDirectory();
    final modelPath = '${appDir.path}/models/swing_classifier.tflite';
    final labelsPath = '${appDir.path}/models/swing_classifier_labels.json';
    final modelFile = File(modelPath);
    final labelsFile = File(labelsPath);

    if (!modelFile.existsSync()) {
      await _tryMaterializeAssetToFile(_modelAssetPath, modelFile);
    }
    if (!labelsFile.existsSync()) {
      await _tryMaterializeAssetToFile(_labelsAssetPath, labelsFile);
    }

    if (!modelFile.existsSync()) {
      throw StateError(
        'Missing TFLite model at $modelPath, and no bundled asset found at '
        '$_modelAssetPath.',
      );
    }

    _interpreter = Interpreter.fromFile(modelFile);
    if (labelsFile.existsSync()) {
      final labelsPayload =
          json.decode(labelsFile.readAsStringSync()) as Map<String, dynamic>;
      final names = (labelsPayload['class_names'] as List<dynamic>?)
          ?.cast<String>();
      if (names != null && names.isNotEmpty) {
        _classNames = names;
      }
    }
  }

  Future<void> _tryMaterializeAssetToFile(String assetPath, File target) async {
    try {
      final byteData = await rootBundle.load(assetPath);
      target.parent.createSync(recursive: true);
      await target.writeAsBytes(
        byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        ),
        flush: true,
      );
    } catch (_) {
      // Keep fallback behavior: caller checks file existence afterwards.
    }
  }

  List<double> _extractFeaturesFromPosePayload(Map<String, dynamic> payload) {
    final frames = (payload['frames'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    if (frames.isEmpty) {
      return List<double>.filled(54, 0);
    }

    final timestamps = <double>[];
    final upperBodyPresence = <double>[];
    final torsoSeparationDeg = <double>[];
    final leftWristSpeed = <double>[];
    final rightWristSpeed = <double>[];
    final meanWristSpeed = <double>[];
    final smoothedWristSpeed = <double>[];
    final handsToTorsoDistance = <double>[];
    final torsoVelocity = <double>[];
    final handsVelocity = <double>[];
    final swingScore = <double>[];

    for (final frame in frames) {
      final ts =
          (frame['offsetMs'] as num?)?.toDouble() ??
          (frame['timestamp_ms'] as num?)?.toDouble() ??
          (timestamps.isEmpty ? 0.0 : timestamps.last + 33.0);
      timestamps.add(ts);
      final lm = (frame['lm'] as Map<String, dynamic>? ?? const {});
      final completeness =
          (frame['complete'] as num?)?.toDouble() ?? _fallbackCompleteness(lm);
      upperBodyPresence.add(completeness);
      final torso = _torsoSeparationDeg(lm);
      torsoSeparationDeg.add(torso);
      final leftSpeed = _speedAt(timestamps, frames, 'leftWrist');
      final rightSpeed = _speedAt(timestamps, frames, 'rightWrist');
      leftWristSpeed.add(leftSpeed.$1);
      rightWristSpeed.add(rightSpeed.$1);
      meanWristSpeed.add((leftSpeed.$1 + rightSpeed.$1) / 2.0);
      final handDist = _handsToTorsoDistance(lm);
      handsToTorsoDistance.add(handDist);
    }

    smoothedWristSpeed.addAll(_movingAverage(meanWristSpeed, 5));
    torsoVelocity.addAll(_derivative(torsoSeparationDeg, timestamps));
    handsVelocity.addAll(_derivative(handsToTorsoDistance, timestamps));
    final wristZ = _zscore(smoothedWristSpeed);
    final torsoAbsZ = _zscore(torsoVelocity.map((v) => v.abs()).toList());
    final handsAbsZ = _zscore(handsVelocity.map((v) => v.abs()).toList());
    for (var i = 0; i < timestamps.length; i++) {
      swingScore.add(
        0.50 * wristZ[i] + 0.35 * torsoAbsZ[i] + 0.15 * handsAbsZ[i],
      );
    }

    final featureColumns = <List<double>>[
      upperBodyPresence,
      torsoSeparationDeg,
      leftWristSpeed,
      rightWristSpeed,
      meanWristSpeed,
      smoothedWristSpeed,
      handsToTorsoDistance,
      torsoVelocity,
      handsVelocity,
      swingScore,
    ];
    final out = <double>[];
    for (final series in featureColumns) {
      out.addAll(_aggregate(series));
    }
    final durationMs = timestamps.length > 1
        ? timestamps.last - timestamps.first
        : 0.0;
    out.add(durationMs);
    out.add(_safeMax(swingScore));
    out.add(_safeMax(torsoVelocity.map((v) => v.abs()).toList()));
    out.add(_safeMax(handsVelocity.map((v) => v.abs()).toList()));
    return out;
  }

  double _fallbackCompleteness(Map<String, dynamic> lm) {
    if (lm.isEmpty) return 0.0;
    return (lm.length / 13.0).clamp(0.0, 1.0);
  }

  (double, double) _speedAt(
    List<double> timestamps,
    List<Map<String, dynamic>> frames,
    String key,
  ) {
    final i = timestamps.length - 1;
    if (i <= 0) return (0.0, 0.0);
    final dt = (timestamps[i] - timestamps[i - 1]) / 1000.0;
    if (dt <= 0) return (0.0, dt);
    final lmNow = (frames[i]['lm'] as Map<String, dynamic>? ?? const {});
    final lmPrev = (frames[i - 1]['lm'] as Map<String, dynamic>? ?? const {});
    final pNow = lmNow[key] as Map<String, dynamic>?;
    final pPrev = lmPrev[key] as Map<String, dynamic>?;
    if (pNow == null || pPrev == null) return (0.0, dt);
    final dx =
        ((pNow['x'] as num?)?.toDouble() ?? 0.0) -
        ((pPrev['x'] as num?)?.toDouble() ?? 0.0);
    final dy =
        ((pNow['y'] as num?)?.toDouble() ?? 0.0) -
        ((pPrev['y'] as num?)?.toDouble() ?? 0.0);
    return (math.sqrt(dx * dx + dy * dy) / dt, dt);
  }

  double _torsoSeparationDeg(Map<String, dynamic> lm) {
    final ls = lm['leftShoulder'] as Map<String, dynamic>?;
    final rs = lm['rightShoulder'] as Map<String, dynamic>?;
    final lh = lm['leftHip'] as Map<String, dynamic>?;
    final rh = lm['rightHip'] as Map<String, dynamic>?;
    if (ls == null || rs == null || lh == null || rh == null) return 0.0;
    final sAngle = math.atan2(
      ((rs['y'] as num?)?.toDouble() ?? 0) -
          ((ls['y'] as num?)?.toDouble() ?? 0),
      ((rs['x'] as num?)?.toDouble() ?? 0) -
          ((ls['x'] as num?)?.toDouble() ?? 0),
    );
    final hAngle = math.atan2(
      ((rh['y'] as num?)?.toDouble() ?? 0) -
          ((lh['y'] as num?)?.toDouble() ?? 0),
      ((rh['x'] as num?)?.toDouble() ?? 0) -
          ((lh['x'] as num?)?.toDouble() ?? 0),
    );
    return (sAngle - hAngle) * 180.0 / math.pi;
  }

  double _handsToTorsoDistance(Map<String, dynamic> lm) {
    final lw = lm['leftWrist'] as Map<String, dynamic>?;
    final rw = lm['rightWrist'] as Map<String, dynamic>?;
    final ls = lm['leftShoulder'] as Map<String, dynamic>?;
    final rs = lm['rightShoulder'] as Map<String, dynamic>?;
    final lh = lm['leftHip'] as Map<String, dynamic>?;
    final rh = lm['rightHip'] as Map<String, dynamic>?;
    if (lw == null ||
        rw == null ||
        ls == null ||
        rs == null ||
        lh == null ||
        rh == null) {
      return 0.0;
    }
    final cx =
        (((ls['x'] as num?)?.toDouble() ?? 0) +
            ((rs['x'] as num?)?.toDouble() ?? 0) +
            ((lh['x'] as num?)?.toDouble() ?? 0) +
            ((rh['x'] as num?)?.toDouble() ?? 0)) /
        4.0;
    final cy =
        (((ls['y'] as num?)?.toDouble() ?? 0) +
            ((rs['y'] as num?)?.toDouble() ?? 0) +
            ((lh['y'] as num?)?.toDouble() ?? 0) +
            ((rh['y'] as num?)?.toDouble() ?? 0)) /
        4.0;
    final ldx = ((lw['x'] as num?)?.toDouble() ?? 0) - cx;
    final ldy = ((lw['y'] as num?)?.toDouble() ?? 0) - cy;
    final rdx = ((rw['x'] as num?)?.toDouble() ?? 0) - cx;
    final rdy = ((rw['y'] as num?)?.toDouble() ?? 0) - cy;
    return (math.sqrt(ldx * ldx + ldy * ldy) +
            math.sqrt(rdx * rdx + rdy * rdy)) /
        2.0;
  }

  List<double> _movingAverage(List<double> values, int window) {
    if (values.isEmpty) return [];
    final out = <double>[];
    for (var i = 0; i < values.length; i++) {
      final start = math.max(0, i - window + 1);
      final slice = values.sublist(start, i + 1);
      out.add(slice.reduce((a, b) => a + b) / slice.length);
    }
    return out;
  }

  List<double> _derivative(List<double> values, List<double> timestampsMs) {
    if (values.isEmpty) return [];
    final out = <double>[0.0];
    for (var i = 1; i < values.length; i++) {
      final dt = (timestampsMs[i] - timestampsMs[i - 1]) / 1000.0;
      if (dt <= 0) {
        out.add(0.0);
      } else {
        out.add((values[i] - values[i - 1]) / dt);
      }
    }
    return out;
  }

  List<double> _zscore(List<double> values) {
    if (values.isEmpty) return [];
    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance =
        values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
        values.length;
    final std = math.sqrt(variance);
    final denom = std == 0 ? 1.0 : std;
    return values.map((v) => (v - mean) / denom).toList();
  }

  List<double> _aggregate(List<double> values) {
    if (values.isEmpty) return [0, 0, 0, 0];
    var minV = values.first;
    var maxV = values.first;
    var sum = 0.0;
    for (final v in values) {
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
      sum += v;
    }
    return [minV, maxV, sum / values.length, values.last];
  }

  double _safeMax(List<double> values) {
    if (values.isEmpty) return 0.0;
    var maxV = values.first;
    for (final v in values) {
      if (v > maxV) maxV = v;
    }
    return maxV;
  }
}
