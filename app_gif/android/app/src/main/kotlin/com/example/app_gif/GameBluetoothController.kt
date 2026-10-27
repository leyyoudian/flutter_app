package com.example.app_gif

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/** Shared BLE device-control session; Wi-Fi is only the bulk-data transport. */
@SuppressLint("MissingPermission")
class GameBluetoothController(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val serviceId = UUID.fromString("31494a41-6252-4288-b942-2f8d009e1ab1")
    private val controlId = UUID.fromString("31494a41-6252-4288-b942-2f8d019e1ab1")
    private val cccdId = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    private var gatt: BluetoothGatt? = null
    private var control: BluetoothGattCharacteristic? = null
    private var scanner: BluetoothLeScanner? = null
    private var connectResult: MethodChannel.Result? = null
    private var commandResult: MethodChannel.Result? = null
    private var sequence = 0
    private var ready = false
    private var lastStatus = ""
    private var deviceReply = false
    private var automaticConnect = false
    private val preferences = context.getSharedPreferences("dotloop_bluetooth", Context.MODE_PRIVATE)
    private val candidates = linkedMapOf<String, BluetoothDevice>()
    private val connectTimeout = Runnable { fail("未找到可连接的 P4 蓝牙设备，请确认设备已开机且未被其他手机占用") }
    private val commandTimeout = Runnable { commandError("设备未确认游戏指令，请重试") }
    private val finishScan = Runnable {
        stopScan()
        val previous = preferences.getString("last_device_address", null)
        val target = previous?.let { candidates[it] }
            ?: if (automaticConnect && previous != null) null else candidates.values.singleOrNull()
        if (target == null) fail(if (automaticConnect && previous != null) "未发现上次连接的 DotLoop" else if (candidates.isEmpty()) "未发现 DotLoop 蓝牙设备" else "附近有多个 DotLoop，请只保留目标设备开机后重试")
        else gatt = target.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
    }

    fun connect(result: MethodChannel.Result, automatic: Boolean = false) {
        if (ready && gatt != null) { result.success(info()); return }
        if (connectResult != null) { result.error("bluetooth_busy", "正在连接蓝牙，请稍候", null); return }
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        if (adapter?.isEnabled != true) { result.error("bluetooth_off", "请先打开手机蓝牙", null); return }
        connectResult = result
        automaticConnect = automatic
        candidates.clear()
        scanner = adapter.bluetoothLeScanner
        main.postDelayed(connectTimeout, 15000)
        try {
            val filter = ScanFilter.Builder().setServiceUuid(android.os.ParcelUuid(serviceId)).build()
            scanner?.startScan(listOf(filter), ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanCallback)
            main.postDelayed(finishScan, 2500)
        } catch (error: Exception) { fail(error.message ?: "无法启动蓝牙扫描") }
    }

    fun send(action: String, result: MethodChannel.Result) {
        if (action !in setOf("start", "flap", "restart", "pause", "resume", "stop", "status")) {
            result.error("bad_action", "不支持的游戏指令", null); return
        }
        write(action, false, result)
    }

    fun sendDevice(command: String, result: MethodChannel.Result) {
        if (command.length !in 1..63 || command.any { it.code !in 32..126 }) {
            result.error("bad_control", "设备指令参数无效", null); return
        }
        if (!lastStatus.contains("dc=1")) {
            result.error("firmware_update_required", "请更新 P4 固件后使用蓝牙设备控制", null); return
        }
        write("DC:$command", true, result)
    }

    private fun write(action: String, isDevice: Boolean, result: MethodChannel.Result) {
        val active = gatt
        val characteristic = control
        if (!ready || active == null || characteristic == null) {
            result.error("bluetooth_disconnected", "蓝牙未连接，请重新连接", null); return
        }
        if (commandResult != null) { result.error("game_busy", "设备正在处理上一条游戏指令", null); return }
        commandResult = result
        deviceReply = isDevice
        sequence = if (sequence >= 999999) 1 else sequence + 1
        val payload = "GB:$sequence:$action".toByteArray(Charsets.UTF_8)
        main.postDelayed(commandTimeout, 10000)
        try {
            val accepted = if (Build.VERSION.SDK_INT >= 33) {
                active.writeCharacteristic(characteristic, payload, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                characteristic.value = payload
                characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                @Suppress("DEPRECATION")
                active.writeCharacteristic(characteristic)
            }
            if (!accepted) commandError("蓝牙写入失败，请重新连接")
        } catch (error: Exception) { commandError(error.message ?: "蓝牙写入失败") }
    }

    fun status(result: MethodChannel.Result) {
        if (ready) result.success(lastStatus) else result.error("bluetooth_disconnected", "蓝牙已断开", null)
    }
    fun setInteractive(active: Boolean) {
        runCatching { gatt?.requestConnectionPriority(if (active) BluetoothGatt.CONNECTION_PRIORITY_HIGH else BluetoothGatt.CONNECTION_PRIORITY_BALANCED) }
    }
    fun connectionInfo(result: MethodChannel.Result) { result.success(if (ready) info() else mapOf("connected" to false)) }
    private fun info() = mapOf("connected" to true, "name" to "DotLoop", "address" to gatt?.device?.address,
        "status" to lastStatus, "transport" to "bluetooth")
    private fun stopScan() { main.removeCallbacks(finishScan); runCatching { scanner?.stopScan(scanCallback) }; scanner = null }
    private fun fail(message: String) {
        main.removeCallbacks(connectTimeout); stopScan(); ready = false; control = null
        val old = gatt; gatt = null; lastStatus = ""
        runCatching { old?.disconnect(); old?.close() }
        connectResult?.error("bluetooth_connect_failed", message, null); connectResult = null
        commandError(message, "bluetooth_disconnected")
    }
    private fun commandError(message: String, code: String = "game_failed") {
        main.removeCallbacks(commandTimeout)
        commandResult?.error(code, message, null); commandResult = null
    }
    fun close() { fail("蓝牙连接已关闭") }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (result.scanRecord?.serviceUuids?.any { it.uuid == serviceId } == true) {
                main.post {
                    candidates[result.device.address] = result.device
                    val remembered = preferences.getString("last_device_address", null)
                    if (automaticConnect && remembered == result.device.address && connectResult != null && gatt == null) {
                        stopScan()
                        gatt = result.device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
                    }
                }
            }
        }
        override fun onScanFailed(errorCode: Int) { main.post { fail("蓝牙扫描失败：$errorCode") } }
    }
    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(active: BluetoothGatt, status: Int, newState: Int) { main.post {
            if (active != gatt) return@post
            if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                if (!active.requestMtu(256)) fail("无法协商蓝牙数据长度")
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) fail("设备蓝牙已断开（$status）")
        } }
        override fun onMtuChanged(active: BluetoothGatt, mtu: Int, status: Int) { main.post {
            if (active != gatt) return@post
            if (status != BluetoothGatt.GATT_SUCCESS || mtu < 185) { fail("蓝牙 MTU 不足，请重新连接"); return@post }
            if (!active.discoverServices()) fail("无法发现蓝牙服务")
        } }
        override fun onServicesDiscovered(active: BluetoothGatt, status: Int) { main.post {
            if (active != gatt) return@post
            val characteristic = active.getService(serviceId)?.getCharacteristic(controlId)
            val descriptor = characteristic?.getDescriptor(cccdId)
            if (status != BluetoothGatt.GATT_SUCCESS || characteristic == null || descriptor == null) {
                fail("设备固件缺少蓝牙游戏服务，请更新 P4 固件"); return@post
            }
            control = characteristic
            active.setCharacteristicNotification(characteristic, true)
            val accepted = if (Build.VERSION.SDK_INT >= 33) {
                active.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                @Suppress("DEPRECATION")
                active.writeDescriptor(descriptor)
            }
            if (!accepted) fail("无法订阅设备蓝牙状态")
        } }
        override fun onDescriptorWrite(active: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) { main.post {
            if (active != gatt) return@post
            if (status != BluetoothGatt.GATT_SUCCESS) { fail("蓝牙通知订阅失败"); return@post }
            val characteristic = control
            if (characteristic == null || !active.readCharacteristic(characteristic)) fail("无法读取设备身份")
        } }
        private fun readStatus(active: BluetoothGatt, value: ByteArray, status: Int) { main.post {
            if (active != gatt || connectResult == null) return@post
            val text = value.toString(Charsets.UTF_8)
            if (status != BluetoothGatt.GATT_SUCCESS || !text.contains("hardware=esp32p4")) { fail("蓝牙设备身份校验失败"); return@post }
            lastStatus = text; ready = true; main.removeCallbacks(connectTimeout)
            if (text.contains("dc=1")) preferences.edit().putString("last_device_address", active.device.address).apply()
            connectResult?.success(info()); connectResult = null
        } }
        @Deprecated("Deprecated in Java")
        override fun onCharacteristicRead(active: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            @Suppress("DEPRECATION")
            readStatus(active, characteristic.value, status)
        }
        override fun onCharacteristicRead(active: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) { readStatus(active, value, status) }
        override fun onCharacteristicWrite(active: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) main.post { if (active == gatt) commandError("设备拒绝蓝牙指令（$status）") }
            // Wait for application ACK, not merely ATT delivery.
        }
        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(active: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION")
            notification(active, characteristic.value)
        }
        override fun onCharacteristicChanged(active: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) { notification(active, value) }
    }
    private fun notification(active: BluetoothGatt, value: ByteArray) { main.post {
        if (active != gatt) return@post
        val text = value.toString(Charsets.UTF_8)
        if (text.startsWith("GB:$sequence:")) {
            main.removeCallbacks(commandTimeout)
            val pending = commandResult; commandResult = null
            if (deviceReply && text.startsWith("GB:$sequence:OK:")) pending?.success(text.substringAfter("GB:$sequence:OK:"))
            else if (!deviceReply && text == "GB:$sequence:OK") pending?.success(true)
            else pending?.error("game_rejected", text.substringAfter(":ERR:", text), null)
        } else if (text.contains("hardware=esp32p4")) lastStatus = text
    } }
}
