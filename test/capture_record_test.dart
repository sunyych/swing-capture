import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/core/models/capture_record.dart';

void main() {
  test(
    'CaptureRecord map round-trip preserves session and tagging metadata',
    () {
      final now = DateTime.utc(2026, 5, 4, 10, 0, 0);
      final original = CaptureRecord(
        id: 'id-1',
        videoPath: '/tmp/a.mp4',
        thumbnailPath: '/tmp/a.jpg',
        createdAt: now,
        durationMs: 1200,
        albumName: 'MotionCapture',
        videoFps: 59.94,
        poseJsonPath: '/tmp/a.pose.json',
        sessionId: 'session-1',
        clipIndex: 1,
        sessionStatus: CaptureSessionStatus.committed,
        userTag: 'action',
        reviewState: CaptureReviewState.accepted,
        datasetState: CaptureDatasetState.labeled,
        modelLabel: 'forehand',
        modelConfidence: 0.91,
        trainingState: TrainingLifecycleState.queued,
      );

      final parsed = CaptureRecord.fromMap(original.toMap());
      expect(parsed.sessionId, original.sessionId);
      expect(parsed.videoFps, original.videoFps);
      expect(parsed.clipIndex, original.clipIndex);
      expect(parsed.sessionStatus, original.sessionStatus);
      expect(parsed.userTag, original.userTag);
      expect(parsed.reviewState, original.reviewState);
      expect(parsed.datasetState, original.datasetState);
      expect(parsed.modelLabel, original.modelLabel);
      expect(parsed.modelConfidence, original.modelConfidence);
      expect(parsed.trainingState, original.trainingState);
    },
  );
}
