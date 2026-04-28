import 'dart:math' as math;

import '../../../../core/models/action_event.dart';
import '../models/pose_frame.dart';
import 'action_detector.dart';
import 'shoulder_gather_tracker.dart';

class CrossBodyShoulderSwingDetectorConfig {
  const CrossBodyShoulderSwingDetectorConfig({
    required this.cooldown,
    this.label = 'baseball_swing',
    this.category = 'sports',
    this.minLandmarkConfidence = 0.35,
    this.maxTransitionDuration = const Duration(milliseconds: 900),
    this.minTransitionDuration = const Duration(milliseconds: 40),
    this.wristCarryTtl = const Duration(milliseconds: 240),
    this.minTravelSpanFactor = 0.72,
    this.crossMidlineSlackSpanFactor = 0.10,
    this.minAverageCrossSpeed = 0.55,
    this.minBurstLateralSpeed = 0.90,
    this.preRollMs = 2000,
    this.postRollMs = 2000,
  });

  final Duration cooldown;
  final String label;
  final String category;
  final double minLandmarkConfidence;
  final Duration maxTransitionDuration;
  final Duration minTransitionDuration;
  final Duration wristCarryTtl;
  final double minTravelSpanFactor;
  final double crossMidlineSlackSpanFactor;
  final double minAverageCrossSpeed;
  final double minBurstLateralSpeed;
  final int preRollMs;
  final int postRollMs;
}

class CrossBodyShoulderSwingDetector implements ActionDetector {
  CrossBodyShoulderSwingDetector({
    required CrossBodyShoulderSwingDetectorConfig config,
    required ShoulderGatherTracker shoulderGather,
  }) : _config = config,
       _shoulderGather = shoulderGather;

  final CrossBodyShoulderSwingDetectorConfig _config;
  final ShoulderGatherTracker _shoulderGather;

  DateTime? _lastTriggeredAt;
  PoseLandmarkPoint? _carriedLeft;
  PoseLandmarkPoint? _carriedRight;
  DateTime? _lastLeftSeenAt;
  DateTime? _lastRightSeenAt;
  _CrossBodySample? _previousSample;

  @override
  ActionEvent? process(PoseFrame frame) {
    if (_lastTriggeredAt != null &&
        frame.timestamp.difference(_lastTriggeredAt!) < _config.cooldown) {
      _updateCarry(frame);
      return null;
    }

    _updateCarry(frame);
    final gather = _shoulderGather.latestSnapshotAt(frame.timestamp);
    final sample = _effectiveSample(frame);
    final previousSample = _previousSample;
    if (sample != null) {
      _previousSample = sample;
    }
    if (gather == null || sample == null) {
      return null;
    }

    final transition = frame.timestamp.difference(gather.timestamp);
    if (transition < _config.minTransitionDuration ||
        transition > _config.maxTransitionDuration) {
      return null;
    }

    final currentSide = sample.x >= gather.shoulderMidX
        ? ShoulderGatherSide.right
        : ShoulderGatherSide.left;
    if (currentSide == gather.side) {
      return null;
    }

    final span = math.max(gather.shoulderSpan, 0.05);
    final travel = (sample.x - gather.wristMidX).abs();
    final minTravel = span * _config.minTravelSpanFactor;
    if (travel < minTravel) {
      return null;
    }

    final crossedOppositeHalf = switch (gather.side) {
      ShoulderGatherSide.left =>
        sample.x >=
            gather.shoulderMidX + span * _config.crossMidlineSlackSpanFactor,
      ShoulderGatherSide.right =>
        sample.x <=
            gather.shoulderMidX - span * _config.crossMidlineSlackSpanFactor,
    };
    if (!crossedOppositeHalf) {
      return null;
    }

    final averageSpeed =
        travel / (transition.inMicroseconds / Duration.microsecondsPerSecond);
    if (averageSpeed < _config.minAverageCrossSpeed) {
      return null;
    }

    final burstVx = previousSample == null
        ? averageSpeed
        : _lateralVelocity(previousSample, sample);
    if (burstVx.abs() < _config.minBurstLateralSpeed) {
      return null;
    }

    final score = _score(
      travel: travel,
      minTravel: minTravel,
      averageSpeed: averageSpeed,
      burstVx: burstVx.abs(),
    );
    final windowStart = gather.timestamp.subtract(
      Duration(milliseconds: _config.preRollMs),
    );
    final windowEnd = frame.timestamp.add(
      Duration(milliseconds: _config.postRollMs),
    );

    _lastTriggeredAt = frame.timestamp;
    return ActionEvent(
      label: _config.label,
      category: _config.category,
      triggeredAt: frame.timestamp,
      score: score,
      preRollMs: _config.preRollMs,
      postRollMs: _config.postRollMs,
      windowStartAt: windowStart,
      windowEndAt: windowEnd,
      reason:
          'cross_body: load=${gather.side.name}, '
          'travel=${travel.toStringAsFixed(3)}, '
          'dt=${transition.inMilliseconds}ms, '
          'avg=${averageSpeed.toStringAsFixed(2)}, '
          'burst=${burstVx.toStringAsFixed(2)}',
    );
  }

  @override
  void reset() {
    _lastTriggeredAt = null;
    _carriedLeft = null;
    _carriedRight = null;
    _lastLeftSeenAt = null;
    _lastRightSeenAt = null;
    _previousSample = null;
  }

  void _updateCarry(PoseFrame frame) {
    final lw = frame.landmarks[PoseLandmark.leftWrist];
    final rw = frame.landmarks[PoseLandmark.rightWrist];
    final leftOk = lw != null && lw.confidence >= _config.minLandmarkConfidence;
    final rightOk =
        rw != null && rw.confidence >= _config.minLandmarkConfidence;
    if (leftOk) {
      _carriedLeft = lw;
      _lastLeftSeenAt = frame.timestamp;
    }
    if (rightOk) {
      _carriedRight = rw;
      _lastRightSeenAt = frame.timestamp;
    }
  }

  _CrossBodySample? _effectiveSample(PoseFrame frame) {
    final now = frame.timestamp;
    final left = _resolveWrist(
      live: frame.landmarks[PoseLandmark.leftWrist],
      carried: _carriedLeft,
      lastSeenAt: _lastLeftSeenAt,
      now: now,
    );
    final right = _resolveWrist(
      live: frame.landmarks[PoseLandmark.rightWrist],
      carried: _carriedRight,
      lastSeenAt: _lastRightSeenAt,
      now: now,
    );
    if (left == null && right == null) {
      return null;
    }
    final shoulders = _shoulders(frame);
    if (shoulders == null) {
      return null;
    }
    final x = switch ((left, right)) {
      (final l?, final r?) => (l.x + r.x) / 2.0,
      (final l?, null) => l.x,
      (null, final r?) => r.x,
      _ => 0.0,
    };
    final y = switch ((left, right)) {
      (final l?, final r?) => (l.y + r.y) / 2.0,
      (final l?, null) => l.y,
      (null, final r?) => r.y,
      _ => 0.0,
    };
    return _CrossBodySample(
      timestamp: frame.timestamp,
      x: x,
      y: y,
      shoulderMidX: shoulders.$1,
      shoulderSpan: shoulders.$2,
    );
  }

  PoseLandmarkPoint? _resolveWrist({
    required PoseLandmarkPoint? live,
    required PoseLandmarkPoint? carried,
    required DateTime? lastSeenAt,
    required DateTime now,
  }) {
    if (live != null && live.confidence >= _config.minLandmarkConfidence) {
      return live;
    }
    if (carried == null || lastSeenAt == null) {
      return null;
    }
    if (now.difference(lastSeenAt) > _config.wristCarryTtl) {
      return null;
    }
    return carried;
  }

  (double, double)? _shoulders(PoseFrame frame) {
    final left = frame.landmarks[PoseLandmark.leftShoulder];
    final right = frame.landmarks[PoseLandmark.rightShoulder];
    if (left == null ||
        right == null ||
        left.confidence < _config.minLandmarkConfidence ||
        right.confidence < _config.minLandmarkConfidence) {
      return null;
    }
    final midX = (left.x + right.x) / 2.0;
    final span = math.max(0.05, _distance(left, right));
    return (midX, span);
  }

  double _lateralVelocity(_CrossBodySample previous, _CrossBodySample current) {
    final dtUs = current.timestamp
        .difference(previous.timestamp)
        .inMicroseconds;
    if (dtUs <= 0) {
      return 0;
    }
    return (current.x - previous.x) / (dtUs / Duration.microsecondsPerSecond);
  }

  double _score({
    required double travel,
    required double minTravel,
    required double averageSpeed,
    required double burstVx,
  }) {
    final travelScore = (travel / (minTravel * 1.35)).clamp(0.0, 1.0);
    final averageSpeedScore =
        (averageSpeed / (_config.minAverageCrossSpeed * 1.5)).clamp(0.0, 1.0);
    final burstScore = (burstVx / (_config.minBurstLateralSpeed * 1.5)).clamp(
      0.0,
      1.0,
    );
    return ((travelScore + averageSpeedScore + burstScore) / 3.0)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  double _distance(PoseLandmarkPoint a, PoseLandmarkPoint b) {
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    return math.sqrt(dx * dx + dy * dy);
  }
}

class _CrossBodySample {
  const _CrossBodySample({
    required this.timestamp,
    required this.x,
    required this.y,
    required this.shoulderMidX,
    required this.shoulderSpan,
  });

  final DateTime timestamp;
  final double x;
  final double y;
  final double shoulderMidX;
  final double shoulderSpan;
}
