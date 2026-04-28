import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/core/models/action_event.dart';
import 'package:swingcapture/features/capture/domain/models/pose_frame.dart';
import 'package:swingcapture/features/capture/domain/services/cross_body_shoulder_swing_detector.dart';
import 'package:swingcapture/features/capture/domain/services/shoulder_gather_tracker.dart';

void main() {
  group('CrossBodyShoulderSwingDetector', () {
    test('triggers after a shoulder gather drives across the body', () {
      final tracker = ShoulderGatherTracker();
      final detector = CrossBodyShoulderSwingDetector(
        config: const CrossBodyShoulderSwingDetectorConfig(
          cooldown: Duration(milliseconds: 1500),
          preRollMs: 300,
          postRollMs: 400,
        ),
        shoulderGather: tracker,
      );

      final base = DateTime(2026, 4, 17, 12);
      final frames = <PoseFrame>[
        _frame(base, leftWristX: 0.39, rightWristX: 0.43, wristY: 0.35),
        _frame(
          base.add(const Duration(milliseconds: 40)),
          leftWristX: 0.39,
          rightWristX: 0.43,
          wristY: 0.35,
        ),
        _frame(
          base.add(const Duration(milliseconds: 100)),
          leftWristX: 0.47,
          rightWristX: 0.52,
          wristY: 0.37,
        ),
        _frame(
          base.add(const Duration(milliseconds: 160)),
          leftWristX: 0.58,
          rightWristX: 0.64,
          wristY: 0.39,
        ),
      ];

      ActionEvent? triggered;
      for (final frame in frames) {
        tracker.observe(frame);
        triggered ??= detector.process(frame);
      }

      expect(triggered, isNotNull);
      expect(triggered!.reason, contains('load=left'));
      expect(
        triggered.windowStartAt,
        base
            .add(const Duration(milliseconds: 40))
            .subtract(const Duration(milliseconds: 300)),
      );
      expect(
        triggered.windowEndAt,
        base
            .add(const Duration(milliseconds: 160))
            .add(const Duration(milliseconds: 400)),
      );
    });

    test('does not trigger without a shoulder gather preface', () {
      final tracker = ShoulderGatherTracker();
      final detector = CrossBodyShoulderSwingDetector(
        config: const CrossBodyShoulderSwingDetectorConfig(
          cooldown: Duration(milliseconds: 1500),
        ),
        shoulderGather: tracker,
      );

      final base = DateTime(2026, 4, 17, 12);
      final frames = <PoseFrame>[
        _frame(base, leftWristX: 0.46, rightWristX: 0.50),
        _frame(
          base.add(const Duration(milliseconds: 60)),
          leftWristX: 0.56,
          rightWristX: 0.62,
        ),
        _frame(
          base.add(const Duration(milliseconds: 120)),
          leftWristX: 0.64,
          rightWristX: 0.70,
        ),
      ];

      ActionEvent? triggered;
      for (final frame in frames) {
        tracker.observe(frame);
        triggered ??= detector.process(frame);
      }

      expect(triggered, isNull);
    });
  });
}

PoseFrame _frame(
  DateTime timestamp, {
  required double leftWristX,
  required double rightWristX,
  double wristY = 0.47,
}) {
  return PoseFrame(
    timestamp: timestamp,
    landmarks: {
      PoseLandmark.leftShoulder: const PoseLandmarkPoint(
        x: 0.40,
        y: 0.30,
        confidence: 0.95,
      ),
      PoseLandmark.rightShoulder: const PoseLandmarkPoint(
        x: 0.62,
        y: 0.30,
        confidence: 0.95,
      ),
      PoseLandmark.leftHip: const PoseLandmarkPoint(
        x: 0.47,
        y: 0.62,
        confidence: 0.95,
      ),
      PoseLandmark.rightHip: const PoseLandmarkPoint(
        x: 0.55,
        y: 0.62,
        confidence: 0.95,
      ),
      PoseLandmark.leftWrist: PoseLandmarkPoint(
        x: leftWristX,
        y: wristY,
        confidence: 0.95,
      ),
      PoseLandmark.rightWrist: PoseLandmarkPoint(
        x: rightWristX,
        y: wristY - 0.02,
        confidence: 0.95,
      ),
    },
  );
}
