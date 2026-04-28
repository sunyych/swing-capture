import 'dart:collection';
import 'dart:math' as math;

import '../../../../core/models/action_event.dart';
import '../models/pose_frame.dart';
import 'action_detector.dart';
import 'shoulder_gather_tracker.dart';

/// Configuration for [LateralWristBurstSwingDetector].
///
/// Mirrors the heuristic in `scripts/detect_swings_from_pose_json.py`, extended
/// so a **single** high-confidence wrist can drive the lateral burst (one-hand
/// practice swings). When both wrists are visible, behavior matches the legacy
/// midpoint (`mid_x = (left + right) / 2`) + mean 2D wrist speed formulation.
class LateralWristBurstDetectorConfig {
  const LateralWristBurstDetectorConfig({
    required this.cooldown,
    this.label = 'baseball_swing',
    this.category = 'sports',
    this.smoothWindow = 5,
    this.minWristVisibility = 0.35,
    this.minAbsVx = 0.9,
    this.minMeanWristSpeed = 0.6,
    this.minScore = 0.45,
    this.preRollMs = 2000,
    this.postRollMs = 2000,
  });

  /// Minimum spacing between successive triggers.
  final Duration cooldown;

  final String label;
  final String category;

  /// Number of samples in the moving-average window (SMA).
  final int smoothWindow;

  /// Wrist landmarks below this confidence break the derivative chain.
  final double minWristVisibility;

  /// Minimum |smoothed lateral velocity of the wrist midpoint|, in
  /// normalized image-width units per second.
  final double minAbsVx;

  /// Minimum smoothed mean 2D wrist speed, normalized units per second.
  final double minMeanWristSpeed;

  /// Minimum value of `|vx_sma| * sqrt(wrist_speed_sma)`.
  final double minScore;

  final int preRollMs;
  final int postRollMs;
}

enum _ArmMode { both, leftOnly, rightOnly }

class _WristSample {
  _WristSample({
    required this.timestamp,
    required this.referenceX,
    required this.mode,
    required this.leftWrist,
    required this.rightWrist,
    required this.leftLive,
    required this.rightLive,
  });

  final DateTime timestamp;
  final double referenceX;
  final _ArmMode mode;
  final PoseLandmarkPoint leftWrist;
  final PoseLandmarkPoint rightWrist;
  final bool leftLive;
  final bool rightLive;
}

/// Online swing detector driven by lateral wrist-midpoint motion.
///
/// Matches the Python analysis step (see detector docstring). The streaming
/// variant cannot compute a global percentile threshold, so we gate on
/// absolute minimums tuned for normalized image coordinates at typical
/// preview framerates.
class LateralWristBurstSwingDetector implements ActionDetector {
  LateralWristBurstSwingDetector({
    required LateralWristBurstDetectorConfig config,
    ShoulderGatherTracker? shoulderGather,
  }) : _config = config,
       _shoulderGather = shoulderGather;

  final LateralWristBurstDetectorConfig _config;
  final ShoulderGatherTracker? _shoulderGather;
  final Queue<_WristSample> _samples = ListQueue<_WristSample>();
  final Queue<double> _vxWindow = ListQueue<double>();
  final Queue<double> _speedWindow = ListQueue<double>();
  DateTime? _lastTriggeredAt;
  PoseLandmarkPoint? _carriedLeft;
  PoseLandmarkPoint? _carriedRight;
  DateTime? _lastLeftLiveAt;
  DateTime? _lastRightLiveAt;
  _ArmMode? _prevModeForDerivative;

  static const Duration _wristCarryTtl = Duration(milliseconds: 280);

  @override
  ActionEvent? process(PoseFrame frame) {
    final lwRaw = frame.landmarks[PoseLandmark.leftWrist];
    final rwRaw = frame.landmarks[PoseLandmark.rightWrist];
    final lwLive =
        lwRaw != null && lwRaw.confidence >= _config.minWristVisibility;
    final rwLive =
        rwRaw != null && rwRaw.confidence >= _config.minWristVisibility;

    if (lwLive) {
      _carriedLeft = lwRaw;
      _lastLeftLiveAt = frame.timestamp;
    }
    if (rwLive) {
      _carriedRight = rwRaw;
      _lastRightLiveAt = frame.timestamp;
    }

    if (!lwLive && !rwLive) {
      _resetDerivativeChain();
      return null;
    }

    final lwCarryOk = _carriedLeft != null &&
        _lastLeftLiveAt != null &&
        frame.timestamp.difference(_lastLeftLiveAt!) <= _wristCarryTtl;
    final rwCarryOk = _carriedRight != null &&
        _lastRightLiveAt != null &&
        frame.timestamp.difference(_lastRightLiveAt!) <= _wristCarryTtl;

    final lwEff = lwLive ? lwRaw : (lwCarryOk ? _carriedLeft! : null);
    final rwEff = rwLive ? rwRaw : (rwCarryOk ? _carriedRight! : null);

    if (lwEff == null && rwEff == null) {
      _resetDerivativeChain();
      return null;
    }

    final mode = lwEff != null && rwEff != null
        ? _ArmMode.both
        : (lwEff != null ? _ArmMode.leftOnly : _ArmMode.rightOnly);

    final referenceX = switch (mode) {
      _ArmMode.both => (lwEff!.x + rwEff!.x) / 2.0,
      _ArmMode.leftOnly => lwEff!.x,
      _ArmMode.rightOnly => rwEff!.x,
    };

    final modeChanged =
        _prevModeForDerivative != null && _prevModeForDerivative != mode;
    _prevModeForDerivative = mode;

    var vx = 0.0;
    var meanSpeed = 0.0;
    if (_samples.isNotEmpty && !modeChanged) {
      final prev = _samples.last;
      final dtMs =
          frame.timestamp.difference(prev.timestamp).inMicroseconds / 1000.0;
      if (dtMs > 0) {
        final dt = dtMs / 1000.0;
        vx = (referenceX - prev.referenceX) / dt;
        switch (mode) {
          case _ArmMode.both:
            final sl = _distance(prev.leftWrist, lwEff!) / dt;
            final sr = _distance(prev.rightWrist, rwEff!) / dt;
            if (lwLive && rwLive) {
              meanSpeed = (sl + sr) / 2.0;
            } else {
              meanSpeed = math.max(sl, sr);
            }
          case _ArmMode.leftOnly:
            meanSpeed = _distance(prev.leftWrist, lwEff!) / dt;
          case _ArmMode.rightOnly:
            meanSpeed = _distance(prev.rightWrist, rwEff!) / dt;
        }
      }
    }

    final lwStore = lwEff ??
        PoseLandmarkPoint(x: referenceX, y: 0.5, confidence: 0);
    final rwStore = rwEff ??
        PoseLandmarkPoint(x: referenceX, y: 0.5, confidence: 0);

    _samples.addLast(
      _WristSample(
        timestamp: frame.timestamp,
        referenceX: referenceX,
        mode: mode,
        leftWrist: lwStore,
        rightWrist: rwStore,
        leftLive: lwLive,
        rightLive: rwLive,
      ),
    );
    while (_samples.length > _config.smoothWindow + 1) {
      _samples.removeFirst();
    }
    _vxWindow.addLast(vx);
    _speedWindow.addLast(meanSpeed);
    while (_vxWindow.length > _config.smoothWindow) {
      _vxWindow.removeFirst();
    }
    while (_speedWindow.length > _config.smoothWindow) {
      _speedWindow.removeFirst();
    }

    if (_vxWindow.length < _config.smoothWindow) {
      return null;
    }

    if (_lastTriggeredAt != null &&
        frame.timestamp.difference(_lastTriggeredAt!) < _config.cooldown) {
      return null;
    }

    final vxSma = _mean(_vxWindow);
    final speedSma = _mean(_speedWindow);
    if (vxSma == 0 || speedSma <= 0) {
      return null;
    }

    final sign = vxSma.isNegative ? -1 : 1;
    // Require a consistent direction across the window: any motion in the
    // opposite direction disqualifies (prevents triggering on jittery idle).
    for (final v in _vxWindow) {
      if (v == 0) continue;
      final s = v.isNegative ? -1 : 1;
      if (s != sign) {
        return null;
      }
    }

    final absVx = vxSma.abs();
    final score = absVx * math.sqrt(speedSma);
    if (absVx < _config.minAbsVx ||
        speedSma < _config.minMeanWristSpeed ||
        score < _config.minScore) {
      return null;
    }

    final gatherGate = _shoulderGather;
    if (gatherGate != null && !gatherGate.allowsSwingAt(frame.timestamp)) {
      return null;
    }

    _lastTriggeredAt = frame.timestamp;
    final direction = sign > 0 ? 'left_to_right' : 'right_to_left';
    final armNote = switch (mode) {
      _ArmMode.both => 'both_hands',
      _ArmMode.leftOnly => 'left_hand_only',
      _ArmMode.rightOnly => 'right_hand_only',
    };
    return ActionEvent(
      label: _config.label,
      category: _config.category,
      triggeredAt: frame.timestamp,
      score: score.clamp(0.0, 1.0).toDouble(),
      preRollMs: _config.preRollMs,
      postRollMs: _config.postRollMs,
      reason:
          'lateral burst $direction ($armNote): vx=${vxSma.toStringAsFixed(3)}, '
          'speed=${speedSma.toStringAsFixed(3)}, '
          'score=${score.toStringAsFixed(3)}',
    );
  }

  @override
  void reset() {
    _resetDerivativeChain();
    _lastTriggeredAt = null;
  }

  void _resetDerivativeChain() {
    _samples.clear();
    _vxWindow.clear();
    _speedWindow.clear();
    _prevModeForDerivative = null;
    _carriedLeft = null;
    _carriedRight = null;
    _lastLeftLiveAt = null;
    _lastRightLiveAt = null;
  }

  double _distance(PoseLandmarkPoint a, PoseLandmarkPoint b) {
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  double _mean(Iterable<double> values) {
    if (values.isEmpty) return 0;
    double sum = 0;
    var count = 0;
    for (final v in values) {
      sum += v;
      count++;
    }
    return sum / count;
  }
}
