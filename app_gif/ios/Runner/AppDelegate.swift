import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Flutter
import ImageIO
import Network
import PhotosUI
import UniformTypeIdentifiers
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, PHPickerViewControllerDelegate {
  private var badgeChannel: FlutterMethodChannel?
  private var pendingPickResult: FlutterResult?
  private var activeUpload: NWConnection?
  private var connectedAddress: String?
  private var activeBadgeHost = BadgeConstants.badgeApHost
  private var sdAvailable = false
  private var isUploading = false
  private var uploadBackgroundTask: UIBackgroundTaskIdentifier = .invalid

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
    case "pickMedia":
      pickMedia(result: result)
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
        scale: min(4.0, max(1.0, args["cropScale"] as? Double ?? 1.0)),
        offsetX: min(1.5, max(-1.5, args["cropOffsetX"] as? Double ?? 0.0)),
        offsetY: min(1.5, max(-1.5, args["cropOffsetY"] as? Double ?? 0.0))
      )
      prepareAsset(
        uriText: uri,
        displayName: name,
        fps: fps,
        maxPackageBytes: maxPackageBytes,
        crop: crop,
        warmPreviewPath: args["warmPreviewPath"] as? String,
        result: result
      )
    case "uploadAsset":
      guard let path = args["assetPath"] as? String else {
        result(FlutterError(code: "bad_asset", message: "素材包为空", details: nil))
        return
      }
      uploadAsset(assetPath: path, result: result)
    case "loadHistory":
      result(loadHistory())
    case "saveHistory":
      saveHistory(call.arguments as? [[String: Any]] ?? [])
      result(nil)
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
    case "switchToAsset":
      guard let id = args["id"] as? String, !id.isEmpty else {
        result(FlutterError(code: "bad_id", message: "素材ID为空", details: nil))
        return
      }
      switchToAsset(id: id, result: result)
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
    sendEvent(["type": "scanState", "scanning": false])
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
        self.sendConnectionEvent(connected: false, connecting: false, message: "请先连接 ESP-BAJI Wi-Fi")
        DispatchQueue.main.async {
          result(FlutterError(code: "connect_failed", message: "请先连接 ESP-BAJI Wi-Fi", details: nil))
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
    throw BadgeError.message("请先连接 ESP-BAJI Wi-Fi，或让手机和设备在同一 Wi-Fi 下")
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
    let previewBytes = try buildPreviewData(url: local, mime: mime, crop: .default)
    let animatedPreviewPath: String?
    if isGif(local) {
      animatedPreviewPath = try copyAnimatedPreview(source: local, directoryName: "media_preview")
    } else {
      animatedPreviewPath = nil
    }
    return [
      "uri": local.absoluteString,
      "name": local.lastPathComponent,
      "size": size,
      "mime": mime,
      "previewBytes": FlutterStandardTypedData(bytes: previewBytes),
      "animatedPreviewPath": nullable(animatedPreviewPath),
    ]
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
    warmPreviewPath: String?,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let url = try self.url(from: uriText)
        let mime = self.mimeType(for: url)
        let encoder = EbajEncoder { progress in
          self.sendEvent(["type": "prepareProgress", "progress": progress])
        }
        let encoded = try encoder.encode(url: url, mime: mime, requestedFps: fps, maxPackageBytes: maxPackageBytes, crop: crop)
        let stem = "\(Int(Date().timeIntervalSince1970 * 1000))_\(self.safeFileName(displayName))"
        let assetPath = try self.writeCacheFile(data: encoded.packageBytes, directoryName: "ebaj", stem: stem, ext: "ebaj")
        let previewPath = try? self.writeCacheFile(
          data: self.buildPreviewData(url: url, mime: mime, crop: crop),
          directoryName: "ebaj",
          stem: stem,
          ext: "png"
        )
        let animatedPreviewPath: String?
        if self.isVideoMime(mime) {
          if let warmPreviewPath,
             FileManager.default.fileExists(atPath: URL(fileURLWithPath: warmPreviewPath).path) {
            let gifData = try Data(contentsOf: URL(fileURLWithPath: warmPreviewPath))
            animatedPreviewPath = try self.writeCacheFile(data: gifData, directoryName: "ebaj", stem: stem, ext: "gif")
          } else {
            animatedPreviewPath = nil
          }
        } else if self.isGif(url) {
          animatedPreviewPath = try self.copyAnimatedPreview(source: url, directoryName: "ebaj", stem: stem)
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
            directoryName: "ebaj",
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
        if let id = assignedId { resultMap["assignedId"] = id }
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
      guard uploadBackgroundTask == .invalid else { return }
      uploadBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ESP BAJI Upload") { [weak self] in
        self?.endUploadBackgroundTask()
      }
    }
  }

  private func endUploadBackgroundTask() {
    performOnMainSync {
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

  private func switchToAsset(id: String, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let response = try self.sendSwitchCommand(id: id)
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

  private func sendSwitchCommand(id: String) throws -> String {
    let semaphore = DispatchSemaphore(value: 0)
    var responseData = Data()
    var failure: Error?
    let connection = NWConnection(
      host: NWEndpoint.Host(activeBadgeHost),
      port: NWEndpoint.Port(rawValue: UInt16(BadgeConstants.badgeUploadTcpPort))!,
      using: .tcp
    )
    connection.stateUpdateHandler = { state in
      switch state {
      case .ready:
        let cmd = "SWITCH \(id)\n"
        connection.send(
          content: cmd.data(using: .utf8),
          completion: .contentProcessed { error in
            if let error = error {
              failure = error
              semaphore.signal()
              return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, receiveError in
              if let data = data { responseData = data }
              if let receiveError = receiveError { failure = receiveError }
              connection.cancel()
              semaphore.signal()
            }
          }
        )
      case .failed(let error), .waiting(let error):
        failure = error
        connection.cancel()
        semaphore.signal()
      case .cancelled:
        semaphore.signal()
      default:
        break
      }
    }
    connection.start(queue: .global())
    _ = semaphore.wait(timeout: .now() + .seconds(5))
    connection.cancel()
    if let failure = failure { throw failure }
    return String(data: responseData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private func uploadAssetOverTcp(package: UploadPackageInfo) throws -> String? {
    let semaphore = DispatchSemaphore(value: 0)
    var failure: Error?
    var assignedId: String?
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
            failure = error
            semaphore.signal()
            return
          }
          connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { readyData, _, _, readyError in
            if let readyError {
              failure = readyError
              semaphore.signal()
              return
            }
            let readyText = readyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard readyText.hasPrefix("READY") else {
              let trimmedReady = readyText.trimmingCharacters(in: .whitespacesAndNewlines)
              failure = BadgeError.message(trimmedReady.isEmpty ? "设备未准备好上传" : trimmedReady)
              semaphore.signal()
              return
            }
            self.sendTcpFileChunks(connection: connection, package: package) { chunkError in
              if let chunkError {
                failure = chunkError
                semaphore.signal()
                return
              }
              connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, error in
                if let error = error {
                  failure = error
                } else if let data = data, let text = String(data: data, encoding: .utf8) {
                  if text.hasPrefix("OK") {
                    let idPart = text.trimmingCharacters(in: .whitespacesAndNewlines)
                      .replacingOccurrences(of: "OK", with: "")
                      .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !idPart.isEmpty { assignedId = idPart }
                  } else {
                    failure = BadgeError.message(text.trimmingCharacters(in: .whitespacesAndNewlines))
                  }
                }
                semaphore.signal()
              }
            }
          }
        })
      case .failed(let error):
        failure = error
        semaphore.signal()
      default:
        break
      }
    }
    connection.start(queue: .global(qos: .userInitiated))
    if semaphore.wait(timeout: .now() + .seconds(BadgeConstants.uploadTimeoutSeconds)) == .timedOut {
      failure = BadgeError.message("TCP上传超时")
    }
    connection.cancel()
    activeUpload = nil
    if let failure = failure { throw failure }
    return assignedId
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

  private func buildPreviewData(url: URL, mime: String, crop: CropTransform) throws -> Data {
    let image = try renderFirstFrame(url: url, mime: mime, size: BadgeConstants.previewSize, crop: crop)
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

  private func renderFirstFrame(url: URL, mime: String, size: Int, crop: CropTransform) throws -> CGImage {
    if isVideoMime(mime) {
      let generator = AVAssetImageGenerator(asset: AVAsset(url: url))
      generator.appliesPreferredTrackTransform = true
      let image = try generator.copyCGImage(at: .zero, actualTime: nil)
      return renderImage(image, width: size, height: size, crop: crop)
    }
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
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
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    if size < BadgeConstants.headerSize {
      throw BadgeError.message("素材包头不完整，请重新导入生成 EBAJ4")
    }
    if size > Int(UInt32.max) {
      throw BadgeError.message("素材包过大，请换短一点的素材")
    }

    let handle = try FileHandle(forReadingFrom: fileURL)
    let header = handle.readData(ofLength: BadgeConstants.headerSize)
    handle.closeFile()
    if let message = validatePackageForUpload(header, packageSize: size) {
      throw BadgeError.message(message)
    }

    return UploadPackageInfo(fileURL: fileURL, size: size, crc: try crc32(fileURL: fileURL))
  }

  private func validatePackageForUpload(_ data: Data, packageSize packageLength: Int) -> String? {
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
    if fps < BadgeConstants.minDeviceFps || fps > BadgeConstants.maxDeviceFps {
      return "历史素材帧率不是25-30fps，请重新导入生成"
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
    status.split { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }
      .contains { token in token.lowercased() == "sd=1" || token.lowercased() == "storage=sd" }
  }

  private func sendConnectionEvent(connected: Bool, connecting: Bool, message: String) {
    sendEvent([
      "type": "connectionState",
      "connected": connected,
      "connecting": connecting,
      "address": nullable(connectedAddress),
      "sdAvailable": sdAvailable,
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
      let gifData = try convertVideoToAnimatedGif(url: url, delayMs: delayMs, streamSize: streamSize, crop: crop)
      guard let source = CGImageSourceCreateWithData(gifData as CFData, nil),
            CGImageSourceGetCount(source) > 1 else {
        throw BadgeError.message("视频转GIF失败")
      }
      frames = try encodeImageSequence(source: source, delayMs: delayMs, streamSize: streamSize, crop: crop)
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

private enum BadgeConstants {
  static let channel = "esp_baji/native"
  static let badgeDeviceName = "ESP-DotLoop"
  static let badgeApHost = "192.168.4.1"
  static let badgeUploadTcpPort = 3333
  static let badgeTcpUploadMagic: UInt32 = 0x31505542
  static let statusTimeout: TimeInterval = 2.5
  static let lanDiscoveryProbeTimeout: TimeInterval = 0.45
  static let lanDiscoveryTimeoutGrace: TimeInterval = 0.15
  static let lanDiscoveryConcurrency = 32
  static let lanDiscoveryMaxCandidates = 260
  static let uploadTimeoutSeconds = 180
  static let uploadChunkBytes = 256 * 1024
  static let uploadProgressStepBytes = 512 * 1024
  static let sdStreamBudgetBytes = 512 * 1024 * 1024
  static let assetTooLargeMessage = "转换后的设备包超过当前素材存储空间，请换短一点的素材。"
  static let maxHistoryItems = 20
  static let historyKey = "history"
  static let width = 480
  static let height = 480
  static let minDeviceFps = 25
  static let deviceFps = 40
  static let maxDeviceFps = 40
  static let previewSize = 320
  static let videoPreviewGifSize = 192
  static let videoPreviewGifFps = 30
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
