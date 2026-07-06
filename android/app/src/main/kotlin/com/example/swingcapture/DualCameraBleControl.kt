package com.lumiaiq.MotionCapture

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.util.UUID

class DualCameraBleControl(private val activity: Activity) {
    companion object {
        private val SERVICE_UUID: UUID = UUID.fromString("0f7d4d80-2f37-4d4c-bf9a-fc4fdc1a0901")
        private val HELLO_UUID: UUID = UUID.fromString("0f7d4d81-2f37-4d4c-bf9a-fc4fdc1a0901")
        private val MESSAGE_UUID: UUID = UUID.fromString("0f7d4d82-2f37-4d4c-bf9a-fc4fdc1a0901")
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val bluetoothManager: BluetoothManager?
        get() = activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val bluetoothAdapter
        get() = bluetoothManager?.adapter

    private var eventSink: EventChannel.EventSink? = null
    private var role: String = "disabled"
    private var helloPayload: Map<String, Any?> = emptyMap()
    private var helloBytes: ByteArray = ByteArray(0)

    private var gattServer: BluetoothGattServer? = null
    private var advertiserCallback: AdvertiseCallback? = null
    private var scannerCallback: ScanCallback? = null
    private var connectedGatt: BluetoothGatt? = null
    private var messageCharacteristic: BluetoothGattCharacteristic? = null
    private val deviceIdsByAddress = mutableMapOf<String, String>()

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(call, result)
            "stop" -> {
                stop()
                result.success(null)
            }
            "sendTrigger" -> result.success(sendTrigger(call))
            else -> result.notImplemented()
        }
    }

    fun stop() {
        stopScan()
        stopAdvertise()
        try {
            connectedGatt?.disconnect()
            connectedGatt?.close()
        } catch (_: SecurityException) {
        }
        connectedGatt = null
        messageCharacteristic = null
        try {
            gattServer?.close()
        } catch (_: SecurityException) {
        }
        gattServer = null
        deviceIdsByAddress.clear()
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        if (!hasBluetoothPermissions()) {
            result.error(
                "bluetooth_permission",
                "Bluetooth permission is required for dual-phone control.",
                null,
            )
            return
        }
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val nextRole = args["role"] as? String ?: "disabled"
        val rawHello = args["hello"] as? Map<*, *> ?: emptyMap<Any, Any>()
        val nextHello = rawHello.entries.associate { it.key.toString() to it.value }
        stop()
        role = nextRole
        helloPayload = nextHello
        helloBytes = JSONObject(helloPayload).toString().toByteArray(StandardCharsets.UTF_8)
        when (role) {
            "recorder" -> startRecorder(result)
            "detector" -> startDetector(result)
            else -> result.success(null)
        }
    }

    @SuppressLint("MissingPermission")
    private fun startRecorder(result: MethodChannel.Result) {
        val manager = bluetoothManager
        val adapter = bluetoothAdapter
        val advertiser = adapter?.bluetoothLeAdvertiser
        if (manager == null || adapter == null || !adapter.isEnabled || advertiser == null) {
            result.error("bluetooth_unavailable", "Bluetooth LE advertising is unavailable.", null)
            return
        }

        val server = manager.openGattServer(activity, gattServerCallback)
        if (server == null) {
            result.error("bluetooth_unavailable", "Unable to open Bluetooth GATT server.", null)
            return
        }
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        val hello = BluetoothGattCharacteristic(
            HELLO_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        hello.value = helloBytes
        val message = BluetoothGattCharacteristic(
            MESSAGE_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        service.addCharacteristic(hello)
        service.addCharacteristic(message)
        server.addService(service)
        gattServer = server

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .setIncludeDeviceName(false)
            .build()
        val callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                emitStatus("Bluetooth recorder ready.")
            }

            override fun onStartFailure(errorCode: Int) {
                emitStatus("Bluetooth advertising failed.")
            }
        }
        advertiserCallback = callback
        advertiser.startAdvertising(settings, data, callback)
        emitStatus("Bluetooth recorder advertising.")
        result.success(null)
    }

    @SuppressLint("MissingPermission")
    private fun startDetector(result: MethodChannel.Result) {
        val scanner = bluetoothAdapter?.bluetoothLeScanner
        if (scanner == null || bluetoothAdapter?.isEnabled != true) {
            result.error("bluetooth_unavailable", "Bluetooth LE scanning is unavailable.", null)
            return
        }
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                connectToRecorder(result.device)
            }

            override fun onScanFailed(errorCode: Int) {
                emitStatus("Bluetooth scan failed.")
            }
        }
        scannerCallback = callback
        val filters = listOf(
            ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build(),
        )
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        scanner.startScan(filters, settings, callback)
        emitStatus("Searching for recorder over Bluetooth.")
        result.success(null)
    }

    @SuppressLint("MissingPermission")
    private fun connectToRecorder(device: BluetoothDevice) {
        if (connectedGatt?.device?.address == device.address) {
            return
        }
        stopScan()
        connectedGatt?.close()
        messageCharacteristic = null
        connectedGatt = device.connectGatt(activity, false, gattCallback)
        emitStatus("Connecting to Bluetooth recorder.")
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        val callback = scannerCallback ?: return
        try {
            bluetoothAdapter?.bluetoothLeScanner?.stopScan(callback)
        } catch (_: SecurityException) {
        }
        scannerCallback = null
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertise() {
        val callback = advertiserCallback ?: return
        try {
            bluetoothAdapter?.bluetoothLeAdvertiser?.stopAdvertising(callback)
        } catch (_: SecurityException) {
        }
        advertiserCallback = null
    }

    @SuppressLint("MissingPermission")
    private fun sendTrigger(call: MethodCall): Boolean {
        val args = call.arguments as? Map<*, *> ?: return false
        val payload = args["payload"] as? Map<*, *> ?: return false
        val characteristic = messageCharacteristic ?: return false
        val gatt = connectedGatt ?: return false
        val bytes = JSONObject(payload.entries.associate { it.key.toString() to it.value })
            .toString()
            .toByteArray(StandardCharsets.UTF_8)
        characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(
                characteristic,
                bytes,
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
            ) == BluetoothGatt.GATT_SUCCESS
        } else {
            characteristic.value = bytes
            gatt.writeCharacteristic(characteristic)
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                emitStatus("Bluetooth detector connected.")
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                val deviceId = deviceIdsByAddress.remove(device.address)
                if (deviceId != null) {
                    emit(mapOf("type" to "peer_lost", "deviceId" to deviceId))
                }
                emitStatus("Bluetooth detector disconnected.")
            }
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (characteristic.uuid != HELLO_UUID) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                return
            }
            val bytes = if (offset >= helloBytes.size) {
                ByteArray(0)
            } else {
                helloBytes.copyOfRange(offset, helloBytes.size)
            }
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, bytes)
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            if (characteristic.uuid == MESSAGE_UUID) {
                handleIncomingMessage(device.address, value)
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
            }
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                connectedGatt = gatt
                gatt.requestMtu(512)
                gatt.discoverServices()
                emitStatus("Bluetooth recorder connected.")
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                val deviceId = deviceIdsByAddress.remove(gatt.device.address)
                if (deviceId != null) {
                    emit(mapOf("type" to "peer_lost", "deviceId" to deviceId))
                }
                messageCharacteristic = null
                gatt.close()
                if (connectedGatt == gatt) {
                    connectedGatt = null
                }
                emitStatus("Bluetooth recorder disconnected.")
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val service = gatt.getService(SERVICE_UUID)
            val hello = service?.getCharacteristic(HELLO_UUID)
            messageCharacteristic = service?.getCharacteristic(MESSAGE_UUID)
            if (hello == null || messageCharacteristic == null) {
                emitStatus("Bluetooth recorder service unavailable.")
                return
            }
            gatt.readCharacteristic(hello)
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (characteristic.uuid != HELLO_UUID || status != BluetoothGatt.GATT_SUCCESS) {
                return
            }
            handleIncomingMessage(gatt.device.address, characteristic.value)
            writeHelloToRecorder(gatt)
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            if (characteristic.uuid != HELLO_UUID || status != BluetoothGatt.GATT_SUCCESS) {
                return
            }
            handleIncomingMessage(gatt.device.address, value)
            writeHelloToRecorder(gatt)
        }
    }

    @SuppressLint("MissingPermission")
    private fun writeHelloToRecorder(gatt: BluetoothGatt) {
        val characteristic = messageCharacteristic ?: return
        characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(
                characteristic,
                helloBytes,
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
            )
        } else {
            characteristic.value = helloBytes
            gatt.writeCharacteristic(characteristic)
        }
    }

    private fun handleIncomingMessage(address: String, value: ByteArray) {
        val payload = try {
            jsonToMap(JSONObject(String(value, StandardCharsets.UTF_8)))
        } catch (_: Exception) {
            return
        }
        val type = payload["type"] as? String ?: return
        when (type) {
            "hello" -> {
                val deviceId = payload["deviceId"] as? String
                if (!deviceId.isNullOrEmpty()) {
                    deviceIdsByAddress[address] = deviceId
                }
                emit(mapOf("type" to "peer", "payload" to payload))
            }
            "trigger" -> emit(mapOf("type" to "trigger", "payload" to payload))
        }
    }

    private fun emitStatus(message: String) {
        emit(mapOf("type" to "status", "message" to message))
    }

    private fun emit(event: Map<String, Any?>) {
        mainHandler.post {
            eventSink?.success(event)
        }
    }

    private fun hasBluetoothPermissions(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return activity.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) ==
                PackageManager.PERMISSION_GRANTED &&
                activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED &&
                activity.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) ==
                PackageManager.PERMISSION_GRANTED
        }
        return activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun jsonToMap(json: JSONObject): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>()
        val keys = json.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val value = json.get(key)
            result[key] = if (value == JSONObject.NULL) null else value
        }
        return result
    }
}
