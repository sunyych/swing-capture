import 'dart:async';

import 'package:flutter/services.dart';

import '../../../../core/models/capture_settings.dart';

sealed class DualCameraBluetoothEvent {
  const DualCameraBluetoothEvent();

  factory DualCameraBluetoothEvent.fromMap(Map<Object?, Object?> map) {
    final type = map['type'] as String? ?? '';
    return switch (type) {
      'peer' => DualCameraBluetoothPeerEvent(
        payload: _stringObjectMap(map['payload']),
      ),
      'peer_lost' => DualCameraBluetoothPeerLostEvent(
        deviceId: map['deviceId'] as String? ?? '',
      ),
      'trigger' => DualCameraBluetoothTriggerEvent(
        payload: _stringObjectMap(map['payload']),
      ),
      'status' => DualCameraBluetoothStatusEvent(
        message: map['message'] as String? ?? 'Bluetooth control updated.',
      ),
      _ => DualCameraBluetoothStatusEvent(
        message: map['message'] as String? ?? 'Bluetooth control updated.',
      ),
    };
  }
}

class DualCameraBluetoothPeerEvent extends DualCameraBluetoothEvent {
  const DualCameraBluetoothPeerEvent({required this.payload});

  final Map<String, Object?> payload;
}

class DualCameraBluetoothPeerLostEvent extends DualCameraBluetoothEvent {
  const DualCameraBluetoothPeerLostEvent({required this.deviceId});

  final String deviceId;
}

class DualCameraBluetoothTriggerEvent extends DualCameraBluetoothEvent {
  const DualCameraBluetoothTriggerEvent({required this.payload});

  final Map<String, Object?> payload;
}

class DualCameraBluetoothStatusEvent extends DualCameraBluetoothEvent {
  const DualCameraBluetoothStatusEvent({required this.message});

  final String message;
}

abstract interface class DualCameraBluetoothControl {
  Stream<DualCameraBluetoothEvent> get events;

  Future<void> start({
    required DualCameraRole role,
    required Map<String, Object?> helloPayload,
  });

  Future<void> stop();

  Future<bool> sendTrigger(Map<String, Object?> payload);

  Future<void> dispose();
}

class PlatformDualCameraBluetoothControl implements DualCameraBluetoothControl {
  PlatformDualCameraBluetoothControl({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _methodChannel =
           methodChannel ?? const MethodChannel('swingcapture/dual_camera_ble'),
       _eventChannel =
           eventChannel ??
           const EventChannel('swingcapture/dual_camera_ble_events');

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  Stream<DualCameraBluetoothEvent>? _events;

  @override
  Stream<DualCameraBluetoothEvent> get events {
    return _events ??= _eventChannel
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map((event) {
          final map = (event as Map).cast<Object?, Object?>();
          return DualCameraBluetoothEvent.fromMap(map);
        });
  }

  @override
  Future<void> start({
    required DualCameraRole role,
    required Map<String, Object?> helloPayload,
  }) async {
    await _methodChannel.invokeMethod<void>('start', {
      'role': role.wireValue,
      'hello': helloPayload,
    });
  }

  @override
  Future<void> stop() async {
    try {
      await _methodChannel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Unit tests and non-mobile shells may not register the native BLE channel.
    }
  }

  @override
  Future<bool> sendTrigger(Map<String, Object?> payload) async {
    final delivered = await _methodChannel.invokeMethod<bool>('sendTrigger', {
      'payload': payload,
    });
    return delivered ?? false;
  }

  @override
  Future<void> dispose() async {
    await stop();
  }
}

Map<String, Object?> _stringObjectMap(Object? raw) {
  if (raw is! Map) {
    return const <String, Object?>{};
  }
  return raw.map((key, value) => MapEntry(key.toString(), value));
}
