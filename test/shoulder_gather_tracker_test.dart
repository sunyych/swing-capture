import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/features/capture/domain/models/pose_frame.dart';
import 'package:swingcapture/features/capture/domain/services/shoulder_gather_tracker.dart';

void main() {
  test('records gather after two consecutive qualifying frames', () {
    final tracker = ShoulderGatherTracker();
    final t = DateTime(2026, 6, 1, 12);
    final f = _frame(
      t,
      leftShoulderX: 0.40,
      rightShoulderX: 0.62,
      leftWristX: 0.38,
      rightWristX: 0.42,
      wristY: 0.36,
    );
    tracker.observe(f);
    expect(tracker.allowsSwingAt(t), isFalse);
    final t1 = t.add(const Duration(milliseconds: 33));
    tracker.observe(
      _frame(
        t1,
        leftShoulderX: 0.40,
        rightShoulderX: 0.62,
        leftWristX: 0.38,
        rightWristX: 0.42,
        wristY: 0.36,
      ),
    );
    expect(tracker.allowsSwingAt(t1), isTrue);
  });

  test('rejects centered / non-near-shoulder pose', () {
    final tracker = ShoulderGatherTracker();
    final t = DateTime(2026, 6, 1, 12);
    final f = _frame(
      t,
      leftShoulderX: 0.40,
      rightShoulderX: 0.60,
      leftWristX: 0.49,
      rightWristX: 0.51,
      wristY: 0.48,
    );
    tracker.observe(f);
    tracker.observe(
      _frame(
        t.add(const Duration(milliseconds: 33)),
        leftShoulderX: 0.40,
        rightShoulderX: 0.60,
        leftWristX: 0.49,
        rightWristX: 0.51,
        wristY: 0.48,
      ),
    );
    expect(tracker.allowsSwingAt(t.add(const Duration(milliseconds: 33))), isFalse);
  });

  test('prunes hits older than lookback', () {
    final tracker = ShoulderGatherTracker(
      config: const ShoulderGatherConfig(lookback: Duration(milliseconds: 100)),
    );
    final t0 = DateTime(2026, 6, 1, 12);
    tracker.observe(
      _frame(
        t0,
        leftShoulderX: 0.40,
        rightShoulderX: 0.62,
        leftWristX: 0.38,
        rightWristX: 0.42,
        wristY: 0.36,
      ),
    );
    tracker.observe(
      _frame(
        t0.add(const Duration(milliseconds: 20)),
        leftShoulderX: 0.40,
        rightShoulderX: 0.62,
        leftWristX: 0.38,
        rightWristX: 0.42,
        wristY: 0.36,
      ),
    );
    expect(tracker.allowsSwingAt(t0.add(const Duration(milliseconds: 20))), isTrue);
    final tLate = t0.add(const Duration(milliseconds: 200));
    tracker.observe(
      _frame(
        tLate,
        leftShoulderX: 0.40,
        rightShoulderX: 0.62,
        leftWristX: 0.49,
        rightWristX: 0.51,
        wristY: 0.48,
      ),
    );
    expect(tracker.allowsSwingAt(tLate), isFalse);
  });

  test('swing not armed when last gather is too old', () {
    final tracker = ShoulderGatherTracker(
      config: const ShoulderGatherConfig(
        lookback: Duration(seconds: 2),
        maxGatherAgeForSwing: Duration(milliseconds: 150),
      ),
    );
    final t0 = DateTime(2026, 6, 1, 12);
    tracker.observe(
      _frame(
        t0,
        leftShoulderX: 0.40,
        rightShoulderX: 0.62,
        leftWristX: 0.38,
        rightWristX: 0.42,
        wristY: 0.36,
      ),
    );
    tracker.observe(
      _frame(
        t0.add(const Duration(milliseconds: 20)),
        leftShoulderX: 0.40,
        rightShoulderX: 0.62,
        leftWristX: 0.38,
        rightWristX: 0.42,
        wristY: 0.36,
      ),
    );
    expect(tracker.allowsSwingAt(t0.add(const Duration(milliseconds: 100))), isTrue);
    expect(tracker.allowsSwingAt(t0.add(const Duration(milliseconds: 500))), isFalse);
  });
}

PoseFrame _frame(
  DateTime timestamp, {
  required double leftShoulderX,
  required double rightShoulderX,
  required double leftWristX,
  required double rightWristX,
  double wristY = 0.47,
}) {
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
