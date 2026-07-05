import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../../../core/models/capture_settings.dart';
import '../models/dual_camera_sync.dart';

class DualCameraSyncService {
  DualCameraSyncService({
    String? deviceName,
    String? deviceId,
    this.discoveryPort = dualCameraSyncDiscoveryPort,
  }) : localDeviceName = _sanitizeDeviceName(deviceName),
       localDeviceId = deviceId ?? _newDeviceId() {
    _state = DualCameraSyncState.initial(
      localDeviceId: localDeviceId,
      localDeviceName: localDeviceName,
    );
  }

  final String localDeviceId;
  final String localDeviceName;
  final int discoveryPort;

  late DualCameraSyncState _state;
  RawDatagramSocket? _udpSocket;
  ServerSocket? _serverSocket;
  Timer? _announceTimer;
  Timer? _pruneTimer;
  int? _advertisedFps;
  final Map<String, DualCameraPeer> _peers = <String, DualCameraPeer>{};

  final StreamController<DualCameraSyncState> _stateController =
      StreamController<DualCameraSyncState>.broadcast();
  final StreamController<RemoteSwingTrigger> _triggerController =
      StreamController<RemoteSwingTrigger>.broadcast();

  Stream<DualCameraSyncState> get states => _stateController.stream;
  Stream<RemoteSwingTrigger> get remoteTriggers => _triggerController.stream;
  DualCameraSyncState get state => _state;

  Future<void> start({required DualCameraRole role, int? advertisedFps}) async {
    _advertisedFps = advertisedFps;
    if (!role.isActive) {
      await stop();
      return;
    }

    if (_state.isRunning && _state.role == role) {
      _emitState(message: _messageFor(role));
      _announce();
      return;
    }

    await stop();
    try {
      _serverSocket = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        0,
        shared: true,
      );
      _serverSocket!.listen(
        _handleControlSocket,
        onError: (_) => _emitState(message: 'Dual camera control failed.'),
      );

      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
        reusePort: true,
      );
      _udpSocket!
        ..broadcastEnabled = true
        ..listen(_handleUdpEvent);

      _emitState(
        role: role,
        isRunning: true,
        controlPort: _serverSocket!.port,
        peers: const [],
        message: _messageFor(role),
      );
      _announce();
      _announceTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _announce(),
      );
      _pruneTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _prunePeers(),
      );
    } catch (error) {
      await stop();
      _emitState(
        role: role,
        isRunning: false,
        message: 'Dual camera network unavailable.',
      );
    }
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _pruneTimer?.cancel();
    _announceTimer = null;
    _pruneTimer = null;
    _udpSocket?.close();
    _udpSocket = null;
    await _serverSocket?.close();
    _serverSocket = null;
    _peers.clear();
    _emitState(
      role: DualCameraRole.disabled,
      isRunning: false,
      controlPort: 0,
      peers: const [],
      message: 'Dual camera is off.',
    );
  }

  Future<int> sendTrigger(DualCameraTrigger trigger) async {
    if (!_state.isRunning || _state.role != DualCameraRole.detector) {
      return 0;
    }
    final peers = _peers.values
        .where((peer) => peer.canReceiveTriggers)
        .toList(growable: false);
    if (peers.isEmpty) {
      _emitState(message: 'No recorder phone paired yet.');
      return 0;
    }

    final payload = DualCameraProtocol.triggerPayload(
      senderDeviceId: localDeviceId,
      senderName: localDeviceName,
      trigger: trigger,
      sentAt: DateTime.now(),
    );
    final line = '${jsonEncode(payload)}\n';
    var delivered = 0;
    for (final peer in peers) {
      try {
        final socket = await Socket.connect(
          peer.address,
          peer.controlPort,
          timeout: const Duration(milliseconds: 600),
        );
        socket.write(line);
        await socket.flush();
        await socket.close();
        delivered += 1;
      } catch (_) {
        // Peer will be pruned by the hello timeout if it is gone.
      }
    }
    _emitState(
      message: delivered == 0
          ? 'Recorder phone did not receive trigger.'
          : 'Trigger sent to $delivered recorder phone(s).',
    );
    return delivered;
  }

  Future<void> dispose() async {
    await stop();
    await _stateController.close();
    await _triggerController.close();
  }

  void _handleUdpEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }
    final datagram = _udpSocket?.receive();
    if (datagram == null) {
      return;
    }
    try {
      final decoded = jsonDecode(utf8.decode(datagram.data));
      if (decoded is! Map) {
        return;
      }
      final peer = DualCameraProtocol.peerFromHelloPayload(
        payload: decoded.cast<String, Object?>(),
        address: datagram.address.address,
        receivedAt: DateTime.now(),
        localDeviceId: localDeviceId,
      );
      if (peer == null) {
        return;
      }
      _peers[peer.deviceId] = peer;
      _emitState(peers: _sortedPeers(), message: _messageFor(_state.role));
    } catch (_) {
      // Ignore unrelated LAN traffic.
    }
  }

  void _handleControlSocket(Socket socket) {
    final remoteAddress = socket.remoteAddress.address;
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            try {
              final decoded = jsonDecode(line);
              if (decoded is! Map) {
                return;
              }
              final peer = _peerForTrigger(
                decoded.cast<String, Object?>(),
                remoteAddress,
              );
              final trigger = DualCameraProtocol.remoteTriggerFromPayload(
                payload: decoded.cast<String, Object?>(),
                receivedAt: DateTime.now(),
                peer: peer,
              );
              if (trigger == null) {
                return;
              }
              _triggerController.add(trigger);
              _emitState(
                lastTrigger: trigger,
                message: 'Remote swing trigger received.',
              );
            } catch (_) {
              // Ignore malformed control payloads.
            }
          },
          onDone: socket.destroy,
          onError: (_) => socket.destroy(),
          cancelOnError: true,
        );
  }

  DualCameraPeer? _peerForTrigger(
    Map<String, Object?> payload,
    String remoteAddress,
  ) {
    final senderDeviceId = payload['senderDeviceId'] as String?;
    if (senderDeviceId != null && _peers.containsKey(senderDeviceId)) {
      return _peers[senderDeviceId];
    }
    for (final peer in _peers.values) {
      if (peer.address == remoteAddress) {
        return peer;
      }
    }
    return null;
  }

  void _announce() {
    final socket = _udpSocket;
    if (socket == null || !_state.isRunning || !_state.role.isActive) {
      return;
    }
    final payload = DualCameraProtocol.helloPayload(
      deviceId: localDeviceId,
      deviceName: localDeviceName,
      role: _state.role,
      controlPort: _state.controlPort,
      sentAt: DateTime.now(),
      advertisedFps: _advertisedFps,
    );
    final data = utf8.encode(jsonEncode(payload));
    socket.send(data, InternetAddress('255.255.255.255'), discoveryPort);
  }

  void _prunePeers() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 5));
    _peers.removeWhere((_, peer) => peer.lastSeenAt.isBefore(cutoff));
    _emitState(peers: _sortedPeers(), message: _messageFor(_state.role));
  }

  List<DualCameraPeer> _sortedPeers() {
    final peers = _peers.values.toList(growable: false)
      ..sort((a, b) => a.deviceName.compareTo(b.deviceName));
    return peers;
  }

  void _emitState({
    DualCameraRole? role,
    bool? isRunning,
    int? controlPort,
    List<DualCameraPeer>? peers,
    String? message,
    RemoteSwingTrigger? lastTrigger,
  }) {
    _state = _state.copyWith(
      role: role,
      isRunning: isRunning,
      controlPort: controlPort,
      peers: peers,
      message: message,
      lastTrigger: lastTrigger,
    );
    if (!_stateController.isClosed) {
      _stateController.add(_state);
    }
  }

  String _messageFor(DualCameraRole role) {
    return switch (role) {
      DualCameraRole.disabled => 'Dual camera is off.',
      DualCameraRole.detector =>
        _peers.values.any((peer) => peer.canReceiveTriggers)
            ? 'Recorder phone paired.'
            : 'Waiting for recorder phone.',
      DualCameraRole.recorder =>
        _peers.values.any((peer) => peer.role == DualCameraRole.detector)
            ? 'Detector phone paired.'
            : 'Waiting for detector phone.',
    };
  }

  static String _sanitizeDeviceName(String? raw) {
    final fallback = Platform.localHostname;
    final value = (raw == null || raw.trim().isEmpty) ? fallback : raw.trim();
    return value.isEmpty ? 'SwingCapture phone' : value;
  }

  static String _newDeviceId() {
    final random = Random.secure().nextInt(1 << 32).toRadixString(16);
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-$random';
  }
}
