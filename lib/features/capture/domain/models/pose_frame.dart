enum PoseLandmark {
  nose,
  leftShoulder,
  rightShoulder,
  leftElbow,
  rightElbow,
  leftWrist,
  rightWrist,
  leftHip,
  rightHip,
  leftKnee,
  rightKnee,
  leftAnkle,
  rightAnkle,
}

class PoseLandmarkPoint {
  const PoseLandmarkPoint({
    required this.x,
    required this.y,
    required this.confidence,
  });

  final double x;
  final double y;
  final double confidence;
}

/// A normalized pose frame used by the rule-based swing detector.
class PoseFrame {
  const PoseFrame({required this.timestamp, required this.landmarks});

  final DateTime timestamp;
  final Map<PoseLandmark, PoseLandmarkPoint> landmarks;

  /// Landmarks the swing detector and "hitter detected" gate require.
  /// Adding optional landmarks (head/elbows/knees/ankles) for skeleton
  /// rendering must not move the completeness threshold.
  static const Set<PoseLandmark> coreLandmarks = {
    PoseLandmark.leftShoulder,
    PoseLandmark.rightShoulder,
    PoseLandmark.leftHip,
    PoseLandmark.rightHip,
    PoseLandmark.leftWrist,
    PoseLandmark.rightWrist,
  };

  /// Fraction of [coreLandmarks] "slots" satisfied at >= 0.5 confidence.
  ///
  /// Shoulders and hips are counted individually. The two wrist slots are
  /// scored as: +1 if **either** wrist is confident (enough for one-hand
  /// swings), and +1 additional only if **both** wrists are confident.
  double completenessScore() {
    if (landmarks.isEmpty) return 0;
    var confident = 0;
    const torso = {
      PoseLandmark.leftShoulder,
      PoseLandmark.rightShoulder,
      PoseLandmark.leftHip,
      PoseLandmark.rightHip,
    };
    for (final key in torso) {
      final point = landmarks[key];
      if (point != null && point.confidence >= 0.5) {
        confident++;
      }
    }
    final lw = landmarks[PoseLandmark.leftWrist];
    final rw = landmarks[PoseLandmark.rightWrist];
    final leftOk = lw != null && lw.confidence >= 0.5;
    final rightOk = rw != null && rw.confidence >= 0.5;
    if (leftOk || rightOk) {
      confident++;
    }
    if (leftOk && rightOk) {
      confident++;
    }
    return confident / coreLandmarks.length;
  }
}

/// Pairs of landmarks that form bones in the rendered stick figure.
const List<({PoseLandmark a, PoseLandmark b})> kPoseBones = [
  (a: PoseLandmark.leftShoulder, b: PoseLandmark.rightShoulder),
  (a: PoseLandmark.leftHip, b: PoseLandmark.rightHip),
  (a: PoseLandmark.leftShoulder, b: PoseLandmark.leftHip),
  (a: PoseLandmark.rightShoulder, b: PoseLandmark.rightHip),
  (a: PoseLandmark.leftShoulder, b: PoseLandmark.leftElbow),
  (a: PoseLandmark.leftElbow, b: PoseLandmark.leftWrist),
  (a: PoseLandmark.rightShoulder, b: PoseLandmark.rightElbow),
  (a: PoseLandmark.rightElbow, b: PoseLandmark.rightWrist),
  (a: PoseLandmark.leftHip, b: PoseLandmark.leftKnee),
  (a: PoseLandmark.leftKnee, b: PoseLandmark.leftAnkle),
  (a: PoseLandmark.rightHip, b: PoseLandmark.rightKnee),
  (a: PoseLandmark.rightKnee, b: PoseLandmark.rightAnkle),
];
