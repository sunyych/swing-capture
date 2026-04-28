import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/features/capture/domain/models/pose_frame.dart';
import 'package:swingcapture/features/capture/domain/services/rule_based_swing_detector.dart';

void main() {
  test(
    'rule-based detector triggers on strong hand travel and torso rotation',
    () {
      final detector = RuleBasedSwingDetector(
        config: const RuleBasedSwingDetectorConfig(
          cooldown: Duration(milliseconds: 1200),
        ),
      );

      final base = DateTime(2026, 1, 1, 12);
      final frames = [
        _frame(base, 0.45, 0.60, 0.45, 0.56),
        _frame(
          base.add(const Duration(milliseconds: 60)),
          0.40,
          0.68,
          0.43,
          0.59,
        ),
        _frame(
          base.add(const Duration(milliseconds: 120)),
          0.32,
          0.80,
          0.39,
          0.65,
        ),
        _frame(
          base.add(const Duration(milliseconds: 180)),
          0.24,
          0.88,
          0.35,
          0.72,
        ),
      ];

      var triggered = false;
      for (final frame in frames) {
        final event = detector.process(frame);
        triggered = triggered || event != null;
      }

      expect(triggered, isTrue);
    },
  );

  test('detector respects cooldown window', () {
    final detector = RuleBasedSwingDetector(
      config: const RuleBasedSwingDetectorConfig(
        cooldown: Duration(seconds: 2),
      ),
    );

    final base = DateTime(2026, 1, 1, 12);
    final firstWave = [
      _frame(base, 0.45, 0.60, 0.45, 0.56),
      _frame(
        base.add(const Duration(milliseconds: 60)),
        0.35,
        0.78,
        0.39,
        0.66,
      ),
    ];
    final secondWave = [
      _frame(
        base.add(const Duration(milliseconds: 300)),
        0.46,
        0.61,
        0.45,
        0.56,
      ),
      _frame(
        base.add(const Duration(milliseconds: 360)),
        0.30,
        0.84,
        0.36,
        0.70,
      ),
    ];

    final firstEvent = firstWave.any(
      (frame) => detector.process(frame) != null,
    );
    final secondEvent = secondWave.any(
      (frame) => detector.process(frame) != null,
    );

    expect(firstEvent, isTrue);
    expect(secondEvent, isFalse);
  });
}

PoseFrame _frame(
  DateTime timestamp,
  double leftWristX,
  double rightWristX,
  double leftShoulderX,
  double rightShoulderX,
) {
  return PoseFrame(
    timestamp: timestamp,
    landmarks: {
      PoseLandmark.leftShoulder: PoseLandmarkPoint(
        x: leftShoulderX,
        y: 0.30,
        confidence: 0.95,
      ),
      PoseLandmark.rightShoulder: PoseLandmarkPoint(
        x: rightShoulderX,
        y: 0.28,
        confidence: 0.95,
      ),
      PoseLandmark.leftHip: const PoseLandmarkPoint(
        x: 0.48,
        y: 0.62,
        confidence: 0.9,
      ),
      PoseLandmark.rightHip: const PoseLandmarkPoint(
        x: 0.55,
        y: 0.62,
        confidence: 0.9,
      ),
      PoseLandmark.leftWrist: PoseLandmarkPoint(
        x: leftWristX,
        y: 0.47,
        confidence: 0.95,
      ),
      PoseLandmark.rightWrist: PoseLandmarkPoint(
        x: rightWristX,
        y: 0.43,
        confidence: 0.95,
      ),
    },
  );
}
