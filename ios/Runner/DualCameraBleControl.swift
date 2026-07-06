import CoreBluetooth
import Flutter
import Foundation

final class DualCameraBleControl: NSObject, FlutterStreamHandler {
  private let serviceUUID = CBUUID(string: "0f7d4d80-2f37-4d4c-bf9a-fc4fdc1a0901")
  private let helloUUID = CBUUID(string: "0f7d4d81-2f37-4d4c-bf9a-fc4fdc1a0901")
  private let messageUUID = CBUUID(string: "0f7d4d82-2f37-4d4c-bf9a-fc4fdc1a0901")

  private var eventSink: FlutterEventSink?
  private var role = "disabled"
  private var helloPayload: [String: Any] = [:]
  private var helloData = Data()

  private var peripheralManager: CBPeripheralManager?
  private var centralManager: CBCentralManager?
  private var connectedPeripheral: CBPeripheral?
  private var messageCharacteristic: CBCharacteristic?
  private var deviceIdsByPeripheral = [UUID: String]()
  private var recorderService: CBMutableService?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      start(call, result: result)
    case "stop":
      stop()
      result(nil)
    case "sendTrigger":
      result(sendTrigger(call))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func stop() {
    if peripheralManager?.isAdvertising == true {
      peripheralManager?.stopAdvertising()
    }
    peripheralManager?.removeAllServices()
    peripheralManager = nil
    centralManager?.stopScan()
    if let connectedPeripheral {
      centralManager?.cancelPeripheralConnection(connectedPeripheral)
    }
    centralManager = nil
    connectedPeripheral = nil
    messageCharacteristic = nil
    recorderService = nil
    deviceIdsByPeripheral.removeAll()
  }

  private func start(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let nextRole = args["role"] as? String,
      let hello = args["hello"] as? [String: Any]
    else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "Bluetooth control requires role and hello payload.",
          details: nil
        )
      )
      return
    }

    stop()
    role = nextRole
    helloPayload = hello
    helloData = (try? JSONSerialization.data(withJSONObject: hello, options: [])) ?? Data()

    switch role {
    case "recorder":
      peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
      if peripheralManager?.state == .poweredOn {
        startRecorderAdvertising()
      }
      emitStatus("Bluetooth recorder starting.")
      result(nil)
    case "detector":
      centralManager = CBCentralManager(delegate: self, queue: nil)
      if centralManager?.state == .poweredOn {
        startDetectorScan()
      }
      emitStatus("Bluetooth detector starting.")
      result(nil)
    default:
      result(nil)
    }
  }

  private func sendTrigger(_ call: FlutterMethodCall) -> Bool {
    guard
      let args = call.arguments as? [String: Any],
      let payload = args["payload"] as? [String: Any],
      let peripheral = connectedPeripheral,
      let characteristic = messageCharacteristic,
      let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
    else {
      return false
    }
    peripheral.writeValue(data, for: characteristic, type: .withResponse)
    return true
  }

  private func startRecorderAdvertising() {
    guard let peripheralManager, peripheralManager.state == .poweredOn else {
      emitStatus("Bluetooth is not ready.")
      return
    }
    if recorderService != nil {
      return
    }
    let hello = CBMutableCharacteristic(
      type: helloUUID,
      properties: [.read],
      value: nil,
      permissions: [.readable]
    )
    let message = CBMutableCharacteristic(
      type: messageUUID,
      properties: [.write, .writeWithoutResponse],
      value: nil,
      permissions: [.writeable]
    )
    let service = CBMutableService(type: serviceUUID, primary: true)
    service.characteristics = [hello, message]
    recorderService = service
    peripheralManager.add(service)
  }

  private func startDetectorScan() {
    guard let centralManager, centralManager.state == .poweredOn else {
      emitStatus("Bluetooth is not ready.")
      return
    }
    centralManager.scanForPeripherals(
      withServices: [serviceUUID],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )
    emitStatus("Searching for recorder over Bluetooth.")
  }

  private func handleIncoming(_ data: Data, from identifier: UUID?) {
    guard
      let raw = try? JSONSerialization.jsonObject(with: data, options: []),
      let payload = raw as? [String: Any],
      let type = payload["type"] as? String
    else {
      return
    }
    if type == "hello" {
      if let id = payload["deviceId"] as? String, let identifier {
        deviceIdsByPeripheral[identifier] = id
      }
      emit(["type": "peer", "payload": payload])
    } else if type == "trigger" {
      emit(["type": "trigger", "payload": payload])
    }
  }

  private func emitStatus(_ message: String) {
    emit(["type": "status", "message": message])
  }

  private func emit(_ event: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(event)
    }
  }
}

extension DualCameraBleControl: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    if peripheral.state == .poweredOn, role == "recorder" {
      startRecorderAdvertising()
    } else if peripheral.state != .poweredOn {
      emitStatus("Bluetooth recorder unavailable.")
    }
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    didAdd service: CBService,
    error: Error?
  ) {
    if error != nil {
      emitStatus("Bluetooth recorder service failed.")
      return
    }
    peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID]])
    emitStatus("Bluetooth recorder advertising.")
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    didReceiveRead request: CBATTRequest
  ) {
    guard request.characteristic.uuid == helloUUID else {
      peripheral.respond(to: request, withResult: .requestNotSupported)
      return
    }
    if request.offset > helloData.count {
      peripheral.respond(to: request, withResult: .invalidOffset)
      return
    }
    request.value = helloData.subdata(in: request.offset..<helloData.count)
    peripheral.respond(to: request, withResult: .success)
  }

  func peripheralManager(
    _ peripheral: CBPeripheralManager,
    didReceiveWrite requests: [CBATTRequest]
  ) {
    for request in requests {
      if request.characteristic.uuid == messageUUID, let value = request.value {
        handleIncoming(value, from: request.central.identifier)
      }
      peripheral.respond(to: request, withResult: .success)
    }
  }
}

extension DualCameraBleControl: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state == .poweredOn, role == "detector" {
      startDetectorScan()
    } else if central.state != .poweredOn {
      emitStatus("Bluetooth detector unavailable.")
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    central.stopScan()
    connectedPeripheral = peripheral
    peripheral.delegate = self
    central.connect(peripheral)
    emitStatus("Connecting to Bluetooth recorder.")
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    connectedPeripheral = peripheral
    peripheral.delegate = self
    peripheral.discoverServices([serviceUUID])
    emitStatus("Bluetooth recorder connected.")
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    if let deviceId = deviceIdsByPeripheral.removeValue(forKey: peripheral.identifier) {
      emit(["type": "peer_lost", "deviceId": deviceId])
    }
    if connectedPeripheral?.identifier == peripheral.identifier {
      connectedPeripheral = nil
      messageCharacteristic = nil
    }
    emitStatus("Bluetooth recorder disconnected.")
  }
}

extension DualCameraBleControl: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard error == nil else {
      emitStatus("Bluetooth recorder service unavailable.")
      return
    }
    for service in peripheral.services ?? [] where service.uuid == serviceUUID {
      peripheral.discoverCharacteristics([helloUUID, messageUUID], for: service)
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    guard error == nil else {
      emitStatus("Bluetooth recorder characteristics unavailable.")
      return
    }
    var helloCharacteristic: CBCharacteristic?
    for characteristic in service.characteristics ?? [] {
      if characteristic.uuid == helloUUID {
        helloCharacteristic = characteristic
      } else if characteristic.uuid == messageUUID {
        messageCharacteristic = characteristic
      }
    }
    if let helloCharacteristic {
      peripheral.readValue(for: helloCharacteristic)
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard characteristic.uuid == helloUUID, error == nil, let value = characteristic.value else {
      return
    }
    handleIncoming(value, from: peripheral.identifier)
    if let messageCharacteristic {
      peripheral.writeValue(helloData, for: messageCharacteristic, type: .withResponse)
    }
  }
}
