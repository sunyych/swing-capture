import 'dart:collection';
import 'dart:math' as math;

import '../../../../core/models/action_event.dart';
import '../models/pose_frame.dart';
import 'action_detector.dart';
import 'shoulder_gather_tracker.dart';

class RuleBasedActionDetectorConfig {
  const RuleBasedActionDetectorConfig({
    required this.cooldown,
    this.label = 'baseball_swing',
    this.category = 'sports',
    this.windowSize = 5,
    this.minCompleteness = 0.65,
    this.minHandTravel = 0.12,
    this.minTorsoRotationDelta = 0.10,
    this.preRollMs = 2000,
    this.postRollMs = 2000,
  });

  final Duration cooldown;
  final String label;
  final String category;
  final int windowSize;
  final double minCompleteness;
  final double minHandTravel;
  final double minTorsoRotationDelta;
  final int preRollMs;
  final int postRollMs;
}

/// Generic upper-body motion detector that can be tuned for multiple sports.
class RuleBasedActionDetector implements ActionDetector {
  RuleBasedActionDetector({
    required RuleBasedActionDetectorConfig config,
    ShoulderGatherTracker? shoulderGather,
  }) : _config = config,
       _shoulderGather = shoulderGather;

  final RuleBasedActionDetectorConfig _config;
  final ShoulderGatherTracker? _shoulderGather;
  final Queue<PoseFrame> _frames = ListQueue<PoseFrame>();
  DateTime? _lastTriggeredAt;

  @override
  ActionEvent? process(PoseFrame frame) {
    _frames.addLast(frame);
    while (_frames.length > _config.windowSize) {
      _frames.removeFirst();
    }

    if (_frames.length < 2) {
      return null;
    }

    final first = _frames.first;
    final last = _frames.last;
    if (last.completenessScore() < _config.minCompleteness) {
      return null;
    }

    if (_lastTriggeredAt != null &&
        frame.timestamp.difference(_lastTriggeredAt!) < _config.cooldown) {
      return null;
    }

    final handTravel = _averageHandTravel(first, last);
    final torsoRotationDelta = _torsoRotation(last) - _torsoRotation(first);

    if (handTravel < _config.minHandTravel ||
        torsoRotationDelta.abs() < _config.minTorsoRotationDelta) {
      return null;
    }

    final gatherGate = _shoulderGather;
    if (gatherGate != null && !gatherGate.allowsSwingAt(frame.timestamp)) {
      return null;
    }

    _lastTriggeredAt = frame.timestamp;
    final score = _normalizedScore(
      handTravel: handTravel,
      torsoRotationDelta: torsoRotationDelta.abs(),
    );

    return ActionEvent(
      label: _config.label,
      category: _config.category,
      triggeredAt: frame.timestamp,
      score: score,
      preRollMs: _config.preRollMs,
      postRollMs: _config.postRollMs,
      reason:
          'rule: handTravel=${handTravel.toStringAsFixed(3)}, torsoDelta=${torsoRotationDelta.toStringAsFixed(3)}',
    );
  }

  @override
  void reset() {
    _frames.clear();
    _lastTriggeredAt = null;
  }

  double _averageHandTravel(PoseFrame first, PoseFrame last) {
    final left = _distanceBetween(
      first.landmarks[PoseLandmark.leftWrist],
      last.landmarks[PoseLandmark.leftWrist],
    );
    final right = _distanceBetween(
      first.landmarks[PoseLandmark.rightWrist],
      last.landmarks[PoseLandmark.rightWrist],
    );
    // One-hand swings: the idle hand contributes ~0 travel; use max so the
    // active hand still clears [minHandTravel]. Two-hand swings: both move
    // similarly, so max matches the stronger side.
    return math.max(left, right);
  }

  double _torsoRotation(PoseFrame frame) {
    final shoulders = _segmentAngle(
      frame.landmarks[PoseLandmark.leftShoulder],
      frame.landmarks[PoseLandmark.rightShoulder],
    );
    final hips = _segmentAngle(
      frame.landmarks[PoseLandmark.leftHip],
      frame.landmarks[PoseLandmark.rightHip],
    );
    return shoulders - hips;
  }

  double _segmentAngle(PoseLandmarkPoint? a, PoseLandmarkPoint? b) {
    if (a == null || b == null) {
      return 0;
    }
    return math.atan2(b.y - a.y, b.x - a.x);
  }

  double _distanceBetween(PoseLandmarkPoint? a, PoseLandmarkPoint? b) {
    if (a == null || b == null) {
      return 0;
    }
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  double _normalizedScore({
    required double handTravel,
    required double torsoRotationDelta,
  }) {
    final handScore = (handTravel / (_config.minHandTravel * 2)).clamp(0, 1);
    final torsoScore =
        (torsoRotationDelta / (_config.minTorsoRotationDelta * 2)).clamp(0, 1);
    return ((handScore + torsoScore) / 2).toDouble();
  }
}
