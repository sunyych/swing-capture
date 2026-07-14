import 'pose_frame.dart';

class PoseBounds {
  const PoseBounds({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => (right - left).clamp(0.0, 1.0).toDouble();
  double get height => (bottom - top).clamp(0.0, 1.0).toDouble();
  double get area => width * height;
  double get centerX => ((left + right) / 2).clamp(0.0, 1.0).toDouble();
  double get centerY => ((top + bottom) / 2).clamp(0.0, 1.0).toDouble();

  PoseBounds clamp() {
    return PoseBounds(
      left: left.clamp(0.0, 1.0).toDouble(),
      top: top.clamp(0.0, 1.0).toDouble(),
      right: right.clamp(0.0, 1.0).toDouble(),
      bottom: bottom.clamp(0.0, 1.0).toDouble(),
    );
  }

  double iou(PoseBounds other) {
    final x1 = left > other.left ? left : other.left;
    final y1 = top > other.top ? top : other.top;
    final x2 = right < other.right ? right : other.right;
    final y2 = bottom < other.bottom ? bottom : other.bottom;
    final intersectionWidth = (x2 - x1).clamp(0.0, 1.0).toDouble();
    final intersectionHeight = (y2 - y1).clamp(0.0, 1.0).toDouble();
    final intersection = intersectionWidth * intersectionHeight;
    final union = area + other.area - intersection;
    if (union <= 0) {
      return 0;
    }
    return intersection / union;
  }
}

class PoseCandidate {
  const PoseCandidate({
    required this.source,
    required this.timestamp,
    required this.landmarks,
    required this.confidence,
    required this.bounds,
    this.trackId,
  });

  final PoseFrameSource source;
  final DateTime timestamp;
  final Map<PoseLandmark, PoseLandmarkPoint> landmarks;
  final double confidence;
  final PoseBounds bounds;
  final String? trackId;

  double completenessScore() {
    return PoseFrame(
      timestamp: timestamp,
      landmarks: landmarks,
    ).completenessScore();
  }

  PoseFrame toPoseFrame({
    int? candidateCount,
    double? selectionScore,
    String? selectionReason,
  }) {
    return PoseFrame(
      timestamp: timestamp,
      landmarks: landmarks,
      source: source,
      candidateCount: candidateCount,
      selectionScore: selectionScore,
      selectionReason: selectionReason,
    );
  }
}
