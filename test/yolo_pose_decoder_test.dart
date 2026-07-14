import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/features/capture/data/yolo_pose_decoder.dart';
import 'package:swingcapture/features/capture/domain/models/pose_frame.dart';
import 'package:swingcapture/features/capture/domain/services/target_pose_selector.dart';

void main() {
  test('decodes channel-first YOLO pose output into multiple candidates', () {
    const decoder = YoloPoseDecoder();
    final timestamp = DateTime.utc(2026, 7, 6, 12);
    final rows = [
      _poseRow(centerX: 320, centerY: 330, confidence: 0.72),
      _poseRow(centerX: 90, centerY: 330, confidence: 0.94),
    ];
    final output = [
      [
        for (var attr = 0; attr < rows.first.length; attr++)
          [for (final row in rows) row[attr]],
      ],
    ];

    final candidates = decoder.decode(output: output, timestamp: timestamp);

    expect(candidates, hasLength(2));
    expect(candidates.first.source, PoseFrameSource.yolo);
    expect(candidates.first.landmarks[PoseLandmark.leftShoulder], isNotNull);
    expect(candidates.first.landmarks[PoseLandmark.rightAnkle], isNotNull);
  });

  test('runs nms and keeps separated people', () {
    const decoder = YoloPoseDecoder();
    final timestamp = DateTime.utc(2026, 7, 6, 12);
    final candidates = decoder.decode(
      output: [
        _poseRow(centerX: 320, centerY: 330, confidence: 0.91),
        _poseRow(centerX: 326, centerY: 334, confidence: 0.75),
        _poseRow(centerX: 110, centerY: 330, confidence: 0.82),
      ],
      timestamp: timestamp,
    );

    expect(candidates, hasLength(2));
    expect(candidates.map((candidate) => candidate.confidence), [0.91, 0.82]);
  });

  test('target selector prefers centered hitter over side bystander', () {
    const decoder = YoloPoseDecoder();
    final selector = TargetPoseSelector();
    final timestamp = DateTime.utc(2026, 7, 6, 12);
    final candidates = decoder.decode(
      output: [
        _poseRow(centerX: 85, centerY: 330, confidence: 0.96),
        _poseRow(centerX: 320, centerY: 330, confidence: 0.70),
      ],
      timestamp: timestamp,
    );

    final selected = selector.select(candidates);

    expect(selected, isNotNull);
    expect(selected!.candidate.bounds.centerX, closeTo(0.5, 0.01));
    expect(selected.reason, contains('center_target'));
    final frame = selected.candidate.toPoseFrame(
      candidateCount: candidates.length,
      selectionScore: selected.score,
      selectionReason: selected.reason,
    );
    expect(frame.source, PoseFrameSource.yolo);
    expect(frame.candidateCount, 2);
    expect(frame.selectionReason, contains('center_target'));
  });

  test('supports xyxy box output format', () {
    const decoder = YoloPoseDecoder(
      config: YoloPoseDecoderConfig(boxFormat: YoloPoseBoxFormat.xyxy),
    );
    final row = _poseRow(centerX: 320, centerY: 330, confidence: 0.81);
    row[0] = 240;
    row[1] = 160;
    row[2] = 400;
    row[3] = 500;

    final candidates = decoder.decode(
      output: [row],
      timestamp: DateTime.utc(2026, 7, 6, 12),
    );

    expect(candidates.single.bounds.left, closeTo(0.375, 0.001));
    expect(candidates.single.bounds.right, closeTo(0.625, 0.001));
  });
}

List<double> _poseRow({
  required double centerX,
  required double centerY,
  required double confidence,
}) {
  const width = 170.0;
  const height = 340.0;
  final row = List<double>.filled(56, 0);
  row[0] = centerX;
  row[1] = centerY;
  row[2] = width;
  row[3] = height;
  row[4] = confidence;

  void keypoint(int index, double x, double y, [double score = 0.92]) {
    final offset = 5 + index * 3;
    row[offset] = x;
    row[offset + 1] = y;
    row[offset + 2] = score;
  }

  keypoint(0, centerX, centerY - 150);
  keypoint(5, centerX - 45, centerY - 80);
  keypoint(6, centerX + 45, centerY - 80);
  keypoint(7, centerX - 70, centerY - 20);
  keypoint(8, centerX + 70, centerY - 20);
  keypoint(9, centerX - 82, centerY + 40);
  keypoint(10, centerX + 82, centerY + 40);
  keypoint(11, centerX - 35, centerY + 55);
  keypoint(12, centerX + 35, centerY + 55);
  keypoint(13, centerX - 42, centerY + 135);
  keypoint(14, centerX + 42, centerY + 135);
  keypoint(15, centerX - 45, centerY + 185);
  keypoint(16, centerX + 45, centerY + 185);
  return row;
}
