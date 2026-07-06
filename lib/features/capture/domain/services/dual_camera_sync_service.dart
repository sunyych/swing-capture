import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../../../core/models/capture_settings.dart';
import '../models/dual_camera_sync.dart';
import 'dual_camera_bluetooth_control.dart';

class DualCameraSyncService {
  DualCameraSyncService({
    String? deviceName,
    String? deviceId,
    this.discoveryPort = dualCameraSyncDiscoveryPort,
    DualCameraBluetoothControl? bluetoothControl,
  }) : localDeviceName = _sanitizeDeviceName(deviceName),
       localDeviceId = deviceId ?? _newDeviceId(),
       _bluetoothControl =
           bluetoothControl ?? PlatformDualCameraBluetoothControl() {
    _state = DualCameraSyncState.initial(
      localDeviceId: localDeviceId,
      localDeviceName: localDeviceName,
    );
  }

  final String localDeviceId;
  final String localDeviceName;
  final int discoveryPort;
  final DualCameraBluetoothControl _bluetoothControl;

  late DualCameraSyncState _state;
  RawDatagramSocket? _udpSocket;
  ServerSocket? _serverSocket;
  Timer? _announceTimer;
  Timer? _pruneTimer;
  StreamSubscription<DualCameraBluetoothEvent>? _bluetoothSubscription;
  Directory? _incomingClipDirectory;
  int? _advertisedFps;
  DualCameraTransportMode _transportMode = DualCameraTransportMode.wifi;
  final Map<String, DualCameraPeer> _peers = <String, DualCameraPeer>{};

  final StreamController<DualCameraSyncState> _stateController =
      StreamController<DualCameraSyncState>.broadcast();
  final StreamController<RemoteSwingTrigger> _triggerController =
      StreamController<RemoteSwingTrigger>.broadcast();
  final StreamController<RemoteDualCameraClip> _clipController =
      StreamController<RemoteDualCameraClip>.broadcast();

  Stream<DualCameraSyncState> get states => _stateController.stream;
  Stream<RemoteSwingTrigger> get remoteTriggers => _triggerController.stream;
  Stream<RemoteDualCameraClip> get remoteClips => _clipController.stream;
  DualCameraSyncState get state => _state;

  void addPeerForTesting(DualCameraPeer peer) {
    assert(() {
      _peers[peer.deviceId] = peer;
      _emitState(peers: _sortedPeers(), message: _messageFor(_state.role));
      return true;
    }());
  }

  Future<void> start({
    required DualCameraRole role,
    DualCameraTransportMode transportMode = DualCameraTransportMode.wifi,
    int? advertisedFps,
    Directory? incomingClipDirectory,
  }) async {
    _advertisedFps = advertisedFps;
    _incomingClipDirectory = incomingClipDirectory;
    if (!role.isActive) {
      await stop();
      return;
    }

    if (_state.isRunning &&
        _state.role == role &&
        _transportMode == transportMode) {
      _emitState(message: _messageFor(role));
      if (transportMode == DualCameraTransportMode.wifi) {
        _announce();
      } else {
        await _startBluetooth(role: role);
      }
      return;
    }

    await stop();
    _transportMode = transportMode;
    if (transportMode == DualCameraTransportMode.bluetoothControl) {
      await _startBluetooth(role: role);
      return;
    }

    await _startWifi(role);
  }

  Future<void> _startWifi(DualCameraRole role) async {
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
        transport: DualCameraTransportMode.wifi,
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
        transport: DualCameraTransportMode.wifi,
        message: 'Dual camera network unavailable.',
      );
    }
  }

  Future<void> _startBluetooth({required DualCameraRole role}) async {
    try {
      _bluetoothSubscription ??= _bluetoothControl.events.listen(
        _handleBluetoothEvent,
        onError: (_) => _emitState(message: 'Bluetooth control failed.'),
      );
      final hello = DualCameraProtocol.helloPayload(
        deviceId: localDeviceId,
        deviceName: localDeviceName,
        role: role,
        controlPort: 0,
        sentAt: DateTime.now(),
        transport: DualCameraTransportMode.bluetoothControl,
        advertisedFps: _advertisedFps,
      );
      await _bluetoothControl.start(role: role, helloPayload: hello);
      _emitState(
        role: role,
        isRunning: true,
        controlPort: 0,
        transport: DualCameraTransportMode.bluetoothControl,
        peers: _sortedPeers(),
        message: _messageFor(role),
      );
      _pruneTimer ??= Timer.periodic(
        const Duration(seconds: 2),
        (_) => _prunePeers(),
      );
    } catch (_) {
      await stop();
      _transportMode = DualCameraTransportMode.bluetoothControl;
      _emitState(
        role: role,
        isRunning: false,
        transport: DualCameraTransportMode.bluetoothControl,
        message: 'Bluetooth control unavailable.',
      );
    }
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _pruneTimer?.cancel();
    _announceTimer = null;
    _pruneTimer = null;
    await _bluetoothSubscription?.cancel();
    _bluetoothSubscription = null;
    if (_transportMode == DualCameraTransportMode.bluetoothControl) {
      try {
        await _bluetoothControl.stop();
      } catch (_) {}
    }
    _udpSocket?.close();
    _udpSocket = null;
    await _serverSocket?.close();
    _serverSocket = null;
    _peers.clear();
    _emitState(
      role: DualCameraRole.disabled,
      isRunning: false,
      controlPort: 0,
      transport: _transportMode,
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
    if (_transportMode == DualCameraTransportMode.bluetoothControl) {
      final delivered = await _bluetoothControl.sendTrigger(payload) ? 1 : 0;
      _emitState(
        message: delivered == 0
            ? 'Bluetooth recorder did not receive trigger.'
            : 'Bluetooth trigger sent to recorder phone.',
      );
      return delivered;
    }

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

  Future<int> sendRecordedClip({
    required String filePath,
    required String swingId,
    required int preRollMs,
    required int postRollMs,
    int? durationMs,
  }) async {
    if (!_state.isRunning || _state.role != DualCameraRole.recorder) {
      return 0;
    }
    if (_transportMode == DualCameraTransportMode.bluetoothControl) {
      _emitState(message: 'Clip saved. Connect with Wi-Fi to merge videos.');
      return 0;
    }
    final file = File(filePath);
    if (!await file.exists()) {
      return 0;
    }
    final peers = _peers.values
        .where(
          (peer) =>
              peer.role == DualCameraRole.detector && peer.controlPort > 0,
        )
        .toList(growable: false);
    if (peers.isEmpty) {
      _emitState(message: 'No detector phone paired for clip transfer.');
      return 0;
    }

    final length = await file.length();
    final header = DualCameraProtocol.clipUploadHeaderPayload(
      senderDeviceId: localDeviceId,
      senderName: localDeviceName,
      swingId: swingId,
      fileName: file.uri.pathSegments.isEmpty
          ? 'swing_$swingId.mp4'
          : file.uri.pathSegments.last,
      fileSizeBytes: length,
      preRollMs: preRollMs,
      postRollMs: postRollMs,
      durationMs: durationMs,
      sentAt: DateTime.now(),
    );
    final headerBytes = utf8.encode('${jsonEncode(header)}\n');
    var delivered = 0;
    for (final peer in peers) {
      try {
        final socket = await Socket.connect(
          peer.address,
          peer.controlPort,
          timeout: const Duration(seconds: 2),
        );
        socket.add(headerBytes);
        await socket.flush();
        await file.openRead().pipe(socket);
        delivered += 1;
      } catch (_) {
        // Peer will be pruned by the hello timeout if it is gone.
      }
    }
    _emitState(
      message: delivered == 0
          ? 'Detector phone did not receive clip.'
          : 'Clip sent to detector phone.',
    );
    return delivered;
  }

  Future<void> dispose() async {
    await stop();
    await _bluetoothControl.dispose();
    await _stateController.close();
    await _triggerController.close();
    await _clipController.close();
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
        transport: DualCameraTransportMode.wifi,
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
    unawaited(_readControlSocket(socket));
  }

  Future<void> _readControlSocket(Socket socket) async {
    final remoteAddress = socket.remoteAddress.address;
    final headerBuffer = <int>[];
    Map<String, Object?>? header;
    IOSink? clipSink;
    File? clipFile;
    var receivedClipBytes = 0;
    var expectedClipBytes = 0;

    Future<void> finishClipIfComplete() async {
      if (header == null ||
          clipSink == null ||
          clipFile == null ||
          receivedClipBytes < expectedClipBytes) {
        return;
      }
      final sink = clipSink!;
      final file = clipFile;
      await sink.flush();
      await sink.close();
      clipSink = null;
      final payload = header;
      final clip = RemoteDualCameraClip(
        swingId: payload['swingId'] as String? ?? '',
        senderDeviceId: payload['senderDeviceId'] as String? ?? '',
        senderName: payload['senderName'] as String? ?? 'Recorder',
        filePath: file.path,
        fileSizeBytes: receivedClipBytes,
        receivedAt: DateTime.now(),
        preRollMs: (payload['preRollMs'] as num?)?.toInt() ?? 2000,
        postRollMs: (payload['postRollMs'] as num?)?.toInt() ?? 2000,
        durationMs: (payload['durationMs'] as num?)?.toInt(),
      );
      if (clip.swingId.isNotEmpty && !_clipController.isClosed) {
        _clipController.add(clip);
        _emitState(message: 'Remote recorder clip received.');
      }
    }

    Future<void> writeClipBytes(List<int> bytes) async {
      final sink = clipSink;
      if (sink == null || expectedClipBytes <= receivedClipBytes) {
        return;
      }
      final remaining = expectedClipBytes - receivedClipBytes;
      final count = min(remaining, bytes.length);
      if (count <= 0) {
        return;
      }
      sink.add(bytes.sublist(0, count));
      receivedClipBytes += count;
      await finishClipIfComplete();
    }

    try {
      await for (final chunk in socket) {
        if (header == null) {
          headerBuffer.addAll(chunk);
          final newlineIndex = headerBuffer.indexOf(10);
          if (newlineIndex < 0) {
            if (headerBuffer.length > 64 * 1024) {
              break;
            }
            continue;
          }
          final line = utf8.decode(headerBuffer.sublist(0, newlineIndex));
          final decoded = jsonDecode(line);
          if (decoded is! Map) {
            break;
          }
          header = decoded.cast<String, Object?>();
          final overflow = headerBuffer.sublist(newlineIndex + 1);
          if (DualCameraProtocol.isClipUploadHeader(header)) {
            expectedClipBytes = (header['fileSizeBytes'] as num?)?.toInt() ?? 0;
            if (expectedClipBytes <= 0) {
              break;
            }
            final directory = await _resolveIncomingClipDirectory();
            final swingId = _safeFileToken(header['swingId'] as String?);
            final sender = _safeFileToken(header['senderDeviceId'] as String?);
            clipFile = File(
              '${directory.path}/dual_${swingId}_${sender}_'
              '${DateTime.now().millisecondsSinceEpoch}.mp4',
            );
            clipSink = clipFile.openWrite();
            await writeClipBytes(overflow);
          } else {
            _handleTriggerPayload(header, remoteAddress);
            break;
          }
        } else if (clipSink != null) {
          await writeClipBytes(chunk);
        }
      }
    } catch (_) {
      // Ignore malformed or interrupted control connections.
    } finally {
      try {
        await clipSink?.close();
      } catch (_) {}
      socket.destroy();
    }
  }

  void _handleTriggerPayload(
    Map<String, Object?> payload,
    String remoteAddress,
  ) {
    final peer = _peerForTrigger(payload, remoteAddress);
    final trigger = DualCameraProtocol.remoteTriggerFromPayload(
      payload: payload,
      receivedAt: DateTime.now(),
      peer: peer,
    );
    if (trigger == null) {
      return;
    }
    if (!_triggerController.isClosed) {
      _triggerController.add(trigger);
    }
    _emitState(lastTrigger: trigger, message: 'Remote swing trigger received.');
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
      transport: DualCameraTransportMode.wifi,
      advertisedFps: _advertisedFps,
    );
    final data = utf8.encode(jsonEncode(payload));
    socket.send(data, InternetAddress('255.255.255.255'), discoveryPort);
  }

  void _handleBluetoothEvent(DualCameraBluetoothEvent event) {
    switch (event) {
      case DualCameraBluetoothPeerEvent(:final payload):
        final peer = DualCameraProtocol.peerFromHelloPayload(
          payload: payload,
          address: 'bluetooth',
          receivedAt: DateTime.now(),
          localDeviceId: localDeviceId,
          transport: DualCameraTransportMode.bluetoothControl,
        );
        if (peer == null) {
          return;
        }
        _peers[peer.deviceId] = peer;
        _emitState(peers: _sortedPeers(), message: _messageFor(_state.role));
      case DualCameraBluetoothPeerLostEvent(:final deviceId):
        if (deviceId.isEmpty) {
          return;
        }
        _peers.remove(deviceId);
        _emitState(peers: _sortedPeers(), message: _messageFor(_state.role));
      case DualCameraBluetoothTriggerEvent(:final payload):
        _handleTriggerPayload(payload, 'bluetooth');
      case DualCameraBluetoothStatusEvent(:final message):
        _emitState(message: message);
    }
  }

  void _prunePeers() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 5));
    _peers.removeWhere(
      (_, peer) =>
          peer.transport == DualCameraTransportMode.wifi &&
          peer.lastSeenAt.isBefore(cutoff),
    );
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
    DualCameraTransportMode? transport,
    List<DualCameraPeer>? peers,
    String? message,
    RemoteSwingTrigger? lastTrigger,
  }) {
    _state = _state.copyWith(
      role: role,
      isRunning: isRunning,
      controlPort: controlPort,
      transport: transport,
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

  Future<Directory> _resolveIncomingClipDirectory() async {
    final configured = _incomingClipDirectory;
    final directory =
        configured ??
        Directory('${Directory.systemTemp.path}/swingcapture_dual_camera');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  static String _safeFileToken(String? raw) {
    final value = (raw == null || raw.trim().isEmpty) ? 'unknown' : raw.trim();
    return value.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]+'), '_');
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
