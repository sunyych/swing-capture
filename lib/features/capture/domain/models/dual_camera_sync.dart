import '../../../../core/models/capture_settings.dart';

const int dualCameraSyncProtocolVersion = 1;
const String dualCameraSyncAppId = 'swingcapture';
const int dualCameraSyncDiscoveryPort = 45761;

class DualCameraPeer {
  const DualCameraPeer({
    required this.deviceId,
    required this.deviceName,
    required this.role,
    required this.address,
    required this.controlPort,
    required this.lastSeenAt,
    required this.clockOffsetMs,
    this.advertisedFps,
  });

  final String deviceId;
  final String deviceName;
  final DualCameraRole role;
  final String address;
  final int controlPort;
  final DateTime lastSeenAt;

  /// Approximate remote wall-clock minus local wall-clock.
  final int clockOffsetMs;
  final int? advertisedFps;

  bool get canReceiveTriggers =>
      role == DualCameraRole.recorder && controlPort > 0;

  DualCameraPeer copyWith({
    String? deviceName,
    DualCameraRole? role,
    String? address,
    int? controlPort,
    DateTime? lastSeenAt,
    int? clockOffsetMs,
    int? advertisedFps,
  }) {
    return DualCameraPeer(
      deviceId: deviceId,
      deviceName: deviceName ?? this.deviceName,
      role: role ?? this.role,
      address: address ?? this.address,
      controlPort: controlPort ?? this.controlPort,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      clockOffsetMs: clockOffsetMs ?? this.clockOffsetMs,
      advertisedFps: advertisedFps ?? this.advertisedFps,
    );
  }
}

class DualCameraTrigger {
  const DualCameraTrigger({
    required this.swingId,
    required this.triggeredAt,
    required this.preRollMs,
    required this.postRollMs,
    required this.score,
    required this.modelLabel,
  });

  final String swingId;
  final DateTime triggeredAt;
  final int preRollMs;
  final int postRollMs;
  final double score;
  final String modelLabel;
}

class RemoteSwingTrigger {
  const RemoteSwingTrigger({
    required this.swingId,
    required this.senderDeviceId,
    required this.senderName,
    required this.localTriggeredAt,
    required this.preRollMs,
    required this.postRollMs,
    required this.score,
    required this.modelLabel,
    required this.receivedAt,
  });

  final String swingId;
  final String senderDeviceId;
  final String senderName;
  final DateTime localTriggeredAt;
  final int preRollMs;
  final int postRollMs;
  final double score;
  final String modelLabel;
  final DateTime receivedAt;
}

class DualCameraSyncState {
  const DualCameraSyncState({
    required this.role,
    required this.isRunning,
    required this.localDeviceId,
    required this.localDeviceName,
    required this.controlPort,
    required this.peers,
    required this.message,
    this.lastTrigger,
  });

  factory DualCameraSyncState.initial({
    String localDeviceId = '',
    String localDeviceName = '',
  }) {
    return DualCameraSyncState(
      role: DualCameraRole.disabled,
      isRunning: false,
      localDeviceId: localDeviceId,
      localDeviceName: localDeviceName,
      controlPort: 0,
      peers: const [],
      message: 'Dual camera is off.',
    );
  }

  final DualCameraRole role;
  final bool isRunning;
  final String localDeviceId;
  final String localDeviceName;
  final int controlPort;
  final List<DualCameraPeer> peers;
  final String message;
  final RemoteSwingTrigger? lastTrigger;

  List<DualCameraPeer> get recorderPeers =>
      peers.where((peer) => peer.role == DualCameraRole.recorder).toList();

  DualCameraSyncState copyWith({
    DualCameraRole? role,
    bool? isRunning,
    String? localDeviceId,
    String? localDeviceName,
    int? controlPort,
    List<DualCameraPeer>? peers,
    String? message,
    RemoteSwingTrigger? lastTrigger,
  }) {
    return DualCameraSyncState(
      role: role ?? this.role,
      isRunning: isRunning ?? this.isRunning,
      localDeviceId: localDeviceId ?? this.localDeviceId,
      localDeviceName: localDeviceName ?? this.localDeviceName,
      controlPort: controlPort ?? this.controlPort,
      peers: peers ?? this.peers,
      message: message ?? this.message,
      lastTrigger: lastTrigger ?? this.lastTrigger,
    );
  }
}

class DualCameraProtocol {
  const DualCameraProtocol._();

  static Map<String, Object?> helloPayload({
    required String deviceId,
    required String deviceName,
    required DualCameraRole role,
    required int controlPort,
    required DateTime sentAt,
    int? advertisedFps,
  }) {
    return {
      'app': dualCameraSyncAppId,
      'version': dualCameraSyncProtocolVersion,
      'type': 'hello',
      'deviceId': deviceId,
      'deviceName': deviceName,
      'role': role.wireValue,
      'controlPort': controlPort,
      'sentAtEpochMs': sentAt.millisecondsSinceEpoch,
      if (advertisedFps != null) 'advertisedFps': advertisedFps,
    };
  }

  static DualCameraPeer? peerFromHelloPayload({
    required Map<String, Object?> payload,
    required String address,
    required DateTime receivedAt,
    required String localDeviceId,
  }) {
    if (payload['app'] != dualCameraSyncAppId ||
        payload['type'] != 'hello' ||
        payload['version'] != dualCameraSyncProtocolVersion) {
      return null;
    }
    final deviceId = payload['deviceId'] as String?;
    if (deviceId == null || deviceId.isEmpty || deviceId == localDeviceId) {
      return null;
    }
    final role = dualCameraRoleFromWire(payload['role'] as String?);
    if (!role.isActive) {
      return null;
    }
    final remoteSentAt = (payload['sentAtEpochMs'] as num?)?.toInt();
    final clockOffsetMs = remoteSentAt == null
        ? 0
        : remoteSentAt - receivedAt.millisecondsSinceEpoch;
    return DualCameraPeer(
      deviceId: deviceId,
      deviceName: payload['deviceName'] as String? ?? 'SwingCapture phone',
      role: role,
      address: address,
      controlPort: (payload['controlPort'] as num?)?.toInt() ?? 0,
      lastSeenAt: receivedAt,
      clockOffsetMs: clockOffsetMs,
      advertisedFps: (payload['advertisedFps'] as num?)?.toInt(),
    );
  }

  static Map<String, Object?> triggerPayload({
    required String senderDeviceId,
    required String senderName,
    required DualCameraTrigger trigger,
    required DateTime sentAt,
  }) {
    return {
      'app': dualCameraSyncAppId,
      'version': dualCameraSyncProtocolVersion,
      'type': 'trigger',
      'senderDeviceId': senderDeviceId,
      'senderName': senderName,
      'swingId': trigger.swingId,
      'triggerEpochMs': trigger.triggeredAt.millisecondsSinceEpoch,
      'preRollMs': trigger.preRollMs,
      'postRollMs': trigger.postRollMs,
      'score': trigger.score,
      'modelLabel': trigger.modelLabel,
      'sentAtEpochMs': sentAt.millisecondsSinceEpoch,
    };
  }

  static RemoteSwingTrigger? remoteTriggerFromPayload({
    required Map<String, Object?> payload,
    required DateTime receivedAt,
    DualCameraPeer? peer,
  }) {
    if (payload['app'] != dualCameraSyncAppId ||
        payload['type'] != 'trigger' ||
        payload['version'] != dualCameraSyncProtocolVersion) {
      return null;
    }
    final swingId = payload['swingId'] as String?;
    final remoteTriggerEpochMs = (payload['triggerEpochMs'] as num?)?.toInt();
    if (swingId == null || swingId.isEmpty || remoteTriggerEpochMs == null) {
      return null;
    }
    final localTriggerEpochMs =
        remoteTriggerEpochMs - (peer?.clockOffsetMs ?? 0);
    return RemoteSwingTrigger(
      swingId: swingId,
      senderDeviceId: payload['senderDeviceId'] as String? ?? '',
      senderName:
          payload['senderName'] as String? ?? peer?.deviceName ?? 'Detector',
      localTriggeredAt: DateTime.fromMillisecondsSinceEpoch(
        localTriggerEpochMs,
      ),
      preRollMs: (payload['preRollMs'] as num?)?.toInt() ?? 2000,
      postRollMs: (payload['postRollMs'] as num?)?.toInt() ?? 2000,
      score: ((payload['score'] as num?)?.toDouble() ?? 1)
          .clamp(0, 1)
          .toDouble(),
      modelLabel: payload['modelLabel'] as String? ?? 'remote_swing',
      receivedAt: receivedAt,
    );
  }
}
