import AVFoundation
import CoreBluetooth
import CoreGraphics
import CoreMotion
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Flutter
import ImageIO
import Network
import NetworkExtension
import PhotosUI
import UniformTypeIdentifiers
import UIKit

// TCP preserves byte order, not message boundaries. The device sends one
// response line followed by a generic status line; consume only the first.
struct BadgeTcpLineBuffer {
  private var bytes = Data()
  private let maximumBytes = 256

  mutating func append(_ data: Data?, isComplete: Bool) throws -> String? {
    if let data { bytes.append(data) }
    if let newline = bytes.firstIndex(of: 0x0a) {
      let lineBytes = bytes[..<newline]
      guard lineBytes.count <= maximumBytes else { throw Self.failure("设备响应过长") }
      guard let text = String(data: Data(lineBytes), encoding: .utf8) else {
        throw Self.failure("设备响应格式无效")
      }
      let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { throw Self.failure("设备未返回响应") }
      return line
    }
    guard bytes.count <= maximumBytes else { throw Self.failure("设备响应过长") }
    if isComplete {
      throw Self.failure(bytes.isEmpty ? "设备未返回响应" : "设备响应不完整，请重试")
    }
    return nil
  }

  static func uploadedAssetID(_ response: String) throws -> String? {
    if response == "OK" { return nil } // Older firmware has no assigned ID.
    if response.hasPrefix("OK ") {
      let id = String(response.dropFirst(3))
      let digits = id.utf8.dropFirst()
      if id.utf8.count == 4 && id.utf8.first == 0x55 &&
          digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
        return id
      }
    }
    throw failure(response.isEmpty ? "设备未返回响应" : response)
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "DotLoopTcp", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, PHPickerViewControllerDelegate {
  private var badgeChannel: FlutterMethodChannel?
  private var pendingPickResult: FlutterResult?
  private var activeUpload: NWConnection?
  private var connectedAddress: String?
  private var activeBadgeHost = BadgeConstants.badgeApHost
  private var sdAvailable = false
  private var badgeHardware = "esp32p4"
  private var isUploading = false
  private var uploadBackgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var uploadPreviousIdleTimerDisabled: Bool?
  private lazy var gameBluetooth = GameBluetoothController()
  private let interactionFeedback = UIImpactFeedbackGenerator(style: .heavy)
  private let swingMotion = DotLoopSwingMotion()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: BadgeConstants.channel,
        binaryMessenger: controller.binaryMessenger
      )
      badgeChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handle(call, result: result)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "interactionHaptic":
      interactionFeedback.impactOccurred(intensity: 1.0)
      interactionFeedback.prepare()
      result(true)
    case "startScan":
      startScan()
      result(nil)
    case "connect":
      connect(address: args["address"] as? String, result: result)
    case "disconnect":
      connectedAddress = nil
      activeBadgeHost = BadgeConstants.badgeApHost
      sdAvailable = false
      activeUpload?.cancel()
      activeUpload = nil
      result(nil)
    case "connectionState":
      readConnectionState(result: result)
    case "setBrightness":
      let value = min(100, max(0, args["value"] as? Int ?? 70))
      setBrightness(value, result: result)
    case "enterCalibration":
      calibrationCommand(action: "enter", angleTenths: nil, returnsSnapshot: true, result: result)
    case "loadLanguage":
      result(UserDefaults.standard.string(forKey: "app_language") ?? "system")
    case "saveLanguage":
      let language = args["language"] as? String ?? "system"
      guard ["system", "chinese", "english", "traditionalChinese", "japanese", "russian"].contains(language) else {
        result(FlutterError(code: "invalid_language", message: "Invalid language", details: nil))
        return
      }
      UserDefaults.standard.set(language, forKey: "app_language")
      result(nil)
    case "ensureGameBluetooth", "ensureDeviceBluetooth":
      gameBluetooth.connect(automatic: args["automatic"] as? Bool ?? false, result: result)
    case "deviceBluetoothState":
      gameBluetooth.connectionInfo(result: result)
    case "deviceBluetoothCommand":
      gameBluetooth.sendDevice(command: args["command"] as? String ?? "", result: result)
    case "joinDeviceAccessPoint":
      let configuration = NEHotspotConfiguration(ssid: "DotLoop")
      configuration.joinOnce = true
      NEHotspotConfigurationManager.shared.apply(configuration) { error in
        if let error = error as NSError?,
           !(error.domain == NEHotspotConfigurationErrorDomain && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue) {
          DispatchQueue.main.async { result(FlutterError(code: "wifi_connect", message: error.localizedDescription, details: nil)) }
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          self.setActiveBadgeHost(BadgeConstants.badgeApHost)
          var lastError: Error?
          for _ in 0..<10 {
            do {
              let status = try self.requestText(self.badgeUrl("/status"), timeout: 2)
              guard self.isBadgeStatusText(status) else { throw BadgeError.message("设备热点尚未就绪") }
              self.sdAvailable = self.parseSdAvailable(status)
              self.connectedAddress = BadgeConstants.badgeApHost
              DispatchQueue.main.async { result(true) }
              return
            } catch { lastError = error; usleep(300_000) }
          }
          DispatchQueue.main.async { result(FlutterError(code: "wifi_connect", message: lastError?.localizedDescription ?? "请连接 DotLoop 热点后重试", details: nil)) }
        }
      }
    case "leaveDeviceAccessPoint":
      NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: "DotLoop")
      connectedAddress = nil
      result(nil)
    case "releaseGameBluetooth":
      gameBluetooth.close()
      result(nil)
    case "gameCommand", "sendGameControl":
      gameBluetooth.send(action: args["action"] as? String ?? "flap", result: result)
    case "gameControlStatus", "readGameControlStatus":
      gameBluetooth.status(result: result)
    case "calibrationStatus":
      calibrationCommand(action: "status", angleTenths: nil, returnsSnapshot: true, result: result)
    case "previewCalibration":
      calibrationCommand(
        action: "preview",
        angleTenths: args["angleTenths"] as? Int ?? 0,
        returnsSnapshot: false,
        result: result
      )
    case "saveCalibration":
      calibrationCommand(
        action: "save",
        angleTenths: args["angleTenths"] as? Int ?? 0,
        returnsSnapshot: false,
        result: result
      )
    case "cancelCalibration":
      calibrationCommand(action: "cancel", angleTenths: nil, returnsSnapshot: false, result: result)
    case "inspectLocalPackage":
      let path = args["assetPath"] as? String ?? ""
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let metadata = try self.localPackageMetadata(fileURL: URL(fileURLWithPath: path), hardware: args["hardware"] as? String)
          DispatchQueue.main.async { result(metadata) }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "package_invalid", message: error.localizedDescription, details: nil)) }
        }
      }
    case "pickMedia":
      pickMedia(result: result)
    case "videoFramePreview":
      guard let uriText = args["uri"] as? String else {
        result(FlutterError(code: "bad_uri", message: "素材地址为空", details: nil))
        return
      }
      videoFramePreview(
        uriText: uriText,
        frameFraction: args["coverFrame"] as? Double ?? 0,
        crop: CropTransform(
          scale: min(4.0, max(0.5, args["cropScale"] as? Double ?? 1.0)),
          offsetX: min(1.5, max(-1.5, args["cropOffsetX"] as? Double ?? 0.0)),
          offsetY: min(1.5, max(-1.5, args["cropOffsetY"] as? Double ?? 0.0))
        ),
        result: result
      )
    case "saveMaterialCover":
      guard let bytes = (args["bytes"] as? FlutterStandardTypedData)?.data, !bytes.isEmpty else {
        result(FlutterError(code: "bad_cover", message: "封面为空", details: nil))
        return
      }
      do {
        let path = try writeCacheFile(data: bytes, directoryName: "ebaj", stem: "\(UUID().uuidString)_cover", ext: "png")
        result(path)
      } catch {
        result(FlutterError(code: "cover_save_failed", message: error.localizedDescription, details: nil))
      }
    case "warmVideoAnimatedPreview":
      guard let uri = args["uri"] as? String else {
        result(FlutterError(code: "bad_uri", message: "素材地址为空", details: nil))
        return
      }
      let name = args["name"] as? String ?? "asset"
      warmVideoAnimatedPreview(uriText: uri, displayName: name, result: result)
    case "prepareAsset":
      guard let uri = args["uri"] as? String else {
        result(FlutterError(code: "bad_uri", message: "素材地址为空", details: nil))
        return
      }
      let name = args["name"] as? String ?? "asset"
      let fps = min(60, max(1, args["fps"] as? Int ?? 40))
      let maxPackageBytes = max(
        args["maxPackageBytes"] as? Int ?? BadgeConstants.sdStreamBudgetBytes,
        BadgeConstants.headerSize + BadgeConstants.frameEntrySize + BadgeConstants.paletteBytes + BadgeConstants.stream240Pixels
      )
      let crop = CropTransform(
        scale: min(4.0, max(0.5, args["cropScale"] as? Double ?? 1.0)),
        offsetX: min(1.5, max(-1.5, args["cropOffsetX"] as? Double ?? 0.0)),
        offsetY: min(1.5, max(-1.5, args["cropOffsetY"] as? Double ?? 0.0))
      )
      let coverFrame = min(1.0, max(0.0, args["coverFrame"] as? Double ?? 0.0))
      prepareAsset(
        uriText: uri,
        displayName: name,
        fps: fps,
        maxPackageBytes: maxPackageBytes,
        crop: crop,
        coverFrame: coverFrame,
        warmPreviewPath: args["warmPreviewPath"] as? String,
        outputDirectoryName: "ebaj",
        result: result
      )
    case "startSwingMotion": result(swingMotion.start())
    case "readSwingMotion": result(swingMotion.read())
    case "calibrateSwingMotion": swingMotion.calibrate(); result(nil)
    case "stopSwingMotion": swingMotion.stop(); result(nil)
    case "installGamePackage":
      installFactoryPackage(args: args, isGame: true, result: result)
    case "installFactoryPackage":
      installFactoryPackage(args: args, result: result)
    case "uploadAsset":
      guard let path = args["assetPath"] as? String else {
        result(FlutterError(code: "bad_asset", message: "素材包为空", details: nil))
        return
      }
      uploadAsset(assetPath: path, result: result)
    case "transcodeOnServer":
      guard let uri = args["uri"] as? String else {
        result(FlutterError(code: "bad_uri", message: "素材地址为空", details: nil))
        return
      }
      let name = args["name"] as? String ?? "asset"
      let maxFps = min(80, max(1, args["maxFps"] as? Int ?? 80))
      let crop = CropTransform(
        scale: min(4.0, max(0.5, args["cropScale"] as? Double ?? 1.0)),
        offsetX: min(1.5, max(-1.5, args["cropOffsetX"] as? Double ?? 0.0)),
        offsetY: min(1.5, max(-1.5, args["cropOffsetY"] as? Double ?? 0.0))
      )
      transcodeOnServer(
        uriText: uri,
        name: name,
        maxFps: maxFps,
        crop: crop,
        hardware: normalizeBadgeHardware(args["hardware"] as? String),
        deviceTransfer: args["deviceTransfer"] as? Bool ?? false,
        backendBase: args["backendBase"] as? String ?? "http://47.108.204.22",
        result: result
      )
    case "downloadApprovedPackage":
      guard let assetId = args["assetId"] as? String, !assetId.isEmpty else {
        result(FlutterError(code: "bad_asset", message: "素材 ID 为空", details: nil))
        return
      }
      downloadApprovedPackage(
        assetId: assetId,
        name: args["name"] as? String ?? "asset",
        hardware: normalizeBadgeHardware(args["hardware"] as? String),
        backendBase: args["backendBase"] as? String ?? "http://47.108.204.22",
        result: result
      )
    case "checkFirmwareUpdate":
      runFirmwareOperation(result: result) {
        let hardware = args["hardware"] as? String ?? ""
        guard hardware == "esp32p4-2.8",
              let backend = args["backendBase"] as? String,
              let url = URL(string: "\(backend.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/ota/manifest?hardware=\(hardware)") else {
          throw transferFailure("firmware_invalid", "暂不支持此设备型号或服务器地址无效")
        }
        let reply = try self.firmwareJSONRequest(URLRequest(url: url))
        let manifest = try RelayFirmwareManifest(reply)
        return manifest.dictionary
      }
    case "downloadFirmware":
      runFirmwareOperation(result: result, transfer: true) {
        let manifest = try RelayFirmwareManifest(args)
        let directory = try self.cacheDirectory("firmware")
        let target = directory.appendingPathComponent("\(manifest.sha256).bin")
        if (try? self.verifyFirmware(target, manifest: manifest)) == nil {
          do {
            _ = try self.downloadBackendFile(url: manifest.url, target: target,
              maximumBytes: manifest.size, expectedSize: manifest.size, expectedSHA256: manifest.sha256)
            try self.verifyFirmware(target, manifest: manifest)
          } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
          }
        }
        return ["assetPath": target.path]
      }
    case "uploadFirmware":
      runFirmwareOperation(result: result, transfer: true) {
        let manifest = try RelayFirmwareManifest(args)
        guard let path = args["assetPath"] as? String,
              let deviceId = args["deviceId"] as? String,
              deviceId.range(of: "^P4-[0-9a-fA-F]{12}$", options: .regularExpression) != nil else {
          throw transferFailure("firmware_invalid", "固件缓存地址或设备身份无效")
        }
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let directory = try self.cacheDirectory("firmware").resolvingSymlinksInPath().standardizedFileURL
        guard file.deletingLastPathComponent() == directory else {
          throw transferFailure("firmware_invalid", "固件缓存地址无效")
        }
        try self.verifyFirmware(file, manifest: manifest)
        guard let statusURL = URL(string: self.badgeUrl("/ota/status")),
              let uploadURL = URL(string: self.badgeUrl("/ota/upload")) else {
          throw transferFailure("firmware_invalid", "设备热点地址无效")
        }
        let status = try self.firmwareJSONRequest(URLRequest(url: statusURL), unsupportedOn404: true)
        guard status["relay"] as? Bool == true,
              status["hardware"] as? String == manifest.hardware,
              status["deviceId"] as? String == deviceId,
              ((status["maxSize"] as? NSNumber)?.intValue ?? 0) >= manifest.size else {
          throw transferFailure("firmware_invalid", "热点设备身份或固件型号不匹配，已停止更新")
        }
        guard status["otaActive"] as? Bool != true else {
          throw transferFailure("firmware_busy", "设备正在更新，请稍后重试")
        }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(manifest.size), forHTTPHeaderField: "Content-Length")
        request.setValue(manifest.hardware, forHTTPHeaderField: "X-OTA-Hardware")
        request.setValue(manifest.version, forHTTPHeaderField: "X-OTA-Version")
        request.setValue(manifest.sha256, forHTTPHeaderField: "X-OTA-SHA256")
        let reply = try self.firmwareJSONRequest(request, uploadFile: file)
        guard reply["success"] as? Bool == true,
              reply["version"] as? String == manifest.version else {
          throw transferFailure("firmware_rejected", "设备未确认固件更新成功")
        }
        return ["success": true, "version": manifest.version, "rebooting": true]
      }
    case "loadHistory":
      result(loadHistory())
    case "saveHistory":
      saveHistory(call.arguments as? [[String: Any]] ?? [])
      result(nil)
    case "loadPendingDeviceDeletes":
      result(loadPendingDeviceDeletes())
    case "savePendingDeviceDeletes":
      if savePendingDeviceDeletes(call.arguments as? [[String: Any]] ?? []) {
        result(nil)
      } else {
        result(FlutterError(code: "delete_queue_save_failed", message: "删除队列保存失败", details: nil))
      }
    case "deleteAssetFiles":
      deleteAssetFiles(
        assetPath: args["assetPath"] as? String,
        previewPath: args["previewPath"] as? String,
        animatedPreviewPath: args["animatedPreviewPath"] as? String
      )
      result(nil)
    case "openUrl":
      guard let urlText = args["url"] as? String, let url = URL(string: urlText) else {
        result(FlutterError(code: "bad_url", message: "链接为空", details: nil))
        return
      }
      UIApplication.shared.open(url, options: [:]) { success in
        if success {
          result(nil)
        } else {
          result(FlutterError(code: "open_url_failed", message: "无法打开链接", details: nil))
        }
      }
    case "requestUserId":
      requestNewUserId(result: result)
    case "getFactoryAnimations":
      result([
        ["id": "F001", "name": "F001", "previewAsset": "assets/factory_previews/F001.png"],
        ["id": "F002", "name": "F002", "previewAsset": "assets/factory_previews/F002.png"],
        ["id": "F003", "name": "F003", "previewAsset": "assets/factory_previews/F003.png"],
      ])
    case "factoryCacheRoot":
      do {
        result(try cacheDirectory("factory_catalog").path)
      } catch {
        result(FlutterError(code: "factory_cache_failed", message: error.localizedDescription, details: nil))
      }
    case "gameCacheRoot":
      do {
        result(try userGameDirectory().path)
      } catch {
        result(FlutterError(code: "game_cache_failed", message: error.localizedDescription, details: nil))
      }
    case "switchToAsset":
      guard let id = args["id"] as? String, !id.isEmpty else {
        result(FlutterError(code: "bad_id", message: "素材ID为空", details: nil))
        return
      }
      switchToAsset(id: id, crc32: args["crc32"] as? String, result: result)
    case "getDeviceIdentity":
      runDeviceCommand("IDENTITY\n", errorCode: "identity_failed", result: result) { response in
        guard let key = self.parseDeviceKey(response) else {
          throw BadgeError.message(response.isEmpty ? "设备身份读取失败" : response)
        }
        return key
      }
    case "statDeviceAsset":
      guard let id = args["id"] as? String,
            let crc32 = args["crc32"] as? String,
            validUserDeviceCommand(id: id, crc32: crc32) else {
        result(FlutterError(code: "bad_asset_identity", message: "素材身份无效", details: nil))
        return
      }
      runDeviceCommand("STAT \(id) \(crc32)\n", errorCode: "asset_stat_failed", result: result) { $0 }
    case "deleteDeviceAsset":
      guard let id = args["id"] as? String,
            let crc32 = args["crc32"] as? String,
            validUserDeviceCommand(id: id, crc32: crc32) else {
        result(FlutterError(code: "bad_asset_identity", message: "素材身份无效", details: nil))
        return
      }
      runDeviceCommand("DELETE \(id) \(crc32)\n", errorCode: "asset_delete_failed", result: result) { $0 }
    case "setRandomMode":
      let enabled = args["enabled"] as? Bool ?? false
      setRandomMode(enabled: enabled, result: result)
    case "getRandomMode":
      getRandomMode(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startScan() {
    sendEvent(["type": "scanState", "scanning": true])
    sendEvent([
      "type": "scanResult",
      "device": [
        "address": BadgeConstants.badgeApHost,
        "name": BadgeConstants.badgeDeviceName,
        "rssi": -30,
        "serviceMatch": true,
      ],
    ])
    publishLanBadgeScanResult()
    publishHotspotBadgeScanResult()
    DispatchQueue.main.asyncAfter(deadline: .now() + BadgeConstants.discoveryListenTimeout) {
      self.sendEvent(["type": "scanState", "scanning": false])
    }
  }

  private func connect(address: String?, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      if let address, self.isIpv4Address(address) {
        self.setActiveBadgeHost(address)
      } else {
        self.setActiveBadgeHost(BadgeConstants.badgeApHost)
      }
      do {
        let status = try self.resolveBadgeStatus()
        self.rememberDiscoveredBadge(DiscoveredBadge(host: self.activeBadgeHost, status: status))
        self.sendConnectionEvent(connected: true, connecting: false, message: "已连接")
        DispatchQueue.main.async { result(nil) }
      } catch {
        self.connectedAddress = nil
        self.sdAvailable = false
        self.sendConnectionEvent(connected: false, connecting: false, message: "请先连接 DotLoop Wi-Fi")
        DispatchQueue.main.async {
          result(FlutterError(code: "connect_failed", message: "请先连接 DotLoop Wi-Fi", details: nil))
        }
      }
    }
  }

  private func readConnectionState(result: @escaping FlutterResult) {
    if isUploading {
      result([
        "connected": connectedAddress != nil,
        "connecting": false,
        "address": nullable(connectedAddress),
        "sdAvailable": sdAvailable,
        "hardware": badgeHardware,
        "message": "上传中",
      ])
      return
    }
    DispatchQueue.global(qos: .utility).async {
      var connected = false
      var message = "未连接"
      if self.connectedAddress != nil {
        do {
          let status = try self.requestText(self.badgeUrl("/status"), timeout: BadgeConstants.statusTimeout)
          self.sdAvailable = self.parseSdAvailable(status)
          connected = true
          message = "已连接"
        } catch {
          self.connectedAddress = nil
          self.sdAvailable = false
          message = "断开连接"
        }
      } else if let discovered = self.discoverBadgeOnLan() {
        self.rememberDiscoveredBadge(discovered)
        connected = true
        message = "已发现局域网设备"
      }
      DispatchQueue.main.async {
        result([
          "connected": connected,
          "connecting": false,
          "address": nullable(self.connectedAddress),
          "sdAvailable": self.sdAvailable,
          "hardware": self.badgeHardware,
          "message": message,
        ])
      }
    }
  }

  private func setBrightness(_ value: Int, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .utility).async {
      do {
        _ = try self.requestText("\(self.badgeUrl("/brightness"))?value=\(value)", timeout: BadgeConstants.statusTimeout)
        DispatchQueue.main.async { result(nil) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "wifi_write", message: "亮度写入失败", details: nil))
        }
      }
    }
  }

  private func calibrationCommand(
    action: String,
    angleTenths: Int?,
    returnsSnapshot: Bool,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        var url = "\(self.badgeUrl("/calibration"))?action=\(action)"
        if let angleTenths {
          url += "&angle_tenths=\(min(1800, max(-1800, angleTenths)))"
        }
        let response = try self.requestText(url, timeout: BadgeConstants.statusTimeout)
        guard
          let data = response.data(using: .utf8),
          let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          payload["success"] as? Bool == true
        else {
          throw BadgeError.message("校正失败")
        }
        DispatchQueue.main.async {
          if returnsSnapshot {
            result([
              "angleTenths": payload["angleTenths"] as? Int ?? 0,
              "active": payload["active"] as? Bool ?? false,
            ])
          } else {
            result(nil)
          }
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "calibration_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func badgeUrl(_ path: String, host: String? = nil) -> String {
    let targetHost = host ?? activeBadgeHost
    let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
    return "http://\(targetHost)\(normalizedPath)"
  }

  private func setActiveBadgeHost(_ host: String) {
    activeBadgeHost = isIpv4Address(host) ? host : BadgeConstants.badgeApHost
  }

  private func isIpv4Address(_ value: String) -> Bool {
    let parts = value.split(separator: ".")
    guard parts.count == 4 else { return false }
    return parts.allSatisfy { part in
      guard !part.isEmpty, part.count <= 3, let number = Int(part) else { return false }
      return number >= 0 && number <= 255
    }
  }

  private func isBadgeStatusText(_ status: String) -> Bool {
    let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return false }
    return (normalized.hasPrefix("idle ") || normalized.hasPrefix("upload ")) &&
      normalized.contains("storage=") &&
      normalized.contains("sd=") &&
      normalized.contains("format=")
  }

  private func rememberDiscoveredBadge(_ discovered: DiscoveredBadge) {
    setActiveBadgeHost(discovered.host)
    sdAvailable = parseSdAvailable(discovered.status)
    connectedAddress = activeBadgeHost
  }

  private func resolveBadgeStatus() throws -> String {
    if let discovered = probeBadgeHost(activeBadgeHost) {
      setActiveBadgeHost(discovered.host)
      return discovered.status
    }
    if activeBadgeHost != BadgeConstants.badgeApHost,
       let discovered = probeBadgeHost(BadgeConstants.badgeApHost) {
      setActiveBadgeHost(discovered.host)
      return discovered.status
    }
    if let discovered = discoverBadgeOnLan() {
      setActiveBadgeHost(discovered.host)
      return discovered.status
    }
    throw BadgeError.message("请先连接 DotLoop Wi-Fi，或让手机和设备在同一 Wi-Fi 下")
  }

  private func publishLanBadgeScanResult() {
    DispatchQueue.global(qos: .utility).async {
      guard let discovered = self.discoverBadgeOnLan() else { return }
      self.setActiveBadgeHost(discovered.host)
      self.sdAvailable = self.parseSdAvailable(discovered.status)
      self.sendEvent([
        "type": "scanResult",
        "device": [
          "address": discovered.host,
          "name": "\(BadgeConstants.badgeDeviceName) LAN",
          "rssi": 0,
          "serviceMatch": true,
        ],
      ])
      self.sendEvent(["type": "status", "message": "已发现局域网设备 \(discovered.host)"])
    }
  }

  private func publishHotspotBadgeScanResult() {
    DispatchQueue.global(qos: .utility).async {
      guard let discovered = self.listenForBadgeHello() else { return }
      self.rememberDiscoveredBadge(discovered)
      self.sendEvent([
        "type": "scanResult",
        "device": [
          "address": discovered.host,
          "name": "\(BadgeConstants.badgeDeviceName) Hotspot",
          "rssi": 0,
          "serviceMatch": true,
        ],
      ])
      self.sendEvent(["type": "status", "message": "已发现手机热点设备 \(discovered.host)"])
    }
  }

  private func listenForBadgeHello() -> DiscoveredBadge? {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(BadgeConstants.discoveryUdpPort).bigEndian
    address.sin_addr = in_addr(s_addr: INADDR_ANY)
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else { return nil }

    let deadline = Date().addingTimeInterval(BadgeConstants.discoveryListenTimeout)
    var buffer = [UInt8](repeating: 0, count: BadgeConstants.discoveryPacketBytes)
    while Date() < deadline {
      var sender = sockaddr_in()
      var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
      let count = buffer.withUnsafeMutableBytes { rawBuffer in
        withUnsafeMutablePointer(to: &sender) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.recvfrom(fd, rawBuffer.baseAddress, rawBuffer.count, 0, sockaddrPointer, &senderLength)
          }
        }
      }
      guard count > 0 else { continue }
      let payload = String(bytes: buffer.prefix(count), encoding: .utf8) ?? ""
      guard payload.contains("espbaji_hello") else { continue }

      var senderAddress = sender.sin_addr
      var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      let converted = hostBuffer.withUnsafeMutableBufferPointer { hostPointer in
        inet_ntop(AF_INET, &senderAddress, hostPointer.baseAddress, socklen_t(INET_ADDRSTRLEN))
      }
      guard converted != nil else { continue }
      let host = String(cString: hostBuffer)
      if let discovered = probeBadgeHost(host) {
        return discovered
      }
    }
    return nil
  }

  private func discoverBadgeOnLan() -> DiscoveredBadge? {
    let candidates = lanScanCandidates()
    guard !candidates.isEmpty else { return nil }

    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = BadgeConstants.lanDiscoveryConcurrency
    let lock = NSLock()
    var found: DiscoveredBadge?

    for host in candidates.prefix(BadgeConstants.lanDiscoveryMaxCandidates) {
      queue.addOperation {
        lock.lock()
        let alreadyFound = found != nil
        lock.unlock()
        if alreadyFound || queue.isSuspended { return }

        if let discovered = self.probeBadgeHost(host) {
          lock.lock()
          if found == nil {
            found = discovered
            queue.cancelAllOperations()
          }
          lock.unlock()
        }
      }
    }
    queue.waitUntilAllOperationsAreFinished()
    return found
  }

  private func probeBadgeHost(_ host: String) -> DiscoveredBadge? {
    guard isIpv4Address(host) else { return nil }
    guard
      let status = try? requestText(
        badgeUrl("/status", host: host),
        timeout: BadgeConstants.lanDiscoveryProbeTimeout,
        timeoutGrace: BadgeConstants.lanDiscoveryTimeoutGrace
      ),
      isBadgeStatusText(status)
    else {
      return nil
    }
    return DiscoveredBadge(host: host, status: status)
  }

  private func lanScanCandidates() -> [String] {
    var candidates: [String] = []
    var seen = Set<String>()

    func add(_ host: String) {
      guard isIpv4Address(host), !seen.contains(host) else { return }
      seen.insert(host)
      candidates.append(host)
    }

    add(activeBadgeHost)
    add(BadgeConstants.badgeApHost)

    let localAddresses = localIPv4Addresses()
    for address in localAddresses {
      let parts = address.split(separator: ".")
      guard parts.count == 4 else { continue }
      let prefix = parts.prefix(3).joined(separator: ".")
      for last in 1...254 {
        let host = "\(prefix).\(last)"
        if host != address {
          add(host)
        }
      }
    }
    return candidates
  }

  private func localIPv4Addresses() -> [String] {
    var output: [String] = []
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return output }
    defer { freeifaddrs(first) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let item = cursor {
      defer { cursor = item.pointee.ifa_next }
      guard let address = item.pointee.ifa_addr else { continue }
      let family = address.pointee.sa_family
      let flags = Int32(item.pointee.ifa_flags)
      guard family == UInt8(AF_INET), (flags & IFF_LOOPBACK) == 0 else { continue }

      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let result = getnameinfo(
        address,
        socklen_t(MemoryLayout<sockaddr_in>.size),
        &host,
        socklen_t(host.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      if result == 0 {
        output.append(String(cString: host))
      }
    }
    return output
  }

  private func pickMedia(result: @escaping FlutterResult) {
    guard pendingPickResult == nil else {
      result(FlutterError(code: "busy", message: "正在选择素材", details: nil))
      return
    }
    pendingPickResult = result
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .any(of: [.images, .videos])
    configuration.selectionLimit = 1
    configuration.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    window?.rootViewController?.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let pending = pendingPickResult else { return }
    pendingPickResult = nil
    guard let itemProvider = results.first?.itemProvider else {
      pending(nil)
      return
    }

    loadPickedMediaFile(from: itemProvider) { result in
      switch result {
      case .success(let url):
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let media = try self.preparePickedMedia(url: url)
            DispatchQueue.main.async { pending(media) }
          } catch {
            DispatchQueue.main.async {
              pending(FlutterError(code: "pick_failed", message: error.localizedDescription, details: nil))
            }
          }
        }
      case .failure(let error):
        DispatchQueue.main.async {
          pending(FlutterError(code: "pick_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func preparePickedMedia(url: URL) throws -> [String: Any] {
    let local = try copyPickedFileToCache(url)
    let mime = mimeType(for: local)
    let attributes = try FileManager.default.attributesOfItem(atPath: local.path)
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    if isVideoMime(mime) && size > BadgeConstants.maxVideoInputBytes {
      throw BadgeError.message("视频文件过大")
    }
    let previewBytes = try buildPreviewData(url: local, mime: mime, crop: .default)
    let animatedPreviewPath: String?
    if isGif(local) {
      animatedPreviewPath = try copyAnimatedPreview(source: local, directoryName: "media_preview")
    } else {
      animatedPreviewPath = nil
    }
    let durationMs = mediaDurationMs(local, mime: mime)
    return [
      "uri": local.absoluteString,
      "name": local.lastPathComponent,
      "size": size,
      "mime": mime,
      "durationMs": durationMs,
      "previewBytes": FlutterStandardTypedData(bytes: previewBytes),
      "animatedPreviewPath": nullable(animatedPreviewPath),
    ]
  }

  private func videoDurationMs(_ url: URL) -> Int {
    let seconds = CMTimeGetSeconds(AVAsset(url: url).duration)
    return seconds.isFinite ? max(0, Int(seconds * 1000.0)) : 0
  }

  private func gifFrameDelaysMs(_ source: CGImageSource) -> [Int] {
    return (0..<CGImageSourceGetCount(source)).map { index in
      let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
      let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
      let unclamped = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue ?? 0
      let clamped = (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0
      let seconds = unclamped.isFinite && unclamped > 0 ? unclamped : clamped
      return seconds.isFinite && seconds > 0 ? max(1, Int((seconds * 1000).rounded())) : 100
    }
  }

  private func mediaDurationMs(_ url: URL, mime: String) -> Int {
    if isVideoMime(mime) { return videoDurationMs(url) }
    guard mime == "image/gif", let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
    return gifFrameDelaysMs(source).reduce(0, +)
  }

  private func videoFramePreview(uriText: String, frameFraction: Double, crop: CropTransform, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let url = try self.url(from: uriText)
        let mime = self.mimeType(for: url)
        let durationMs = self.mediaDurationMs(url, mime: mime)
        let fraction = min(1.0, max(0.0, frameFraction))
        let timeMs = min(max(0, durationMs - 1), Int(Double(durationMs) * fraction))
        let bytes = try self.buildPreviewData(url: url, mime: mime, crop: crop, frameTimeMs: timeMs)
        DispatchQueue.main.async {
          result(["previewBytes": FlutterStandardTypedData(bytes: bytes), "durationMs": durationMs, "timeMs": timeMs])
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "frame_preview_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func loadPickedMediaFile(
    from itemProvider: NSItemProvider,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    let typeIdentifiers = [
      UTType.movie.identifier,
      UTType.mpeg4Movie.identifier,
      UTType.quickTimeMovie.identifier,
      UTType.gif.identifier,
      UTType.png.identifier,
      UTType.jpeg.identifier,
      UTType.webP.identifier,
      UTType.image.identifier,
    ].filter { itemProvider.hasItemConformingToTypeIdentifier($0) }

    guard let typeIdentifier = typeIdentifiers.first else {
      completion(.failure(BadgeError.message("相册素材格式不支持")))
      return
    }

    itemProvider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
      if let error {
        completion(.failure(error))
        return
      }
      guard let url else {
        completion(.failure(BadgeError.message("相册素材读取失败")))
        return
      }
      do {
        let local = try self.copyPickedFileToCache(url)
        completion(.success(local))
      } catch {
        completion(.failure(error))
      }
    }
  }

  private func warmVideoAnimatedPreview(uriText: String, displayName: String, result: @escaping FlutterResult) {
    result(nil)
    DispatchQueue.global(qos: .utility).async {
      do {
        let url = try self.url(from: uriText)
        guard self.isVideoMime(self.mimeType(for: url)) else { return }
        self.scheduleVideoAnimatedPreview(
          url: url,
          uriText: uriText,
          directoryName: "media_preview",
          stem: self.safeFileName(displayName),
          crop: .default,
          eventType: "videoPreviewReady"
        )
      } catch {
      }
    }
  }

  private func prepareAsset(
    uriText: String,
    displayName: String,
    fps: Int,
    maxPackageBytes: Int,
    crop: CropTransform,
    coverFrame: Double,
    warmPreviewPath: String?,
    outputDirectoryName: String,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let url = try self.url(from: uriText)
        let mime = self.mimeType(for: url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if self.isVideoMime(mime) && size > BadgeConstants.maxVideoInputBytes {
          throw BadgeError.message("视频文件过大")
        }
        let encoder = EbajEncoder { progress in
          self.sendEvent(["type": "prepareProgress", "progress": progress])
        }
        let encoded = try encoder.encode(url: url, mime: mime, requestedFps: fps, maxPackageBytes: maxPackageBytes, crop: crop)
        let stem = "\(Int(Date().timeIntervalSince1970 * 1000))_\(self.safeFileName(displayName))"
        let assetPath = try self.writeCacheFile(data: encoded.packageBytes, directoryName: outputDirectoryName, stem: stem, ext: "ebaj")
        let durationMs = self.mediaDurationMs(url, mime: mime)
        let coverTimeMs = min(max(0, durationMs - 1), Int(Double(durationMs) * coverFrame))
        let previewPath = try? self.writeCacheFile(
          data: self.buildPreviewData(url: url, mime: mime, crop: crop, frameTimeMs: coverTimeMs),
          directoryName: outputDirectoryName,
          stem: stem,
          ext: "png"
        )
        let animatedPreviewPath: String?
        if self.isVideoMime(mime) {
          if let warmPreviewPath,
             FileManager.default.fileExists(atPath: URL(fileURLWithPath: warmPreviewPath).path) {
            let gifData = try Data(contentsOf: URL(fileURLWithPath: warmPreviewPath))
            animatedPreviewPath = try self.writeCacheFile(data: gifData, directoryName: outputDirectoryName, stem: stem, ext: "gif")
          } else {
            animatedPreviewPath = nil
          }
        } else if self.isGif(url) {
          animatedPreviewPath = try self.copyAnimatedPreview(source: url, directoryName: outputDirectoryName, stem: stem)
        } else {
          animatedPreviewPath = nil
        }
        DispatchQueue.main.async {
          result([
            "assetPath": assetPath,
            "previewPath": nullable(previewPath),
            "animatedPreviewPath": nullable(animatedPreviewPath),
            "sourceUri": url.absoluteString,
            "mime": mime,
            "name": displayName,
            "packageSize": encoded.packageBytes.count,
            "frameCount": encoded.frameCount,
            "fps": encoded.fps,
            "crc32": Int(encoded.crc32),
          ])
        }
        if self.isVideoMime(mime), animatedPreviewPath == nil {
          self.scheduleVideoAnimatedPreview(
            url: url,
            uriText: url.absoluteString,
            directoryName: outputDirectoryName,
            stem: stem,
            crop: crop,
            eventType: "assetPreviewReady",
            assetPath: assetPath
          )
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "prepare_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func scheduleVideoAnimatedPreview(
    url: URL,
    uriText: String,
    directoryName: String,
    stem: String,
    crop: CropTransform,
    eventType: String,
    assetPath: String? = nil
  ) {
    DispatchQueue.global(qos: .utility).async {
      if self.isUploading { return }
      Thread.sleep(forTimeInterval: 1.2)
      if self.isUploading { return }
      do {
        let started = Date()
        let data = try self.buildVideoAnimatedPreview(url: url, crop: crop, warmPreviewPath: nil)
        let path = try self.writeCacheFile(data: data, directoryName: directoryName, stem: stem, ext: "gif")
        NSLog(
          "BadgePrepare animated preview ready event=%@ bytes=%ld time=%ldms",
          eventType as NSString,
          data.count,
          Int(Date().timeIntervalSince(started) * 1000)
        )
        self.sendEvent([
          "type": eventType,
          "uri": uriText,
          "assetPath": nullable(assetPath),
          "animatedPreviewPath": path,
        ])
      } catch {
      }
    }
  }

  private func installFactoryPackage(args: [String: Any], isGame: Bool = false, result: @escaping FlutterResult) {
    guard let path = args["assetPath"] as? String,
          let key = args["deviceKey"] as? String,
          let expectedHash = args["sha256"] as? String,
          let id = args["id"] as? String, !isUploading else {
      result(FlutterError(code: "factory_invalid", message: "素材参数无效或设备正在传输", details: nil))
      return
    }
    isUploading = true
    DispatchQueue.global(qos: .userInitiated).async {
      self.beginUploadBackgroundTask()
      defer { self.isUploading = false; self.endUploadBackgroundTask() }
      do {
        let file = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count > 0, data.count <= (isGame ? 131072 : 64 * 1024 * 1024 + 8200), actualHash == expectedHash,
              self.parseDeviceKey(try self.sendRawTcpCommand("IDENTITY\n")) == key,
              let url = URL(string: "http://\(self.activeBadgeHost)/\(isGame ? "games" : "factory")/install") else {
          throw transferFailure("factory_invalid", "素材校验失败或热点设备身份不一致")
        }
        let capability = try self.factoryInstallRequest(URLRequest(url: url))
        guard capability["protocol"] as? Int == 1, capability["deviceKey"] as? String == key else {
          throw transferFailure("factory_invalid", "设备安装协议或身份不一致")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Device-Key")
        if isGame {
          guard id.range(of: "^[a-z0-9_]{1,24}$", options: .regularExpression) != nil else {
            throw transferFailure("game_invalid", "游戏编号无效")
          }
          request.setValue(id, forHTTPHeaderField: "X-Game-Id")
          request.setValue(expectedHash, forHTTPHeaderField: "X-Content-SHA256")
        }
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        let reply = try self.factoryInstallRequest(request, uploadFile: file)
        guard reply["installed"] as? Bool == true, reply["id"] as? String == id,
              reply["deviceKey"] as? String == key else {
          throw transferFailure("factory_invalid", "设备安装确认无效")
        }
        self.sendEvent(["type": "uploadProgress", "progress": 0.98, "message": "素材已安装"])
        self.isUploading = false
        DispatchQueue.main.async { result(reply) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "factory_install_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func factoryInstallRequest(_ original: URLRequest, uploadFile: URL? = nil) throws -> [String: Any] {
    var request = original
    request.timeoutInterval = 150
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForResource = 180
    var progress = RelayInstallProgress()
    let delegate = RelayNoRedirectDelegate(onUploadProgress: { [weak self] sent, total in
      guard let value = progress.update(sent: sent, total: total,
                                        now: ProcessInfo.processInfo.systemUptime) else { return }
      self?.sendEvent(["type": "uploadProgress", "progress": value, "message": "安装设备素材"])
    })
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let semaphore = DispatchSemaphore(value: 0)
    var output = Data()
    var status = 0
    var failure: Error?
    let completion: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
      output = data ?? Data(); status = (response as? HTTPURLResponse)?.statusCode ?? 0
      failure = error; semaphore.signal()
    }
    let task: URLSessionTask = uploadFile == nil
      ? session.dataTask(with: request, completionHandler: completion)
      : session.uploadTask(with: request, fromFile: uploadFile!, completionHandler: completion)
    task.resume()
    guard semaphore.wait(timeout: .now() + 185) != .timedOut else {
      task.cancel()
      throw transferFailure("factory_timeout", "素材传输超时，请重新点选重试")
    }
    if let failure { throw failure }
    guard (200...299).contains(status) else {
      throw transferFailure("factory_rejected", status == 404
        ? "设备固件尚不支持手机安装出厂素材，需要先更新固件"
        : "设备安装失败 (\(status))，请重新点选重试")
    }
    guard output.count <= 8192,
          let reply = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any] else {
      throw transferFailure("factory_invalid", "设备安装响应无效，请重新点选确认")
    }
    return reply
  }

  private func uploadAsset(assetPath: String, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      self.beginUploadBackgroundTask()
      self.isUploading = true
      defer {
        self.isUploading = false
        self.endUploadBackgroundTask()
      }
      do {
        let package = try self.preparePackageForUpload(fileURL: URL(fileURLWithPath: assetPath))
        var assignedId: String?
        do {
          assignedId = try self.uploadAssetOverTcp(package: package)
        } catch {
          try self.uploadAssetOverHttp(package: package)
        }
        self.sendEvent(["type": "uploadProgress", "progress": 1.0, "message": "已切换显示"])
        var resultMap: [String: Any] = [:]
        resultMap["crc32"] = package.crc
        resultMap["packageSize"] = package.size
        if let id = assignedId { resultMap["assignedId"] = id }
        if assignedId != nil,
           let response = try? self.sendRawTcpCommand("IDENTITY\n"),
           let deviceKey = self.parseDeviceKey(response) {
          resultMap["deviceKey"] = deviceKey
        }
        DispatchQueue.main.async { result(resultMap.isEmpty ? nil : resultMap) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "upload_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func beginUploadBackgroundTask() {
    performOnMainSync {
      guard uploadPreviousIdleTimerDisabled == nil else { return }
      uploadPreviousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      uploadBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ESP BAJI Upload") { [weak self] in
        self?.endUploadBackgroundTask()
      }
    }
  }

  private func endUploadBackgroundTask() {
    performOnMainSync {
      guard let previousIdleTimerDisabled = uploadPreviousIdleTimerDisabled else { return }
      uploadPreviousIdleTimerDisabled = nil
      UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
      guard uploadBackgroundTask != .invalid else { return }
      let task = uploadBackgroundTask
      uploadBackgroundTask = .invalid
      UIApplication.shared.endBackgroundTask(task)
    }
  }

  private func performOnMainSync(_ block: () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.sync(execute: block)
    }
  }

  private func switchToAsset(id: String, crc32: String?, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let response = try self.sendSwitchCommand(id: id, crc32: crc32)
        if response.hasPrefix("OK") {
          self.sendEvent(["type": "switchResult", "id": id, "success": true])
          DispatchQueue.main.async { result(true) }
        } else if response.hasPrefix("NEED_UPLOAD") {
          DispatchQueue.main.async {
            result(["needsUpload": true, "id": id])
          }
        } else {
          throw NSError(
            domain: "BadgeSwitch",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: response.isEmpty ? "切换失败" : response]
          )
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "switch_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func setRandomMode(enabled: Bool, result: @escaping FlutterResult) {
    sendRandomModeCommand(enabled ? "ON" : "OFF", result: result)
  }

  private func getRandomMode(result: @escaping FlutterResult) {
    sendRandomModeCommand("GET", result: result)
  }

  private func sendRandomModeCommand(_ arg: String, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let response = try self.sendRawTcpCommandWithRetry("RANDOM \(arg)\n")
        guard response.hasPrefix("OK RANDOM") else {
          throw BadgeError.message(response.isEmpty ? "随机播放设置失败" : response)
        }
        DispatchQueue.main.async {
          result(response.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("1"))
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "random_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func requestNewUserId(result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let response = try self.sendSwitchCommand(id: "NEWID")
        if response.hasPrefix("OK ") {
          let newId = response
            .dropFirst(3)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          DispatchQueue.main.async { result(newId) }
        } else {
          throw BadgeError.message(response.isEmpty ? "获取素材 ID 失败" : response)
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "id_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func sendSwitchCommand(id: String, crc32: String? = nil) throws -> String {
    let command = crc32.map { "SWITCH \(id) \($0)\n" } ?? "SWITCH \(id)\n"
    return try sendRawTcpCommand(command)
  }

  private func receiveTcpLine(
    connection: NWConnection,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    var buffer = BadgeTcpLineBuffer()
    func receiveNext() {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, isComplete, error in
        if let error { completion(.failure(error)); return }
        do {
          if let line = try buffer.append(data, isComplete: isComplete) {
            completion(.success(line))
          } else {
            receiveNext()
          }
        } catch {
          completion(.failure(error))
        }
      }
    }
    receiveNext()
  }

  private func sendRawTcpCommand(_ command: String) throws -> String {
    let semaphore = DispatchSemaphore(value: 0)
    let completionLock = NSLock()
    var response: Result<String, Error>?
    func finish(_ value: Result<String, Error>) {
      completionLock.lock()
      defer { completionLock.unlock() }
      guard response == nil else { return }
      response = value
      semaphore.signal()
    }
    let connection = NWConnection(
      host: NWEndpoint.Host(activeBadgeHost),
      port: NWEndpoint.Port(rawValue: UInt16(BadgeConstants.badgeUploadTcpPort))!,
      using: .tcp
    )
    connection.stateUpdateHandler = { state in
      switch state {
      case .ready:
        connection.send(
          content: command.data(using: .utf8),
          completion: .contentProcessed { error in
            if let error = error {
              finish(.failure(error))
              return
            }
            self.receiveTcpLine(connection: connection) { reply in
              finish(reply)
            }
          }
        )
      case .failed(let error), .waiting(let error):
        finish(.failure(error))
      default:
        break
      }
    }
    connection.start(queue: .global())
    if semaphore.wait(timeout: .now() + .seconds(5)) == .timedOut {
      finish(.failure(BadgeError.message("TCP请求超时")))
    }
    connection.cancel()
    completionLock.lock()
    defer { completionLock.unlock() }
    return try response!.get()
  }

  private func transcodeOnServer(
    uriText: String,
    name: String,
    maxFps: Int,
    crop: CropTransform,
    hardware: String,
    deviceTransfer: Bool,
    backendBase: String,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        self.sendEvent(["type": "transcodeProgress", "stage": "upload", "message": "上传素材到服务器"])
        let source = try self.url(from: uriText)
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if self.isVideoMime(self.mimeType(for: source)) && size > BadgeConstants.maxVideoInputBytes {
          throw BadgeError.message("视频文件过大")
        }
        let params: [String: Any] = [
          "name": name,
          "maxFps": maxFps,
          "streamSize": 480,
          "userId": "ios-user",
          "hardware": hardware,
          "deviceTransfer": deviceTransfer,
          "crop": ["scale": crop.scale, "offsetX": crop.offsetX, "offsetY": crop.offsetY],
        ]
        let backend = backendBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let jobId = try self.postTranscodeJob(backend: backend, source: source, params: params)
        self.sendEvent(["type": "transcodeProgress", "stage": "transcoding", "message": "服务器解码中"])
        let job = try self.waitForTranscode(backend: backend, jobId: jobId)
        let assetId = job["assetId"] as? String ?? ""
        guard !assetId.isEmpty else { throw BadgeError.message("转码结果缺失") }

        let directory = try self.cacheDirectory("ebaj")
        let stem = "\(Int(Date().timeIntervalSince1970 * 1000))_\(self.safeFileName(name))"
        let preview = directory.appendingPathComponent("\(stem).png")
        let previewPath = try? self.downloadBackendFile(
          url: URL(string: "\(backend)/api/assets/\(assetId)/preview")!,
          target: preview,
          maximumBytes: 8 * 1024 * 1024,
          requestTimeout: BadgeConstants.previewRequestTimeout,
          resourceTimeout: BadgeConstants.previewResourceTimeout
        )
        DispatchQueue.main.async {
          result([
            "reviewId": assetId,
            "reviewStatus": job["reviewStatus"] as? String ?? "pending",
            "fps": job["fps"] as? Int ?? 60,
            "previewPath": nullable(previewPath?.path),
          ])
        }
      } catch {
        DispatchQueue.main.async {
          let ns = error as NSError
          let networkCodes = [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet]
          let unavailable = (ns.domain == NSURLErrorDomain && networkCodes.contains(ns.code)) || ns.domain == "DotLoopBackendUnavailable"
          result(FlutterError(code: unavailable ? "network_unavailable" : "transcode_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func localPackageMetadata(fileURL: URL, hardware: String? = nil) throws -> [String: Any] {
    let info = try preparePackageForUpload(fileURL: fileURL, hardware: hardware)
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { handle.closeFile() }
    let header = handle.readData(ofLength: BadgeConstants.headerSize)
    return ["assetPath": fileURL.path, "crc32": info.crc, "packageSize": info.size,
            "frameCount": Int(readLe16(header, 12)), "fps": Int(readLe16(header, 14))]
  }

  private func runFirmwareOperation(result: @escaping FlutterResult, transfer: Bool = false,
                                    operation: @escaping () throws -> [String: Any]) {
    DispatchQueue.global(qos: .userInitiated).async {
      if transfer {
        self.beginUploadBackgroundTask()
        self.isUploading = true
      }
      defer {
        if transfer {
          self.isUploading = false
          self.endUploadBackgroundTask()
        }
      }
      do {
        let value = try operation()
        DispatchQueue.main.async { result(value) }
      } catch {
        DispatchQueue.main.async { result(nativeTransferError(error, fallback: "firmware_failed")) }
      }
    }
  }

  private func verifyFirmware(_ file: URL, manifest: RelayFirmwareManifest) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard (attributes[.size] as? NSNumber)?.intValue == manifest.size else {
      throw transferFailure("firmware_invalid", "固件长度校验失败，请重新下载")
    }
    // At most 3 MiB: never map an unbounded or unverified input into memory.
    let data = try Data(contentsOf: file)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    func field(_ offset: Int, _ length: Int) -> String {
      String(bytes: data[offset..<(offset + length)].prefix { $0 != 0 }, encoding: .utf8) ?? ""
    }
    guard data.count >= 288, data.count == manifest.size, hash == manifest.sha256,
          data[0] == 0xe9, field(48, 32) == manifest.version,
          field(80, 32) == "esp32-p4c5-dotloop" else {
      throw transferFailure("firmware_invalid", "固件 SHA256 或内容与版本清单不一致")
    }
  }

  private func firmwareJSONRequest(_ original: URLRequest, uploadFile: URL? = nil,
                                   unsupportedOn404: Bool = false) throws -> [String: Any] {
    var request = original
    request.timeoutInterval = 120
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForResource = 150
    // Firmware URLs and device responses must not redirect uploads elsewhere.
    let redirects = RelayNoRedirectDelegate()
    let session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let semaphore = DispatchSemaphore(value: 0)
    var output = Data()
    var failure: Error?
    var status = 0
    let completion: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
      output = data ?? Data()
      failure = error
      status = (response as? HTTPURLResponse)?.statusCode ?? 0
      semaphore.signal()
    }
    let task: URLSessionTask = uploadFile == nil
      ? session.dataTask(with: request, completionHandler: completion)
      : session.uploadTask(with: request, fromFile: uploadFile!, completionHandler: completion)
    let started = Date()
    if uploadFile != nil { NSLog("BadgeFirmware upload started bytes=%@", request.value(forHTTPHeaderField: "Content-Length") ?? "unknown") }
    task.resume()
    if semaphore.wait(timeout: .now() + 155) == .timedOut {
      task.cancel()
      throw transferFailure(uploadFile == nil ? "network_unavailable" : "firmware_result_unknown",
        uploadFile == nil ? "固件请求超时" : "固件更新请求超时，手机未收到更新结果。设备可能已更新，请重新连接并查看实际固件版本后再决定是否重试。")
    }
    if let failure {
      if uploadFile != nil {
        NSLog("BadgeFirmware upload response lost elapsed=%ldms bytes=%lld error=%@",
          Int(Date().timeIntervalSince(started) * 1000), redirects.sentBytes, failure.localizedDescription)
        // An upload response can disappear when a verified device reboots.
        // Preserve uncertainty and never issue another firmware POST here.
        throw transferFailure("firmware_result_unknown",
          "手机未收到固件更新结果。设备可能已更新并重启，请重新连接并查看实际固件版本后再决定是否重试。")
      }
      throw failure
    }
    guard (200...299).contains(status) else {
      if status == 404 && unsupportedOn404 {
        throw transferFailure("firmware_unsupported", "设备当前固件不支持手机更新，请先安装支持更新的固件")
      }
      throw transferHTTPFailure(status, firmware: true)
    }
    guard output.count <= 8192,
          let reply = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any] else {
      if uploadFile != nil {
        throw transferFailure("firmware_result_unknown",
          "固件已传送，但设备确认响应不完整。设备可能已更新并重启，请重新连接并查看实际固件版本后再决定是否重试。")
      }
      throw transferFailure("firmware_invalid", "固件响应格式无效")
    }
    if uploadFile != nil { NSLog("BadgeFirmware upload acknowledged elapsed=%ldms", Int(Date().timeIntervalSince(started) * 1000)) }
    return reply
  }

  private func downloadApprovedPackage(
    assetId: String,
    name: String,
    hardware: String,
    backendBase: String,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      var downloaded: URL?
      do {
        self.sendEvent(["type": "transcodeProgress", "stage": "download", "message": "下载素材包"])
        let backend = backendBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let directory = try self.cacheDirectory("ebaj")
        let target = directory.appendingPathComponent(
          "\(Int(Date().timeIntervalSince1970 * 1000))_\(self.safeFileName(name)).ebaj"
        )
        guard let url = URL(string: "\(backend)/api/assets/\(assetId)/package?hardware=\(hardware)") else {
          throw BadgeError.message("素材包地址错误")
        }
        _ = try self.downloadBackendFile(url: url, target: target)
        downloaded = target
        let metadata = try self.localPackageMetadata(fileURL: target, hardware: hardware)
        DispatchQueue.main.async { result(metadata) }
      } catch {
        if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
        DispatchQueue.main.async {
          result(nativeTransferError(error, fallback: "download_failed"))
        }
      }
    }
  }

  private func postTranscodeJob(backend: String, source: URL, params: [String: Any]) throws -> String {
    guard let endpoint = URL(string: "\(backend)/api/transcode") else {
      throw BadgeError.message("服务器地址错误")
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 3600
    request.setValue(mimeType(for: source), forHTTPHeaderField: "Content-Type")
    request.setValue(safeFileName(source.lastPathComponent), forHTTPHeaderField: "X-Esp-Baji-Filename")
    request.setValue(
      try JSONSerialization.data(withJSONObject: params).base64EncodedString(),
      forHTTPHeaderField: "X-Esp-Baji-Params"
    )
    let data = try performBackendRequest(request, uploadFile: source)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let jobId = json?["jobId"] as? String, !jobId.isEmpty else {
      throw BadgeError.message("服务器未接受转码任务")
    }
    return jobId
  }

  private func waitForTranscode(backend: String, jobId: String) throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(10 * 60)
    while Date() < deadline {
      guard let url = URL(string: "\(backend)/api/transcode/\(jobId)") else {
        throw BadgeError.message("转码任务地址错误")
      }
      var request = URLRequest(url: url)
      request.timeoutInterval = 30
      let data = try performBackendRequest(request)
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
      switch json["status"] as? String {
      case "done": return json
      case "failed": throw BadgeError.message(json["error"] as? String ?? "服务器转码失败")
      default: Thread.sleep(forTimeInterval: 0.25)
      }
    }
    throw BadgeError.message("转码超时")
  }

  private func performBackendRequest(_ request: URLRequest, uploadFile: URL? = nil) throws -> Data {
    let semaphore = DispatchSemaphore(value: 0)
    var responseData: Data?
    var responseError: Error?
    var statusCode = 0
    let completion: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
      responseData = data
      responseError = error
      statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
      semaphore.signal()
    }
    let task: URLSessionTask = uploadFile == nil
      ? URLSession.shared.dataTask(with: request, completionHandler: completion)
      : URLSession.shared.uploadTask(with: request, fromFile: uploadFile!, completionHandler: completion)
    task.resume()
    semaphore.wait()
    if let responseError { throw responseError }
    guard (200...299).contains(statusCode) else {
      let message = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? "HTTP \(statusCode)"
      if statusCode >= 500 { throw NSError(domain: "DotLoopBackendUnavailable", code: statusCode, userInfo: [NSLocalizedDescriptionKey: message]) }
      throw BadgeError.message(message)
    }
    return responseData ?? Data()
  }

  private func downloadBackendFile(url: URL, target: URL,
                                   maximumBytes: Int = BadgeConstants.sdStreamBudgetBytes,
                                   expectedSize: Int? = nil, expectedSHA256: String? = nil,
                                   requestTimeout: TimeInterval = 120,
                                   resourceTimeout: TimeInterval = 900) throws -> URL {
    let transfer = RelayBoundedDownload(target: target, maximumBytes: maximumBytes,
      expectedSize: expectedSize, expectedSHA256: expectedSHA256,
      requestTimeout: requestTimeout, resourceTimeout: resourceTimeout)
    return try transfer.download(url)
  }

  private func validUserDeviceCommand(id: String, crc32: String) -> Bool {
    let idChars = Array(id)
    return idChars.count == 4 && idChars[0] == "U" &&
      idChars.dropFirst().allSatisfy(\.isNumber) &&
      crc32.count == 8 && crc32.allSatisfy(\.isHexDigit)
  }

  private func parseDeviceKey(_ response: String) -> String? {
    let prefix = "OK DEVICE "
    guard response.hasPrefix(prefix) else { return nil }
    let key = String(response.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    let suffix = key.hasPrefix("P4-") ? key.dropFirst(3) : Substring()
    guard suffix.count == 12 && suffix.allSatisfy(\.isHexDigit) else { return nil }
    return key
  }

  private func runDeviceCommand<T>(
    _ command: String,
    errorCode: String,
    result: @escaping FlutterResult,
    transform: @escaping (String) throws -> T
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let response = try self.sendRawTcpCommand(command)
        let value = try transform(response)
        DispatchQueue.main.async { result(value) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: errorCode, message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func sendRawTcpCommandWithRetry(_ command: String) throws -> String {
    var lastError: Error = BadgeError.message("设备未返回响应")
    for attempt in 0..<BadgeConstants.randomCommandAttempts {
      do {
        let response = try sendRawTcpCommand(command)
        if !response.isEmpty {
          return response
        }
        throw BadgeError.message("设备未返回响应")
      } catch {
        lastError = error
        if attempt + 1 < BadgeConstants.randomCommandAttempts {
          usleep(useconds_t(BadgeConstants.randomCommandRetryDelayMs * 1000))
        }
      }
    }
    throw lastError
  }

  private func uploadAssetOverTcp(package: UploadPackageInfo) throws -> String? {
    let semaphore = DispatchSemaphore(value: 0)
    let completionLock = NSLock()
    var response: Result<String?, Error>?
    func finish(_ value: Result<String?, Error>) {
      completionLock.lock()
      defer { completionLock.unlock() }
      guard response == nil else { return }
      response = value
      semaphore.signal()
    }
    let connection = NWConnection(
      host: NWEndpoint.Host(activeBadgeHost),
      port: NWEndpoint.Port(rawValue: UInt16(BadgeConstants.badgeUploadTcpPort))!,
      using: .tcp
    )
    activeUpload = connection
    connection.stateUpdateHandler = { state in
      switch state {
      case .ready:
        var header = Data()
        appendLe32(&header, BadgeConstants.badgeTcpUploadMagic)
        appendLe32(&header, UInt32(package.size))
        appendLe32(&header, package.crc)
        connection.send(content: header, completion: .contentProcessed { error in
          if let error = error {
            finish(.failure(error))
            return
          }
          self.receiveTcpLine(connection: connection) { readyReply in
            let readyText: String
            do {
              readyText = try readyReply.get()
            } catch {
              finish(.failure(error))
              return
            }
            guard readyText == "READY" else {
              let trimmedReady = readyText.trimmingCharacters(in: .whitespacesAndNewlines)
              finish(.failure(BadgeError.message(trimmedReady.isEmpty ? "设备未准备好上传" : trimmedReady)))
              return
            }
            self.sendTcpFileChunks(connection: connection, package: package) { chunkError in
              if let chunkError {
                finish(.failure(chunkError))
                return
              }
              self.receiveTcpLine(connection: connection) { reply in
                do {
                  let text = try reply.get()
                  finish(.success(try BadgeTcpLineBuffer.uploadedAssetID(text)))
                } catch {
                  finish(.failure(error))
                }
              }
            }
          }
        })
      case .failed(let error), .waiting(let error):
        finish(.failure(error))
      default:
        break
      }
    }
    connection.start(queue: .global(qos: .userInitiated))
    if semaphore.wait(timeout: .now() + .seconds(BadgeConstants.uploadTimeoutSeconds)) == .timedOut {
      finish(.failure(BadgeError.message("TCP上传超时")))
    }
    connection.cancel()
    activeUpload = nil
    completionLock.lock()
    defer { completionLock.unlock() }
    return try response!.get()
  }

  private func uploadAssetOverHttp(package: UploadPackageInfo) throws {
    var request = URLRequest(url: URL(string: badgeUrl("/upload"))!)
    request.httpMethod = "POST"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue(String(format: "%08x", package.crc), forHTTPHeaderField: "X-EBAJ-CRC32")
    request.timeoutInterval = TimeInterval(BadgeConstants.uploadTimeoutSeconds)
    let semaphore = DispatchSemaphore(value: 0)
    var failure: Error?
    let task = URLSession.shared.uploadTask(with: request, fromFile: package.fileURL) { _, response, error in
      if let error = error {
        failure = error
      } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        failure = BadgeError.message("HTTP \(http.statusCode) 上传失败")
      }
      semaphore.signal()
    }
    task.resume()
    if semaphore.wait(timeout: .now() + .seconds(BadgeConstants.uploadTimeoutSeconds)) == .timedOut {
      task.cancel()
      failure = BadgeError.message("HTTP上传超时")
    }
    if let failure = failure { throw failure }
  }

  private func sendTcpFileChunks(
    connection: NWConnection,
    package: UploadPackageInfo,
    completion: @escaping (Error?) -> Void
  ) {
    guard let stream = InputStream(url: package.fileURL) else {
      completion(BadgeError.message("素材包读取失败"))
      return
    }

    stream.open()
    var sent = 0
    var nextProgressAt = BadgeConstants.uploadProgressStepBytes

    func sendNextChunk() {
      var buffer = [UInt8](repeating: 0, count: BadgeConstants.uploadChunkBytes)
      let read = stream.read(&buffer, maxLength: buffer.count)
      if read < 0 {
        let error = stream.streamError ?? BadgeError.message("素材包读取失败")
        stream.close()
        completion(error)
        return
      }
      if read == 0 {
        stream.close()
        guard sent == package.size else {
          completion(BadgeError.message("素材读取中断"))
          return
        }
        connection.send(content: nil, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { error in
          completion(error)
        })
        return
      }

      let data = Data(buffer.prefix(read))
      connection.send(content: data, completion: .contentProcessed { error in
        if let error {
          stream.close()
          completion(error)
          return
        }
        sent += read
        if sent >= nextProgressAt || sent == package.size {
          self.sendEvent([
            "type": "uploadProgress",
            "progress": Double(sent) / Double(package.size),
            "message": "TCP上传 \(sent * 100 / package.size)%",
          ])
          while nextProgressAt <= sent {
            nextProgressAt += BadgeConstants.uploadProgressStepBytes
          }
        }
        sendNextChunk()
      })
    }

    sendNextChunk()
  }

  private func requestText(
    _ urlText: String,
    timeout: TimeInterval,
    timeoutGrace: TimeInterval = 2
  ) throws -> String {
    guard let url = URL(string: urlText) else { throw BadgeError.message("URL错误") }
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    let semaphore = DispatchSemaphore(value: 0)
    var output = ""
    var failure: Error?
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
      if let error = error {
        failure = error
      } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        failure = BadgeError.message("HTTP \(http.statusCode)")
      } else if let data = data {
        output = String(data: data, encoding: .utf8) ?? ""
      }
      semaphore.signal()
    }
    task.resume()
    if semaphore.wait(timeout: .now() + timeout + timeoutGrace) == .timedOut {
      task.cancel()
      throw BadgeError.message("请求超时")
    }
    if let failure = failure { throw failure }
    return output
  }

  private func buildPreviewData(url: URL, mime: String, crop: CropTransform, frameTimeMs: Int = 0) throws -> Data {
    let image = try renderFirstFrame(url: url, mime: mime, size: BadgeConstants.previewSize, crop: crop, frameTimeMs: frameTimeMs)
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else {
      throw BadgeError.message("预览生成失败")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw BadgeError.message("预览写入失败")
    }
    return data as Data
  }

  private func buildVideoAnimatedPreview(url: URL, crop: CropTransform, warmPreviewPath: String?) throws -> Data {
    if let path = warmPreviewPath {
      let warm = URL(fileURLWithPath: path)
      if FileManager.default.fileExists(atPath: warm.path) {
        return try Data(contentsOf: warm)
      }
    }
    let delayMs = frameDelayMs(BadgeConstants.videoPreviewGifFps)
    let frames = try buildVideoPreviewFrames(url: url, crop: crop)
    return try encodeIndexedGif(frames: frames, width: BadgeConstants.videoPreviewGifSize, height: BadgeConstants.videoPreviewGifSize, delayMs: delayMs)
  }

  private func buildVideoPreviewFrames(url: URL, crop: CropTransform) throws -> [Data] {
    let asset = AVAsset(url: url)
    let durationMs = max(1, Int(CMTimeGetSeconds(asset.duration) * 1000.0))
    let delayMs = frameDelayMs(BadgeConstants.videoPreviewGifFps)
    let totalFrames = max(1, (durationMs + delayMs - 1) / delayMs)
    guard let track = asset.tracks(withMediaType: .video).first else {
      throw BadgeError.message("视频轨道不存在")
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderVideoCompositionOutput(
      videoTracks: [track],
      videoSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: BadgeConstants.videoPreviewGifSize,
        kCVPixelBufferHeightKey as String: BadgeConstants.videoPreviewGifSize,
      ]
    )
    output.alwaysCopiesSampleData = false
    output.videoComposition = videoPreviewComposition(asset: asset, track: track, crop: crop)
    guard reader.canAdd(output) else {
      throw BadgeError.message("视频预览读取失败")
    }
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error ?? BadgeError.message("视频预览解码失败")
    }

    var frames: [Data] = []
    while frames.count < totalFrames, let sample = output.copyNextSampleBuffer() {
      guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
      frames.append(Data(quantizePixelBufferToGifIndexed(pixelBuffer)))
    }
    if let last = frames.last {
      while frames.count < totalFrames {
        frames.append(last)
      }
    }
    if reader.status == .failed {
      throw reader.error ?? BadgeError.message("视频预览解码失败")
    }
    guard !frames.isEmpty else {
      throw BadgeError.message("视频预览没有可用帧")
    }
    return frames
  }

  private func videoPreviewComposition(asset: AVAsset, track: AVAssetTrack, crop: CropTransform) -> AVMutableVideoComposition {
    let target = CGFloat(BadgeConstants.videoPreviewGifSize)
    let transformedBounds = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
    let uprightSize = CGSize(width: abs(transformedBounds.width), height: abs(transformedBounds.height))
    let moveToOrigin = CGAffineTransform(translationX: -transformedBounds.origin.x, y: -transformedBounds.origin.y)
    let uprightTransform = track.preferredTransform.concatenating(moveToOrigin)
    let scale = max(target / max(1, uprightSize.width), target / max(1, uprightSize.height)) * CGFloat(crop.scale)
    let dx = (target - uprightSize.width * scale) / 2.0 + CGFloat(crop.offsetX) * target
    let dy = (target - uprightSize.height * scale) / 2.0 + CGFloat(crop.offsetY) * target
    let previewTransform = uprightTransform
      .concatenating(CGAffineTransform(scaleX: scale, y: scale))
      .concatenating(CGAffineTransform(translationX: dx, y: dy))

    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    layerInstruction.setTransform(previewTransform, at: .zero)
    instruction.layerInstructions = [layerInstruction]

    let videoComposition = AVMutableVideoComposition()
    videoComposition.renderSize = CGSize(width: target, height: target)
    videoComposition.frameDuration = CMTime(value: CMTimeValue(frameDelayMs(BadgeConstants.videoPreviewGifFps)), timescale: 1000)
    videoComposition.instructions = [instruction]
    let bgLayer = CALayer()
    bgLayer.frame = CGRect(x: 0, y: 0, width: target, height: target)
    bgLayer.backgroundColor = UIColor.black.cgColor
    return videoComposition
  }

  private func renderFirstFrame(url: URL, mime: String, size: Int, crop: CropTransform, frameTimeMs: Int = 0) throws -> CGImage {
    if isVideoMime(mime) {
      let generator = AVAssetImageGenerator(asset: AVAsset(url: url))
      generator.appliesPreferredTrackTransform = true
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
      let time = CMTime(value: CMTimeValue(max(0, frameTimeMs)), timescale: 1000)
      let image = try generator.copyCGImage(at: time, actualTime: nil)
      return renderImage(image, width: size, height: size, crop: crop)
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw BadgeError.message("无法读取素材")
    }
    var frameIndex = 0
    if mime == "image/gif" {
      var elapsed = 0
      let delays = gifFrameDelaysMs(source)
      for (index, delay) in delays.enumerated() {
        frameIndex = index
        elapsed += delay
        if frameTimeMs < elapsed { break }
      }
    }
    guard
      let image = CGImageSourceCreateImageAtIndex(source, frameIndex, nil)
    else {
      throw BadgeError.message("无法读取素材")
    }
    return renderImage(image, width: size, height: size, crop: crop)
  }

  private func renderImage(_ source: CGImage, width: Int, height: Int, crop: CropTransform) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(UIColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let scale = max(Double(width) / Double(source.width), Double(height) / Double(source.height)) * crop.scale
    let drawWidth = Double(source.width) * scale
    let drawHeight = Double(source.height) * scale
    let dx = (Double(width) - drawWidth) / 2.0 + crop.offsetX * Double(width)
    let dy = (Double(height) - drawHeight) / 2.0 + crop.offsetY * Double(height)
    context.interpolationQuality = .high
    context.draw(source, in: CGRect(x: dx, y: dy, width: drawWidth, height: drawHeight))
    return context.makeImage()!
  }

  private func quantizeToIndexed(_ image: CGImage) -> [UInt8] {
    quantizeImage(image, sharpen: true)
  }

  private func quantizeBitmapToGifIndexed(_ image: CGImage) -> [UInt8] {
    quantizeImage(image, sharpen: true)
  }

  private func quantizePixelBufferToGifIndexed(_ pixelBuffer: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      return [UInt8](repeating: 0, count: width * height)
    }
    let source = baseAddress.assumingMemoryBound(to: UInt8.self)
    var output = [UInt8](repeating: 0, count: width * height)
    var out = 0
    for y in 0..<height {
      let row = y * bytesPerRow
      for x in 0..<width {
        let offset = row + x * 4
        var blue = Int(source[offset])
        var green = Int(source[offset + 1])
        var red = Int(source[offset + 2])
        let alpha = Int(source[offset + 3])
        if alpha < 255 {
          red = red * alpha / 255
          green = green * alpha / 255
          blue = blue * alpha / 255
        }
        red = clamp(sharpenForIndexed(red) + orderedDither(x: x, y: y, bits: 3))
        green = clamp(sharpenForIndexed(green) + orderedDither(x: x, y: y, bits: 3))
        blue = clamp(sharpenForIndexed(blue) + orderedDither(x: x, y: y, bits: 2))
        output[out] = UInt8(((red >> 5) << 5) | ((green >> 5) << 2) | (blue >> 6))
        out += 1
      }
    }
    return output
  }

  private func quantizeImage(_ image: CGImage, sharpen: Bool) -> [UInt8] {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { buffer in
      let context = CGContext(
        data: buffer.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
      )!
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    var output = [UInt8](repeating: 0, count: width * height)
    var out = 0
    for y in 0..<height {
      for x in 0..<width {
        let offset = (y * width + x) * 4
        let alpha = Int(pixels[offset + 3])
        var red = Int(pixels[offset])
        var green = Int(pixels[offset + 1])
        var blue = Int(pixels[offset + 2])
        if alpha < 255 {
          red = red * alpha / 255
          green = green * alpha / 255
          blue = blue * alpha / 255
        }
        if sharpen {
          red = clamp(sharpenForIndexed(red) + orderedDither(x: x, y: y, bits: 3))
          green = clamp(sharpenForIndexed(green) + orderedDither(x: x, y: y, bits: 3))
          blue = clamp(sharpenForIndexed(blue) + orderedDither(x: x, y: y, bits: 2))
        }
        output[out] = UInt8(((red >> 5) << 5) | ((green >> 5) << 2) | (blue >> 6))
        out += 1
      }
    }
    return output
  }

  private func encodeIndexedGif(frames: [Data], width: Int, height: Int, delayMs: Int) throws -> Data {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil)
    else {
      throw BadgeError.message("GIF生成失败")
    }
    CGImageDestinationSetProperties(destination, [
      kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
    ] as CFDictionary)
    let palette = rgb332Palette()
    for frame in frames {
      let image = indexedImage(indexes: [UInt8](frame), width: width, height: height, palette: palette)
      CGImageDestinationAddImage(
        destination,
        image,
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: max(0.01, Double(delayMs) / 1000.0)]] as CFDictionary
      )
    }
    guard CGImageDestinationFinalize(destination) else {
      throw BadgeError.message("GIF写入失败")
    }
    return data as Data
  }

  private func indexedImage(indexes: [UInt8], width: Int, height: Int, palette: [UInt8]) -> CGImage {
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    for index in 0..<(width * height) {
      let color = Int(indexes[index]) * 3
      let offset = index * 4
      rgba[offset] = palette[color]
      rgba[offset + 1] = palette[color + 1]
      rgba[offset + 2] = palette[color + 2]
      rgba[offset + 3] = 255
    }
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
      ),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )!
  }

  private func loadHistory() -> [[String: Any]] {
    guard
      let text = UserDefaults.standard.string(forKey: BadgeConstants.historyKey),
      let data = text.data(using: .utf8),
      let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
      return []
    }
    return array
  }

  private func saveHistory(_ items: [[String: Any]]) {
    let trimmed = Array(items.prefix(BadgeConstants.maxHistoryItems))
    guard let data = try? JSONSerialization.data(withJSONObject: trimmed),
          let text = String(data: data, encoding: .utf8) else {
      return
    }
    UserDefaults.standard.set(text, forKey: BadgeConstants.historyKey)
  }

  private func loadPendingDeviceDeletes() -> [[String: Any]] {
    guard
      let text = UserDefaults.standard.string(forKey: BadgeConstants.pendingDeviceDeletesKey),
      let data = text.data(using: .utf8),
      let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
      return []
    }
    return array
  }

  private func savePendingDeviceDeletes(_ items: [[String: Any]]) -> Bool {
    guard let data = try? JSONSerialization.data(withJSONObject: items),
          let text = String(data: data, encoding: .utf8) else {
      return false
    }
    UserDefaults.standard.set(text, forKey: BadgeConstants.pendingDeviceDeletesKey)
    return UserDefaults.standard.synchronize()
  }

  private func copyPickedFileToCache(_ url: URL) throws -> URL {
    let access = url.startAccessingSecurityScopedResource()
    defer {
      if access { url.stopAccessingSecurityScopedResource() }
    }
    let directory = try cacheDirectory("picked")
    let target = directory.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))_\(safeFileName(url.lastPathComponent))")
    if FileManager.default.fileExists(atPath: target.path) {
      try FileManager.default.removeItem(at: target)
    }
    try FileManager.default.copyItem(at: url, to: target)
    return target
  }

  private func copyAnimatedPreview(source: URL, directoryName: String, stem: String? = nil) throws -> String {
    let data = try Data(contentsOf: source)
    return try writeCacheFile(
      data: data,
      directoryName: directoryName,
      stem: stem ?? "\(Int(Date().timeIntervalSince1970 * 1000))_\(safeFileName(source.lastPathComponent))",
      ext: "gif"
    )
  }

  private func writeCacheFile(data: Data, directoryName: String, stem: String, ext: String) throws -> String {
    let directory = try cacheDirectory(directoryName)
    let path = directory.appendingPathComponent("\(stem).\(ext)")
    try data.write(to: path, options: .atomic)
    return path.path
  }

  private func cacheDirectory(_ name: String) throws -> URL {
    let base = try assetRootDirectory()
    let directory = base.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func userGameDirectory() throws -> URL {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("badge_user/game_data", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func assetRootDirectory() throws -> URL {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("badge_assets", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func deleteAssetFiles(assetPath: String?, previewPath: String?, animatedPreviewPath: String?) {
    guard let root = try? assetRootDirectory().resolvingSymlinksInPath() else {
      return
    }
    let paths = Set([assetPath, previewPath, animatedPreviewPath].compactMap { $0 })
    for path in paths where !path.isEmpty && path != "null" {
      let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
      guard url.path.hasPrefix(root.path + "/") || url.path == root.path else {
        continue
      }
      if FileManager.default.fileExists(atPath: url.path) {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }

  private func url(from text: String) throws -> URL {
    if text.hasPrefix("file://"), let url = URL(string: text) {
      return url
    }
    if text.hasPrefix("/") {
      return URL(fileURLWithPath: text)
    }
    guard let url = URL(string: text) else {
      throw BadgeError.message("素材地址错误")
    }
    return url
  }

  private func isGif(_ url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
      return false
    }
    return data.starts(with: Data([0x47, 0x49, 0x46, 0x38]))
  }

  private func mimeType(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "gif": return "image/gif"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "webp": return "image/webp"
    case "mp4": return "video/mp4"
    case "mov": return "video/quicktime"
    case "webm": return "video/webm"
    default:
      return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
  }

  private func isVideoMime(_ mime: String) -> Bool {
    mime.lowercased().hasPrefix("video/")
  }

  private func preparePackageForUpload(fileURL: URL) throws -> UploadPackageInfo {
    try preparePackageForUpload(fileURL: fileURL, hardware: badgeHardware)
  }

  private func preparePackageForUpload(fileURL: URL, hardware: String?) throws -> UploadPackageInfo {
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    if size < BadgeConstants.headerSize {
      throw BadgeError.message("素材包头不完整，请重新导入生成 EBAJ4")
    }
    if size > Int(UInt32.max) {
      throw BadgeError.message("素材包过大，请换短一点的素材")
    }

    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { handle.closeFile() }
    let header = handle.readData(ofLength: BadgeConstants.headerSize)
    // First validate header geometry without assuming a codec. Codec/fps checks
    // happen against the actual frame table before this file may be uploaded.
    if let message = validatePackageForUpload(header, packageSize: size, jpeg: true) {
      throw BadgeError.message(message)
    }
    let frameCount = Int(readLe16(header, 12))
    let tableOffset = Int(readLe32(header, 16))
    handle.seek(toFileOffset: UInt64(tableOffset))
    let table = handle.readData(ofLength: frameCount * BadgeConstants.frameEntrySize)
    guard table.count == frameCount * BadgeConstants.frameEntrySize else {
      throw BadgeError.message("素材帧表不完整，请重新下载")
    }
    let jpeg = table[10] == 0x20
    if jpeg && hardware != nil && hardware != "esp32p4" {
      throw BadgeError.message("P4 JPEG 素材不能用于 S3 设备，请重新转换")
    }
    if let message = validatePackageForUpload(header, packageSize: size, jpeg: jpeg) {
      throw BadgeError.message(message)
    }
    let frameDataOffset = Int(readLe32(header, 20))
    for index in 0..<frameCount {
      let offset = index * BadgeConstants.frameEntrySize
      let codec = table[offset + 10]
      let payloadOffset = Int(readLe32(table, offset))
      let payloadSize = Int(readLe32(table, offset + 4))
      guard (jpeg ? codec == 0x20 : [0x10, 0x11, 0x12].contains(Int(codec))),
            payloadOffset >= frameDataOffset, payloadOffset + payloadSize <= size else {
        throw BadgeError.message("素材帧编码或范围无效，请重新下载")
      }
    }

    return UploadPackageInfo(fileURL: fileURL, size: size, crc: try crc32(fileURL: fileURL))
  }

  private func validatePackageForUpload(_ data: Data, packageSize packageLength: Int, jpeg: Bool = false) -> String? {
    guard data.count >= BadgeConstants.headerSize else {
      return "素材包头不完整，请重新导入生成 EBAJ4"
    }

    let magic = readLe32(data, 0)
    let version = Int(readLe16(data, 4))
    let headerSize = Int(readLe16(data, 6))
    let width = Int(readLe16(data, 8))
    let height = Int(readLe16(data, 10))
    let frameCount = Int(readLe16(data, 12))
    let fps = Int(readLe16(data, 14))
    let frameTableOffset = Int(readLe32(data, 16))
    let frameDataOffset = Int(readLe32(data, 20))
    let packageSize = Int(readLe32(data, 24))
    let streamWidth = Int(readLe16(data, 36))
    let streamHeight = Int(readLe16(data, 38))
    let paletteEntries = Int(readLe16(data, 40))

    if magic != BadgeConstants.magic || version != BadgeConstants.version {
      return "历史素材是旧格式，请重新导入生成 EBAJ4"
    }
    if headerSize != BadgeConstants.headerSize || width != BadgeConstants.width || height != BadgeConstants.height {
      return "素材尺寸和当前设备不匹配，请重新导入生成"
    }
    if frameCount == 0 {
      return "素材没有可用帧，请重新导入生成"
    }
    let minimumFps = jpeg ? 1 : BadgeConstants.minDeviceFps
    let maximumFps = jpeg ? 80 : BadgeConstants.maxDeviceFps
    if fps < minimumFps || fps > maximumFps {
      return jpeg ? "P4 素材帧率不在1–80fps范围，请重新转换" : "S3 素材帧率不在25–40fps范围，请重新转换"
    }
    if paletteEntries != BadgeConstants.paletteEntries || !isValidStreamSize(streamWidth, streamHeight) {
      return "素材编码和当前固件不匹配，请重新导入生成"
    }
    if packageSize != packageLength {
      return "素材包大小不匹配，请重新导入生成"
    }
    let tableBytes = frameCount * BadgeConstants.frameEntrySize
    let tableEnd = frameTableOffset + tableBytes
    if frameTableOffset < BadgeConstants.headerSize ||
      tableEnd > frameDataOffset ||
      frameDataOffset > packageSize {
      return "素材帧表损坏，请重新导入生成"
    }
    return nil
  }

  private func isValidStreamSize(_ streamWidth: Int, _ streamHeight: Int) -> Bool {
    (streamWidth == 480 && streamHeight == 480) ||
      (streamWidth == 320 && streamHeight == 320) ||
      (streamWidth == 240 && streamHeight == 240)
  }

  private func parseSdAvailable(_ status: String) -> Bool {
    badgeHardware = parseBadgeHardware(status)
    return status.split { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }
      .contains { token in token.lowercased() == "sd=1" || token.lowercased() == "storage=sd" }
  }

  private func parseBadgeHardware(_ status: String) -> String {
    let token = status
      .split { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }
      .first { $0.lowercased().hasPrefix("hardware=") }
    return token?.split(separator: "=", maxSplits: 1).last?.lowercased().hasPrefix("esp32s3") == true
      ? "esp32s3"
      : "esp32p4"
  }

  private func normalizeBadgeHardware(_ value: String?) -> String {
    value?.lowercased().hasPrefix("esp32s3") == true ? "esp32s3" : "esp32p4"
  }

  private func sendConnectionEvent(connected: Bool, connecting: Bool, message: String) {
    sendEvent([
      "type": "connectionState",
      "connected": connected,
      "connecting": connecting,
      "address": nullable(connectedAddress),
      "sdAvailable": sdAvailable,
      "hardware": badgeHardware,
      "message": message,
    ])
  }

  private func sendEvent(_ payload: [String: Any]) {
    DispatchQueue.main.async {
      self.badgeChannel?.invokeMethod("nativeEvent", arguments: payload)
    }
  }

  private func safeFileName(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let filtered = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    return filtered.isEmpty ? "asset" : filtered
  }
}

/// Separate BLE session: firmware/material uploads continue to use Wi-Fi.
private final class GameBluetoothController: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  private let serviceID = CBUUID(string: "31494a41-6252-4288-b942-2f8d009e1ab1")
  private let controlID = CBUUID(string: "31494a41-6252-4288-b942-2f8d019e1ab1")
  private var central: CBCentralManager?
  private var peripheral: CBPeripheral?
  private var control: CBCharacteristic?
  private var connectResult: FlutterResult?
  private var commandResult: FlutterResult?
  private var candidates: [UUID: CBPeripheral] = [:]
  private var connectTimeout: DispatchWorkItem?
  private var scanEnd: DispatchWorkItem?
  private var commandTimeout: DispatchWorkItem?
  private var ready = false
  private var sequence = 0
  private var lastStatus = ""
  private var deviceReply = false
  private var automaticConnect = false

  func connect(automatic: Bool = false, result: @escaping FlutterResult) {
    if ready { result(info()); return }
    guard connectResult == nil else {
      result(FlutterError(code: "bluetooth_busy", message: "正在连接蓝牙，请稍候", details: nil)); return
    }
    connectResult = result
    automaticConnect = automatic
    candidates.removeAll()
    let timeout = DispatchWorkItem { [weak self] in self?.fail("未找到可连接的 P4 蓝牙设备，请确认设备已开机") }
    connectTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
    else if central?.state == .poweredOn { scan() }
    else if central?.state != .unknown && central?.state != .resetting { fail("请打开蓝牙，并允许 DotLoop 使用蓝牙") }
  }

  private func info() -> [String: Any] {
    ["connected": true, "name": "DotLoop", "address": peripheral?.identifier.uuidString ?? "", "status": lastStatus, "transport": "bluetooth"]
  }
  func connectionInfo(result: @escaping FlutterResult) { result(ready ? info() : ["connected": false]) }
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state == .poweredOn && connectResult != nil { scan() }
    else if central.state != .unknown && central.state != .resetting && central.state != .poweredOn { fail("请打开蓝牙，并允许 DotLoop 使用蓝牙") }
  }
  private func scan() {
    central?.scanForPeripherals(withServices: [serviceID])
    scanEnd?.cancel()
    let end = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.central?.stopScan()
      let previous = UserDefaults.standard.string(forKey: "dotloop_last_bluetooth_device")
      let remembered = previous.flatMap { UUID(uuidString: $0) }.flatMap { self.candidates[$0] }
      let single = self.candidates.count == 1 ? self.candidates.values.first : nil
      guard let device = remembered ?? ((self.automaticConnect && previous != nil) ? nil : single) else {
        if self.automaticConnect && previous != nil { self.fail("未发现上次连接的 DotLoop"); return }
        self.fail(self.candidates.isEmpty ? "未发现 DotLoop 蓝牙设备" : "附近有多个 DotLoop，请只保留目标设备开机后重试"); return
      }
      self.connect(device)
    }
    scanEnd = end
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: end)
  }
  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any], rssi RSSI: NSNumber) {
    candidates[peripheral.identifier] = peripheral
    let previous = UserDefaults.standard.string(forKey: "dotloop_last_bluetooth_device")
    if automaticConnect, previous == peripheral.identifier.uuidString, connectResult != nil {
      scanEnd?.cancel()
      central.stopScan()
      connect(peripheral)
    }
  }
  private func connect(_ device: CBPeripheral) {
    guard connectResult != nil, self.peripheral == nil else { return }
    peripheral = device
    device.delegate = self
    central?.connect(device)
  }
  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard self.peripheral === peripheral, connectResult != nil else { return }
    peripheral.discoverServices([serviceID])
  }
  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    guard self.peripheral === peripheral else { return }
    fail(error?.localizedDescription ?? "蓝牙连接失败")
  }
  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    guard self.peripheral === peripheral else { return }
    fail("设备蓝牙已断开，请重新连接")
  }
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard self.peripheral === peripheral, connectResult != nil else { return }
    guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
      fail("设备固件缺少蓝牙游戏服务，请更新 P4 固件"); return
    }
    peripheral.discoverCharacteristics([controlID], for: service)
  }
  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard self.peripheral === peripheral, connectResult != nil else { return }
    guard error == nil, let characteristic = service.characteristics?.first(where: { $0.uuid == controlID }) else {
      fail("设备缺少蓝牙控制特征"); return
    }
    control = characteristic
    peripheral.setNotifyValue(true, for: characteristic)
  }
  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    guard self.peripheral === peripheral, characteristic === control else { return }
    guard error == nil && characteristic.isNotifying else { fail("无法订阅蓝牙状态"); return }
    if connectResult != nil { peripheral.readValue(for: characteristic) }
  }
  func send(action: String, result: @escaping FlutterResult) {
    guard ["start", "flap", "restart", "pause", "resume", "stop", "status"].contains(action) else {
      result(FlutterError(code: "bad_action", message: "不支持的游戏指令", details: nil)); return
    }
    write(action: action, isDevice: false, result: result)
  }
  func sendDevice(command: String, result: @escaping FlutterResult) {
    guard (1...63).contains(command.utf8.count), command.utf8.allSatisfy({ (32...126).contains($0) }) else {
      result(FlutterError(code: "bad_control", message: "设备指令参数无效", details: nil)); return
    }
    guard lastStatus.contains("dc=1") else {
      result(FlutterError(code: "firmware_update_required", message: "请更新 P4 蓝牙控制固件", details: nil)); return
    }
    write(action: "DC:\(command)", isDevice: true, result: result)
  }
  private func write(action: String, isDevice: Bool, result: @escaping FlutterResult) {
    guard ready, let device = peripheral, let characteristic = control else {
      result(FlutterError(code: "bluetooth_disconnected", message: "蓝牙未连接，请重新连接", details: nil)); return
    }
    guard commandResult == nil else {
      result(FlutterError(code: "game_busy", message: "设备正在处理上一条游戏指令", details: nil)); return
    }
    sequence = sequence >= 999999 ? 1 : sequence + 1
    commandResult = result
    deviceReply = isDevice
    // A lost ACK may mean a start was accepted. Disconnect to release game
    // ownership and let Flutter reconnect; never replay an action blindly.
    let timeout = DispatchWorkItem { [weak self] in self?.fail("设备未确认游戏指令，请重新连接") }
    commandTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    let payload = Data("GB:\(sequence):\(action)".utf8)
    guard payload.count <= device.maximumWriteValueLength(for: .withResponse) else {
      fail("蓝牙数据长度不足，请重新连接"); return
    }
    device.writeValue(payload, for: characteristic, type: .withResponse)
  }
  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    guard self.peripheral === peripheral, characteristic === control else { return }
    if let error = error { fail(error.localizedDescription) }
  }
  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard self.peripheral === peripheral, characteristic === control else { return }
    guard error == nil, let data = characteristic.value, let text = String(data: data, encoding: .utf8) else {
      fail("蓝牙响应读取失败，请重新连接"); return
    }
    if text.hasPrefix("GB:\(sequence):") {
      commandTimeout?.cancel()
      let result = commandResult; commandResult = nil
      if deviceReply && text.hasPrefix("GB:\(sequence):OK:") { result?(String(text.dropFirst("GB:\(sequence):OK:".count))) }
      else if !deviceReply && text == "GB:\(sequence):OK" { result?(true) }
      else { result?(FlutterError(code: "game_rejected", message: "设备拒绝指令：\(text)", details: nil)) }
    } else if text.contains("hardware=esp32p4") {
      lastStatus = text
      if connectResult != nil && characteristic.isNotifying {
        ready = true; connectTimeout?.cancel()
        if text.contains("dc=1") {
          UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "dotloop_last_bluetooth_device")
        }
        let result = connectResult; connectResult = nil
        result?(info())
      }
    }
  }
  func status(result: @escaping FlutterResult) {
    if ready { result(lastStatus) }
    else { result(FlutterError(code: "bluetooth_disconnected", message: "蓝牙已断开", details: nil)) }
  }
  func close() { fail("蓝牙连接已关闭") }
  private func commandError(_ message: String, code: String = "game_failed") {
    commandTimeout?.cancel()
    let result = commandResult; commandResult = nil
    result?(FlutterError(code: code, message: message, details: nil))
  }
  private func fail(_ message: String) {
    connectTimeout?.cancel(); scanEnd?.cancel(); central?.stopScan()
    ready = false; control = nil; lastStatus = ""
    let device = peripheral; peripheral = nil
    if let device = device { central?.cancelPeripheralConnection(device) }
    let result = connectResult; connectResult = nil
    result?(FlutterError(code: "bluetooth_connect_failed", message: message, details: nil))
    commandError(message, code: "bluetooth_disconnected")
  }
}

private final class EbajEncoder {
  private let onProgress: (Double) -> Void

  init(onProgress: @escaping (Double) -> Void) {
    self.onProgress = onProgress
  }

  func encode(url: URL, mime: String, requestedFps: Int, maxPackageBytes: Int, crop: CropTransform) throws -> EncodedPackage {
    let fps = BadgeConstants.deviceFps
    let delayMs = frameDelayMs(fps)
    let selectedStreamSize = try sampleStreamResolution(url: url, mime: mime, fps: fps, delayMs: delayMs, crop: crop)
    let candidates = candidateStreamResolutions(selectedStreamSize)
    for (index, streamSize) in candidates.enumerated() {
      let selected = try encodeAtResolution(url: url, mime: mime, fps: fps, delayMs: delayMs, streamSize: streamSize, crop: crop)
      if selected.packageBytes.count > maxPackageBytes {
        continue
      }
      if actualQualityBytesPerSecond(selected) <= BadgeConstants.qualityStreamBytesPerSecond ||
        index == candidates.count - 1 {
        return selected
      }
      NSLog(
        "BadgePrepare stream %d actual=%dBps exceeds target=%d, retry lower",
        streamSize,
        actualQualityBytesPerSecond(selected),
        BadgeConstants.qualityStreamBytesPerSecond
      )
    }
    throw BadgeError.message(BadgeConstants.assetTooLargeMessage)
  }

  private func encodeAtResolution(url: URL, mime: String, fps: Int, delayMs: Int, streamSize: Int, crop: CropTransform) throws -> EncodedPackage {
    let frames: [EncodedFrame]
    if mime.lowercased().hasPrefix("video/") {
      frames = try encodeVideoFrames(url: url, delayMs: delayMs, streamSize: streamSize, crop: crop)
    } else {
      guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        CGImageSourceGetCount(source) > 0
      else {
        throw BadgeError.message("无法读取素材")
      }
      let count = CGImageSourceGetCount(source)
      if count > 1 {
        frames = try encodeImageSequence(source: source, delayMs: delayMs, streamSize: streamSize, crop: crop)
      } else if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
        let rendered = renderStaticImage(image, streamSize: streamSize, crop: crop)
        let indexed = quantizeRenderedImage(rendered)
        frames = [encodeFrame(indexed: indexed, previous: nil, delayMs: delayMs, streamSize: streamSize, forceKeyframe: true)]
      } else {
        throw BadgeError.message("不支持的图片格式")
      }
    }
    return try packFrames(frames: frames, fps: fps, streamSize: streamSize)
  }

  private func convertVideoToAnimatedGif(url: URL, delayMs: Int, streamSize: Int, crop: CropTransform) throws -> Data {
    let asset = AVAsset(url: url)
    let durationMs = max(1, Int(CMTimeGetSeconds(asset.duration) * 1000.0))
    let totalFrames = max(1, (durationMs + delayMs - 1) / delayMs)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero

    guard let destination = CGImageDestinationCreateWithData(
      NSMutableData() as CFMutableData, UTType.gif.identifier as CFString, totalFrames, nil
    ) else {
      throw BadgeError.message("无法创建GIF编码器")
    }

    let gifProperties = [
      kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFLoopCount: 0
      ]
    ] as CFDictionary
    CGImageDestinationSetProperties(destination, gifProperties)

    let frameProperties = [
      kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFDelayTime: Double(delayMs) / 1000.0
      ]
    ] as CFDictionary

    for index in 0..<totalFrames {
      let timeMs = min(durationMs - 1, index * delayMs)
      let image = try generator.copyCGImage(
        at: CMTime(value: CMTimeValue(timeMs), timescale: 1000), actualTime: nil
      )
      let rendered = renderStaticImage(image, streamSize: streamSize, crop: crop)
      CGImageDestinationAddImage(destination, rendered, frameProperties)
      onProgress(Double(index + 1) / Double(totalFrames))
    }

    guard CGImageDestinationFinalize(destination) else {
      throw BadgeError.message("GIF编码失败")
    }

    return (destination as? NSMutableData).map { $0 as Data } ?? Data()
  }

  private func encodeVideoFrames(url: URL, delayMs: Int, streamSize: Int, crop: CropTransform) throws -> [EncodedFrame] {
    let asset = AVAsset(url: url)
    let durationMs = max(1, Int(CMTimeGetSeconds(asset.duration) * 1000.0))
    let totalFrames = max(1, (durationMs + delayMs - 1) / delayMs)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    var frames: [EncodedFrame] = []
    var previous: [UInt8]?
    for index in 0..<totalFrames {
      let timeMs = min(durationMs - 1, index * delayMs)
      let image = try generator.copyCGImage(at: CMTime(value: CMTimeValue(timeMs), timescale: 1000), actualTime: nil)
      let rendered = renderStaticImage(image, streamSize: streamSize, crop: crop)
      let indexed = quantizeRenderedImage(rendered)
      frames.append(encodeFrame(indexed: indexed, previous: previous, delayMs: delayMs, streamSize: streamSize, forceKeyframe: index == 0))
      previous = indexed
      onProgress(Double(index + 1) / Double(totalFrames))
    }
    return frames
  }

  private func sampleStreamResolution(url: URL, mime: String, fps: Int, delayMs: Int, crop: CropTransform) throws -> Int {
    if mime.lowercased().hasPrefix("video/") {
      let estimates = try BadgeConstants.streamResolutions.map { size in
        StreamEstimate(streamSize: size, bytesPerSecond: try estimateVideoBytesPerSecond(url: url, fps: fps, delayMs: delayMs, streamSize: size, crop: crop))
      }
      return selectStreamResolution(estimates)
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 1 else {
      return BadgeConstants.width
    }
    let estimates = try BadgeConstants.streamResolutions.map { size in
      StreamEstimate(streamSize: size, bytesPerSecond: try estimateImageSequenceBytesPerSecond(source: source, fps: fps, delayMs: delayMs, streamSize: size, crop: crop))
    }
    return selectStreamResolution(estimates)
  }

  private func estimateVideoBytesPerSecond(url: URL, fps: Int, delayMs: Int, streamSize: Int, crop: CropTransform) throws -> Int {
    let asset = AVAsset(url: url)
    let durationMs = max(1, Int(CMTimeGetSeconds(asset.duration) * 1000.0))
    let totalFrames = max(1, (durationMs + delayMs - 1) / delayMs)
    let indexes = sampleFrameIndexes(totalFrames)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    var previous: [UInt8]?
    var payloadBytes = 0
    for (sampleIndex, frameIndex) in indexes.enumerated() {
      let timeMs = min(durationMs - 1, frameIndex * delayMs)
      let image = try generator.copyCGImage(at: CMTime(value: CMTimeValue(timeMs), timescale: 1000), actualTime: nil)
      let indexed = quantizeRenderedImage(renderStaticImage(image, streamSize: streamSize, crop: crop))
      let frame = encodeFrame(indexed: indexed, previous: previous, delayMs: delayMs, streamSize: streamSize, forceKeyframe: sampleIndex == 0)
      payloadBytes += frame.data.count
      previous = indexed
    }
    return payloadBytes * fps / max(1, indexes.count)
  }

  private func estimateImageSequenceBytesPerSecond(source: CGImageSource, fps: Int, delayMs: Int, streamSize: Int, crop: CropTransform) throws -> Int {
    let frameCount = CGImageSourceGetCount(source)
    let totalFrames = max(1, frameCount)
    let indexes = sampleFrameIndexes(totalFrames)
    var previous: [UInt8]?
    var payloadBytes = 0
    for (sampleIndex, frameIndex) in indexes.enumerated() {
      guard let image = CGImageSourceCreateImageAtIndex(source, frameIndex, nil) else { continue }
      let indexed = quantizeRenderedImage(renderStaticImage(image, streamSize: streamSize, crop: crop))
      let frame = encodeFrame(indexed: indexed, previous: previous, delayMs: delayMs, streamSize: streamSize, forceKeyframe: sampleIndex == 0)
      payloadBytes += frame.data.count
      previous = indexed
    }
    return payloadBytes * fps / max(1, indexes.count)
  }

  private func encodeImageSequence(source: CGImageSource, delayMs: Int, streamSize: Int, crop: CropTransform) throws -> [EncodedFrame] {
    let frameCount = CGImageSourceGetCount(source)
    var frames: [EncodedFrame] = []
    var previous: [UInt8]?
    for index in 0..<frameCount {
      guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
      let indexed = quantizeRenderedImage(renderStaticImage(image, streamSize: streamSize, crop: crop))
      frames.append(encodeFrame(indexed: indexed, previous: previous, delayMs: delayMs, streamSize: streamSize, forceKeyframe: index == 0))
      previous = indexed
      onProgress(Double(index + 1) / Double(max(1, frameCount)))
    }
    return frames
  }

  private func sampleFrameIndexes(_ totalFrames: Int) -> [Int] {
    let sampleCount = min(BadgeConstants.sampleFrameCount, totalFrames)
    if sampleCount <= 1 { return [0] }
    return Array(Set((0..<sampleCount).map { $0 * (totalFrames - 1) / (sampleCount - 1) })).sorted()
  }

  private func encodeFrame(indexed: [UInt8], previous: [UInt8]?, delayMs: Int, streamSize: Int, forceKeyframe: Bool) -> EncodedFrame {
    if !forceKeyframe, let previous, previous == indexed {
      return EncodedFrame(data: Data(), codec: BadgeConstants.codecIndexedRepeat, delayMs: delayMs, width: streamSize, height: streamSize)
    }
    let key = encodeIndexedKey(indexed)
    if !forceKeyframe, let previous {
      let tile = encodeIndexedTile(indexed, previous: previous, streamSize: streamSize)
      if tile.count < key.count {
        return EncodedFrame(data: tile, codec: BadgeConstants.codecIndexedTile, delayMs: delayMs, width: streamSize, height: streamSize)
      }
    }
    return EncodedFrame(data: key, codec: BadgeConstants.codecIndexedKey, delayMs: delayMs, width: streamSize, height: streamSize)
  }

  private func encodeIndexedKey(_ indexed: [UInt8]) -> Data {
    var output = Data(rgb332Palette565())
    output.append(contentsOf: indexed)
    return output
  }

  private func encodeIndexedTile(_ indexed: [UInt8], previous: [UInt8], streamSize: Int) -> Data {
    var output = Data(rgb332Palette565())
    output.append(0)
    output.append(0)
    var changedTiles = 0
    let tileCols = streamSize / BadgeConstants.tileSize
    let tileRows = streamSize / BadgeConstants.tileSize
    for tileY in 0..<tileRows {
      for tileX in 0..<tileCols {
        var changed = false
        for row in 0..<BadgeConstants.tileSize {
          let offset = ((tileY * BadgeConstants.tileSize + row) * streamSize) + tileX * BadgeConstants.tileSize
          for index in offset..<(offset + BadgeConstants.tileSize) {
            if indexed[index] != previous[index] {
              changed = true
              break
            }
          }
          if changed { break }
        }
        if !changed { continue }
        let tileIndex = tileY * tileCols + tileX
        output.append(UInt8(tileIndex & 0xff))
        output.append(UInt8((tileIndex >> 8) & 0xff))
        for row in 0..<BadgeConstants.tileSize {
          let offset = ((tileY * BadgeConstants.tileSize + row) * streamSize) + tileX * BadgeConstants.tileSize
          output.append(contentsOf: indexed[offset..<(offset + BadgeConstants.tileSize)])
        }
        changedTiles += 1
      }
    }
    output[BadgeConstants.paletteBytes] = UInt8(changedTiles & 0xff)
    output[BadgeConstants.paletteBytes + 1] = UInt8((changedTiles >> 8) & 0xff)
    return output
  }

  private func packFrames(frames: [EncodedFrame], fps: Int, streamSize: Int) throws -> EncodedPackage {
    guard !frames.isEmpty else { throw BadgeError.message("素材没有可用帧") }
    let dataBytes = frames.reduce(0) { $0 + $1.data.count }
    let frameTableOffset = BadgeConstants.headerSize
    let frameDataOffset = BadgeConstants.headerSize + frames.count * BadgeConstants.frameEntrySize
    let packageSize = frameDataOffset + dataBytes
    var output = Data(count: packageSize)
    writeLe32(&output, 0, BadgeConstants.magic)
    writeLe16(&output, 4, UInt16(BadgeConstants.version))
    writeLe16(&output, 6, UInt16(BadgeConstants.headerSize))
    writeLe16(&output, 8, UInt16(BadgeConstants.width))
    writeLe16(&output, 10, UInt16(BadgeConstants.height))
    writeLe16(&output, 12, UInt16(frames.count))
    writeLe16(&output, 14, UInt16(fps))
    writeLe32(&output, 16, UInt32(frameTableOffset))
    writeLe32(&output, 20, UInt32(frameDataOffset))
    writeLe32(&output, 24, UInt32(packageSize))
    writeLe32(&output, 28, 0)
    writeLe32(&output, 32, 0)
    writeLe16(&output, 36, UInt16(streamSize))
    writeLe16(&output, 38, UInt16(streamSize))
    writeLe16(&output, 40, UInt16(BadgeConstants.paletteEntries))
    writeLe16(&output, 42, 0)
    var tableOffset = frameTableOffset
    var dataOffset = frameDataOffset
    for frame in frames {
      writeLe32(&output, tableOffset, UInt32(dataOffset))
      writeLe32(&output, tableOffset + 4, UInt32(frame.data.count))
      writeLe16(&output, tableOffset + 8, UInt16(frame.delayMs))
      output[tableOffset + 10] = UInt8(frame.codec)
      output[tableOffset + 11] = 0
      writeLe16(&output, tableOffset + 12, UInt16(frame.width))
      writeLe16(&output, tableOffset + 14, UInt16(frame.height))
      output.replaceSubrange(dataOffset..<(dataOffset + frame.data.count), with: frame.data)
      tableOffset += BadgeConstants.frameEntrySize
      dataOffset += frame.data.count
    }
    return EncodedPackage(packageBytes: output, frameCount: frames.count, fps: fps, crc32: crc32(output))
  }

  private func selectStreamResolution(_ estimates: [StreamEstimate]) -> Int {
    for estimate in estimates where isPlaybackSafeStream(estimate) {
      return estimate.streamSize
    }
    return estimates.last?.streamSize ?? BadgeConstants.streamResolutions.last!
  }

  private func isPlaybackSafeStream(_ estimate: StreamEstimate) -> Bool {
    let budget = min(
      BadgeConstants.qualityStreamBytesPerSecond,
      playbackBudgetBytesPerSecond(estimate.streamSize)
    )
    return estimate.bytesPerSecond <= budget
  }

  private func playbackBudgetBytesPerSecond(_ streamSize: Int) -> Int {
    return streamSize == BadgeConstants.width ? BadgeConstants.playbackStreamBytesPerSecond : BadgeConstants.qualityStreamBytesPerSecond
  }

  private func candidateStreamResolutions(_ selectedStreamSize: Int) -> [Int] {
    guard let start = BadgeConstants.streamResolutions.firstIndex(of: selectedStreamSize) else {
      return BadgeConstants.streamResolutions
    }
    return Array(BadgeConstants.streamResolutions[start...])
  }

  private func actualQualityBytesPerSecond(_ selected: EncodedPackage) -> Int {
    let tableBytes = selected.frameCount * BadgeConstants.frameEntrySize
    let payloadBytes = max(0, selected.packageBytes.count - BadgeConstants.headerSize - tableBytes)
    return payloadBytes * selected.fps / max(1, selected.frameCount)
  }
}

private struct RelayFirmwareManifest {
  let hardware: String
  let version: String
  let url: URL
  let size: Int
  let sha256: String
  let notes: String

  init(_ data: [String: Any]) throws {
    guard let hardware = data["hardware"] as? String, hardware == "esp32p4-2.8",
          let version = data["version"] as? String, version.utf8.count <= 31,
          version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$", options: .regularExpression) != nil,
          let address = data["url"] as? String, let url = URL(string: address),
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !(url.host ?? "").isEmpty,
          let size = (data["size"] as? NSNumber)?.intValue, (288...3 * 1024 * 1024).contains(size),
          let sha256 = data["sha256"] as? String,
          sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
      throw transferFailure("firmware_invalid", "固件清单不完整或设备型号不匹配")
    }
    self.hardware = hardware
    self.version = version
    self.url = url
    self.size = size
    self.sha256 = sha256.lowercased()
    self.notes = data["notes"] as? String ?? ""
  }

  var dictionary: [String: Any] {
    ["hardware": hardware, "version": version, "url": url.absoluteString,
     "size": size, "sha256": sha256, "notes": notes]
  }
}

private func transferFailure(_ code: String, _ message: String) -> NSError {
  NSError(domain: "DotLoopTransfer", code: 0,
          userInfo: [NSLocalizedDescriptionKey: message, "nativeCode": code])
}

private func transferHTTPFailure(_ status: Int, firmware: Bool) -> NSError {
  if status >= 500 {
    return NSError(domain: "DotLoopBackendUnavailable", code: status,
      userInfo: [NSLocalizedDescriptionKey: "服务器暂不可用 HTTP \(status)，请稍后重试"])
  }
  let code = status == 404
    ? (firmware ? "firmware_unavailable" : "package_unavailable")
    : (firmware ? "firmware_rejected" : "download_failed")
  let message = status == 404
    ? (firmware ? "该设备型号暂无可用固件" : "服务器素材包不存在，请重新转换素材")
    : "下载或更新请求失败 HTTP \(status)"
  return transferFailure(code, message)
}

private func nativeTransferError(_ error: Error, fallback: String) -> FlutterError {
  let ns = error as NSError
  let networkCodes = [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
    NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet]
  let unavailable = ns.domain == "DotLoopBackendUnavailable" ||
    (ns.domain == NSURLErrorDomain && networkCodes.contains(ns.code))
  return FlutterError(code: unavailable ? "network_unavailable" : ns.userInfo["nativeCode"] as? String ?? fallback,
    message: ns.localizedDescription, details: nil)
}

/// Match Android's 45–95% upload range. Reaching the wire's last byte does not
/// mean the device has checked and installed it; only the response confirms it.
private struct RelayInstallProgress {
  private var lastSent: Int64 = -1
  private var lastTime: TimeInterval = -Double.infinity

  mutating func update(sent: Int64, total: Int64, now: TimeInterval) -> Double? {
    guard total > 0, sent >= 0, now.isFinite else { return nil }
    let bounded = min(sent, total)
    guard bounded > lastSent else { return nil }
    guard lastSent < 0 || now - lastTime >= 0.1 || bounded == total else { return nil }
    lastSent = bounded
    lastTime = now
    return 0.45 + 0.5 * Double(bounded) / Double(total)
  }
}

private final class RelayNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
  private(set) var sentBytes: Int64 = 0
  private let onUploadProgress: ((Int64, Int64) -> Void)?

  init(onUploadProgress: ((Int64, Int64) -> Void)? = nil) {
    self.onUploadProgress = onUploadProgress
    super.init()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                  totalBytesExpectedToSend: Int64) {
    sentBytes = totalBytesSent
    onUploadProgress?(totalBytesSent, totalBytesExpectedToSend)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

/// Streams into a unique partial file. Both firmware and approved asset
/// downloads commit only after byte count and any advertised SHA256 match.
private final class RelayBoundedDownload: NSObject, URLSessionDataDelegate {
  private let target: URL
  private let partial: URL
  private let maximumBytes: Int
  private let expectedSize: Int?
  private let expectedSHA256: String?
  private let requestTimeout: TimeInterval
  private let resourceTimeout: TimeInterval
  private let semaphore = DispatchSemaphore(value: 0)
  private var handle: FileHandle?
  private var failure: Error?
  private var received = 0
  private var contentLength: Int?
  private var serverSHA256: String?
  private var hasher = SHA256()
  private var firmware: Bool { expectedSHA256 != nil }

  init(target: URL, maximumBytes: Int, expectedSize: Int?, expectedSHA256: String?,
       requestTimeout: TimeInterval, resourceTimeout: TimeInterval) {
    self.target = target
    self.partial = target.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).part")
    self.maximumBytes = maximumBytes
    self.expectedSize = expectedSize
    self.expectedSHA256 = expectedSHA256?.lowercased()
    self.requestTimeout = requestTimeout
    self.resourceTimeout = resourceTimeout
    super.init()
  }

  private func invalid(_ message: String) -> NSError {
    transferFailure(firmware ? "firmware_invalid" : "package_invalid", message)
  }

  func download(_ url: URL) throws -> URL {
    guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
      throw invalid("下载缓存创建失败")
    }
    defer { try? FileManager.default.removeItem(at: partial) }
    handle = try FileHandle(forWritingTo: partial)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = resourceTimeout
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    session.dataTask(with: request).resume()
    semaphore.wait()
    if let failure { throw failure }
    guard received > 0,
          expectedSize == nil || expectedSize == received,
          contentLength == nil || contentLength == received else {
      throw invalid("下载长度校验失败，请重新下载")
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard expectedSHA256 == nil || expectedSHA256 == digest,
          serverSHA256 == nil || serverSHA256 == digest else {
      throw invalid("下载 SHA256 校验失败，请重新下载")
    }
    if FileManager.default.fileExists(atPath: target.path) {
      try FileManager.default.removeItem(at: target)
    }
    try FileManager.default.moveItem(at: partial, to: target)
    return target
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                  didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      failure = transferHTTPFailure((response as? HTTPURLResponse)?.statusCode ?? 0, firmware: firmware)
      completionHandler(.cancel)
      return
    }
    if let length = http.value(forHTTPHeaderField: "Content-Length") {
      guard let count = Int(length), count >= 0, count <= maximumBytes,
            expectedSize == nil || expectedSize == count else {
        failure = invalid("下载长度与清单不匹配")
        completionHandler(.cancel)
        return
      }
      contentLength = count
    }
    if let hash = http.value(forHTTPHeaderField: "x-asset-sha256") {
      guard hash.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
        failure = invalid("服务器 SHA256 响应无效")
        completionHandler(.cancel)
        return
      }
      serverSHA256 = hash.lowercased()
    }
    if ["text/html", "application/json", "text/plain"].contains(http.mimeType?.lowercased() ?? "") {
      failure = invalid("服务器未返回有效素材或固件文件")
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard failure == nil else { return }
    guard received + data.count <= maximumBytes else {
      failure = invalid("下载文件超出允许长度")
      dataTask.cancel()
      return
    }
    do {
      try handle?.write(contentsOf: data)
      hasher.update(data: data)
      received += data.count
    } catch {
      failure = error
      dataTask.cancel()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if failure == nil { failure = error }
    do { try handle?.close() } catch { if failure == nil { failure = error } }
    handle = nil
    semaphore.signal()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

private enum BadgeConstants {
  static let channel = "esp_baji/native"
  static let badgeDeviceName = "DotLoop"
  static let badgeApHost = "192.168.4.1"
  static let badgeUploadTcpPort = 3333
  static let discoveryUdpPort: UInt16 = 3334
  static let badgeTcpUploadMagic: UInt32 = 0x31505542
  static let statusTimeout: TimeInterval = 2.5
  static let lanDiscoveryProbeTimeout: TimeInterval = 0.45
  static let lanDiscoveryTimeoutGrace: TimeInterval = 0.15
  static let lanDiscoveryConcurrency = 32
  static let lanDiscoveryMaxCandidates = 260
  static let discoveryListenTimeout: TimeInterval = 6.5
  static let discoveryPacketBytes = 512
  static let uploadTimeoutSeconds = 180
  static let uploadChunkBytes = 256 * 1024
  static let uploadProgressStepBytes = 512 * 1024
  static let randomCommandAttempts = 4
  static let randomCommandRetryDelayMs = 120
  static let sdStreamBudgetBytes = 512 * 1024 * 1024
  static let maxVideoInputBytes = 200 * 1024 * 1024
  static let previewRequestTimeout: TimeInterval = 5
  static let previewResourceTimeout: TimeInterval = 8
  static let assetTooLargeMessage = "转换后的设备包超过当前素材存储空间，请换短一点的素材。"
  static let maxHistoryItems = 20
  static let historyKey = "history"
  static let pendingDeviceDeletesKey = "pending_device_deletes_v1"
  static let width = 480
  static let height = 480
  static let minDeviceFps = 25
  static let deviceFps = 40
  static let maxDeviceFps = 40
  static let previewSize = 320
  static let videoPreviewGifSize = 192
  static let videoPreviewGifFps = 25
  static let stream240Pixels = 240 * 240
  static let magic: UInt32 = 0x344a4142
  static let version = 4
  static let headerSize = 44
  static let frameEntrySize = 16
  static let codecIndexedKey = 0x10
  static let codecIndexedTile = 0x11
  static let codecIndexedRepeat = 0x12
  static let paletteEntries = 256
  static let paletteBytes = paletteEntries * 2
  static let sampleFrameCount = 4
  static let qualityStreamBytesPerSecond = 10 * 512 * 1024
  static let playbackStreamBytesPerSecond = 10 * 512 * 1024
  static let sharpenPercent = 106
  static let dither4x4 = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
  static let tileSize = 16
  static let streamResolutions = [480, 320, 240]
}

private struct CropTransform {
  let scale: Double
  let offsetX: Double
  let offsetY: Double
  static let `default` = CropTransform(scale: 1.0, offsetX: 0.0, offsetY: 0.0)
}

private struct EncodedFrame {
  let data: Data
  let codec: Int
  let delayMs: Int
  let width: Int
  let height: Int
}

private struct EncodedPackage {
  let packageBytes: Data
  let frameCount: Int
  let fps: Int
  let crc32: UInt32
}

private struct UploadPackageInfo {
  let fileURL: URL
  let size: Int
  let crc: UInt32
}

private struct DiscoveredBadge {
  let host: String
  let status: String
}

private struct StreamEstimate {
  let streamSize: Int
  let bytesPerSecond: Int
}

private enum BadgeError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    switch self {
    case .message(let text): return text
    }
  }
}

private func frameDelayMs(_ fps: Int) -> Int {
  max(1, Int((1000.0 / Double(fps)).rounded()))
}

private func renderStaticImage(_ image: CGImage, streamSize: Int, crop: CropTransform) -> CGImage {
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  let context = CGContext(
    data: nil,
    width: streamSize,
    height: streamSize,
    bitsPerComponent: 8,
    bytesPerRow: streamSize * 4,
    space: colorSpace,
    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  context.setFillColor(UIColor.black.cgColor)
  context.fill(CGRect(x: 0, y: 0, width: streamSize, height: streamSize))
  let scale = max(Double(streamSize) / Double(image.width), Double(streamSize) / Double(image.height)) * crop.scale
  let drawWidth = Double(image.width) * scale
  let drawHeight = Double(image.height) * scale
  let dx = (Double(streamSize) - drawWidth) / 2.0 + crop.offsetX * Double(streamSize)
  let dy = (Double(streamSize) - drawHeight) / 2.0 + crop.offsetY * Double(streamSize)
  context.interpolationQuality = .high
  context.draw(image, in: CGRect(x: dx, y: dy, width: drawWidth, height: drawHeight))
  return context.makeImage()!
}

private func quantizeRenderedImage(_ image: CGImage) -> [UInt8] {
  let width = image.width
  let height = image.height
  var pixels = [UInt8](repeating: 0, count: width * height * 4)
  pixels.withUnsafeMutableBytes { buffer in
    let context = CGContext(
      data: buffer.baseAddress,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  }
  var output = [UInt8](repeating: 0, count: width * height)
  var out = 0
  for y in 0..<height {
    for x in 0..<width {
      let offset = (y * width + x) * 4
      let alpha = Int(pixels[offset + 3])
      var red = Int(pixels[offset])
      var green = Int(pixels[offset + 1])
      var blue = Int(pixels[offset + 2])
      if alpha < 255 {
        red = red * alpha / 255
        green = green * alpha / 255
        blue = blue * alpha / 255
      }
      red = clamp(sharpenForIndexed(red) + orderedDither(x: x, y: y, bits: 3))
      green = clamp(sharpenForIndexed(green) + orderedDither(x: x, y: y, bits: 3))
      blue = clamp(sharpenForIndexed(blue) + orderedDither(x: x, y: y, bits: 2))
      output[out] = UInt8(((red >> 5) << 5) | ((green >> 5) << 2) | (blue >> 6))
      out += 1
    }
  }
  return output
}

private func sharpenForIndexed(_ value: Int) -> Int {
  clamp(128 + (value - 128) * BadgeConstants.sharpenPercent / 100)
}

private func orderedDither(x: Int, y: Int, bits: Int) -> Int {
  let levelStep = bits == 2 ? 64 : 32
  let threshold = BadgeConstants.dither4x4[((y & 3) << 2) | (x & 3)] - 8
  return threshold * levelStep / 16
}

private func clamp(_ value: Int) -> Int {
  min(255, max(0, value))
}

private func nullable(_ value: Any?) -> Any {
  value ?? NSNull()
}

private func rgb332Palette() -> [UInt8] {
  var palette = [UInt8](repeating: 0, count: BadgeConstants.paletteEntries * 3)
  var offset = 0
  for index in 0..<BadgeConstants.paletteEntries {
    palette[offset] = UInt8(((index >> 5) & 0x07) * 255 / 7)
    palette[offset + 1] = UInt8(((index >> 2) & 0x07) * 255 / 7)
    palette[offset + 2] = UInt8((index & 0x03) * 255 / 3)
    offset += 3
  }
  return palette
}

private func rgb332Palette565() -> [UInt8] {
  var palette = [UInt8](repeating: 0, count: BadgeConstants.paletteBytes)
  var offset = 0
  for index in 0..<BadgeConstants.paletteEntries {
    let red = ((index >> 5) & 0x07) * 255 / 7
    let green = ((index >> 2) & 0x07) * 255 / 7
    let blue = (index & 0x03) * 255 / 3
    let rgb565 = ((red & 0xf8) << 8) | ((green & 0xfc) << 3) | (blue >> 3)
    palette[offset] = UInt8(rgb565 & 0xff)
    palette[offset + 1] = UInt8((rgb565 >> 8) & 0xff)
    offset += 2
  }
  return palette
}

private func crc32(_ data: Data) -> UInt32 {
  var crc: UInt32 = 0xffff_ffff
  for byte in data {
    var current = UInt32(byte)
    for _ in 0..<8 {
      let mix = (crc ^ current) & 1
      crc >>= 1
      if mix != 0 { crc ^= 0xedb8_8320 }
      current >>= 1
    }
  }
  return crc ^ 0xffff_ffff
}

private func crc32(fileURL: URL) throws -> UInt32 {
  let handle = try FileHandle(forReadingFrom: fileURL)
  defer { handle.closeFile() }

  var crc: UInt32 = 0xffff_ffff
  while true {
    let data = handle.readData(ofLength: BadgeConstants.uploadChunkBytes)
    if data.isEmpty { break }
    for byte in data {
      var current = UInt32(byte)
      for _ in 0..<8 {
        let mix = (crc ^ current) & 1
        crc >>= 1
        if mix != 0 { crc ^= 0xedb8_8320 }
        current >>= 1
      }
    }
  }
  return crc ^ 0xffff_ffff
}

private func appendLe32(_ data: inout Data, _ value: UInt32) {
  data.append(UInt8(value & 0xff))
  data.append(UInt8((value >> 8) & 0xff))
  data.append(UInt8((value >> 16) & 0xff))
  data.append(UInt8((value >> 24) & 0xff))
}

private func writeLe16(_ data: inout Data, _ offset: Int, _ value: UInt16) {
  data[offset] = UInt8(value & 0xff)
  data[offset + 1] = UInt8((value >> 8) & 0xff)
}

private func writeLe32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
  data[offset] = UInt8(value & 0xff)
  data[offset + 1] = UInt8((value >> 8) & 0xff)
  data[offset + 2] = UInt8((value >> 16) & 0xff)
  data[offset + 3] = UInt8((value >> 24) & 0xff)
}

private func readLe16(_ data: Data, _ offset: Int) -> UInt16 {
  UInt16(data[offset]) |
    (UInt16(data[offset + 1]) << 8)
}

private func readLe32(_ data: Data, _ offset: Int) -> UInt32 {
  UInt32(data[offset]) |
    (UInt32(data[offset + 1]) << 8) |
    (UInt32(data[offset + 2]) << 16) |
    (UInt32(data[offset + 3]) << 24)
}

// All callbacks are on the main queue, including Flutter's read-and-consume.
private final class DotLoopSwingMotion {
  private let manager = CMMotionManager()
  private var base: [Double]?, current: [Double]?
  private var x = 0.0, y = 0.0, roll = 0.0, lastHit = 0.0
  private var pending = 0, direction = 1, first = true
  private var observer: NSObjectProtocol?
  init() {
    observer = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.stop() }
  }
  deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; manager.stopDeviceMotionUpdates() }
  func start() -> Bool {
    stop(); guard manager.isDeviceMotionAvailable else { return false }
    base=nil; current=nil; first=true; lastHit=ProcessInfo.processInfo.systemUptime
    manager.deviceMotionUpdateInterval = 1.0/60.0
    manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
      guard let self, let motion else { return }
      let q=motion.attitude.quaternion
      let v=[q.w,q.x,q.y,q.z]
      self.current=v
      if self.base == nil { self.base=v }
      let b=self.base!
      let w=b[0]*v[0]+b[1]*v[1]+b[2]*v[2]+b[3]*v[3]
      let a=b[0]*v[1]-b[1]*v[0]-b[2]*v[3]+b[3]*v[2]
      let c=b[0]*v[2]+b[1]*v[3]-b[2]*v[0]-b[3]*v[1]
      let d=b[0]*v[3]-b[1]*v[2]+b[2]*v[1]-b[3]*v[0]
      let dx=2*(a*d+w*c), dy=2*(c*d-w*a), dz=1-2*(a*a+c*c)
      let px=max(-1,min(1,atan2(dx,dz)/0.62))
      let py=max(-1,min(1,-atan2(-dy,sqrt(dx*dx+dz*dz))/0.50))
      let pr=max(-1,min(1,atan2(2*(w*d+a*c),1-2*(a*a+d*d))/0.9))
      let alpha=self.first ? 1.0 : 0.55
      self.x += (px-self.x)*alpha; self.y += (py-self.y)*alpha; self.roll += (pr-self.roll)*alpha
      self.first=false
      let gx=motion.rotationRate.x, gy=motion.rotationRate.y
      if abs(gy)>0.35 { self.direction=gy<0 ? -1 : 1 }
      let strength=max(sqrt(gx*gx+gy*gy)/2.2,abs(motion.userAcceleration.z)*9.81/3.6)
      let now=ProcessInfo.processInfo.systemUptime
      if strength>=1, now-self.lastHit>=0.17 {
        self.pending=self.direction*min(1000,Int(450+strength*170)); self.lastHit=now
      }
    }
    return true
  }
  func stop() { manager.stopDeviceMotionUpdates(); pending=0 }
  func calibrate() { base=current; first=true; x=0; y=0; roll=0; pending=0; lastHit=ProcessInfo.processInfo.systemUptime }
  func read() -> [String: Any] {
    let pulse=pending; pending=0
    return ["available": manager.isDeviceMotionActive && current != nil, "x": x, "y": y, "roll": roll, "swing": pulse]
  }
}
