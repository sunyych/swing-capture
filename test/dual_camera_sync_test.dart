import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/core/models/capture_settings.dart';
import 'package:swingcapture/features/capture/domain/models/dual_camera_sync.dart';

void main() {
  group('DualCameraProtocol', () {
    test('parses hello payload and estimates remote clock offset', () {
      final receivedAt = DateTime.fromMillisecondsSinceEpoch(10_000);
      final payload = DualCameraProtocol.helloPayload(
        deviceId: 'detector-1',
        deviceName: 'Detector phone',
        role: DualCameraRole.detector,
        controlPort: 50123,
        sentAt: DateTime.fromMillisecondsSinceEpoch(10_125),
        advertisedFps: 240,
      );

      final peer = DualCameraProtocol.peerFromHelloPayload(
        payload: payload,
        address: '192.168.1.20',
        receivedAt: receivedAt,
        localDeviceId: 'recorder-1',
      );

      expect(peer, isNotNull);
      expect(peer!.deviceId, 'detector-1');
      expect(peer.role, DualCameraRole.detector);
      expect(peer.controlPort, 50123);
      expect(peer.clockOffsetMs, 125);
      expect(peer.advertisedFps, 240);
    });

    test('ignores self hello payload', () {
      final payload = DualCameraProtocol.helloPayload(
        deviceId: 'same-phone',
        deviceName: 'Same phone',
        role: DualCameraRole.recorder,
        controlPort: 50123,
        sentAt: DateTime.fromMillisecondsSinceEpoch(10_000),
      );

      final peer = DualCameraProtocol.peerFromHelloPayload(
        payload: payload,
        address: '192.168.1.20',
        receivedAt: DateTime.fromMillisecondsSinceEpoch(10_000),
        localDeviceId: 'same-phone',
      );

      expect(peer, isNull);
    });

    test('converts remote trigger time into local clock domain', () {
      final peer = DualCameraPeer(
        deviceId: 'detector-1',
        deviceName: 'Detector phone',
        role: DualCameraRole.detector,
        address: '192.168.1.20',
        controlPort: 50123,
        lastSeenAt: DateTime.fromMillisecondsSinceEpoch(10_000),
        clockOffsetMs: 125,
      );
      final trigger = DualCameraTrigger(
        swingId: 'swing-1',
        triggeredAt: DateTime.fromMillisecondsSinceEpoch(20_000),
        preRollMs: 1800,
        postRollMs: 2200,
        score: 0.91,
        modelLabel: 'baseball_swing',
      );
      final payload = DualCameraProtocol.triggerPayload(
        senderDeviceId: peer.deviceId,
        senderName: peer.deviceName,
        trigger: trigger,
        sentAt: DateTime.fromMillisecondsSinceEpoch(20_050),
      );

      final remote = DualCameraProtocol.remoteTriggerFromPayload(
        payload: payload,
        receivedAt: DateTime.fromMillisecondsSinceEpoch(20_090),
        peer: peer,
      );

      expect(remote, isNotNull);
      expect(remote!.swingId, 'swing-1');
      expect(remote.localTriggeredAt.millisecondsSinceEpoch, 19_875);
      expect(remote.preRollMs, 1800);
      expect(remote.postRollMs, 2200);
      expect(remote.score, 0.91);
      expect(remote.modelLabel, 'baseball_swing');
    });
  });
}
