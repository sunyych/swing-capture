import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/core/models/action_event.dart';
import 'package:swingcapture/features/capture/domain/models/pose_frame.dart';
import 'package:swingcapture/features/capture/domain/patterns/action_pattern_catalog.dart';
import 'package:swingcapture/features/capture/domain/services/action_pattern_matcher.dart';

void main() {
  group('ActionPatternMatcher', () {
    test('matches the built-in feet-apart stance pattern from JSON', () {
      final matcher = ActionPatternMatcher(
        definition: ActionPatternCatalog.resolve(
          'feet_apart_stance_v1',
          preRollMs: 300,
          postRollMs: 400,
          cooldownMs: 1500,
        ),
      );

      final base = DateTime(2026, 4, 17, 12);
      final frames = <PoseFrame>[
        _frame(
          base,
          leftAnkleX: 0.33,
          rightAnkleX: 0.69,
          leftHipX: 0.44,
          rightHipX: 0.58,
        ),
        _frame(
          base.add(const Duration(milliseconds: 33)),
          leftAnkleX: 0.332,
          rightAnkleX: 0.688,
          leftHipX: 0.441,
          rightHipX: 0.579,
        ),
        _frame(
          base.add(const Duration(milliseconds: 66)),
          leftAnkleX: 0.331,
          rightAnkleX: 0.689,
          leftHipX: 0.441,
          rightHipX: 0.578,
        ),
        _frame(
          base.add(const Duration(milliseconds: 99)),
          leftAnkleX: 0.332,
          rightAnkleX: 0.688,
          leftHipX: 0.440,
          rightHipX: 0.579,
        ),
      ];

      ActionEvent? triggered;
      for (final frame in frames) {
        triggered ??= matcher.process(frame);
      }

      expect(triggered, isNotNull);
      expect(triggered!.label, 'feet_apart_stance');
      expect(triggered.reason, contains('pattern=feet_apart_stance_v1'));
      expect(
        triggered.windowStartAt,
        base
            .add(const Duration(milliseconds: 99))
            .subtract(const Duration(milliseconds: 300)),
      );
      expect(
        triggered.windowEndAt,
        base
            .add(const Duration(milliseconds: 99))
            .add(const Duration(milliseconds: 400)),
      );
    });

    test('does not trigger on a walking step-through', () {
      final matcher = ActionPatternMatcher(
        definition: ActionPatternCatalog.resolve(
          'feet_apart_stance_v1',
        ),
      );

      final base = DateTime(2026, 4, 17, 12);
      final frames = <PoseFrame>[
        _frame(
          base,
          leftAnkleX: 0.36,
          rightAnkleX: 0.63,
          leftHipX: 0.45,
          rightHipX: 0.57,
        ),
        _frame(
          base.add(const Duration(milliseconds: 33)),
          leftAnkleX: 0.30,
          rightAnkleX: 0.70,
          leftHipX: 0.47,
          rightHipX: 0.59,
        ),
        _frame(
          base.add(const Duration(milliseconds: 66)),
          leftAnkleX: 0.38,
          rightAnkleX: 0.66,
          leftHipX: 0.50,
          rightHipX: 0.62,
        ),
        _frame(
          base.add(const Duration(milliseconds: 99)),
          leftAnkleX: 0.34,
          rightAnkleX: 0.69,
          leftHipX: 0.53,
          rightHipX: 0.65,
        ),
      ];

      ActionEvent? triggered;
      for (final frame in frames) {
        triggered ??= matcher.process(frame);
      }

      expect(triggered, isNull);
    });

    test('parses and runs a custom JSON pattern', () {
      const customJson = '''
{
  "id": "custom_cross_body",
  "name": "Custom Cross-Body",
  "label": "custom_swing",
  "category": "training",
  "preRollMs": 250,
  "postRollMs": 350,
  "cooldownMs": 1200,
  "stages": [
    {
      "id": "load_side",
      "type": "hands_cluster_near_shoulder_side",
      "params": {
        "minLandmarkConfidence": 0.4,
        "nearShoulderSpanFactor": 0.55,
        "midlineSlackSpanFactor": 0.12,
        "minConsecutiveFrames": 2
      }
    },
    {
      "id": "cross_body",
      "type": "cross_body_travel",
      "fromStage": "load_side",
      "params": {
        "minLandmarkConfidence": 0.35,
        "wristCarryTtlMs": 240,
        "minTransitionMs": 40,
        "maxTransitionMs": 900,
        "minTravelSpanFactor": 0.74,
        "crossMidlineSlackSpanFactor": 0.10,
        "minAverageCrossSpeed": 0.52,
        "minBurstLateralSpeed": 0.82
      }
    }
  ]
}
''';
      final matcher = ActionPatternMatcher(
        definition: ActionPatternCatalog.resolve(
          ActionPatternCatalog.customJsonPatternId,
          customJson: customJson,
        ),
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
        triggered ??= matcher.process(frame);
      }

      expect(triggered, isNotNull);
      expect(triggered!.label, 'custom_swing');
      expect(triggered.category, 'training');
      expect(
        triggered.windowStartAt,
        base
            .add(const Duration(milliseconds: 40))
            .subtract(const Duration(milliseconds: 250)),
      );
      expect(
        triggered.windowEndAt,
        base
            .add(const Duration(milliseconds: 160))
            .add(const Duration(milliseconds: 350)),
      );
    });
  });
}

PoseFrame _frame(
  DateTime timestamp, {
  double leftWristX = 0.39,
  double rightWristX = 0.43,
  double wristY = 0.47,
  double leftHipX = 0.47,
  double rightHipX = 0.55,
  double leftAnkleX = 0.43,
  double rightAnkleX = 0.59,
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
      PoseLandmark.leftHip: PoseLandmarkPoint(
        x: leftHipX,
        y: 0.62,
        confidence: 0.95,
      ),
      PoseLandmark.rightHip: PoseLandmarkPoint(
        x: rightHipX,
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
      PoseLandmark.leftAnkle: PoseLandmarkPoint(
        x: leftAnkleX,
        y: 0.92,
        confidence: 0.95,
      ),
      PoseLandmark.rightAnkle: PoseLandmarkPoint(
        x: rightAnkleX,
        y: 0.92,
        confidence: 0.95,
      ),
    },
  );
}
