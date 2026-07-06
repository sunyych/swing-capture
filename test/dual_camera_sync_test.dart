import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:swingcapture/core/models/capture_settings.dart';
import 'package:swingcapture/features/capture/domain/models/dual_camera_sync.dart';
import 'package:swingcapture/features/capture/domain/services/dual_camera_bluetooth_control.dart';
import 'package:swingcapture/features/capture/domain/services/dual_camera_sync_service.dart';

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
        transport: DualCameraTransportMode.bluetoothControl,
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
      expect(peer.transport, DualCameraTransportMode.bluetoothControl);
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

    test('identifies recorder clip upload headers', () {
      final payload = DualCameraProtocol.clipUploadHeaderPayload(
        senderDeviceId: 'recorder-1',
        senderName: 'Recorder',
        swingId: 'swing-1',
        fileName: 'swing-1.mp4',
        fileSizeBytes: 1024,
        preRollMs: 1500,
        postRollMs: 2000,
        sentAt: DateTime.fromMillisecondsSinceEpoch(1200),
        durationMs: 3500,
      );

      expect(DualCameraProtocol.isClipUploadHeader(payload), isTrue);
      expect(payload['type'], 'clip_upload');
      expect(payload['swingId'], 'swing-1');
      expect(payload['fileSizeBytes'], 1024);
    });
  });

  group('DualCameraSyncService bluetooth control', () {
    test(
      'pairs bluetooth recorder peers and sends triggers over bluetooth',
      () async {
        final bluetooth = _FakeBluetoothControl();
        final service = DualCameraSyncService(
          deviceId: 'detector-1',
          deviceName: 'Detector',
          bluetoothControl: bluetooth,
        );
        addTearDown(service.dispose);

        await service.start(
          role: DualCameraRole.detector,
          transportMode: DualCameraTransportMode.bluetoothControl,
          advertisedFps: 120,
        );

        expect(
          service.state.transport,
          DualCameraTransportMode.bluetoothControl,
        );
        expect(bluetooth.startedRole, DualCameraRole.detector);
        expect(
          bluetooth.startedHello?['transport'],
          DualCameraTransportMode.bluetoothControl.wireValue,
        );
        expect(bluetooth.startedHello?['advertisedFps'], 120);

        bluetooth.emit(
          DualCameraBluetoothPeerEvent(
            payload: DualCameraProtocol.helloPayload(
              deviceId: 'recorder-1',
              deviceName: 'Recorder',
              role: DualCameraRole.recorder,
              controlPort: 0,
              sentAt: DateTime.fromMillisecondsSinceEpoch(1000),
              transport: DualCameraTransportMode.bluetoothControl,
              advertisedFps: 60,
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(service.state.recorderPeers, hasLength(1));
        expect(
          service.state.recorderPeers.single.transport,
          DualCameraTransportMode.bluetoothControl,
        );

        final delivered = await service.sendTrigger(
          DualCameraTrigger(
            swingId: 'swing-1',
            triggeredAt: DateTime.fromMillisecondsSinceEpoch(2000),
            preRollMs: 1500,
            postRollMs: 2000,
            score: 0.8,
            modelLabel: 'swing',
          ),
        );

        expect(delivered, 1);
        expect(bluetooth.sentTriggers, hasLength(1));
        expect(bluetooth.sentTriggers.single['type'], 'trigger');
        expect(bluetooth.sentTriggers.single['swingId'], 'swing-1');
      },
    );

    test(
      'delivers incoming bluetooth trigger events to recorder role',
      () async {
        final bluetooth = _FakeBluetoothControl();
        final service = DualCameraSyncService(
          deviceId: 'recorder-1',
          deviceName: 'Recorder',
          bluetoothControl: bluetooth,
        );
        addTearDown(service.dispose);

        await service.start(
          role: DualCameraRole.recorder,
          transportMode: DualCameraTransportMode.bluetoothControl,
          advertisedFps: 60,
        );

        final triggerFuture = service.remoteTriggers.first.timeout(
          const Duration(seconds: 2),
        );
        bluetooth.emit(
          DualCameraBluetoothTriggerEvent(
            payload: DualCameraProtocol.triggerPayload(
              senderDeviceId: 'detector-1',
              senderName: 'Detector',
              trigger: DualCameraTrigger(
                swingId: 'swing-ble',
                triggeredAt: DateTime.fromMillisecondsSinceEpoch(30_000),
                preRollMs: 1200,
                postRollMs: 1800,
                score: 0.93,
                modelLabel: 'swing',
              ),
              sentAt: DateTime.fromMillisecondsSinceEpoch(30_010),
            ),
          ),
        );

        final trigger = await triggerFuture;
        expect(trigger.swingId, 'swing-ble');
        expect(trigger.senderDeviceId, 'detector-1');
        expect(trigger.localTriggeredAt.millisecondsSinceEpoch, 30_000);
        expect(trigger.preRollMs, 1200);
        expect(trigger.postRollMs, 1800);
        expect(trigger.score, 0.93);
        expect(service.state.lastTrigger?.swingId, 'swing-ble');
      },
    );

    test('does not transfer video bytes over bluetooth control', () async {
      final bluetooth = _FakeBluetoothControl();
      final service = DualCameraSyncService(
        deviceId: 'recorder-1',
        deviceName: 'Recorder',
        bluetoothControl: bluetooth,
      );
      addTearDown(service.dispose);
      final temp = await Directory.systemTemp.createTemp(
        'dual_camera_ble_no_clip_transfer_',
      );
      addTearDown(() async {
        await temp.delete(recursive: true);
      });
      final clip = File('${temp.path}/swing.mp4');
      await clip.writeAsBytes([1, 2, 3, 4, 5]);

      await service.start(
        role: DualCameraRole.recorder,
        transportMode: DualCameraTransportMode.bluetoothControl,
        advertisedFps: 120,
      );

      final delivered = await service.sendRecordedClip(
        filePath: clip.path,
        swingId: 'swing-ble',
        preRollMs: 1500,
        postRollMs: 2000,
        durationMs: 3500,
      );

      expect(delivered, 0);
      expect(
        service.state.message,
        'Clip saved. Connect with Wi-Fi to merge videos.',
      );
    });
  });

  group('DualCameraSyncService wifi control and transfer', () {
    test('sends detector trigger to recorder over wifi TCP', () async {
      final detector = DualCameraSyncService(
        deviceId: 'detector-1',
        deviceName: 'Detector',
        discoveryPort: await _availableUdpPort(),
        bluetoothControl: _FakeBluetoothControl(),
      );
      final recorder = DualCameraSyncService(
        deviceId: 'recorder-1',
        deviceName: 'Recorder',
        discoveryPort: await _availableUdpPort(),
        bluetoothControl: _FakeBluetoothControl(),
      );
      addTearDown(() async {
        await detector.dispose();
        await recorder.dispose();
      });

      await recorder.start(
        role: DualCameraRole.recorder,
        transportMode: DualCameraTransportMode.wifi,
        advertisedFps: 60,
      );
      await detector.start(
        role: DualCameraRole.detector,
        transportMode: DualCameraTransportMode.wifi,
        advertisedFps: 120,
      );
      detector.addPeerForTesting(
        _peerForService(
          recorder,
          role: DualCameraRole.recorder,
          clockOffsetMs: 25,
          advertisedFps: 60,
        ),
      );
      recorder.addPeerForTesting(
        _peerForService(
          detector,
          role: DualCameraRole.detector,
          clockOffsetMs: 25,
          advertisedFps: 120,
        ),
      );

      final triggerFuture = recorder.remoteTriggers.first.timeout(
        const Duration(seconds: 2),
      );
      final delivered = await detector.sendTrigger(
        DualCameraTrigger(
          swingId: 'swing-wifi',
          triggeredAt: DateTime.fromMillisecondsSinceEpoch(40_000),
          preRollMs: 1500,
          postRollMs: 2500,
          score: 0.87,
          modelLabel: 'swing',
        ),
      );

      expect(delivered, 1);
      final trigger = await triggerFuture;
      expect(trigger.swingId, 'swing-wifi');
      expect(trigger.senderDeviceId, 'detector-1');
      expect(trigger.localTriggeredAt.millisecondsSinceEpoch, 39_975);
      expect(trigger.preRollMs, 1500);
      expect(trigger.postRollMs, 2500);
      expect(trigger.score, 0.87);
      expect(recorder.state.lastTrigger?.swingId, 'swing-wifi');
    });

    test('uploads recorder clip to detector over wifi TCP', () async {
      final temp = await Directory.systemTemp.createTemp(
        'dual_camera_wifi_clip_transfer_',
      );
      addTearDown(() async {
        await temp.delete(recursive: true);
      });
      final incoming = Directory('${temp.path}/incoming');
      await incoming.create();
      final sourceClip = File('${temp.path}/recorder.mp4');
      final sourceBytes = List<int>.generate(4096, (index) => index % 251);
      await sourceClip.writeAsBytes(sourceBytes);

      final detector = DualCameraSyncService(
        deviceId: 'detector-1',
        deviceName: 'Detector',
        discoveryPort: await _availableUdpPort(),
        bluetoothControl: _FakeBluetoothControl(),
      );
      final recorder = DualCameraSyncService(
        deviceId: 'recorder-1',
        deviceName: 'Recorder',
        discoveryPort: await _availableUdpPort(),
        bluetoothControl: _FakeBluetoothControl(),
      );
      addTearDown(() async {
        await detector.dispose();
        await recorder.dispose();
      });

      await detector.start(
        role: DualCameraRole.detector,
        transportMode: DualCameraTransportMode.wifi,
        advertisedFps: 120,
        incomingClipDirectory: incoming,
      );
      await recorder.start(
        role: DualCameraRole.recorder,
        transportMode: DualCameraTransportMode.wifi,
        advertisedFps: 60,
      );
      recorder.addPeerForTesting(
        _peerForService(
          detector,
          role: DualCameraRole.detector,
          advertisedFps: 120,
        ),
      );

      final clipFuture = detector.remoteClips.first.timeout(
        const Duration(seconds: 2),
      );
      final delivered = await recorder.sendRecordedClip(
        filePath: sourceClip.path,
        swingId: 'swing-wifi',
        preRollMs: 1500,
        postRollMs: 2500,
        durationMs: 4000,
      );

      expect(delivered, 1);
      final clip = await clipFuture;
      expect(clip.swingId, 'swing-wifi');
      expect(clip.senderDeviceId, 'recorder-1');
      expect(clip.senderName, 'Recorder');
      expect(clip.fileSizeBytes, sourceBytes.length);
      expect(clip.preRollMs, 1500);
      expect(clip.postRollMs, 2500);
      expect(clip.durationMs, 4000);
      expect(await File(clip.filePath).readAsBytes(), sourceBytes);
      expect(clip.filePath.startsWith(incoming.path), isTrue);
    });
  });
}

Future<int> _availableUdpPort() async {
  final socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  socket.close();
  return port;
}

DualCameraPeer _peerForService(
  DualCameraSyncService service, {
  required DualCameraRole role,
  int clockOffsetMs = 0,
  int? advertisedFps,
}) {
  return DualCameraPeer(
    deviceId: service.localDeviceId,
    deviceName: service.localDeviceName,
    role: role,
    address: InternetAddress.loopbackIPv4.address,
    controlPort: service.state.controlPort,
    lastSeenAt: DateTime.now(),
    clockOffsetMs: clockOffsetMs,
    transport: DualCameraTransportMode.wifi,
    advertisedFps: advertisedFps,
  );
}

class _FakeBluetoothControl implements DualCameraBluetoothControl {
  final StreamController<DualCameraBluetoothEvent> _events =
      StreamController<DualCameraBluetoothEvent>.broadcast();
  final List<Map<String, Object?>> sentTriggers = <Map<String, Object?>>[];

  DualCameraRole? startedRole;
  Map<String, Object?>? startedHello;
  bool sendTriggerResult = true;

  @override
  Stream<DualCameraBluetoothEvent> get events => _events.stream;

  @override
  Future<void> start({
    required DualCameraRole role,
    required Map<String, Object?> helloPayload,
  }) async {
    startedRole = role;
    startedHello = helloPayload;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<bool> sendTrigger(Map<String, Object?> payload) async {
    sentTriggers.add(payload);
    return sendTriggerResult;
  }

  void emit(DualCameraBluetoothEvent event) {
    _events.add(event);
  }

  @override
  Future<void> dispose() async {
    await _events.close();
  }
}
