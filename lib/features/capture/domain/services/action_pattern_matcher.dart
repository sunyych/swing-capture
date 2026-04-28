import 'dart:math' as math;

import '../../../../core/models/action_event.dart';
import '../models/action_pattern_definition.dart';
import '../models/pose_frame.dart';
import 'action_detector.dart';

class ActionPatternMatcher implements ActionDetector {
  ActionPatternMatcher({required ActionPatternDefinition definition})
    : _definition = definition;

  final ActionPatternDefinition _definition;

  final Map<String, _PatternStageAnchor> _anchors = {};
  final Map<String, _ClusterRuntimeState> _clusterState = {};
  final Map<String, _FeetApartRuntimeState> _feetApartState = {};
  PoseLandmarkPoint? _carriedLeft;
  PoseLandmarkPoint? _carriedRight;
  DateTime? _lastLeftSeenAt;
  DateTime? _lastRightSeenAt;
  _CurrentSample? _previousSample;
  DateTime? _lastTriggeredAt;
  int _activeStageIndex = 0;

  String get patternName => _definition.name;

  bool get isArmed => _anchors.isNotEmpty;

  @override
  ActionEvent? process(PoseFrame frame) {
    _updateCarry(frame);
    if (_definition.stages.isEmpty) {
      return null;
    }

    final stage = _definition.stages[_activeStageIndex];
    final evaluation = _evaluateStage(stage, frame);
    switch (evaluation.status) {
      case _StageStatus.noMatch:
        return null;
      case _StageStatus.expired:
        _resetProgress();
        return _reprocessFromStart(frame);
      case _StageStatus.matched:
        final anchor = evaluation.anchor!;
        _anchors[stage.id] = anchor;
        if (_activeStageIndex < _definition.stages.length - 1) {
          _activeStageIndex += 1;
          return null;
        }

        if (_lastTriggeredAt != null &&
            frame.timestamp.difference(_lastTriggeredAt!) <
                Duration(milliseconds: _definition.cooldownMs)) {
          _resetProgress();
          return null;
        }

        final firstAnchor = _anchors[_definition.stages.first.id]!;
        final event = ActionEvent(
          label: _definition.label,
          category: _definition.category,
          triggeredAt: frame.timestamp,
          score: anchor.score,
          preRollMs: _definition.preRollMs,
          postRollMs: _definition.postRollMs,
          windowStartAt: firstAnchor.timestamp.subtract(
            Duration(milliseconds: _definition.preRollMs),
          ),
          windowEndAt: frame.timestamp.add(
            Duration(milliseconds: _definition.postRollMs),
          ),
          reason:
              'pattern=${_definition.id}, stages=${_anchors.keys.join(' -> ')}, ${anchor.reason}',
        );
        _lastTriggeredAt = frame.timestamp;
        _resetProgress();
        return event;
    }
  }

  @override
  void reset() {
    _resetProgress();
    _carriedLeft = null;
    _carriedRight = null;
    _lastLeftSeenAt = null;
    _lastRightSeenAt = null;
    _previousSample = null;
    _lastTriggeredAt = null;
  }

  ActionEvent? _reprocessFromStart(PoseFrame frame) {
    if (_definition.stages.isEmpty) {
      return null;
    }
    final stage = _definition.stages.first;
    final evaluation = _evaluateStage(stage, frame);
    if (evaluation.status != _StageStatus.matched) {
      return null;
    }
    _anchors[stage.id] = evaluation.anchor!;
    if (_definition.stages.length == 1) {
      final anchor = evaluation.anchor!;
      _lastTriggeredAt = frame.timestamp;
      final event = ActionEvent(
        label: _definition.label,
        category: _definition.category,
        triggeredAt: frame.timestamp,
        score: anchor.score,
        preRollMs: _definition.preRollMs,
        postRollMs: _definition.postRollMs,
        windowStartAt: frame.timestamp.subtract(
          Duration(milliseconds: _definition.preRollMs),
        ),
        windowEndAt: frame.timestamp.add(
          Duration(milliseconds: _definition.postRollMs),
        ),
        reason: 'pattern=${_definition.id}, ${anchor.reason}',
      );
      _resetProgress();
      return event;
    }
    _activeStageIndex = 1;
    return null;
  }

  _StageEvaluation _evaluateStage(
    ActionPatternStageDefinition stage,
    PoseFrame frame,
  ) {
    return switch (stage.type) {
      ActionPatternStageType.handsClusterNearShoulderSide =>
        _evaluateHandsClusterStage(stage, frame),
      ActionPatternStageType.crossBodyTravel => _evaluateCrossBodyStage(
        stage,
        frame,
      ),
      ActionPatternStageType.feetApartStance => _evaluateFeetApartStage(
        stage,
        frame,
      ),
    };
  }

  _StageEvaluation _evaluateFeetApartStage(
    ActionPatternStageDefinition stage,
    PoseFrame frame,
  ) {
    final minConfidence = stage.doubleParam('minLandmarkConfidence', 0.45);
    final leftAnkle = frame.landmarks[PoseLandmark.leftAnkle];
    final rightAnkle = frame.landmarks[PoseLandmark.rightAnkle];
    final leftHip = frame.landmarks[PoseLandmark.leftHip];
    final rightHip = frame.landmarks[PoseLandmark.rightHip];
    if (leftAnkle == null ||
        rightAnkle == null ||
        leftHip == null ||
        rightHip == null ||
        leftAnkle.confidence < minConfidence ||
        rightAnkle.confidence < minConfidence ||
        leftHip.confidence < minConfidence ||
        rightHip.confidence < minConfidence) {
      _feetApartRuntimeFor(stage.id).reset();
      return const _StageEvaluation.noMatch();
    }

    final hipSpan = math.max(0.04, (rightHip.x - leftHip.x).abs());
    final ankleSpan = (rightAnkle.x - leftAnkle.x).abs();
    final separationRatio = ankleSpan / hipSpan;
    final minFeetSeparationRatio = stage.doubleParam(
      'minFeetSeparationRatio',
      1.8,
    );
    if (separationRatio < minFeetSeparationRatio) {
      _feetApartRuntimeFor(stage.id).reset();
      return const _StageEvaluation.noMatch();
    }

    final hipCenterX = (leftHip.x + rightHip.x) / 2.0;
    final runtime = _feetApartRuntimeFor(stage.id);
    final currentSample = _FeetApartSample(
      timestamp: frame.timestamp,
      leftAnkleX: leftAnkle.x,
      rightAnkleX: rightAnkle.x,
      hipCenterX: hipCenterX,
    );
    final previousSample = runtime.previous;
    runtime.previous = currentSample;

    if (previousSample != null) {
      final dtUs = currentSample.timestamp
          .difference(previousSample.timestamp)
          .inMicroseconds;
      if (dtUs > 0) {
        final dtSeconds = dtUs / Duration.microsecondsPerSecond;
        final leftSpeed =
            (currentSample.leftAnkleX - previousSample.leftAnkleX).abs() /
            dtSeconds;
        final rightSpeed =
            (currentSample.rightAnkleX - previousSample.rightAnkleX).abs() /
            dtSeconds;
        final hipSpeed =
            (currentSample.hipCenterX - previousSample.hipCenterX).abs() /
            dtSeconds;
        final maxFootSpeed = stage.doubleParam('maxFootLateralSpeed', 0.24);
        final maxHipSpeed = stage.doubleParam('maxHipLateralSpeed', 0.12);
        if (leftSpeed > maxFootSpeed ||
            rightSpeed > maxFootSpeed ||
            hipSpeed > maxHipSpeed) {
          runtime.reset(keepPrevious: currentSample);
          return const _StageEvaluation.noMatch();
        }
      }
    }

    runtime.streak += 1;
    final minConsecutiveFrames = stage.intParam('minConsecutiveFrames', 4);
    if (runtime.streak < minConsecutiveFrames) {
      return const _StageEvaluation.noMatch();
    }

    final score = (separationRatio / (minFeetSeparationRatio * 1.4))
        .clamp(0.0, 1.0)
        .toDouble();
    return _StageEvaluation.matched(
      _PatternStageAnchor(
        stageId: stage.id,
        timestamp: frame.timestamp,
        bindings: {
          'leftAnkleX': leftAnkle.x,
          'rightAnkleX': rightAnkle.x,
          'hipCenterX': hipCenterX,
          'separationRatio': separationRatio,
        },
        score: score,
        reason:
            'feet_apart_stance: ratio=${separationRatio.toStringAsFixed(2)}, '
            'streak=${runtime.streak}',
      ),
    );
  }

  _StageEvaluation _evaluateHandsClusterStage(
    ActionPatternStageDefinition stage,
    PoseFrame frame,
  ) {
    final ls = frame.landmarks[PoseLandmark.leftShoulder];
    final rs = frame.landmarks[PoseLandmark.rightShoulder];
    final lw = frame.landmarks[PoseLandmark.leftWrist];
    final rw = frame.landmarks[PoseLandmark.rightWrist];
    final minConfidence = stage.doubleParam('minLandmarkConfidence', 0.4);
    if (ls == null ||
        rs == null ||
        lw == null ||
        rw == null ||
        ls.confidence < minConfidence ||
        rs.confidence < minConfidence ||
        lw.confidence < minConfidence ||
        rw.confidence < minConfidence) {
      _clusterRuntimeFor(stage.id).reset();
      return const _StageEvaluation.noMatch();
    }

    final midX = (ls.x + rs.x) / 2.0;
    final span = math.max(0.05, _distance(ls, rs));
    final slack = span * stage.doubleParam('midlineSlackSpanFactor', 0.12);
    final nearCap = span * stage.doubleParam('nearShoulderSpanFactor', 0.55);

    final cluster = _screenSideHandsCluster(
      ls: ls,
      rs: rs,
      lw: lw,
      rw: rw,
      midX: midX,
      slack: slack,
    );
    if (cluster == null) {
      _clusterRuntimeFor(stage.id).reset();
      return const _StageEvaluation.noMatch();
    }

    final match = _matchClusterToShoulder(
      cluster: cluster,
      ls: ls,
      rs: rs,
      lw: lw,
      rw: rw,
      nearCap: nearCap,
    );
    if (match == null) {
      _clusterRuntimeFor(stage.id).reset();
      return const _StageEvaluation.noMatch();
    }

    final runtime = _clusterRuntimeFor(stage.id);
    runtime.push(match.screenSide);
    final minConsecutiveFrames = stage.intParam('minConsecutiveFrames', 2);
    if (runtime.streak < minConsecutiveFrames) {
      return const _StageEvaluation.noMatch();
    }

    return _StageEvaluation.matched(
      _PatternStageAnchor(
        stageId: stage.id,
        timestamp: frame.timestamp,
        bindings: {
          'side': match.screenSide.name,
          'shoulderSide': match.shoulderSide.name,
          'wristMidX': (lw.x + rw.x) / 2.0,
          'wristMidY': (lw.y + rw.y) / 2.0,
          'shoulderMidX': midX,
          'shoulderSpan': span,
        },
        score: 0.5,
        reason:
            'load=${match.screenSide.name}, shoulder=${match.shoulderSide.name}',
      ),
    );
  }

  _PatternSide? _screenSideHandsCluster({
    required PoseLandmarkPoint ls,
    required PoseLandmarkPoint rs,
    required PoseLandmarkPoint lw,
    required PoseLandmarkPoint rw,
    required double midX,
    required double slack,
  }) {
    if (lw.x <= midX + slack && rw.x <= midX + slack) {
      return _PatternSide.left;
    }
    if (lw.x >= midX - slack && rw.x >= midX - slack) {
      return _PatternSide.right;
    }
    return null;
  }

  _ClusterShoulderMatch? _matchClusterToShoulder({
    required _PatternSide cluster,
    required PoseLandmarkPoint ls,
    required PoseLandmarkPoint rs,
    required PoseLandmarkPoint lw,
    required PoseLandmarkPoint rw,
    required double nearCap,
  }) {
    final sameFacingShoulder = cluster == _PatternSide.left ? ls : rs;
    if (_distance(lw, sameFacingShoulder) <= nearCap &&
        _distance(rw, sameFacingShoulder) <= nearCap) {
      return _ClusterShoulderMatch(screenSide: cluster, shoulderSide: cluster);
    }

    final mirroredShoulder = cluster == _PatternSide.left ? rs : ls;
    final mirroredSide = cluster == _PatternSide.left
        ? _PatternSide.right
        : _PatternSide.left;
    if (_distance(lw, mirroredShoulder) <= nearCap &&
        _distance(rw, mirroredShoulder) <= nearCap) {
      return _ClusterShoulderMatch(
        screenSide: cluster,
        shoulderSide: mirroredSide,
      );
    }

    return null;
  }

  _StageEvaluation _evaluateCrossBodyStage(
    ActionPatternStageDefinition stage,
    PoseFrame frame,
  ) {
    final fromStageId = stage.fromStage;
    if (fromStageId == null) {
      return const _StageEvaluation.noMatch();
    }
    final anchor = _anchors[fromStageId];
    if (anchor == null) {
      return const _StageEvaluation.noMatch();
    }

    final minTransitionMs = stage.intParam('minTransitionMs', 40);
    final maxTransitionMs = stage.intParam('maxTransitionMs', 900);
    final transition = frame.timestamp.difference(anchor.timestamp);
    if (transition.inMilliseconds > maxTransitionMs) {
      return const _StageEvaluation.expired();
    }
    if (transition.inMilliseconds < minTransitionMs) {
      return const _StageEvaluation.noMatch();
    }

    final previous = _previousSample;
    final sample = _currentSample(frame, stage);
    if (sample == null) {
      return const _StageEvaluation.noMatch();
    }
    _previousSample = sample;

    final gatherSideName = anchor.bindings['side'] as String?;
    final gatherSide = switch (gatherSideName) {
      'left' => _PatternSide.left,
      'right' => _PatternSide.right,
      _ => null,
    };
    if (gatherSide == null) {
      return const _StageEvaluation.noMatch();
    }

    final shoulderMidX = (anchor.bindings['shoulderMidX'] as num?)?.toDouble();
    final shoulderSpan = (anchor.bindings['shoulderSpan'] as num?)?.toDouble();
    final gatherWristMidX = (anchor.bindings['wristMidX'] as num?)?.toDouble();
    if (shoulderMidX == null ||
        shoulderSpan == null ||
        gatherWristMidX == null) {
      return const _StageEvaluation.noMatch();
    }

    final currentSide = sample.x >= shoulderMidX
        ? _PatternSide.right
        : _PatternSide.left;
    if (currentSide == gatherSide) {
      return const _StageEvaluation.noMatch();
    }

    final minTravel =
        shoulderSpan * stage.doubleParam('minTravelSpanFactor', 0.72);
    final travel = (sample.x - gatherWristMidX).abs();
    if (travel < minTravel) {
      return const _StageEvaluation.noMatch();
    }

    final crossSlack =
        shoulderSpan * stage.doubleParam('crossMidlineSlackSpanFactor', 0.10);
    final crossedMidline = switch (gatherSide) {
      _PatternSide.left => sample.x >= shoulderMidX + crossSlack,
      _PatternSide.right => sample.x <= shoulderMidX - crossSlack,
    };
    if (!crossedMidline) {
      return const _StageEvaluation.noMatch();
    }

    final averageSpeed =
        travel / (transition.inMicroseconds / Duration.microsecondsPerSecond);
    if (averageSpeed < stage.doubleParam('minAverageCrossSpeed', 0.55)) {
      return const _StageEvaluation.noMatch();
    }

    final burstVx = previous == null
        ? averageSpeed
        : _lateralVelocity(previous, sample);
    if (burstVx.abs() < stage.doubleParam('minBurstLateralSpeed', 0.90)) {
      return const _StageEvaluation.noMatch();
    }

    final score = _score(
      travel: travel,
      minTravel: minTravel,
      averageSpeed: averageSpeed,
      burstVx: burstVx.abs(),
      minAverageCrossSpeed: stage.doubleParam('minAverageCrossSpeed', 0.55),
      minBurstLateralSpeed: stage.doubleParam('minBurstLateralSpeed', 0.90),
    );

    return _StageEvaluation.matched(
      _PatternStageAnchor(
        stageId: stage.id,
        timestamp: frame.timestamp,
        bindings: {'x': sample.x, 'y': sample.y},
        score: score,
        reason:
            'cross_body: load=${gatherSide.name}, travel=${travel.toStringAsFixed(3)}, '
            'dt=${transition.inMilliseconds}ms, avg=${averageSpeed.toStringAsFixed(2)}, '
            'burst=${burstVx.toStringAsFixed(2)}',
      ),
    );
  }

  _CurrentSample? _currentSample(
    PoseFrame frame,
    ActionPatternStageDefinition stage,
  ) {
    return _effectiveSample(
      frame: frame,
      minConfidence: stage.doubleParam('minLandmarkConfidence', 0.35),
      wristCarryTtlMs: stage.intParam('wristCarryTtlMs', 240),
    );
  }

  _CurrentSample? _effectiveSample({
    required PoseFrame frame,
    required double minConfidence,
    required int wristCarryTtlMs,
  }) {
    final now = frame.timestamp;
    final left = _resolveWrist(
      live: frame.landmarks[PoseLandmark.leftWrist],
      carried: _carriedLeft,
      lastSeenAt: _lastLeftSeenAt,
      minConfidence: minConfidence,
      now: now,
      wristCarryTtlMs: wristCarryTtlMs,
    );
    final right = _resolveWrist(
      live: frame.landmarks[PoseLandmark.rightWrist],
      carried: _carriedRight,
      lastSeenAt: _lastRightSeenAt,
      minConfidence: minConfidence,
      now: now,
      wristCarryTtlMs: wristCarryTtlMs,
    );
    if (left == null && right == null) {
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
    return _CurrentSample(timestamp: frame.timestamp, x: x, y: y);
  }

  void _updateCarry(PoseFrame frame) {
    final lw = frame.landmarks[PoseLandmark.leftWrist];
    final rw = frame.landmarks[PoseLandmark.rightWrist];
    if (lw != null) {
      _carriedLeft = lw;
      _lastLeftSeenAt = frame.timestamp;
    }
    if (rw != null) {
      _carriedRight = rw;
      _lastRightSeenAt = frame.timestamp;
    }
  }

  PoseLandmarkPoint? _resolveWrist({
    required PoseLandmarkPoint? live,
    required PoseLandmarkPoint? carried,
    required DateTime? lastSeenAt,
    required double minConfidence,
    required DateTime now,
    required int wristCarryTtlMs,
  }) {
    if (live != null && live.confidence >= minConfidence) {
      return live;
    }
    if (carried == null || lastSeenAt == null) {
      return null;
    }
    if (carried.confidence < minConfidence) {
      return null;
    }
    if (now.difference(lastSeenAt).inMilliseconds > wristCarryTtlMs) {
      return null;
    }
    return carried;
  }

  _ClusterRuntimeState _clusterRuntimeFor(String stageId) {
    return _clusterState.putIfAbsent(stageId, _ClusterRuntimeState.new);
  }

  _FeetApartRuntimeState _feetApartRuntimeFor(String stageId) {
    return _feetApartState.putIfAbsent(stageId, _FeetApartRuntimeState.new);
  }

  double _score({
    required double travel,
    required double minTravel,
    required double averageSpeed,
    required double burstVx,
    required double minAverageCrossSpeed,
    required double minBurstLateralSpeed,
  }) {
    final travelScore = (travel / (minTravel * 1.35)).clamp(0.0, 1.0);
    final averageSpeedScore = (averageSpeed / (minAverageCrossSpeed * 1.5))
        .clamp(0.0, 1.0);
    final burstScore = (burstVx / (minBurstLateralSpeed * 1.5)).clamp(0.0, 1.0);
    return ((travelScore + averageSpeedScore + burstScore) / 3.0)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  double _lateralVelocity(_CurrentSample previous, _CurrentSample current) {
    final dtUs = current.timestamp
        .difference(previous.timestamp)
        .inMicroseconds;
    if (dtUs <= 0) {
      return 0;
    }
    return (current.x - previous.x) / (dtUs / Duration.microsecondsPerSecond);
  }

  double _distance(PoseLandmarkPoint a, PoseLandmarkPoint b) {
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  void _resetProgress() {
    _anchors.clear();
    _clusterState.clear();
    _feetApartState.clear();
    _activeStageIndex = 0;
  }
}

enum _StageStatus { noMatch, matched, expired }

class _StageEvaluation {
  const _StageEvaluation._(this.status, this.anchor);

  const _StageEvaluation.noMatch() : this._(_StageStatus.noMatch, null);
  const _StageEvaluation.expired() : this._(_StageStatus.expired, null);
  const _StageEvaluation.matched(_PatternStageAnchor anchor)
    : this._(_StageStatus.matched, anchor);

  final _StageStatus status;
  final _PatternStageAnchor? anchor;
}

class _PatternStageAnchor {
  const _PatternStageAnchor({
    required this.stageId,
    required this.timestamp,
    required this.bindings,
    required this.score,
    required this.reason,
  });

  final String stageId;
  final DateTime timestamp;
  final Map<String, Object?> bindings;
  final double score;
  final String reason;
}

enum _PatternSide { left, right }

class _ClusterRuntimeState {
  int streak = 0;
  _PatternSide? side;

  void push(_PatternSide nextSide) {
    if (side == nextSide) {
      streak += 1;
      return;
    }
    side = nextSide;
    streak = 1;
  }

  void reset() {
    streak = 0;
    side = null;
  }
}

class _CurrentSample {
  const _CurrentSample({
    required this.timestamp,
    required this.x,
    required this.y,
  });

  final DateTime timestamp;
  final double x;
  final double y;
}

class _ClusterShoulderMatch {
  const _ClusterShoulderMatch({
    required this.screenSide,
    required this.shoulderSide,
  });

  final _PatternSide screenSide;
  final _PatternSide shoulderSide;
}

class _FeetApartRuntimeState {
  int streak = 0;
  _FeetApartSample? previous;

  void reset({_FeetApartSample? keepPrevious}) {
    streak = 0;
    previous = keepPrevious;
  }
}

class _FeetApartSample {
  const _FeetApartSample({
    required this.timestamp,
    required this.leftAnkleX,
    required this.rightAnkleX,
    required this.hipCenterX,
  });

  final DateTime timestamp;
  final double leftAnkleX;
  final double rightAnkleX;
  final double hipCenterX;
}
