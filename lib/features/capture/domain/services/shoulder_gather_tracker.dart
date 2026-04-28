import 'dart:math' as math;

import '../models/pose_frame.dart';

enum ShoulderGatherSide { left, right }

class ShoulderGatherSnapshot {
  const ShoulderGatherSnapshot({
    required this.timestamp,
    required this.side,
    required this.wristMidX,
    required this.wristMidY,
    required this.shoulderMidX,
    required this.shoulderSpan,
  });

  final DateTime timestamp;
  final ShoulderGatherSide side;
  final double wristMidX;
  final double wristMidY;
  final double shoulderMidX;
  final double shoulderSpan;
}

/// Tracks a short history of "load" poses: **both** wrists on the **same side**
/// of the upper-body midline **and** within a body-scaled distance of that
/// side's shoulder (typical pre-swing gather). Stricter than ratio-only checks
/// to reduce random triggers from turns.
class ShoulderGatherConfig {
  const ShoulderGatherConfig({
    this.enabled = true,
    this.minLandmarkConfidence = 0.4,

    /// Max distance from the load-side shoulder for each wrist, as a fraction
    /// of shoulder-to-shoulder span (clamped). Typical ~0.5–0.6.
    this.nearShoulderSpanFactor = 0.55,

    /// How far past midline (as a fraction of shoulder span) a wrist may sit
    /// while still counting as "on" the left/right cluster.
    this.midlineSlackSpanFactor = 0.12,

    /// Require this many consecutive qualifying frames before recording a hit.
    this.minConsecutiveGatherFrames = 2,

    /// Drop gather hits older than this (housekeeping).
    this.lookback = const Duration(milliseconds: 1200),

    /// A swing may only arm if the latest gather hit is at most this old
    /// relative to the current frame (tight coupling to the load → burst).
    this.maxGatherAgeForSwing = const Duration(milliseconds: 900),
  });

  final bool enabled;
  final double minLandmarkConfidence;
  final double nearShoulderSpanFactor;
  final double midlineSlackSpanFactor;
  final int minConsecutiveGatherFrames;
  final Duration lookback;
  final Duration maxGatherAgeForSwing;
}

/// Stateful tracker; call [observe] once per pose frame (e.g. from
/// [CaptureController] when a hitter is present).
class ShoulderGatherTracker {
  ShoulderGatherTracker({
    ShoulderGatherConfig config = const ShoulderGatherConfig(),
  }) : _config = config;

  final ShoulderGatherConfig _config;
  int _qualifiedStreak = 0;
  ShoulderGatherSide? _streakSide;
  ShoulderGatherSnapshot? _latestSnapshot;

  /// Whether a swing at [timestamp] is allowed w.r.t. recent shoulder gather.
  bool allowsSwingAt(DateTime timestamp) {
    return latestSnapshotAt(timestamp) != null;
  }

  ShoulderGatherSnapshot? latestSnapshotAt(DateTime timestamp) {
    if (!_config.enabled) {
      return _latestSnapshot;
    }
    _pruneOlderThan(timestamp);
    final latest = _latestSnapshot;
    if (latest == null) {
      return null;
    }
    final age = timestamp.difference(latest.timestamp);
    if (age.isNegative || age > _config.maxGatherAgeForSwing) {
      return null;
    }
    return latest;
  }

  void observe(PoseFrame frame) {
    if (!_config.enabled) {
      return;
    }
    final now = frame.timestamp;
    _pruneOlderThan(now);

    final snapshot = _frameHasSameSideHandsNearShoulder(frame);
    if (snapshot != null) {
      if (_streakSide == snapshot.side) {
        _qualifiedStreak++;
      } else {
        _qualifiedStreak = 1;
        _streakSide = snapshot.side;
      }
      if (_qualifiedStreak >= _config.minConsecutiveGatherFrames) {
        _latestSnapshot = snapshot;
      }
    } else {
      _qualifiedStreak = 0;
      _streakSide = null;
    }
  }

  void reset() {
    _qualifiedStreak = 0;
    _streakSide = null;
    _latestSnapshot = null;
  }

  void _pruneOlderThan(DateTime now) {
    final latest = _latestSnapshot;
    if (latest == null) {
      return;
    }
    if (now.difference(latest.timestamp) > _config.lookback) {
      _latestSnapshot = null;
      _qualifiedStreak = 0;
      _streakSide = null;
    }
  }

  ShoulderGatherSnapshot? _frameHasSameSideHandsNearShoulder(PoseFrame frame) {
    final ls = frame.landmarks[PoseLandmark.leftShoulder];
    final rs = frame.landmarks[PoseLandmark.rightShoulder];
    final lw = frame.landmarks[PoseLandmark.leftWrist];
    final rw = frame.landmarks[PoseLandmark.rightWrist];
    if (ls == null ||
        rs == null ||
        ls.confidence < _config.minLandmarkConfidence ||
        rs.confidence < _config.minLandmarkConfidence) {
      return null;
    }

    final lwOk = lw != null && lw.confidence >= _config.minLandmarkConfidence;
    final rwOk = rw != null && rw.confidence >= _config.minLandmarkConfidence;
    if (!lwOk || !rwOk) {
      return null;
    }

    final left = _sameSideHandsClusterNearShoulder(
      frame: frame,
      clusterSide: ShoulderGatherSide.left,
      ls: ls,
      rs: rs,
      lw: lw,
      rw: rw,
    );
    if (left != null) {
      return left;
    }
    return _sameSideHandsClusterNearShoulder(
      frame: frame,
      clusterSide: ShoulderGatherSide.right,
      ls: ls,
      rs: rs,
      lw: lw,
      rw: rw,
    );
  }

  ShoulderGatherSnapshot? _sameSideHandsClusterNearShoulder({
    required PoseFrame frame,
    required ShoulderGatherSide clusterSide,
    required PoseLandmarkPoint ls,
    required PoseLandmarkPoint rs,
    required PoseLandmarkPoint lw,
    required PoseLandmarkPoint rw,
  }) {
    final midX = (ls.x + rs.x) / 2.0;
    final span = math.max(0.05, _distance(ls, rs));
    final slack = span * _config.midlineSlackSpanFactor;
    final isOnClusterSide = switch (clusterSide) {
      ShoulderGatherSide.left => lw.x <= midX + slack && rw.x <= midX + slack,
      ShoulderGatherSide.right => lw.x >= midX - slack && rw.x >= midX - slack,
    };
    if (!isOnClusterSide) {
      return null;
    }

    final nearCap = span * _config.nearShoulderSpanFactor;
    final sameFacingShoulder = switch (clusterSide) {
      ShoulderGatherSide.left => ls,
      ShoulderGatherSide.right => rs,
    };
    final mirroredShoulder = switch (clusterSide) {
      ShoulderGatherSide.left => rs,
      ShoulderGatherSide.right => ls,
    };
    final nearSameFacing =
        _distance(lw, sameFacingShoulder) <= nearCap &&
        _distance(rw, sameFacingShoulder) <= nearCap;
    final nearMirrored =
        _distance(lw, mirroredShoulder) <= nearCap &&
        _distance(rw, mirroredShoulder) <= nearCap;
    if (!nearSameFacing && !nearMirrored) {
      return null;
    }

    return ShoulderGatherSnapshot(
      timestamp: frame.timestamp,
      side: clusterSide,
      wristMidX: (lw.x + rw.x) / 2.0,
      wristMidY: (lw.y + rw.y) / 2.0,
      shoulderMidX: midX,
      shoulderSpan: span,
    );
  }

  double _distance(PoseLandmarkPoint a, PoseLandmarkPoint b) {
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    return math.sqrt(dx * dx + dy * dy);
  }
}
