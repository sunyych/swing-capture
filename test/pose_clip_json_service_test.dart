import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/core/models/action_event.dart';
import 'package:swingcapture/features/capture/data/pose_clip_json_service.dart';
import 'package:swingcapture/features/capture/domain/models/pose_frame.dart';

void main() {
  test('builds standardized pose clip payload with event and frames', () {
    const service = PoseClipJsonService();
    final startAt = DateTime.utc(2026, 4, 20, 12, 0, 0);
    final endAt = startAt.add(const Duration(milliseconds: 400));
    final event = ActionEvent(
      label: 'baseball_swing',
      category: 'sports',
      triggeredAt: startAt.add(const Duration(milliseconds: 200)),
      score: 0.91,
      preRollMs: 200,
      postRollMs: 200,
      reason: 'test_event',
    );
    final firstFrame = PoseFrame(
      timestamp: startAt,
      landmarks: const {
        PoseLandmark.leftShoulder: PoseLandmarkPoint(
          x: 0.4,
          y: 0.3,
          confidence: 0.9,
        ),
        PoseLandmark.rightShoulder: PoseLandmarkPoint(
          x: 0.6,
          y: 0.3,
          confidence: 0.9,
        ),
        PoseLandmark.leftHip: PoseLandmarkPoint(
          x: 0.44,
          y: 0.6,
          confidence: 0.9,
        ),
        PoseLandmark.rightHip: PoseLandmarkPoint(
          x: 0.56,
          y: 0.6,
          confidence: 0.9,
        ),
        PoseLandmark.leftWrist: PoseLandmarkPoint(
          x: 0.35,
          y: 0.45,
          confidence: 0.9,
        ),
        PoseLandmark.rightWrist: PoseLandmarkPoint(
          x: 0.65,
          y: 0.45,
          confidence: 0.9,
        ),
      },
    );

    final payload = service.buildPayload(
      clipId: 'clip-123',
      videoPath: '/tmp/swing_clip.mp4',
      capturePipeline: 'flutter_camera_buffer',
      cameraFacing: 'back',
      clipStartAt: startAt,
      clipEndAt: endAt,
      event: event,
      frames: [
        firstFrame,
        PoseFrame(timestamp: endAt, landmarks: const {}),
      ],
    );

    expect(payload['schema'], PoseClipJsonService.schemaId);
    expect(payload['schemaVersion'], 1);
    expect((payload['capture'] as Map<String, dynamic>)['clipId'], 'clip-123');
    expect(
      (payload['capture'] as Map<String, dynamic>)['cameraFacing'],
      'back',
    );
    expect(
      (payload['event'] as Map<String, dynamic>)['label'],
      'baseball_swing',
    );

    final outFrames = payload['frames'] as List<dynamic>;
    expect(outFrames, hasLength(2));
    expect((outFrames.first as Map<String, dynamic>)['hasPose'], isTrue);
    expect((outFrames.last as Map<String, dynamic>)['hasPose'], isFalse);
  });
}
