package com.example.app_gif

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Movie
import android.graphics.Paint
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL
import java.nio.ByteBuffer
import java.util.LinkedHashMap
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.CRC32
import kotlin.math.max
import kotlin.math.min

class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private val scanResults = LinkedHashMap<String, Map<String, Any?>>()
    private var pendingPickResult: MethodChannel.Result? = null
    private var bleScanner: BluetoothLeScanner? = null
    private var isScanning = false
    private var gatt: BluetoothGatt? = null
    private var controlCharacteristic: BluetoothGattCharacteristic? = null
    private var dataCharacteristic: BluetoothGattCharacteristic? = null
    private var connectedAddress: String? = null
    private var negotiatedMtu = 23
    private val bleWriteLock = Any()
    @Volatile private var writeLatch: CountDownLatch? = null
    @Volatile private var writeStatus = BluetoothGatt.GATT_FAILURE
    @Volatile private var isUploading = false
    @Volatile private var badgeWifiNetwork: Network? = null
    @Volatile private var badgeSdAvailable = false
    private val preparingVideoUri = AtomicReference<String?>(null)
    private var badgeWifiCallback: ConnectivityManager.NetworkCallback? = null
    private var uploadWifiLock: WifiManager.WifiLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(::handleMethodCall)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestWifiPermissionsIfNeeded()
    }

    override fun onDestroy() {
        stopScan()
        releaseBadgeWifi()
        closeGatt()
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_MEDIA) {
            return
        }

        val pending = pendingPickResult ?: return
        pendingPickResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pending.success(null)
            return
        }

        val uri = data.data!!
        val flags = data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION
        if (flags != 0) {
            runCatching { contentResolver.takePersistableUriPermission(uri, flags) }
        }

        Thread {
            try {
                val name = queryName(uri)
                val size = querySize(uri)
                val mime = normalizeMime(contentResolver.getType(uri), name)
                val isVideo = isVideoMime(mime)
                if (isVideo && size > MAX_VIDEO_INPUT_BYTES) {
                    throw IllegalArgumentException("视频文件过大")
                }
                val bytes = if (isVideo) null else readUriBytes(uri)
                if (bytes != null && bytes.size > MAX_INPUT_BYTES) {
                    throw IllegalArgumentException("素材文件过大")
                }
                val previewBytes = buildPreviewBytes(uri, mime, bytes, CropTransform.DEFAULT)
                val animatedPreviewPath = bytes?.let {
                    copyAnimatedPreview(
                        it,
                        persistentAssetDirectory("media_preview"),
                        "${System.currentTimeMillis()}_${safeFileName(name)}",
                    )
                }
                val result = mapOf(
                    "uri" to uri.toString(),
                    "name" to name,
                    "size" to if (size >= 0) size else (bytes?.size ?: 0),
                    "mime" to mime,
                    "previewBytes" to previewBytes,
                    "animatedPreviewPath" to animatedPreviewPath,
                )
                mainHandler.post { pending.success(result) }
            } catch (error: Exception) {
                mainHandler.post {
                    pending.error("pick_failed", error.message ?: "素材读取失败", null)
                }
            }
        }.start()
    }

    @Deprecated("Deprecated in Java")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_BLE_PERMISSIONS) {
            sendEvent(
                mapOf(
                    "type" to "status",
                    "message" to if (hasWifiPermissions()) "Wi-Fi 权限已允许" else "需要 Wi-Fi 权限",
                ),
            )
        }
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startScan" -> {
                if (!requestWifiPermissionsIfNeeded()) {
                    result.error("permission", "请允许 Wi-Fi 权限后重试", null)
                    return
                }
                startScan()
                result.success(null)
            }
            "connect" -> {
                val address = call.argument<String>("address")
                if (address.isNullOrBlank()) {
                    result.error("bad_address", "设备地址为空", null)
                    return
                }
                if (!requestWifiPermissionsIfNeeded()) {
                    result.error("permission", "请允许 Wi-Fi 权限后重试", null)
                    return
                }
                connect(address)
                result.success(null)
            }
            "disconnect" -> {
                disconnect()
                result.success(null)
            }
            "connectionState" -> readConnectionState(result)
            "setBrightness" -> {
                val value = (call.argument<Int>("value") ?: 70).coerceIn(0, 100)
                writeBrightness(value, result)
            }
            "pickMedia" -> pickMedia(result)
            "warmVideoAnimatedPreview" -> {
                val uri = call.argument<String>("uri")
                if (uri.isNullOrBlank()) {
                    result.error("bad_uri", "素材地址为空", null)
                    return
                }
                val name = call.argument<String>("name") ?: "asset"
                warmVideoAnimatedPreview(uri, name, result)
            }
            "prepareAsset" -> {
                val uri = call.argument<String>("uri")
                if (uri.isNullOrBlank()) {
                    result.error("bad_uri", "素材地址为空", null)
                    return
                }
                val name = call.argument<String>("name") ?: "asset"
                val fps = (call.argument<Int>("fps") ?: 30).coerceIn(1, 60)
                val maxPackageBytes = (call.argument<Int>("maxPackageBytes")
                    ?: resolveBadgePackageBudget(badgeSdAvailable))
                    .coerceAtLeast(HEADER_SIZE + FRAME_ENTRY_SIZE + PALETTE_BYTES + STREAM_240_PIXELS)
                val crop = CropTransform(
                    scale = (call.argument<Double>("cropScale") ?: 1.0).coerceIn(1.0, 4.0),
                    offsetX = (call.argument<Double>("cropOffsetX") ?: 0.0).coerceIn(-1.5, 1.5),
                    offsetY = (call.argument<Double>("cropOffsetY") ?: 0.0).coerceIn(-1.5, 1.5),
                )
                val warmPreviewPath = call.argument<String>("warmPreviewPath")
                prepareAsset(uri, name, fps, maxPackageBytes, crop, warmPreviewPath, result)
            }
            "uploadAsset" -> {
                val assetPath = call.argument<String>("assetPath")
                if (assetPath.isNullOrBlank()) {
                    result.error("bad_asset", "素材包为空", null)
                    return
                }
                uploadAsset(assetPath, result)
            }
            "loadHistory" -> loadHistory(result)
            "saveHistory" -> {
                val items = call.arguments as? List<*> ?: emptyList<Any>()
                saveHistory(items)
                result.success(null)
            }
            "deleteAssetFiles" -> {
                val map = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                deleteAssetFiles(
                    map["assetPath"] as? String,
                    map["previewPath"] as? String,
                    map["animatedPreviewPath"] as? String,
                )
                result.success(null)
            }
            "openUrl" -> {
                val url = call.argument<String>("url")
                if (url.isNullOrBlank()) {
                    result.error("bad_url", "链接为空", null)
                    return
                }
                openExternalUrl(url, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun openExternalUrl(url: String, result: MethodChannel.Result) {
        runCatching {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            startActivity(intent)
        }.onSuccess {
            result.success(null)
        }.onFailure { error ->
            result.error("open_url_failed", error.message ?: "无法打开链接", null)
        }
    }

    private fun bluetoothAdapter(): BluetoothAdapter? {
        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        return manager.adapter
    }

    private fun hasBlePermissions(): Boolean {
        return hasWifiPermissions()
    }

    private fun requestBlePermissionsIfNeeded(): Boolean {
        return requestWifiPermissionsIfNeeded()
    }

    private fun hasWifiPermissions(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }
        return requiredAppPermissions().all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    }

    private fun requestWifiPermissionsIfNeeded(): Boolean {
        if (hasWifiPermissions()) {
            return true
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            requestPermissions(requiredAppPermissions().toTypedArray(), REQUEST_BLE_PERMISSIONS)
        }
        return false
    }

    private fun requiredAppPermissions(): List<String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return emptyList()
        }

        val permissions = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions += Manifest.permission.NEARBY_WIFI_DEVICES
            permissions += Manifest.permission.READ_MEDIA_IMAGES
            permissions += Manifest.permission.READ_MEDIA_VIDEO
        }
        permissions += Manifest.permission.ACCESS_FINE_LOCATION
        return permissions.distinct()
    }

    @SuppressLint("MissingPermission")
    private fun startScan() {
        stopScan()
        scanResults.clear()

        val wifi = wifiManager()
        if (!wifi.isWifiEnabled) {
            sendEvent(mapOf("type" to "scanState", "scanning" to false))
            sendEvent(mapOf("type" to "status", "message" to "请先打开手机 Wi-Fi"))
            return
        }

        isScanning = true
        sendEvent(mapOf("type" to "scanState", "scanning" to true))
        sendEvent(mapOf("type" to "status", "message" to "扫描 $BADGE_WIFI_SSID"))

        runCatching { wifi.startScan() }
        mainHandler.postDelayed({
            publishWifiScanResults()
            stopScan()
        }, 1600)
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        if (!isScanning) {
            return
        }
        isScanning = false
        sendEvent(mapOf("type" to "scanState", "scanning" to false))
    }

    @SuppressLint("MissingPermission")
    private fun publishWifiScanResults() {
        val results = runCatching { wifiManager().scanResults }.getOrDefault(emptyList())
        results
            .filter { result ->
                val ssid = result.SSID.orEmpty()
                ssid == BADGE_WIFI_SSID || ssid.startsWith("$BADGE_WIFI_SSID-")
            }
            .sortedByDescending { it.level }
            .forEach { result ->
                val ssid = result.SSID.ifBlank { BADGE_WIFI_SSID }
                val bssid = result.BSSID ?: ssid
                val device = mapOf(
                    "address" to bssid,
                    "name" to ssid,
                    "rssi" to result.level,
                    "serviceMatch" to true,
                )
                scanResults[bssid] = device
                sendEvent(mapOf("type" to "scanResult", "device" to device))
            }

        if (scanResults.isEmpty()) {
            sendEvent(mapOf("type" to "status", "message" to "未发现 $BADGE_WIFI_SSID"))
        }
    }

    private val scanCallback = object : ScanCallback() {
        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            handleScanResult(result)
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            results.forEach(::handleScanResult)
        }

        override fun onScanFailed(errorCode: Int) {
            isScanning = false
            sendEvent(mapOf("type" to "scanState", "scanning" to false))
            sendEvent(mapOf("type" to "status", "message" to "扫描失败 $errorCode"))
        }
    }

    @SuppressLint("MissingPermission")
    private fun handleScanResult(result: ScanResult) {
        val scanRecord = result.scanRecord
        val advertisedName = scanRecord?.deviceName
        val deviceName = runCatching { result.device.name }.getOrNull()
        val name = advertisedName ?: deviceName ?: ""
        val serviceMatch = scanRecord?.serviceUuids?.any { it.uuid == SERVICE_UUID } == true
        val nameMatch = name.equals(BADGE_DEVICE_NAME, ignoreCase = true) ||
            name.startsWith(BADGE_DEVICE_NAME, ignoreCase = true)
        if (!serviceMatch && !nameMatch) {
            return
        }

        val device = mapOf(
            "address" to result.device.address,
            "name" to (name.ifBlank { BADGE_DEVICE_NAME }),
            "rssi" to result.rssi,
            "serviceMatch" to serviceMatch,
        )
        scanResults[result.device.address] = device
        sendEvent(mapOf("type" to "scanResult", "device" to device))
    }

    @SuppressLint("MissingPermission")
    private fun connect(address: String) {
        stopScan()
        closeGatt()
        Thread {
            sendConnectionEvent(connected = false, connecting = true, address = address, message = "连接 Wi-Fi")
            try {
                val network = ensureBadgeWifiNetwork()
                val status = readBadgeStatus(network)
                badgeSdAvailable = parseSdAvailable(status)
                connectedAddress = address.ifBlank { BADGE_WIFI_SSID }
                sendConnectionEvent(true, false, connectedAddress, status.ifBlank { "已连接 Wi-Fi" })
            } catch (error: Exception) {
                connectedAddress = null
                sendConnectionEvent(false, false, null, error.message ?: "连接失败")
            }
        }.start()
    }

    @SuppressLint("MissingPermission")
    private fun disconnect() {
        releaseBadgeWifi()
        closeGatt()
        badgeSdAvailable = false
        sendConnectionEvent(connected = false, connecting = false, address = null, message = "未连接")
    }

    @SuppressLint("MissingPermission")
    private fun closeGatt() {
        runCatching { gatt?.close() }
        gatt = null
        controlCharacteristic = null
        dataCharacteristic = null
        connectedAddress = null
        writeLatch?.countDown()
        writeLatch = null
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                connectedAddress = gatt.device.address
                sendConnectionEvent(true, true, connectedAddress, "发现服务")
                runCatching { gatt.requestMtu(517) }
                runCatching { gatt.discoverServices() }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                closeGatt()
                sendConnectionEvent(false, false, null, "未连接")
            } else if (status != BluetoothGatt.GATT_SUCCESS) {
                closeGatt()
                sendConnectionEvent(false, false, null, "连接失败 $status")
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                negotiatedMtu = mtu
                sendEvent(mapOf("type" to "status", "message" to "MTU $mtu"))
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                sendConnectionEvent(false, false, connectedAddress, "服务发现失败 $status")
                return
            }

            val service: BluetoothGattService? = gatt.getService(SERVICE_UUID)
            controlCharacteristic = service?.getCharacteristic(CONTROL_UUID)
            dataCharacteristic = service?.getCharacteristic(DATA_UUID)
            if (service == null || controlCharacteristic == null || dataCharacteristic == null) {
                sendConnectionEvent(false, false, connectedAddress, "不是 ESP-BAJI")
                return
            }

            enableControlNotifications(gatt, controlCharacteristic!!)
            sendConnectionEvent(true, false, connectedAddress, "已连接")
            readControlStatus()
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            writeStatus = status
            writeLatch?.countDown()
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (status == BluetoothGatt.GATT_SUCCESS && characteristic.uuid == CONTROL_UUID) {
                sendStatus(characteristic.value)
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (characteristic.uuid == CONTROL_UUID) {
                sendStatus(characteristic.value)
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            if (characteristic.uuid == CONTROL_UUID) {
                sendStatus(value)
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun enableControlNotifications(
        gatt: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
    ) {
        runCatching { gatt.setCharacteristicNotification(characteristic, true) }
        val descriptor = characteristic.getDescriptor(CCCD_UUID) ?: return
        @Suppress("DEPRECATION")
        descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        @Suppress("DEPRECATION")
        runCatching { gatt.writeDescriptor(descriptor) }
    }

    @SuppressLint("MissingPermission")
    private fun readControlStatus() {
        val g = gatt ?: return
        val characteristic = controlCharacteristic ?: return
        runCatching { g.readCharacteristic(characteristic) }
    }

    private fun sendStatus(bytes: ByteArray?) {
        val text = bytes?.toString(Charsets.UTF_8)?.trim().orEmpty()
        if (text.isNotBlank()) {
            sendEvent(mapOf("type" to "status", "message" to text))
        }
    }

    private fun writeBrightness(value: Int, result: MethodChannel.Result) {
        Thread {
            val ok = runCatching {
                val network = ensureBadgeWifiNetwork()
                requestBadgeText(network, "$BADGE_BRIGHTNESS_URL?value=$value")
            }.isSuccess
            mainHandler.post {
                if (ok) {
                    result.success(null)
                } else {
                    result.error("wifi_write", "亮度写入失败", null)
                }
            }
        }.start()
    }

    private fun pickMedia(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("busy", "正在选择素材", null)
            return
        }
        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "image/gif",
                    "image/png",
                    "image/jpeg",
                    "image/webp",
                    "video/mp4",
                    "video/webm",
                    "video/quicktime",
                    "video/*",
                ),
            )
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, REQUEST_PICK_MEDIA)
    }

    private fun prepareAsset(
        uriText: String,
        displayName: String,
        fps: Int,
        maxPackageBytes: Int,
        crop: CropTransform,
        warmPreviewPath: String?,
        result: MethodChannel.Result,
    ) {
        Thread {
            try {
                val totalStartMs = System.currentTimeMillis()
                val uri = Uri.parse(uriText)
                preparingVideoUri.set(if (isVideoMime(normalizeMime(contentResolver.getType(uri), displayName))) uriText else null)
                val mime = normalizeMime(contentResolver.getType(uri), displayName)
                val size = querySize(uri)
                if (isVideoMime(mime) && size > MAX_VIDEO_INPUT_BYTES) {
                    throw IllegalArgumentException("视频文件过大")
                }
                val encoder = EbajEncoder(::sendEncodePrepareProgress)
                val encodeStartMs = System.currentTimeMillis()
                val encoded = encoder.encode(this, uri, mime, fps, maxPackageBytes, crop)
                val encodeMs = System.currentTimeMillis() - encodeStartMs
                sendPrepareProgress(PREPARE_PROGRESS_WRITING)
                val directory = persistentAssetDirectory("ebaj")
                val stem = "${System.currentTimeMillis()}_${safeFileName(displayName)}"
                val file = File(directory, "$stem.ebaj")
                val writeStartMs = System.currentTimeMillis()
                file.writeBytes(encoded.packageBytes)
                val writeMs = System.currentTimeMillis() - writeStartMs
                val previewStartMs = System.currentTimeMillis()
                val previewPath = buildPreviewBytes(uri, mime, null, crop)?.let { preview ->
                    File(directory, "$stem.png").also { it.writeBytes(preview) }.absolutePath
                }
                val animatedPreviewPath = if (isVideoMime(mime)) {
                    reusableWarmPreviewBytes(warmPreviewPath)?.let { preview ->
                        File(directory, "$stem.gif").also { it.writeBytes(preview) }.absolutePath
                    }
                } else {
                    val bytes = readUriBytes(uri)
                    copyAnimatedPreview(bytes, directory, stem)
                }
                val previewMs = System.currentTimeMillis() - previewStartMs
                val response = mapOf(
                    "assetPath" to file.absolutePath,
                    "previewPath" to previewPath,
                    "animatedPreviewPath" to animatedPreviewPath,
                    "sourceUri" to uri.toString(),
                    "mime" to mime,
                    "name" to displayName,
                    "packageSize" to encoded.packageBytes.size,
                    "frameCount" to encoded.frameCount,
                    "fps" to encoded.fps,
                    "crc32" to encoded.crc32,
                )
                val totalMs = System.currentTimeMillis() - totalStartMs
                sendPrepareProgress(PREPARE_PROGRESS_DONE)
                android.util.Log.i(
                    "BadgePrepare",
                    "prepare perf mime=$mime frames=${encoded.frameCount} fps=${encoded.fps} size=${encoded.packageBytes.size} encode=${encodeMs}ms write=${writeMs}ms preview=${previewMs}ms total=${totalMs}ms",
                )
                mainHandler.post { result.success(response) }
                if (isVideoMime(mime) && animatedPreviewPath.isNullOrBlank()) {
                    scheduleVideoAnimatedPreview(uri, uriText, directory, stem, crop, "assetPreviewReady", file.absolutePath)
                }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error("prepare_failed", error.message ?: "素材处理失败", null)
                }
            } finally {
                preparingVideoUri.compareAndSet(uriText, null)
            }
        }.start()
    }

    private fun sendPrepareProgress(progress: Double) {
        sendEvent(mapOf("type" to "prepareProgress", "progress" to progress.coerceIn(0.0, 1.0)))
    }

    private fun sendEncodePrepareProgress(progress: Double) {
        sendPrepareProgress(progress * PREPARE_PROGRESS_PACKING)
    }

    private fun warmVideoAnimatedPreview(uriText: String, displayName: String, result: MethodChannel.Result) {
        result.success(null)
        Thread {
            runCatching {
                val uri = Uri.parse(uriText)
                val mime = normalizeMime(contentResolver.getType(uri), displayName)
                if (!isVideoMime(mime)) {
                    return@Thread
                }
                if (preparingVideoUri.get() == uriText) {
                    return@Thread
                }
                val directory = persistentAssetDirectory("media_preview")
                val stem = "${System.currentTimeMillis()}_${safeFileName(displayName)}"
                scheduleVideoAnimatedPreview(uri, uriText, directory, stem, CropTransform.DEFAULT, "videoPreviewReady")
            }
        }.start()
    }

    private fun scheduleVideoAnimatedPreview(
        uri: Uri,
        uriText: String,
        directory: File,
        stem: String,
        crop: CropTransform,
        eventType: String,
        assetPath: String? = null,
    ) {
        Thread {
            runCatching {
                val previewStartMs = System.currentTimeMillis()
                val preview = buildVideoAnimatedPreview(uri, crop) ?: return@Thread
                val path = File(directory, "$stem.gif").also { it.writeBytes(preview) }.absolutePath
                val previewMs = System.currentTimeMillis() - previewStartMs
                android.util.Log.i(
                    "BadgePrepare",
                    "animated preview ready event=$eventType bytes=${preview.size} time=${previewMs}ms",
                )
                sendEvent(
                    mutableMapOf<String, Any?>(
                        "type" to eventType,
                        "uri" to uriText,
                        "assetPath" to assetPath,
                        "animatedPreviewPath" to path,
                    ),
                )
            }
        }.start()
    }

    private fun uploadAsset(assetPath: String, result: MethodChannel.Result) {
        Thread {
            try {
                isUploading = true
                val file = File(assetPath)
                if (!file.exists()) {
                    throw IllegalArgumentException("素材包不存在")
                }
                val packageBytes = file.readBytes()
                if (!isSupportedPackage(packageBytes)) {
                    throw IllegalArgumentException("历史素材是旧格式，请重新导入生成 EBAJ4")
                }
                val crc = crc32(packageBytes)
                uploadAssetWithRetry(packageBytes, crc)
                sendEvent(mapOf("type" to "uploadProgress", "progress" to 1.0, "message" to "已切换显示"))
                mainHandler.post { result.success(null) }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error("upload_failed", error.message ?: "上传失败", null)
                }
            } finally {
                isUploading = false
            }
        }.start()
    }

    private fun isSupportedPackage(bytes: ByteArray): Boolean {
        if (bytes.size < HEADER_SIZE) {
            return false
        }
        val magic = (bytes[0].toInt() and 0xff) or
            ((bytes[1].toInt() and 0xff) shl 8) or
            ((bytes[2].toInt() and 0xff) shl 16) or
            ((bytes[3].toInt() and 0xff) shl 24)
        val version = (bytes[4].toInt() and 0xff) or
            ((bytes[5].toInt() and 0xff) shl 8)
        return magic == MAGIC &&
            version == VERSION
    }

    private fun uploadAssetWithRetry(packageBytes: ByteArray, crc: Long) {
        var lastError: Exception? = null
        for (attempt in 0 until HTTP_UPLOAD_ATTEMPTS) {
            try {
                val network = ensureBadgeWifiNetwork()
                bindUploadNetwork(network)
                acquireUploadWifiLock()
                try {
                    uploadAssetOverTcp(network, packageBytes, crc)
                } catch (tcpError: Exception) {
                    sendEvent(
                        mapOf(
                            "type" to "status",
                            "message" to "TCP上传失败，回退HTTP",
                        ),
                    )
                    uploadAssetOverHttp(network, packageBytes, crc)
                }
                return
            } catch (error: Exception) {
                lastError = error
                sendEvent(
                    mapOf(
                        "type" to "status",
                        "message" to if (attempt + 1 < HTTP_UPLOAD_ATTEMPTS) "上传中断，重试" else "上传失败",
                    ),
                )
                if (attempt + 1 < HTTP_UPLOAD_ATTEMPTS) {
                    releaseBadgeWifi()
                    Thread.sleep(800)
                }
            } finally {
                releaseUploadWifiLock()
                runCatching { connectivityManager().bindProcessToNetwork(null) }
            }
        }
        throw lastError ?: IllegalStateException("上传失败")
    }

    private fun bindUploadNetwork(network: Network) {
        val bound = connectivityManager().bindProcessToNetwork(network)
        if (!bound) {
            throw IllegalStateException("无法绑定 ESP-BAJI 网络")
        }
    }

    @SuppressLint("WakelockTimeout")
    private fun acquireUploadWifiLock() {
        if (uploadWifiLock?.isHeld == true) {
            return
        }
        uploadWifiLock = wifiManager().createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "esp_baji_upload").also {
            it.setReferenceCounted(false)
            it.acquire()
        }
    }

    private fun releaseUploadWifiLock() {
        runCatching {
            if (uploadWifiLock?.isHeld == true) {
                uploadWifiLock?.release()
            }
        }
        uploadWifiLock = null
    }

    private fun connectivityManager(): ConnectivityManager {
        return getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }

    private fun wifiManager(): WifiManager {
        return applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    }

    @SuppressLint("MissingPermission")
    private fun ensureBadgeWifiNetwork(): Network {
        if (!hasWifiPermissions()) {
            throw IllegalStateException("请允许 Wi-Fi 权限后重试")
        }

        badgeWifiNetwork?.let { return it }

        val manager = connectivityManager()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return manager.activeNetwork ?: throw IllegalStateException("请先手动连接 $BADGE_WIFI_SSID Wi-Fi")
        }

        sendEvent(mapOf("type" to "status", "message" to "连接 $BADGE_WIFI_SSID Wi-Fi"))
        releaseBadgeWifi()

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(BADGE_WIFI_SSID)
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .setNetworkSpecifier(specifier)
            .build()

        val latch = CountDownLatch(1)
        val networkRef = AtomicReference<Network?>()
        val errorRef = AtomicReference<String?>()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                badgeWifiNetwork = network
                networkRef.set(network)
                latch.countDown()
            }

            override fun onUnavailable() {
                errorRef.set("没有连接到 $BADGE_WIFI_SSID")
                latch.countDown()
            }

            override fun onLost(network: Network) {
                if (badgeWifiNetwork == network) {
                    badgeWifiNetwork = null
                    connectedAddress = null
                    sendConnectionEvent(false, false, null, "断开连接")
                }
            }
        }

        badgeWifiCallback = callback
        manager.requestNetwork(request, callback, WIFI_CONNECT_TIMEOUT_MS.toInt())

        val connected = latch.await(WIFI_CONNECT_TIMEOUT_MS + 5000L, TimeUnit.MILLISECONDS)
        val network = networkRef.get()
        if (!connected || network == null) {
            releaseBadgeWifi()
            throw IllegalStateException(errorRef.get() ?: "$BADGE_WIFI_SSID Wi-Fi 连接超时")
        }

        return network
    }

    private fun releaseBadgeWifi() {
        val callback = badgeWifiCallback ?: return
        runCatching { connectivityManager().unregisterNetworkCallback(callback) }
        badgeWifiCallback = null
        badgeWifiNetwork = null
    }

    private fun uploadAssetOverTcp(network: Network, packageBytes: ByteArray, crc: Long) {
        val socket = network.socketFactory.createSocket() as Socket
        socket.use { active ->
            active.tcpNoDelay = true
            active.sendBufferSize = TCP_UPLOAD_CHUNK_BYTES
            active.soTimeout = HTTP_READ_TIMEOUT_MS
            active.connect(InetSocketAddress(BADGE_HOST, BADGE_UPLOAD_TCP_PORT), HTTP_CONNECT_TIMEOUT_MS)

            val header = ByteArray(12)
            writeLe32(header, 0, BADGE_TCP_UPLOAD_MAGIC.toLong())
            writeLe32(header, 4, packageBytes.size.toLong())
            writeLe32(header, 8, crc)

            val output = BufferedOutputStream(active.getOutputStream(), TCP_UPLOAD_CHUNK_BYTES)
            output.write(header)
            var offset = 0
            while (offset < packageBytes.size) {
                val length = min(TCP_UPLOAD_CHUNK_BYTES, packageBytes.size - offset)
                output.write(packageBytes, offset, length)
                offset += length
                if (offset == packageBytes.size || offset % (TCP_UPLOAD_CHUNK_BYTES * 2) == 0) {
                    sendEvent(
                        mapOf(
                            "type" to "uploadProgress",
                            "progress" to offset.toDouble() / packageBytes.size.toDouble(),
                            "message" to "TCP上传 ${offset * 100 / packageBytes.size}%",
                        ),
                    )
                }
            }
            output.flush()
            active.shutdownOutput()

            val response = active.getInputStream().bufferedReader().use { it.readLine() }.orEmpty()
            if (!response.startsWith("OK")) {
                throw IllegalStateException(response.ifBlank { "TCP上传失败" })
            }
        }
    }

    private fun uploadAssetOverHttp(network: Network, packageBytes: ByteArray, crc: Long) {
        val url = URL(BADGE_UPLOAD_URL)
        val connection = network.openConnection(url) as HttpURLConnection
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.useCaches = false
        connection.connectTimeout = HTTP_CONNECT_TIMEOUT_MS
        connection.readTimeout = HTTP_READ_TIMEOUT_MS
        connection.setFixedLengthStreamingMode(packageBytes.size)
        connection.setRequestProperty("Content-Type", "application/octet-stream")
        connection.setRequestProperty("X-EBAJ-CRC32", "%08x".format(crc))

        try {
            connection.outputStream.use { output ->
                var offset = 0
                while (offset < packageBytes.size) {
                    val length = min(HTTP_UPLOAD_CHUNK_BYTES, packageBytes.size - offset)
                    output.write(packageBytes, offset, length)
                    offset += length
                    if (offset == packageBytes.size || offset % (HTTP_UPLOAD_CHUNK_BYTES * 8) == 0) {
                        sendEvent(
                            mapOf(
                                "type" to "uploadProgress",
                                "progress" to offset.toDouble() / packageBytes.size.toDouble(),
                                "message" to "上传 ${offset * 100 / packageBytes.size}%",
                            ),
                        )
                    }
                }
            }

            val code = connection.responseCode
            if (code !in 200..299) {
                val errorText = connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
                throw IllegalStateException("HTTP $code ${errorText.ifBlank { "上传失败" }}")
            }

            connection.inputStream?.close()
        } finally {
            connection.disconnect()
        }
    }

    private fun readBadgeStatus(network: Network): String {
        return requestBadgeText(network, BADGE_STATUS_URL)
    }

    private fun parseSdAvailable(status: String): Boolean {
        return status.split(' ', '\n', '\r', '\t')
            .any { token -> token.equals("sd=1", ignoreCase = true) || token.equals("storage=sd", ignoreCase = true) }
    }

    private fun resolveBadgePackageBudget(sdAvailable: Boolean): Int {
        return if (sdAvailable) SD_STREAM_BUDGET_BYTES else LEGACY_FLASH_BUDGET_BYTES
    }

    private fun requestBadgeText(
        network: Network,
        urlText: String,
        timeoutMs: Int = HTTP_CONNECT_TIMEOUT_MS,
    ): String {
        val connection = network.openConnection(URL(urlText)) as HttpURLConnection
        connection.requestMethod = "GET"
        connection.useCaches = false
        connection.connectTimeout = timeoutMs
        connection.readTimeout = timeoutMs
        return try {
            val code = connection.responseCode
            if (code !in 200..299) {
                val errorText = connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
                throw IllegalStateException("HTTP $code ${errorText.ifBlank { "请求失败" }}")
            }
            connection.inputStream.bufferedReader().use { it.readText() }.trim()
        } finally {
            connection.disconnect()
        }
    }

    private fun buildStartPacket(size: Int, crc: Long): ByteArray {
        val packet = ByteArray(9)
        packet[0] = CMD_START
        writeLe32(packet, 1, size.toLong())
        writeLe32(packet, 5, crc)
        return packet
    }

    private fun writeControl(payload: ByteArray): Boolean {
        val characteristic = controlCharacteristic ?: return false
        return writeCharacteristicSync(characteristic, payload, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
    }

    private fun writeData(payload: ByteArray): Boolean {
        val characteristic = dataCharacteristic ?: return false
        return writeCharacteristicSync(characteristic, payload, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
    }

    @SuppressLint("MissingPermission")
    private fun writeCharacteristicSync(
        characteristic: BluetoothGattCharacteristic,
        payload: ByteArray,
        writeType: Int,
    ): Boolean {
        synchronized(bleWriteLock) {
            val activeGatt = gatt ?: return false
            val latch = CountDownLatch(1)
            writeLatch = latch
            writeStatus = BluetoothGatt.GATT_FAILURE
            mainHandler.post {
                @Suppress("DEPRECATION")
                characteristic.writeType = writeType
                @Suppress("DEPRECATION")
                characteristic.value = payload
                @Suppress("DEPRECATION")
                val accepted = activeGatt.writeCharacteristic(characteristic)
                if (!accepted) {
                    writeStatus = BluetoothGatt.GATT_FAILURE
                    latch.countDown()
                }
            }
            val completed = latch.await(WRITE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            writeLatch = null
            return completed && writeStatus == BluetoothGatt.GATT_SUCCESS
        }
    }

    private fun connectionState(): Map<String, Any?> {
        return mapOf(
            "connected" to (connectedAddress != null && badgeWifiNetwork != null),
            "address" to connectedAddress,
            "sdAvailable" to badgeSdAvailable,
            "message" to if (connectedAddress == null) "未连接" else "已连接",
        )
    }

    private fun readConnectionState(result: MethodChannel.Result) {
        Thread {
            if (isUploading) {
                mainHandler.post {
                    result.success(
                        mapOf(
                            "connected" to (connectedAddress != null && badgeWifiNetwork != null),
                            "address" to connectedAddress,
                            "sdAvailable" to badgeSdAvailable,
                            "message" to "上传中",
                        ),
                    )
                }
                return@Thread
            }

            val network = badgeWifiNetwork
            val address = connectedAddress
            val state = if (network != null && address != null) {
                val ok = runCatching {
                    val status = requestBadgeText(network, BADGE_STATUS_URL, HTTP_STATUS_TIMEOUT_MS)
                    badgeSdAvailable = parseSdAvailable(status)
                }.isSuccess
                if (ok) {
                    mapOf(
                        "connected" to true,
                        "address" to address,
                        "sdAvailable" to badgeSdAvailable,
                        "message" to "已连接",
                    )
                } else {
                    connectedAddress = null
                    releaseBadgeWifi()
                    badgeSdAvailable = false
                    mapOf(
                        "connected" to false,
                        "address" to null,
                        "sdAvailable" to false,
                        "message" to "断开连接",
                    )
                }
            } else {
                connectionState()
            }
            mainHandler.post { result.success(state) }
        }.start()
    }

    private fun sendConnectionEvent(
        connected: Boolean,
        connecting: Boolean,
        address: String?,
        message: String,
    ) {
        sendEvent(
            mapOf(
                "type" to "connectionState",
                "connected" to connected,
                "connecting" to connecting,
                "address" to address,
                "sdAvailable" to badgeSdAvailable,
                "message" to message,
            ),
        )
    }

    private fun sendEvent(payload: Map<String, Any?>) {
        if (!::channel.isInitialized) {
            return
        }
        mainHandler.post { channel.invokeMethod("nativeEvent", payload) }
    }

    private fun queryName(uri: Uri): String {
        query(uri)?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst()) {
                return cursor.getString(index) ?: "asset"
            }
        }
        return uri.lastPathSegment ?: "asset"
    }

    private fun querySize(uri: Uri): Int {
        query(uri)?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (index >= 0 && cursor.moveToFirst()) {
                return cursor.getLong(index).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
            }
        }
        return -1
    }

    private fun query(uri: Uri): Cursor? {
        return contentResolver.query(uri, null, null, null, null)
    }

    private fun readUriBytes(uri: Uri): ByteArray {
        return contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?: throw IllegalArgumentException("无法读取素材")
    }

    private fun buildPreviewBytes(
        uri: Uri,
        mime: String,
        source: ByteArray?,
        crop: CropTransform,
    ): ByteArray? {
        val bitmap = runCatching {
                if (isVideoMime(mime)) {
                    renderVideoFrame(this, uri, PREVIEW_SIZE, PREVIEW_SIZE, crop)
                } else {
                    val bytes = source ?: readUriBytes(uri)
                    val movie = Movie.decodeByteArray(bytes, 0, bytes.size)
                if (movie != null && movie.width() > 0 && movie.height() > 0) {
                    movie.setTime(0)
                    renderMovieFrame(movie, PREVIEW_SIZE, PREVIEW_SIZE, crop)
                } else {
                    val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                        ?: return null
                    renderBitmapFrame(decoded, PREVIEW_SIZE, PREVIEW_SIZE, crop)
                }
                }
            }.getOrNull() ?: return null

        val output = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 92, output)
        bitmap.recycle()
        return output.toByteArray()
    }

    private fun copyAnimatedPreview(source: ByteArray, directory: File, stem: String): String? {
        if (!isGif(source)) {
            return null
        }
        return File(directory, "$stem.gif").also { it.writeBytes(source) }.absolutePath
    }

    private fun buildVideoAnimatedPreview(uri: Uri, crop: CropTransform, warmPreviewPath: String? = null): ByteArray? {
        return runCatching {
            reusableWarmPreviewBytes(warmPreviewPath)?.let { return@runCatching it }
            EbajEncoder {}.buildVideoAnimatedPreview(this, uri, crop)
        }.getOrNull()
    }

    private fun reusableWarmPreviewBytes(path: String?): ByteArray? {
        if (path.isNullOrBlank()) {
            return null
        }
        val file = File(path)
        return if (file.exists() && file.isFile && file.length() > 0L) {
            file.readBytes()
        } else {
            null
        }
    }

    private fun isGif(source: ByteArray): Boolean {
        if (source.size < 6) {
            return false
        }
        return source[0] == 'G'.code.toByte() &&
            source[1] == 'I'.code.toByte() &&
            source[2] == 'F'.code.toByte() &&
            source[3] == '8'.code.toByte() &&
            (source[4] == '7'.code.toByte() || source[4] == '9'.code.toByte()) &&
            source[5] == 'a'.code.toByte()
    }

    private fun guessMimeFromName(name: String): String {
        val lower = name.lowercase()
        return when {
            lower.endsWith(".gif") -> "image/gif"
            lower.endsWith(".png") -> "image/png"
            lower.endsWith(".jpg") || lower.endsWith(".jpeg") -> "image/jpeg"
            lower.endsWith(".webp") -> "image/webp"
            lower.endsWith(".mp4") -> "video/mp4"
            lower.endsWith(".webm") -> "video/webm"
            lower.endsWith(".mov") -> "video/quicktime"
            else -> "application/octet-stream"
        }
    }

    private fun normalizeMime(mime: String?, name: String): String {
        val value = mime.orEmpty()
        return if (value.isBlank() || value == "application/octet-stream") {
            guessMimeFromName(name)
        } else {
            value
        }
    }

    private fun safeFileName(name: String): String {
        return name.replace(Regex("[^A-Za-z0-9._-]"), "_").take(48).ifBlank { "asset" }
    }

    private fun persistentAssetDirectory(name: String): File {
        return File(filesDir, "badge_assets/$name").apply { mkdirs() }
    }

    private fun loadHistory(result: MethodChannel.Result) {
        Thread {
            val history = runCatching { loadAndRepairHistory() }.getOrDefault(emptyList())
            mainHandler.post { result.success(history) }
        }.start()
    }

    private fun loadAndRepairHistory(): List<Map<String, Any?>> {
        val raw = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getString(HISTORY_KEY, "[]")
        val array = JSONArray(raw)
        val output = mutableListOf<Map<String, Any?>>()
        var changed = false
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            val repaired = repairHistoryItem(item)
            changed = changed || repaired.toString() != item.toString()
            output += historyMap(repaired)
            array.put(index, repaired)
        }
        if (changed) {
            getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(HISTORY_KEY, array.toString())
                .apply()
        }
        return output
    }

    private fun historyMap(item: JSONObject): Map<String, Any?> {
        return mapOf(
                "assetPath" to item.optString("assetPath"),
                "previewPath" to item.optString("previewPath"),
                "animatedPreviewPath" to item.optString("animatedPreviewPath"),
                "sourceUri" to item.optString("sourceUri"),
                "mime" to item.optString("mime"),
                "name" to item.optString("name"),
                "packageSize" to item.optInt("packageSize"),
                "frameCount" to item.optInt("frameCount"),
                "fps" to item.optInt("fps"),
                "crc32" to item.optLong("crc32"),
                "createdAt" to item.optLong("createdAt"),
                "cropScale" to item.optDouble("cropScale", 1.0),
                "cropOffsetX" to item.optDouble("cropOffsetX", 0.0),
                "cropOffsetY" to item.optDouble("cropOffsetY", 0.0),
            )
    }

    private fun repairHistoryItem(item: JSONObject): JSONObject {
        val repaired = JSONObject(item.toString())
        val sourceUriText = repaired.optString("sourceUri")
        if (sourceUriText.isBlank() || sourceUriText == "null") {
            return repaired
        }

        val uri = runCatching { Uri.parse(sourceUriText) }.getOrNull() ?: return repaired
        val name = repaired.optString("name").ifBlank { "asset" }
        val mime = normalizeMime(repaired.optString("mime"), name)
        val crop = CropTransform(
            scale = repaired.optDouble("cropScale", 1.0).coerceIn(1.0, 4.0),
            offsetX = repaired.optDouble("cropOffsetX", 0.0).coerceIn(-1.5, 1.5),
            offsetY = repaired.optDouble("cropOffsetY", 0.0).coerceIn(-1.5, 1.5),
        )
        val directory = persistentAssetDirectory("ebaj")
        val stem = "restored_${repaired.optLong("createdAt", System.currentTimeMillis())}_${safeFileName(name)}"
        var changed = false

        if (!existingFilePath(repaired.optString("animatedPreviewPath"))) {
            val restoredAnimated = runCatching {
                if (isVideoMime(mime)) {
                    buildVideoAnimatedPreview(uri, crop, null)?.let { preview ->
                        File(directory, "$stem.gif").also { it.writeBytes(preview) }.absolutePath
                    }
                } else {
                    copyAnimatedPreview(readUriBytes(uri), directory, stem)
                }
            }.getOrNull()
            if (!restoredAnimated.isNullOrBlank()) {
                repaired.put("animatedPreviewPath", restoredAnimated)
                changed = true
            }
        }

        if (!existingFilePath(repaired.optString("previewPath"))) {
            val restoredPreview = runCatching {
                buildPreviewBytes(uri, mime, null, crop)?.let { preview ->
                    File(directory, "$stem.png").also { it.writeBytes(preview) }.absolutePath
                }
            }.getOrNull()
            if (!restoredPreview.isNullOrBlank()) {
                repaired.put("previewPath", restoredPreview)
                changed = true
            }
        }

        if (!existingFilePath(repaired.optString("assetPath"))) {
            val restoredAsset = runCatching {
                val fps = repaired.optInt("fps", 25).coerceIn(1, 60)
                val encoded = EbajEncoder {}.encode(
                    this,
                    uri,
                    mime,
                    fps,
                    resolveBadgePackageBudget(true),
                    crop,
                )
                File(directory, "$stem.ebaj").also { it.writeBytes(encoded.packageBytes) }
                    .absolutePath
            }.getOrNull()
            if (!restoredAsset.isNullOrBlank()) {
                repaired.put("assetPath", restoredAsset)
                changed = true
            }
        }

        return if (changed) repaired else item
    }

    private fun existingFilePath(path: String?): Boolean {
        if (path.isNullOrBlank() || path == "null") {
            return false
        }
        val file = File(path)
        return file.exists() && file.isFile && file.length() > 0L
    }

    private fun deleteAssetFiles(assetPath: String?, previewPath: String?, animatedPreviewPath: String?) {
        listOf(assetPath, previewPath, animatedPreviewPath)
            .filterNotNull()
            .distinct()
            .forEach { path ->
                runCatching {
                    val file = File(path)
                    val root = File(filesDir, "badge_assets").canonicalFile
                    val target = file.canonicalFile
                    val inAssetRoot = target == root || target.path.startsWith(root.path + File.separator)
                    if (inAssetRoot && target.isFile) {
                        target.delete()
                    }
                }
            }
    }

    private fun saveHistory(items: List<*>) {
        val array = JSONArray()
        items.take(MAX_HISTORY_ITEMS).forEach { entry ->
            val map = entry as? Map<*, *> ?: return@forEach
            val item = JSONObject()
            item.put("assetPath", map["assetPath"])
            item.put("previewPath", map["previewPath"])
            item.put("animatedPreviewPath", map["animatedPreviewPath"])
            item.put("sourceUri", map["sourceUri"])
            item.put("mime", map["mime"])
            item.put("name", map["name"])
            item.put("packageSize", map["packageSize"])
            item.put("frameCount", map["frameCount"])
            item.put("fps", map["fps"])
            item.put("crc32", map["crc32"])
            item.put("createdAt", map["createdAt"])
            item.put("cropScale", map["cropScale"])
            item.put("cropOffsetX", map["cropOffsetX"])
            item.put("cropOffsetY", map["cropOffsetY"])
            array.put(item)
        }
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(HISTORY_KEY, array.toString())
            .apply()
    }

    private class EbajEncoder(private val onProgress: (Double) -> Unit) {
        private var pixelScratch: PixelScratch? = null

        fun encode(
            context: Context,
            uri: Uri,
            mime: String,
            requestedFps: Int,
            maxPackageBytes: Int,
            crop: CropTransform,
        ): EncodedPackage {
            val fps = requestedFps.coerceIn(1, 60)
            val delayMs = frameDelayMs(fps)
            val selectedStreamSize = sampleStreamResolution(context, uri, mime, fps, delayMs, crop)
            val selected = encodeAtResolution(context, uri, mime, fps, delayMs, selectedStreamSize, crop)
            if (selected.packageBytes.size > maxPackageBytes) {
                throw PackageTooLargeException(ASSET_TOO_LARGE_MESSAGE)
            }
            return selected
        }

        private fun encodeAtResolution(
            context: Context,
            uri: Uri,
            mime: String,
            fps: Int,
            delayMs: Int,
            streamSize: Int,
            crop: CropTransform,
        ): EncodedPackage {
            val frames = if (isVideoMime(mime)) {
                encodeVideoFrames(context, uri, delayMs, streamSize, crop)
            } else {
                val source = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    ?: throw IllegalArgumentException("无法读取素材")
                val movie = Movie.decodeByteArray(source, 0, source.size)
                if (movie != null && movie.width() > 0 && movie.height() > 0 && movie.duration() > 0) {
                    encodeGifFrames(movie, delayMs, streamSize, crop)
                } else {
                    val bitmap = BitmapFactory.decodeByteArray(source, 0, source.size)
                        ?: throw IllegalArgumentException("不支持的图片格式")
                    val rendered = renderBitmapFrame(bitmap, streamSize, streamSize, crop)
                    val indexed = quantizeToIndexed(rendered)
                    rendered.recycle()
                    listOf(encodeFrame(indexed, null, delayMs, streamSize, forceKeyframe = true))
                }
            }

            return packFrames(frames, fps, streamSize)
        }

        private fun encodeVideoFrames(
            context: Context,
            uri: Uri,
            delayMs: Int,
            streamSize: Int,
            crop: CropTransform,
        ): List<EncodedFrame> {
            return runCatching {
                val durationMs = videoDurationMs(context, uri)
                val totalFrames = max(1, ((durationMs + delayMs - 1) / delayMs).toInt())
                val targetFrameTimesUs = LongArray(totalFrames) { index ->
                    min((durationMs - 1L) * 1000L, index.toLong() * delayMs.toLong() * 1000L)
                }
                val frames = mutableListOf<EncodedFrame>()
                var previous: ByteArray? = null

                decodeVideoFramesSequentially(context, uri, targetFrameTimesUs, streamSize, streamSize, crop) { index, bitmap ->
                    val indexed = quantizeToIndexed(bitmap)
                    bitmap.recycle()
                    val frame = encodeFrame(indexed, previous, delayMs, streamSize, forceKeyframe = index == 0)
                    frames += frame
                    previous = indexed
                    onProgress((index + 1).toDouble() / totalFrames.toDouble())
                }
                if (frames.isEmpty()) {
                    throw IllegalArgumentException("视频帧读取失败")
                }
                frames
            }.getOrElse { error ->
                android.util.Log.w("BadgePrepare", "sequential video decode failed, falling back: ${error.message}")
                encodeVideoFramesWithRetriever(context, uri, delayMs, streamSize, crop)
            }
        }

        private fun encodeVideoFramesWithRetriever(
            context: Context,
            uri: Uri,
            delayMs: Int,
            streamSize: Int,
            crop: CropTransform,
        ): List<EncodedFrame> {
            val retriever = createRetriever(context, uri)
            try {
                val durationMs = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull()
                    ?.coerceAtLeast(1L)
                    ?: 1000L
                val totalFrames = max(1, ((durationMs + delayMs - 1) / delayMs).toInt())
                val frames = mutableListOf<EncodedFrame>()
                var previous: ByteArray? = null

                for (index in 0 until totalFrames) {
                    val timeUs = min((durationMs - 1L) * 1000L, index.toLong() * delayMs.toLong() * 1000L)
                    val source = retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
                        ?: throw IllegalArgumentException("视频帧读取失败")
                    val bitmap = renderBitmapFrame(source, streamSize, streamSize, crop)
                    val indexed = quantizeToIndexed(bitmap)
                    bitmap.recycle()
                    val frame = encodeFrame(indexed, previous, delayMs, streamSize, forceKeyframe = index == 0)
                    frames += frame
                    previous = indexed
                    onProgress((index + 1).toDouble() / totalFrames.toDouble())
                }
                return frames
            } finally {
                retriever.release()
            }
        }

        private fun sampleStreamResolution(
            context: Context,
            uri: Uri,
            mime: String,
            fps: Int,
            delayMs: Int,
            crop: CropTransform,
        ): Int {
            if (isVideoMime(mime)) {
                return selectStreamResolution(
                    STREAM_RESOLUTIONS.toList().map { streamSize ->
                        StreamEstimate(
                            streamSize,
                            estimateVideoBytesPerSecond(context, uri, fps, delayMs, streamSize, crop),
                        )
                    },
                )
            }

            val source = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                ?: throw IllegalArgumentException("无法读取素材")
            val movie = Movie.decodeByteArray(source, 0, source.size)
            if (movie != null && movie.width() > 0 && movie.height() > 0 && movie.duration() > 0) {
                return selectStreamResolution(
                    STREAM_RESOLUTIONS.toList().map { streamSize ->
                        StreamEstimate(streamSize, estimateGifBytesPerSecond(movie, fps, delayMs, streamSize, crop))
                    },
                )
            }

            return WIDTH
        }

        private fun estimateVideoBytesPerSecond(
            context: Context,
            uri: Uri,
            fps: Int,
            delayMs: Int,
            streamSize: Int,
            crop: CropTransform,
        ): Long {
            val retriever = createRetriever(context, uri)
            try {
                val durationMs = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull()
                    ?.coerceAtLeast(1L)
                    ?: 1000L
                val totalFrames = max(1, ((durationMs + delayMs - 1) / delayMs).toInt())
                val indexes = sampleFrameIndexes(totalFrames)
                var previous: ByteArray? = null
                var payloadBytes = 0L

                indexes.forEachIndexed { sampleIndex, frameIndex ->
                    val timeUs = min((durationMs - 1L) * 1000L, frameIndex.toLong() * delayMs.toLong() * 1000L)
                    val source = retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
                        ?: throw IllegalArgumentException("视频帧读取失败")
                    val bitmap = renderBitmapFrame(source, streamSize, streamSize, crop)
                    val indexed = quantizeToIndexed(bitmap)
                    bitmap.recycle()
                    val frame = encodeFrame(indexed, previous, delayMs, streamSize, forceKeyframe = sampleIndex == 0)
                    payloadBytes += frame.data.size.toLong()
                    previous = indexed
                }

                return payloadBytes * fps.toLong() / max(1, indexes.size).toLong()
            } finally {
                retriever.release()
            }
        }

        fun buildVideoAnimatedPreview(
            context: Context,
            uri: Uri,
            crop: CropTransform,
        ): ByteArray? {
            val durationMs = videoDurationMs(context, uri)
            val delayMs = frameDelayMs(VIDEO_PREVIEW_GIF_FPS)
            val totalFrames = max(1, ((durationMs + delayMs - 1) / delayMs).toInt())
            val targetFrameTimesUs = LongArray(totalFrames) { index ->
                min((durationMs - 1L) * 1000L, index.toLong() * delayMs.toLong() * 1000L)
            }
            val frames = mutableListOf<ByteArray>()
            decodeVideoPreviewFramesSequentially(context, uri, targetFrameTimesUs, crop) { _, indexed ->
                frames += indexed
            }
            if (frames.isEmpty()) {
                return null
            }
            return encodeIndexedGif(frames, VIDEO_PREVIEW_GIF_SIZE, VIDEO_PREVIEW_GIF_SIZE, delayMs)
        }

        private fun decodeVideoPreviewFramesSequentially(
            context: Context,
            uri: Uri,
            targetFrameTimesUs: LongArray,
            crop: CropTransform,
            onFrame: (Int, ByteArray) -> Unit,
        ) {
            if (targetFrameTimesUs.isEmpty()) {
                return
            }

            val extractor = MediaExtractor()
            var decoder: MediaCodec? = null
            try {
                context.contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                    extractor.setDataSource(descriptor.fileDescriptor)
                } ?: throw IllegalArgumentException("无法读取视频")

                val trackIndex = selectVideoTrack(extractor)
                if (trackIndex < 0) {
                    throw IllegalArgumentException("视频轨道不存在")
                }
                extractor.selectTrack(trackIndex)
                val inputFormat = extractor.getTrackFormat(trackIndex)
                val mime = inputFormat.getString(MediaFormat.KEY_MIME)
                    ?: throw IllegalArgumentException("视频格式错误")
                inputFormat.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
                decoder = MediaCodec.createDecoderByType(mime)
                decoder.configure(inputFormat, null, null, 0)
                decoder.start()

                val bufferInfo = MediaCodec.BufferInfo()
                var sawInputEnd = false
                var sawOutputEnd = false
                var nextTargetIndex = 0

                while (!sawOutputEnd && nextTargetIndex < targetFrameTimesUs.size) {
                    if (!sawInputEnd) {
                        val inputIndex = decoder.dequeueInputBuffer(VIDEO_DECODE_TIMEOUT_US)
                        if (inputIndex >= 0) {
                            val inputBuffer = decoder.getInputBuffer(inputIndex)
                                ?: throw IllegalArgumentException("视频输入缓冲区不可用")
                            val sampleSize = extractor.readSampleData(inputBuffer, 0)
                            if (sampleSize < 0) {
                                decoder.queueInputBuffer(
                                    inputIndex,
                                    0,
                                    0,
                                    0,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                )
                                sawInputEnd = true
                            } else {
                                decoder.queueInputBuffer(
                                    inputIndex,
                                    0,
                                    sampleSize,
                                    extractor.sampleTime.coerceAtLeast(0L),
                                    0,
                                )
                                extractor.advance()
                            }
                        }
                    }

                    val outputIndex = decoder.dequeueOutputBuffer(bufferInfo, VIDEO_DECODE_TIMEOUT_US)
                    when {
                        outputIndex >= 0 -> {
                            val presentationTimeUs = bufferInfo.presentationTimeUs
                            val shouldKeep = bufferInfo.size > 0 &&
                                presentationTimeUs >= targetFrameTimesUs[nextTargetIndex]
                            if (shouldKeep) {
                                val image = decoder.getOutputImage(outputIndex)
                                if (image != null) {
                                    try {
                                        val indexed = quantizeYuvImageToGifIndexed(image, crop)
                                        while (
                                            nextTargetIndex < targetFrameTimesUs.size &&
                                            targetFrameTimesUs[nextTargetIndex] <= presentationTimeUs
                                        ) {
                                            onFrame(nextTargetIndex, indexed)
                                            nextTargetIndex++
                                        }
                                    } finally {
                                        image.close()
                                    }
                                }
                            }
                            sawOutputEnd = bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            decoder.releaseOutputBuffer(outputIndex, false)
                        }
                        outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            // Decoder output format changes are normal for adaptive videos.
                        }
                        outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                            if (sawInputEnd) {
                                sawOutputEnd = true
                            }
                        }
                    }
                }
            } finally {
                decoder?.runCatchingStopAndRelease()
                extractor.release()
            }
        }

        private fun decodeVideoFramesSequentially(
            context: Context,
            uri: Uri,
            targetFrameTimesUs: LongArray,
            width: Int,
            height: Int,
            crop: CropTransform,
            onFrame: (Int, Bitmap) -> Unit,
        ) {
            if (targetFrameTimesUs.isEmpty()) {
                return
            }

            val extractor = MediaExtractor()
            var decoder: MediaCodec? = null
            try {
                context.contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                    extractor.setDataSource(descriptor.fileDescriptor)
                } ?: throw IllegalArgumentException("无法读取视频")

                val trackIndex = selectVideoTrack(extractor)
                if (trackIndex < 0) {
                    throw IllegalArgumentException("视频轨道不存在")
                }
                extractor.selectTrack(trackIndex)
                val inputFormat = extractor.getTrackFormat(trackIndex)
                val mime = inputFormat.getString(MediaFormat.KEY_MIME)
                    ?: throw IllegalArgumentException("视频格式错误")
                inputFormat.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
                decoder = MediaCodec.createDecoderByType(mime)
                decoder.configure(inputFormat, null, null, 0)
                decoder.start()

                val bufferInfo = MediaCodec.BufferInfo()
                var sawInputEnd = false
                var sawOutputEnd = false
                var nextTargetIndex = 0

                while (!sawOutputEnd && nextTargetIndex < targetFrameTimesUs.size) {
                    if (!sawInputEnd) {
                        val inputIndex = decoder.dequeueInputBuffer(VIDEO_DECODE_TIMEOUT_US)
                        if (inputIndex >= 0) {
                            val inputBuffer = decoder.getInputBuffer(inputIndex)
                                ?: throw IllegalArgumentException("视频输入缓冲区不可用")
                            val sampleSize = extractor.readSampleData(inputBuffer, 0)
                            if (sampleSize < 0) {
                                decoder.queueInputBuffer(
                                    inputIndex,
                                    0,
                                    0,
                                    0,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                )
                                sawInputEnd = true
                            } else {
                                decoder.queueInputBuffer(
                                    inputIndex,
                                    0,
                                    sampleSize,
                                    extractor.sampleTime.coerceAtLeast(0L),
                                    0,
                                )
                                extractor.advance()
                            }
                        }
                    }

                    val outputIndex = decoder.dequeueOutputBuffer(bufferInfo, VIDEO_DECODE_TIMEOUT_US)
                    when {
                        outputIndex >= 0 -> {
                            val presentationTimeUs = bufferInfo.presentationTimeUs
                            val shouldKeep = bufferInfo.size > 0 &&
                                presentationTimeUs >= targetFrameTimesUs[nextTargetIndex]
                            if (shouldKeep) {
                                val image = decoder.getOutputImage(outputIndex)
                                if (image != null) {
                                    try {
                                        val source = imageToBitmap(image)
                                        val rendered = renderBitmapFrame(source, width, height, crop)
                                        var emitted = false
                                        while (
                                            nextTargetIndex < targetFrameTimesUs.size &&
                                            targetFrameTimesUs[nextTargetIndex] <= presentationTimeUs
                                        ) {
                                            val frameBitmap = if (
                                                nextTargetIndex + 1 < targetFrameTimesUs.size &&
                                                targetFrameTimesUs[nextTargetIndex + 1] <= presentationTimeUs
                                            ) {
                                                rendered.copy(Bitmap.Config.ARGB_8888, false)
                                            } else {
                                                rendered
                                            }
                                            emitted = true
                                            onFrame(nextTargetIndex, frameBitmap)
                                            nextTargetIndex++
                                        }
                                        if (!emitted) {
                                            rendered.recycle()
                                        }
                                    } finally {
                                        image.close()
                                    }
                                }
                            }
                            sawOutputEnd = bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            decoder.releaseOutputBuffer(outputIndex, false)
                        }
                        outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            // Decoder output format changes are normal for adaptive videos.
                        }
                        outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                            if (sawInputEnd) {
                                sawOutputEnd = true
                            }
                        }
                    }
                }
            } finally {
                decoder?.runCatchingStopAndRelease()
                extractor.release()
            }
        }

        private fun MediaCodec.runCatchingStopAndRelease() {
            runCatching { stop() }
            runCatching { release() }
        }

        private fun selectVideoTrack(extractor: MediaExtractor): Int {
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) {
                    return index
                }
            }
            return -1
        }

        private fun videoDurationMs(context: Context, uri: Uri): Long {
            val retriever = createRetriever(context, uri)
            return try {
                retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull()
                    ?.coerceAtLeast(1L)
                    ?: 1000L
            } finally {
                retriever.release()
            }
        }

        private fun imageToBitmap(image: Image): Bitmap {
            if (image.format != android.graphics.ImageFormat.YUV_420_888) {
                throw IllegalArgumentException("视频输出格式不支持: ${image.format}")
            }
            val width = image.width
            val height = image.height
            val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val pixels = IntArray(width * height)
            val yPlane = image.planes[0]
            val uPlane = image.planes[1]
            val vPlane = image.planes[2]
            val yBuffer = yPlane.buffer
            val uBuffer = uPlane.buffer
            val vBuffer = vPlane.buffer
            var offset = 0

            for (y in 0 until height) {
                val yRow = y * yPlane.rowStride
                val uvRow = (y / 2) * uPlane.rowStride
                for (x in 0 until width) {
                    val yValue = yBuffer.getUnsigned(yRow + x * yPlane.pixelStride)
                    val uValue = uBuffer.getUnsigned(uvRow + (x / 2) * uPlane.pixelStride)
                    val vValue = vBuffer.getUnsigned((y / 2) * vPlane.rowStride + (x / 2) * vPlane.pixelStride)
                    pixels[offset++] = yuvToArgb(yValue, uValue, vValue)
                }
            }
            output.setPixels(pixels, 0, width, 0, 0, width, height)
            return output
        }

        private fun quantizeYuvImageToGifIndexed(image: Image, crop: CropTransform): ByteArray {
            if (image.format != android.graphics.ImageFormat.YUV_420_888) {
                throw IllegalArgumentException("视频输出格式不支持: ${image.format}")
            }
            val output = ByteArray(VIDEO_PREVIEW_GIF_SIZE * VIDEO_PREVIEW_GIF_SIZE)
            val sourceWidth = image.width
            val sourceHeight = image.height
            val scale = max(
                VIDEO_PREVIEW_GIF_SIZE.toFloat() / sourceWidth.toFloat(),
                VIDEO_PREVIEW_GIF_SIZE.toFloat() / sourceHeight.toFloat(),
            ) * crop.scale.toFloat()
            val dx = (VIDEO_PREVIEW_GIF_SIZE - sourceWidth * scale) / 2f +
                crop.offsetX.toFloat() * VIDEO_PREVIEW_GIF_SIZE
            val dy = (VIDEO_PREVIEW_GIF_SIZE - sourceHeight * scale) / 2f +
                crop.offsetY.toFloat() * VIDEO_PREVIEW_GIF_SIZE

            val yPlane = image.planes[0]
            val uPlane = image.planes[1]
            val vPlane = image.planes[2]
            val yBuffer = yPlane.buffer
            val uBuffer = uPlane.buffer
            val vBuffer = vPlane.buffer
            var offset = 0

            for (y in 0 until VIDEO_PREVIEW_GIF_SIZE) {
                val sourceY = ((y + 0.5f - dy) / scale).toInt()
                if (sourceY !in 0 until sourceHeight) {
                    offset += VIDEO_PREVIEW_GIF_SIZE
                    continue
                }
                val yRow = sourceY * yPlane.rowStride
                val uvY = sourceY / 2
                val uRow = uvY * uPlane.rowStride
                val vRow = uvY * vPlane.rowStride
                for (x in 0 until VIDEO_PREVIEW_GIF_SIZE) {
                    val sourceX = ((x + 0.5f - dx) / scale).toInt()
                    if (sourceX !in 0 until sourceWidth) {
                        offset++
                        continue
                    }
                    val uvX = sourceX / 2
                    val yValue = yBuffer.getUnsigned(yRow + sourceX * yPlane.pixelStride)
                    val uValue = uBuffer.getUnsigned(uRow + uvX * uPlane.pixelStride)
                    val vValue = vBuffer.getUnsigned(vRow + uvX * vPlane.pixelStride)
                    val c = (yValue - 16).coerceAtLeast(0)
                    val d = uValue - 128
                    val e = vValue - 128
                    var red = ((298 * c + 409 * e + 128) shr 8).coerceIn(0, 255)
                    var green = ((298 * c - 100 * d - 208 * e + 128) shr 8).coerceIn(0, 255)
                    var blue = ((298 * c + 516 * d + 128) shr 8).coerceIn(0, 255)
                    red = (sharpenForIndexed(red) + orderedDither(x, y, 3)).coerceIn(0, 255)
                    green = (sharpenForIndexed(green) + orderedDither(x, y, 3)).coerceIn(0, 255)
                    blue = (sharpenForIndexed(blue) + orderedDither(x, y, 2)).coerceIn(0, 255)
                    output[offset++] = (((red ushr 5) shl 5) or ((green ushr 5) shl 2) or (blue ushr 6)).toByte()
                }
            }
            return output
        }

        private fun ByteBuffer.getUnsigned(index: Int): Int {
            return get(index).toInt() and 0xff
        }

        private fun yuvToArgb(yValue: Int, uValue: Int, vValue: Int): Int {
            val c = (yValue - 16).coerceAtLeast(0)
            val d = uValue - 128
            val e = vValue - 128
            val red = ((298 * c + 409 * e + 128) shr 8).coerceIn(0, 255)
            val green = ((298 * c - 100 * d - 208 * e + 128) shr 8).coerceIn(0, 255)
            val blue = ((298 * c + 516 * d + 128) shr 8).coerceIn(0, 255)
            return (0xff shl 24) or (red shl 16) or (green shl 8) or blue
        }

        private fun estimateGifBytesPerSecond(
            movie: Movie,
            fps: Int,
            delayMs: Int,
            streamSize: Int,
            crop: CropTransform,
        ): Long {
            val duration = movie.duration().takeIf { it > 0 } ?: 1000
            val totalFrames = max(1, (duration + delayMs - 1) / delayMs)
            val indexes = sampleFrameIndexes(totalFrames)
            var previous: ByteArray? = null
            var payloadBytes = 0L

            indexes.forEachIndexed { sampleIndex, frameIndex ->
                val timeMs = min(duration - 1, frameIndex * delayMs)
                movie.setTime(timeMs)
                val bitmap = renderMovieFrame(movie, streamSize, streamSize, crop)
                val indexed = quantizeToIndexed(bitmap)
                bitmap.recycle()
                val frame = encodeFrame(indexed, previous, delayMs, streamSize, forceKeyframe = sampleIndex == 0)
                payloadBytes += frame.data.size.toLong()
                previous = indexed
            }

            return payloadBytes * fps.toLong() / max(1, indexes.size).toLong()
        }

        private fun sampleFrameIndexes(totalFrames: Int): List<Int> {
            val sampleCount = min(SAMPLE_FRAME_COUNT, totalFrames)
            if (sampleCount <= 1) {
                return listOf(0)
            }
            return (0 until sampleCount)
                .map { index -> index * (totalFrames - 1) / (sampleCount - 1) }
                .distinct()
        }

        private fun encodeGifFrames(
            movie: Movie,
            delayMs: Int,
            streamSize: Int,
            crop: CropTransform,
        ): List<EncodedFrame> {
            val duration = movie.duration().takeIf { it > 0 } ?: 1000
            val totalFrames = max(1, (duration + delayMs - 1) / delayMs)
            val frames = mutableListOf<EncodedFrame>()
            var previous: ByteArray? = null

            for (index in 0 until totalFrames) {
                val timeMs = min(duration - 1, index * delayMs)
                movie.setTime(timeMs)
                val bitmap = renderMovieFrame(movie, streamSize, streamSize, crop)
                val indexed = quantizeToIndexed(bitmap)
                bitmap.recycle()
                val frame = encodeFrame(indexed, previous, delayMs, streamSize, forceKeyframe = index == 0)
                frames += frame
                previous = indexed
                onProgress((index + 1).toDouble() / totalFrames.toDouble())
            }
            return frames
        }

        private fun encodeFrame(
            indexed: ByteArray,
            previous: ByteArray?,
            delayMs: Int,
            streamSize: Int,
            forceKeyframe: Boolean = false,
        ): EncodedFrame {
            if (!forceKeyframe && previous != null && indexed.contentEquals(previous)) {
                return EncodedFrame(ByteArray(0), CODEC_INDEXED_REPEAT, delayMs, streamSize, streamSize)
            }

            val key = encodeIndexedKey(indexed)
            if (!forceKeyframe && previous != null) {
                val tile = encodeIndexedTile(indexed, previous, streamSize)
                if (tile.size < key.size) {
                    return EncodedFrame(tile, CODEC_INDEXED_TILE, delayMs, streamSize, streamSize)
                }
            }

            return EncodedFrame(key, CODEC_INDEXED_KEY, delayMs, streamSize, streamSize)
        }

        private fun encodeIndexedKey(indexed: ByteArray): ByteArray {
            val output = ByteSink(PALETTE_BYTES + indexed.size)
            output.write(rgb332Palette(), 0, PALETTE_BYTES)
            output.write(indexed, 0, indexed.size)
            return output.toByteArray()
        }

        private fun encodeIndexedTile(indexed: ByteArray, previous: ByteArray, streamSize: Int): ByteArray {
            val output = ByteSink(PALETTE_BYTES + indexed.size / 8)
            output.write(rgb332Palette(), 0, PALETTE_BYTES)
            output.write(0)
            output.write(0)

            var changedTiles = 0
            val tileCols = streamSize / TILE_SIZE
            val tileRows = streamSize / TILE_SIZE
            for (tileY in 0 until tileRows) {
                for (tileX in 0 until tileCols) {
                    var changed = false
                    for (row in 0 until TILE_SIZE) {
                        val offset = ((tileY * TILE_SIZE + row) * streamSize) + tileX * TILE_SIZE
                        val end = offset + TILE_SIZE
                        var index = offset
                        while (index < end) {
                            if (indexed[index] != previous[index]) {
                                changed = true
                                break
                            }
                            index++
                        }
                        if (changed) {
                            break
                        }
                    }

                    if (!changed) {
                        continue
                    }

                    val tileIndex = tileY * tileCols + tileX
                    output.write(tileIndex and 0xff)
                    output.write((tileIndex ushr 8) and 0xff)
                    for (row in 0 until TILE_SIZE) {
                        val offset = ((tileY * TILE_SIZE + row) * streamSize) + tileX * TILE_SIZE
                        output.write(indexed, offset, TILE_SIZE)
                    }
                    changedTiles++
                }
            }

            output.set(PALETTE_BYTES, changedTiles and 0xff)
            output.set(PALETTE_BYTES + 1, (changedTiles ushr 8) and 0xff)
            return output.toByteArray()
        }

        private fun packFrames(
            frames: List<EncodedFrame>,
            fps: Int,
            streamSize: Int,
        ): EncodedPackage {
            if (frames.isEmpty()) {
                throw IllegalArgumentException("素材没有可用帧")
            }

            val dataBytes = frames.sumOf { it.data.size }
            val frameTableOffset = HEADER_SIZE
            val frameDataOffset = HEADER_SIZE + frames.size * FRAME_ENTRY_SIZE
            val packageSize = frameDataOffset + dataBytes

            val output = ByteArray(packageSize)
            writeLe32(output, 0, MAGIC.toLong())
            writeLe16(output, 4, VERSION)
            writeLe16(output, 6, HEADER_SIZE)
            writeLe16(output, 8, WIDTH)
            writeLe16(output, 10, HEIGHT)
            writeLe16(output, 12, frames.size)
            writeLe16(output, 14, fps)
            writeLe32(output, 16, frameTableOffset.toLong())
            writeLe32(output, 20, frameDataOffset.toLong())
            writeLe32(output, 24, packageSize.toLong())
            writeLe32(output, 28, 0)
            writeLe32(output, 32, 0)
            writeLe16(output, 36, streamSize)
            writeLe16(output, 38, streamSize)
            writeLe16(output, 40, PALETTE_ENTRIES)
            writeLe16(output, 42, 0)

            var tableOffset = frameTableOffset
            var dataOffset = frameDataOffset
            frames.forEach { frame ->
                writeLe32(output, tableOffset, dataOffset.toLong())
                writeLe32(output, tableOffset + 4, frame.data.size.toLong())
                writeLe16(output, tableOffset + 8, frame.delayMs)
                output[tableOffset + 10] = frame.codec.toByte()
                output[tableOffset + 11] = 0
                writeLe16(output, tableOffset + 12, frame.width)
                writeLe16(output, tableOffset + 14, frame.height)
                frame.data.copyInto(output, dataOffset)
                tableOffset += FRAME_ENTRY_SIZE
                dataOffset += frame.data.size
            }

            return EncodedPackage(output, frames.size, fps, crc32(output))
        }

        private fun quantizeToIndexed(bitmap: Bitmap): ByteArray {
            val output = ByteArray(bitmap.width * bitmap.height)
            val scratch = pixelScratch(bitmap.width, bitmap.height)
            val pixels = scratch.pixels
            bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
            var offset = 0
            for (y in 0 until bitmap.height) {
                val rowOffset = y * bitmap.width
                for (x in 0 until bitmap.width) {
                    val pixel = pixels[rowOffset + x]
                    val alpha = pixel ushr 24
                    var red = (pixel ushr 16) and 0xff
                    var green = (pixel ushr 8) and 0xff
                    var blue = pixel and 0xff
                    if (alpha < 255) {
                        red = red * alpha / 255
                        green = green * alpha / 255
                        blue = blue * alpha / 255
                    }
                    red = (sharpenForIndexed(red) + orderedDither(x, y, 3)).coerceIn(0, 255)
                    green = (sharpenForIndexed(green) + orderedDither(x, y, 3)).coerceIn(0, 255)
                    blue = (sharpenForIndexed(blue) + orderedDither(x, y, 2)).coerceIn(0, 255)
                    output[offset++] = (((red ushr 5) shl 5) or ((green ushr 5) shl 2) or (blue ushr 6)).toByte()
                }
            }
            return output
        }

        private fun pixelScratch(width: Int, height: Int): PixelScratch {
            val existing = pixelScratch
            if (existing != null && existing.width == width && existing.height == height) {
                return existing
            }
            return PixelScratch(width, height).also { pixelScratch = it }
        }

        private fun sharpenForIndexed(value: Int): Int {
            val centered = value - 128
            return (128 + centered * SHARPEN_PERCENT / 100).coerceIn(0, 255)
        }

        private fun orderedDither(x: Int, y: Int, bits: Int): Int {
            val levelStep = if (bits == 2) 64 else 32
            val threshold = DITHER_4X4[((y and 3) shl 2) or (x and 3)] - 8
            return threshold * levelStep / 16
        }

        private fun selectStreamResolution(estimates: List<StreamEstimate>): Int {
            for (estimate in estimates) {
                if (estimate.bytesPerSecond <= QUALITY_STREAM_BYTES_PER_SECOND) {
                    return estimate.streamSize
                }
            }
            return estimates.lastOrNull()?.streamSize ?: STREAM_RESOLUTIONS.last()
        }

        private fun rgb332Palette(): ByteArray {
            val palette = ByteArray(PALETTE_BYTES)
            var offset = 0
            for (index in 0 until PALETTE_ENTRIES) {
                val red = ((index ushr 5) and 0x07) * 255 / 7
                val green = ((index ushr 2) and 0x07) * 255 / 7
                val blue = (index and 0x03) * 255 / 3
                val rgb565 = ((red and 0xf8) shl 8) or ((green and 0xfc) shl 3) or (blue shr 3)
                palette[offset++] = (rgb565 and 0xff).toByte()
                palette[offset++] = ((rgb565 ushr 8) and 0xff).toByte()
            }
            return palette
        }

    }

    private class ByteSink(initialCapacity: Int) {
        private var buffer = ByteArray(max(64, initialCapacity / 2))
        var size: Int = 0
            private set

        fun write(value: Int) {
            ensure(1)
            buffer[size++] = value.toByte()
        }

        fun write(source: ByteArray, offset: Int, length: Int) {
            if (length <= 0) {
                return
            }
            ensure(length)
            source.copyInto(buffer, size, offset, offset + length)
            size += length
        }

        fun writeLength(length: Int) {
            var remaining = length
            while (remaining >= 255) {
                write(255)
                remaining -= 255
            }
            write(remaining)
        }

        fun set(index: Int, value: Int) {
            buffer[index] = value.toByte()
        }

        fun toByteArray(): ByteArray {
            return buffer.copyOf(size)
        }

        private fun ensure(extra: Int) {
            val required = size + extra
            if (required <= buffer.size) {
                return
            }
            var next = buffer.size
            while (next < required) {
                next *= 2
            }
            buffer = buffer.copyOf(next)
        }
    }

    private data class EncodedFrame(
        val data: ByteArray,
        val codec: Int,
        val delayMs: Int,
        val width: Int,
        val height: Int,
    )
    private data class EncodedPackage(
        val packageBytes: ByteArray,
        val frameCount: Int,
        val fps: Int,
        val crc32: Long,
    )
    private data class StreamEstimate(
        val streamSize: Int,
        val bytesPerSecond: Long,
    )
    private data class CropTransform(
        val scale: Double,
        val offsetX: Double,
        val offsetY: Double,
    ) {
        companion object {
            val DEFAULT = CropTransform(1.0, 0.0, 0.0)
        }
    }
    private class PixelScratch(
        val width: Int,
        val height: Int,
    ) {
        val pixels = IntArray(width * height)
    }

    private class PackageTooLargeException(message: String) : Exception(message)

    companion object {
        private const val CHANNEL = "esp_baji/native"
        private const val BADGE_DEVICE_NAME = "ESP-BAJI"
        private const val BADGE_WIFI_SSID = "ESP-BAJI"
        private const val BADGE_HOST = "192.168.4.1"
        private const val BADGE_UPLOAD_TCP_PORT = 3333
        private const val BADGE_TCP_UPLOAD_MAGIC = 0x31505542
        private const val BADGE_UPLOAD_URL = "http://192.168.4.1/upload"
        private const val BADGE_STATUS_URL = "http://192.168.4.1/status"
        private const val BADGE_BRIGHTNESS_URL = "http://192.168.4.1/brightness"
        private const val REQUEST_PICK_MEDIA = 8101
        private const val REQUEST_BLE_PERMISSIONS = 8102
        private const val SCAN_WINDOW_MS = 8000L
        private const val WRITE_TIMEOUT_MS = 30000L
        private const val WIFI_CONNECT_TIMEOUT_MS = 45000L
        private const val HTTP_CONNECT_TIMEOUT_MS = 15000
        private const val HTTP_READ_TIMEOUT_MS = 60000
        private const val HTTP_STATUS_TIMEOUT_MS = 2500
        private const val HTTP_UPLOAD_ATTEMPTS = 1
        private const val HTTP_UPLOAD_CHUNK_BYTES = 256 * 1024
        private const val TCP_UPLOAD_CHUNK_BYTES = 256 * 1024
        private const val MAX_INPUT_BYTES = 40 * 1024 * 1024
        private const val MAX_VIDEO_INPUT_BYTES = 200 * 1024 * 1024
        private const val LEGACY_FLASH_BUDGET_BYTES = 10 * 1024 * 1024
        private const val SD_STREAM_BUDGET_BYTES = 512 * 1024 * 1024
        private const val ASSET_TOO_LARGE_MESSAGE =
            "转换后的设备包超过当前素材存储空间，请换短一点的素材。"
        private const val MAX_HISTORY_ITEMS = 20
        private const val PREFS_NAME = "esp_baji"
        private const val HISTORY_KEY = "history"

        private const val WIDTH = 480
        private const val HEIGHT = 480
        private const val PREVIEW_SIZE = 320
        private const val VIDEO_PREVIEW_GIF_SIZE = 192
        private const val VIDEO_PREVIEW_GIF_FPS = 25
        private const val VIDEO_DECODE_TIMEOUT_US = 10_000L
        private const val PREPARE_PROGRESS_PACKING = 0.90
        private const val PREPARE_PROGRESS_WRITING = 0.96
        private const val PREPARE_PROGRESS_DONE = 1.0
        private const val STREAM_240_PIXELS = 240 * 240
        private const val MAGIC = 0x344a4142
        private const val VERSION = 4
        private const val HEADER_SIZE = 44
        private const val FRAME_ENTRY_SIZE = 16
        private const val CODEC_INDEXED_KEY = 0x10
        private const val CODEC_INDEXED_TILE = 0x11
        private const val CODEC_INDEXED_REPEAT = 0x12
        private const val PALETTE_ENTRIES = 256
        private const val PALETTE_BYTES = PALETTE_ENTRIES * 2
        private const val SAMPLE_FRAME_COUNT = 4
        private const val QUALITY_STREAM_BYTES_PER_SECOND = 4 * 1024 * 1024
        private const val SHARPEN_PERCENT = 106
        private val DITHER_4X4 = intArrayOf(
            0, 8, 2, 10,
            12, 4, 14, 6,
            3, 11, 1, 9,
            15, 7, 13, 5,
        )
        private const val TILE_SIZE = 16
        private const val CMD_START: Byte = 0x01
        private const val CMD_FINISH: Byte = 0x02
        private const val CMD_SET_BRIGHTNESS: Byte = 0x10
        private val STREAM_RESOLUTIONS = intArrayOf(480, 320, 240)

        private val SERVICE_UUID: UUID = UUID.fromString("31494a41-6252-4288-b942-2f8d009e1ab1")
        private val CONTROL_UUID: UUID = UUID.fromString("31494a41-6252-4288-b942-2f8d019e1ab1")
        private val DATA_UUID: UUID = UUID.fromString("31494a41-6252-4288-b942-2f8d029e1ab1")
        private val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        private fun isVideoMime(mime: String): Boolean {
            return mime.startsWith("video/", ignoreCase = true)
        }

        private fun createRetriever(context: Context, uri: Uri): MediaMetadataRetriever {
            val retriever = MediaMetadataRetriever()
            try {
                context.contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
                    retriever.setDataSource(descriptor.fileDescriptor)
                } ?: throw IllegalArgumentException("无法读取视频")
                return retriever
            } catch (error: Exception) {
                retriever.release()
                throw error
            }
        }

        private fun frameDelayMs(fps: Int): Int {
            return max(1, ((1000f / fps.toFloat()) + 0.5f).toInt())
        }

        private fun renderVideoFrame(
            context: Context,
            uri: Uri,
            width: Int,
            height: Int,
            crop: CropTransform,
        ): Bitmap {
            val retriever = createRetriever(context, uri)
            try {
                val frame = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    ?: throw IllegalArgumentException("无法读取视频预览")
                return renderBitmapFrame(frame, width, height, crop)
            } finally {
                retriever.release()
            }
        }

        private fun renderMovieFrame(
            movie: Movie,
            width: Int,
            height: Int,
            crop: CropTransform,
        ): Bitmap {
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            canvas.drawColor(Color.BLACK)
            val scale = max(width.toFloat() / movie.width().toFloat(), height.toFloat() / movie.height().toFloat()) *
                crop.scale.toFloat()
            val dx = (width - movie.width() * scale) / 2f + crop.offsetX.toFloat() * width
            val dy = (height - movie.height() * scale) / 2f + crop.offsetY.toFloat() * height
            canvas.save()
            canvas.translate(dx, dy)
            canvas.scale(scale, scale)
            movie.draw(canvas, 0f, 0f)
            canvas.restore()
            return bitmap
        }

        private fun renderBitmapFrame(
            source: Bitmap,
            width: Int,
            height: Int,
            crop: CropTransform,
        ): Bitmap {
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            canvas.drawColor(Color.BLACK)
            val scale = max(width.toFloat() / source.width.toFloat(), height.toFloat() / source.height.toFloat()) *
                crop.scale.toFloat()
            val matrix = Matrix().apply {
                postScale(scale, scale)
                postTranslate(
                    (width - source.width * scale) / 2f + crop.offsetX.toFloat() * width,
                    (height - source.height * scale) / 2f + crop.offsetY.toFloat() * height,
                )
            }
            val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.DITHER_FLAG)
            canvas.drawBitmap(source, matrix, paint)
            if (source != bitmap) {
                source.recycle()
            }
            return bitmap
        }

        private fun sharpenForIndexed(value: Int): Int {
            val centered = value - 128
            return (128 + centered * SHARPEN_PERCENT / 100).coerceIn(0, 255)
        }

        private fun orderedDither(x: Int, y: Int, bits: Int): Int {
            val levelStep = if (bits == 2) 64 else 32
            val threshold = DITHER_4X4[((y and 3) shl 2) or (x and 3)] - 8
            return threshold * levelStep / 16
        }

        private fun quantizeBitmapToGifIndexed(bitmap: Bitmap): ByteArray {
            val output = ByteArray(bitmap.width * bitmap.height)
            val pixels = IntArray(bitmap.width * bitmap.height)
            bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
            var offset = 0
            for (y in 0 until bitmap.height) {
                val rowOffset = y * bitmap.width
                for (x in 0 until bitmap.width) {
                    val pixel = pixels[rowOffset + x]
                    val alpha = pixel ushr 24
                    var red = (pixel ushr 16) and 0xff
                    var green = (pixel ushr 8) and 0xff
                    var blue = pixel and 0xff
                    if (alpha < 255) {
                        red = red * alpha / 255
                        green = green * alpha / 255
                        blue = blue * alpha / 255
                    }
                    red = (sharpenForIndexed(red) + orderedDither(x, y, 3)).coerceIn(0, 255)
                    green = (sharpenForIndexed(green) + orderedDither(x, y, 3)).coerceIn(0, 255)
                    blue = (sharpenForIndexed(blue) + orderedDither(x, y, 2)).coerceIn(0, 255)
                    output[offset++] = (((red ushr 5) shl 5) or ((green ushr 5) shl 2) or (blue ushr 6)).toByte()
                }
            }
            return output
        }

        private fun rgb332GifPalette(): ByteArray {
            val palette = ByteArray(PALETTE_ENTRIES * 3)
            var offset = 0
            for (index in 0 until PALETTE_ENTRIES) {
                palette[offset++] = (((index ushr 5) and 0x07) * 255 / 7).toByte()
                palette[offset++] = (((index ushr 2) and 0x07) * 255 / 7).toByte()
                palette[offset++] = ((index and 0x03) * 255 / 3).toByte()
            }
            return palette
        }

        private fun encodeIndexedGif(
            frames: List<ByteArray>,
            width: Int,
            height: Int,
            delayMs: Int,
        ): ByteArray {
            val output = ByteSink(width * height * frames.size / 2)
            "GIF89a".forEach { output.write(it.code) }
            output.write(width and 0xff)
            output.write((width ushr 8) and 0xff)
            output.write(height and 0xff)
            output.write((height ushr 8) and 0xff)
            output.write(0xf7)
            output.write(0)
            output.write(0)
            val palette = rgb332GifPalette()
            output.write(palette, 0, palette.size)
            output.write(0x21)
            output.write(0xff)
            output.write(11)
            "NETSCAPE2.0".forEach { output.write(it.code) }
            output.write(3)
            output.write(1)
            output.write(0)
            output.write(0)
            output.write(0)
            val gifDelay = max(1, delayMs / 10)
            for (frame in frames) {
                output.write(0x21)
                output.write(0xf9)
                output.write(4)
                output.write(0)
                output.write(gifDelay and 0xff)
                output.write((gifDelay ushr 8) and 0xff)
                output.write(0)
                output.write(0)
                output.write(0x2c)
                output.write(0)
                output.write(0)
                output.write(0)
                output.write(0)
                output.write(width and 0xff)
                output.write((width ushr 8) and 0xff)
                output.write(height and 0xff)
                output.write((height ushr 8) and 0xff)
                output.write(0)
                output.write(8)
                val compressed = gifLzwEncodeLiteral(frame)
                var offset = 0
                while (offset < compressed.size) {
                    val chunk = min(255, compressed.size - offset)
                    output.write(chunk)
                    output.write(compressed, offset, chunk)
                    offset += chunk
                }
                output.write(0)
            }
            output.write(0x3b)
            return output.toByteArray()
        }

        private fun gifLzwEncodeLiteral(indexed: ByteArray): ByteArray {
            val minCodeSize = 8
            val clearCode = 1 shl minCodeSize
            val endCode = clearCode + 1
            val codeSize = minCodeSize + 1
            val codes = ArrayList<Int>(indexed.size + indexed.size / 128 + 4)
            codes += clearCode
            indexed.forEachIndexed { index, value ->
                if (index > 0 && index % 128 == 0) {
                    codes += clearCode
                }
                codes += value.toInt() and 0xff
            }
            codes += endCode

            val output = ByteSink(codes.size * 2)
            var bitBuffer = 0
            var bitCount = 0
            for (code in codes) {
                bitBuffer = bitBuffer or (code shl bitCount)
                bitCount += codeSize
                while (bitCount >= 8) {
                    output.write(bitBuffer and 0xff)
                    bitBuffer = bitBuffer ushr 8
                    bitCount -= 8
                }
            }
            if (bitCount > 0) {
                output.write(bitBuffer and 0xff)
            }
            return output.toByteArray()
        }

        private fun writeLe16(target: ByteArray, offset: Int, value: Int) {
            target[offset] = (value and 0xff).toByte()
            target[offset + 1] = ((value ushr 8) and 0xff).toByte()
        }

        private fun writeLe32(target: ByteArray, offset: Int, value: Long) {
            target[offset] = (value and 0xff).toByte()
            target[offset + 1] = ((value ushr 8) and 0xff).toByte()
            target[offset + 2] = ((value ushr 16) and 0xff).toByte()
            target[offset + 3] = ((value ushr 24) and 0xff).toByte()
        }

        private fun crc32(bytes: ByteArray): Long {
            val crc = CRC32()
            crc.update(bytes)
            return crc.value
        }
    }
}
