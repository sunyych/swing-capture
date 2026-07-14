import 'dart:math' as math;

import '../models/pose_candidate.dart';

class SelectedPoseCandidate {
  const SelectedPoseCandidate({
    required this.candidate,
    required this.score,
    required this.reason,
  });

  final PoseCandidate candidate;
  final double score;
  final String reason;
}

/// Picks the person the rest of the capture pipeline should treat as the hitter.
///
/// This intentionally sits after any pose source. ML Kit/Vision can provide one
/// candidate, while YOLO can provide many; downstream detectors still receive a
/// single PoseFrame.
class TargetPoseSelector {
  TargetPoseSelector({
    this.targetCenterX = 0.5,
    this.targetCenterY = 0.52,
    this.centerWeight = 0.42,
    this.completenessWeight = 0.28,
    this.confidenceWeight = 0.18,
    this.sizeWeight = 0.07,
    this.continuityWeight = 0.05,
    this.minCompleteness = 0.35,
  });

  final double targetCenterX;
  final double targetCenterY;
  final double centerWeight;
  final double completenessWeight;
  final double confidenceWeight;
  final double sizeWeight;
  final double continuityWeight;
  final double minCompleteness;

  PoseCandidate? _lastSelected;

  void reset() {
    _lastSelected = null;
  }

  SelectedPoseCandidate? select(List<PoseCandidate> candidates) {
    if (candidates.isEmpty) {
      return null;
    }

    SelectedPoseCandidate? best;
    for (final candidate in candidates) {
      final completeness = candidate.completenessScore();
      if (completeness < minCompleteness) {
        continue;
      }
      final score = _score(candidate, completeness);
      final selected = SelectedPoseCandidate(
        candidate: candidate,
        score: score,
        reason: _reason(candidate, completeness, score),
      );
      if (best == null || selected.score > best.score) {
        best = selected;
      }
    }

    best ??= _fallbackByConfidence(candidates);
    _lastSelected = best.candidate;
    return best;
  }

  SelectedPoseCandidate _fallbackByConfidence(List<PoseCandidate> candidates) {
    final sorted = List<PoseCandidate>.from(candidates)
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    final candidate = sorted.first;
    final completeness = candidate.completenessScore();
    final score = _score(candidate, completeness);
    return SelectedPoseCandidate(
      candidate: candidate,
      score: score,
      reason: 'fallback_confidence',
    );
  }

  double _score(PoseCandidate candidate, double completeness) {
    final dx = candidate.bounds.centerX - targetCenterX;
    final dy = candidate.bounds.centerY - targetCenterY;
    final distance = math.sqrt(dx * dx + dy * dy);
    final centerScore = (1 - distance / 0.72).clamp(0.0, 1.0).toDouble();
    final sizeScore = _sizeScore(candidate.bounds.area);
    final continuityScore = _continuityScore(candidate);
    return centerWeight * centerScore +
        completenessWeight * completeness.clamp(0.0, 1.0).toDouble() +
        confidenceWeight * candidate.confidence.clamp(0.0, 1.0).toDouble() +
        sizeWeight * sizeScore +
        continuityWeight * continuityScore;
  }

  double _sizeScore(double area) {
    if (area <= 0) {
      return 0;
    }
    // A hitter usually occupies a meaningful but not full-frame area.
    const idealArea = 0.22;
    final diff = (area - idealArea).abs();
    return (1 - diff / idealArea).clamp(0.0, 1.0).toDouble();
  }

  double _continuityScore(PoseCandidate candidate) {
    final last = _lastSelected;
    if (last == null) {
      return 0.5;
    }
    final dx = candidate.bounds.centerX - last.bounds.centerX;
    final dy = candidate.bounds.centerY - last.bounds.centerY;
    final distance = math.sqrt(dx * dx + dy * dy);
    return (1 - distance / 0.45).clamp(0.0, 1.0).toDouble();
  }

  String _reason(PoseCandidate candidate, double completeness, double score) {
    final center =
        '${candidate.bounds.centerX.toStringAsFixed(2)},'
        '${candidate.bounds.centerY.toStringAsFixed(2)}';
    return 'center_target score=${score.toStringAsFixed(3)} '
        'center=$center complete=${completeness.toStringAsFixed(2)} '
        'confidence=${candidate.confidence.toStringAsFixed(2)}';
  }
}
