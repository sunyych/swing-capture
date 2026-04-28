import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/core/models/action_event.dart';
import 'package:swingcapture/features/capture/domain/models/pose_frame.dart';
import 'package:swingcapture/features/capture/domain/services/lateral_burst_swing_detector.dart';
import 'package:swingcapture/features/capture/domain/services/shoulder_gather_tracker.dart';

void main() {
  group('LateralWristBurstSwingDetector', () {
    test('triggers on a left-to-right wrist burst', () {
      final detector = LateralWristBurstSwingDetector(
        config: const LateralWristBurstDetectorConfig(
          cooldown: Duration(milliseconds: 1500),
        ),
      );

      final base = DateTime(2026, 4, 17, 12);
      final frames = _lateralSweep(
        base: base,
        startLeft: 0.20,
        startRight: 0.30,
        endLeft: 0.74,
        endRight: 0.84,
        steps: 6,
        stepMs: 60,
      );

      ActionEvent? triggered;
      for (final frame in frames) {
        triggered ??= detector.process(frame);
      }

      expect(triggered, isNotNull);
      expect(triggered!.label, 'baseball_swing');
      expect(triggered.reason, contains('left_to_right'));
    });

    test('triggers on a right-to-left wrist burst', () {
      final detector = LateralWristBurstSwingDetector(
        config: const LateralWristBurstDetectorConfig(
          cooldown: Duration(milliseconds: 1500),
        ),
      );

      final base = DateTime(2026, 4, 17, 12);
      final frames = _lateralSweep(
        base: base,
        startLeft: 0.74,
        startRight: 0.84,
        endLeft: 0.20,
        endRight: 0.30,
        steps: 6,
        stepMs: 60,
      );

      ActionEvent? triggered;
      for (final frame in frames) {
        triggered ??= detector.process(frame);
      }

      expect(triggered, isNotNull);
      expect(triggered!.reason, contains('right_to_left'));
    });

    test('triggers when one wrist briefly drops below visibility mid-sweep',
        () {
      final detector = LateralWristBurstSwingDetector(
        config: const LateralWristBurstDetectorConfig(
          cooldown: Duration(milliseconds: 1500),
        ),
      );

      final base = DateTime(2026, 4, 17, 12);
      final frames = _lateralSweep(
        base: base,
        startLeft: 0.20,
        startRight: 0.30,
        endLeft: 0.74,
        endRight: 0.84,
        steps: 6,
        stepMs: 60,
      );
      // Frame index 2: right wrist flickers low-confidence (common on device).
      final patched = <PoseFrame>[];
      for (var i = 0; i < frames.length; i++) {
        final f = frames[i];
        if (i != 2) {
          patched.add(f);
          continue;
        }
        final m = Map<PoseLandmark, PoseLandmarkPoint>.from(f.landmarks);
        final rw = m[PoseLandmark.rightWrist]!;
        m[PoseLandmark.rightWrist] = PoseLandmarkPoint(
          x: rw.x,
          y: rw.y,
          confidence: 0.12,
        );
        patched.add(PoseFrame(timestamp: f.timestamp, landmarks: m));
      }

      ActionEvent? triggered;
      for (final frame in patched) {
        triggered ??= detector.process(frame);
      }

      expect(triggered, isNotNull);
      expect(triggered!.reason, contains('both_hands'));
    });

    test('triggers on single-arm (left) lateral burst when right wrist weak',
        () {
      final detector = LateralWristBurstSwingDetector(
        config: const LateralWristBurstDetectorConfig(
          cooldown: Duration(milliseconds: 1500),
        ),
      );

      final base = DateTime(2026, 4, 17, 12);
      final frames = <PoseFrame>[];
      const steps = 6;
      const stepMs = 60;
      for (var i = 0; i < steps; i++) {
        final t = i / (steps - 1);
        frames.add(
          _frameSingleLeadHand(
            timestamp: base.add(Duration(milliseconds: stepMs * i)),
            leftWristX: 0.20 + 0.54 * t,
            rightWristX: 0.52,
            rightConfidence: 0.15,
          ),
        );
      }

      ActionEvent? triggered;
      for (final frame in frames) {
        triggered ??= detector.process(frame);
      }

      expect(triggered, isNotNull);
      expect(triggered!.reason, contains('left_hand_only'));
      expect(triggered.reason, contains('left_to_right'));
    });

    test('does not trigger on idle jitter', () {
      final detector = LateralWristBurstSwingDetector(
        config: const LateralWristBurstDetectorConfig(
          cooldown: Duration(milliseconds: 1500),
        ),
      );

      final base = DateTime(2026, 4, 17, 12);
      final jitter = <(double, double)>[
        (0.45, 0.55),
        (0.46, 0.54),
        (0.44, 0.56),
        (0.45, 0.55),
        (0.46, 0.55),
        (0.45, 0.56),
        (0.45, 0.54),
        (0.46, 0.55),
      ];
      var triggered = false;
      for (var i = 0; i < jitter.length; i++) {
        final frame = _frame(
          timestamp: base.add(Duration(milliseconds: 60 * i)),
          leftWristX: jitter[i].$1,
          rightWristX: jitter[i].$2,
        );
        if (detector.process(frame) != null) {
          triggered = true;
        }
      }

      expect(triggered, isFalse);
    });

    test('does not trigger when shoulder gather is required but absent', () {
      final gather = ShoulderGatherTracker();
      final detector = LateralWristBurstSwingDetector(
        config: const LateralWristBurstDetectorConfig(
          cooldown: Duration(milliseconds: 1500),
        ),
        shoulderGather: gather,
      );

      final base = DateTime(2026, 4, 17, 12);
      final frames = _lateralSweep(
        base: base,
        startLeft: 0.20,
        startRight: 0.30,
        endLeft: 0.74,
        endRight: 0.84,
        steps: 6,
        stepMs: 60,
      );

      ActionEvent? triggered;
      for (final frame in frames) {
        triggered ??= detector.process(frame);
      }

      expect(triggered, isNull);
    });

    test('triggers with shoulder gather preface when tracker attached', () {
      final gather = ShoulderGatherTracker();
      final detector = LateralWristBurstSwingDetector(
        config: const LateralWristBurstDetectorConfig(
          cooldown: Duration(milliseconds: 1500),
        ),
        shoulderGather: gather,
      );

      final base = DateTime(2026, 4, 17, 12);
      final gatherFrame = _gatherLoadFrame(base);
      gather.observe(gatherFrame);
      gather.observe(
        _gatherLoadFrame(base.add(const Duration(milliseconds: 33))),
      );
      final frames = _lateralSweep(
        base: base.add(const Duration(milliseconds: 50)),
        startLeft: 0.20,
        startRight: 0.30,
        endLeft: 0.74,
        endRight: 0.84,
        steps: 6,
        stepMs: 60,
      );

      ActionEvent? triggered;
      for (final frame in frames) {
        triggered ??= detector.process(frame);
      }

      expect(triggered, isNotNull);
    });

    test('respects cooldown between bursts', () {
      final detector = LateralWristBurstSwingDetector(
        config: const LateralWristBurstDetectorConfig(
          cooldown: Duration(seconds: 2),
        ),
      );

      final base = DateTime(2026, 4, 17, 12);
      final firstSweep = _lateralSweep(
        base: base,
        startLeft: 0.20,
        startRight: 0.30,
        endLeft: 0.74,
        endRight: 0.84,
        steps: 6,
        stepMs: 60,
      );

      ActionEvent? first;
      for (final frame in firstSweep) {
        first ??= detector.process(frame);
      }
      expect(first, isNotNull);

      // Issue another lateral burst 500 ms after the first peak — well inside
      // the cooldown — and confirm it stays suppressed.
      final followUp = _lateralSweep(
        base: base.add(const Duration(milliseconds: 500)),
        startLeft: 0.74,
        startRight: 0.84,
        endLeft: 0.20,
        endRight: 0.30,
        steps: 6,
        stepMs: 60,
      );
      ActionEvent? second;
      for (final frame in followUp) {
        second ??= detector.process(frame);
      }
      expect(second, isNull);
    });
  });
}

List<PoseFrame> _lateralSweep({
  required DateTime base,
  required double startLeft,
  required double startRight,
  required double endLeft,
  required double endRight,
  required int steps,
  required int stepMs,
}) {
  final frames = <PoseFrame>[];
  for (var i = 0; i < steps; i++) {
    final t = i / (steps - 1);
    frames.add(
      _frame(
        timestamp: base.add(Duration(milliseconds: stepMs * i)),
        leftWristX: startLeft + (endLeft - startLeft) * t,
        rightWristX: startRight + (endRight - startRight) * t,
      ),
    );
  }
  return frames;
}

PoseFrame _frame({
  required DateTime timestamp,
  required double leftWristX,
  required double rightWristX,
}) {
  return PoseFrame(
    timestamp: timestamp,
    landmarks: {
      PoseLandmark.leftShoulder: const PoseLandmarkPoint(
        x: 0.45,
        y: 0.30,
        confidence: 0.95,
      ),
      PoseLandmark.rightShoulder: const PoseLandmarkPoint(
        x: 0.55,
        y: 0.30,
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
        y: 0.45,
        confidence: 0.95,
      ),
    },
  );
}

/// Hands on the left side of the torso midline, close to the left shoulder.
PoseFrame _gatherLoadFrame(DateTime timestamp) {
  return PoseFrame(
    timestamp: timestamp,
    landmarks: {
      PoseLandmark.leftShoulder: const PoseLandmarkPoint(
        x: 0.40,
        y: 0.30,
        confidence: 0.95,
      ),
      PoseLandmark.rightShoulder: const PoseLandmarkPoint(
        x: 0.60,
        y: 0.30,
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
      PoseLandmark.leftWrist: const PoseLandmarkPoint(
        x: 0.38,
        y: 0.36,
        confidence: 0.95,
      ),
      PoseLandmark.rightWrist: const PoseLandmarkPoint(
        x: 0.42,
        y: 0.36,
        confidence: 0.95,
      ),
    },
  );
}

PoseFrame _frameSingleLeadHand({
  required DateTime timestamp,
  required double leftWristX,
  required double rightWristX,
  required double rightConfidence,
}) {
  return PoseFrame(
    timestamp: timestamp,
    landmarks: {
      PoseLandmark.leftShoulder: const PoseLandmarkPoint(
        x: 0.45,
        y: 0.30,
        confidence: 0.95,
      ),
      PoseLandmark.rightShoulder: const PoseLandmarkPoint(
        x: 0.55,
        y: 0.30,
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
        y: 0.45,
        confidence: rightConfidence,
      ),
    },
  );
}
