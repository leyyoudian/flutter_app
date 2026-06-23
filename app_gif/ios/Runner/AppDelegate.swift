import AVFoundation
import CoreGraphics
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
  private var sdAvailable = false
  private var isUploading = false

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
      connect(result: result)
    case "disconnect":
      connectedAddress = nil
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
      let fps = min(60, max(1, args["fps"] as? Int ?? 30))
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
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startScan() {
    sendEvent(["type": "scanState", "scanning": true])
    sendEvent([
      "type": "scanResult",
      "device": [
        "address": BadgeConstants.badgeHost,
        "name": BadgeConstants.badgeDeviceName,
        "rssi": -30,
        "serviceMatch": true,
      ],
    ])
    sendEvent(["type": "scanState", "scanning": false])
  }

  private func connect(result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        _ = try self.requestText(BadgeConstants.badgeStatusUrl, timeout: BadgeConstants.statusTimeout)
        self.connectedAddress = BadgeConstants.badgeHost
        self.sdAvailable = true
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
          let status = try self.requestText(BadgeConstants.badgeStatusUrl, timeout: BadgeConstants.statusTimeout)
          self.sdAvailable = self.parseSdAvailable(status)
          connected = true
          message = "已连接"
        } catch {
          self.connectedAddress = nil
          self.sdAvailable = false
          message = "断开连接"
        }
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
        _ = try self.requestText("\(BadgeConstants.badgeBrightnessUrl)?value=\(value)", timeout: BadgeConstants.statusTimeout)
        DispatchQueue.main.async { result(nil) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "wifi_write", message: "亮度写入失败", details: nil))
        }
      }
    }
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
        let data = try self.buildVideoAnimatedPreview(url: url, crop: .default, warmPreviewPath: nil)
        let path = try self.writeCacheFile(data: data, directoryName: "media_preview", stem: self.safeFileName(displayName), ext: "gif")
        self.sendEvent([
          "type": "videoPreviewReady",
          "uri": uriText,
          "animatedPreviewPath": path,
        ])
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
          let gifData = try self.buildVideoAnimatedPreview(url: url, crop: crop, warmPreviewPath: warmPreviewPath)
          animatedPreviewPath = try self.writeCacheFile(data: gifData, directoryName: "ebaj", stem: stem, ext: "gif")
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
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "prepare_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func uploadAsset(assetPath: String, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      self.isUploading = true
      defer { self.isUploading = false }
      do {
        let data = try Data(contentsOf: URL(fileURLWithPath: assetPath))
        guard self.isSupportedPackage(data) else {
          throw BadgeError.message("历史素材是旧格式，请重新导入生成 EBAJ4")
        }
        try self.uploadAssetOverTcp(packageBytes: data, crc: crc32(data))
        self.sendEvent(["type": "uploadProgress", "progress": 1.0, "message": "已切换显示"])
        DispatchQueue.main.async { result(nil) }
      } catch {
        do {
          let data = try Data(contentsOf: URL(fileURLWithPath: assetPath))
          try self.uploadAssetOverHttp(packageBytes: data, crc: crc32(data))
          self.sendEvent(["type": "uploadProgress", "progress": 1.0, "message": "已切换显示"])
          DispatchQueue.main.async { result(nil) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "upload_failed", message: error.localizedDescription, details: nil))
          }
        }
      }
    }
  }

  private func uploadAssetOverTcp(packageBytes: Data, crc: UInt32) throws {
    let semaphore = DispatchSemaphore(value: 0)
    var failure: Error?
    let connection = NWConnection(
      host: NWEndpoint.Host(BadgeConstants.badgeHost),
      port: NWEndpoint.Port(rawValue: UInt16(BadgeConstants.badgeUploadTcpPort))!,
      using: .tcp
    )
    activeUpload = connection
    connection.stateUpdateHandler = { state in
      switch state {
      case .ready:
        var header = Data()
        appendLe32(&header, BadgeConstants.badgeTcpUploadMagic)
        appendLe32(&header, UInt32(packageBytes.count))
        appendLe32(&header, crc)
        var payload = Data()
        payload.append(header)
        payload.append(packageBytes)
        connection.send(content: payload, completion: .contentProcessed { error in
          if let error = error {
            failure = error
            semaphore.signal()
            return
          }
          connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, error in
            if let error = error {
              failure = error
            } else if let data = data, let text = String(data: data, encoding: .utf8), !text.hasPrefix("OK") {
              failure = BadgeError.message(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            semaphore.signal()
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
    if semaphore.wait(timeout: .now() + .seconds(60)) == .timedOut {
      failure = BadgeError.message("TCP上传超时")
    }
    connection.cancel()
    activeUpload = nil
    if let failure = failure { throw failure }
  }

  private func uploadAssetOverHttp(packageBytes: Data, crc: UInt32) throws {
    var request = URLRequest(url: URL(string: BadgeConstants.badgeUploadUrl)!)
    request.httpMethod = "POST"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue(String(format: "%08x", crc), forHTTPHeaderField: "X-EBAJ-CRC32")
    request.timeoutInterval = 60
    let semaphore = DispatchSemaphore(value: 0)
    var failure: Error?
    let task = URLSession.shared.uploadTask(with: request, from: packageBytes) { _, response, error in
      if let error = error {
        failure = error
      } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        failure = BadgeError.message("HTTP \(http.statusCode) 上传失败")
      }
      semaphore.signal()
    }
    task.resume()
    if semaphore.wait(timeout: .now() + .seconds(60)) == .timedOut {
      task.cancel()
      failure = BadgeError.message("HTTP上传超时")
    }
    if let failure = failure { throw failure }
  }

  private func requestText(_ urlText: String, timeout: TimeInterval) throws -> String {
    guard let url = URL(string: urlText) else { throw BadgeError.message("URL错误") }
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    let semaphore = DispatchSemaphore(value: 0)
    var output = ""
    var failure: Error?
    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error = error {
        failure = error
      } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        failure = BadgeError.message("HTTP \(http.statusCode)")
      } else if let data = data {
        output = String(data: data, encoding: .utf8) ?? ""
      }
      semaphore.signal()
    }.resume()
    if semaphore.wait(timeout: .now() + timeout + 2) == .timedOut {
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
    let asset = AVAsset(url: url)
    let durationMs = max(1, Int(CMTimeGetSeconds(asset.duration) * 1000.0))
    let delayMs = frameDelayMs(BadgeConstants.videoPreviewGifFps)
    let totalFrames = max(1, (durationMs + delayMs - 1) / delayMs)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    var frames: [Data] = []
    for index in 0..<totalFrames {
      let timeMs = min(durationMs - 1, index * delayMs)
      let image = try generator.copyCGImage(at: CMTime(value: CMTimeValue(timeMs), timescale: 1000), actualTime: nil)
      let rendered = renderImage(image, width: BadgeConstants.videoPreviewGifSize, height: BadgeConstants.videoPreviewGifSize, crop: crop)
      frames.append(Data(quantizeBitmapToGifIndexed(rendered)))
    }
    return try encodeIndexedGif(frames: frames, width: BadgeConstants.videoPreviewGifSize, height: BadgeConstants.videoPreviewGifSize, delayMs: delayMs)
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
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("badge_assets", isDirectory: true)
    let directory = base.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
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

  private func isSupportedPackage(_ data: Data) -> Bool {
    data.count >= BadgeConstants.headerSize && readLe32(data, 0) == BadgeConstants.magic
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
    let fps = min(60, max(1, requestedFps))
    let delayMs = frameDelayMs(fps)
    let selectedStreamSize = try sampleStreamResolution(url: url, mime: mime, fps: fps, delayMs: delayMs, crop: crop)
    let selected = try encodeAtResolution(url: url, mime: mime, fps: fps, delayMs: delayMs, streamSize: selectedStreamSize, crop: crop)
    if selected.packageBytes.count > maxPackageBytes {
      throw BadgeError.message(BadgeConstants.assetTooLargeMessage)
    }
    return selected
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
    for estimate in estimates where estimate.bytesPerSecond <= BadgeConstants.qualityStreamBytesPerSecond {
      return estimate.streamSize
    }
    return estimates.last?.streamSize ?? BadgeConstants.streamResolutions.last!
  }
}

private enum BadgeConstants {
  static let channel = "esp_baji/native"
  static let badgeDeviceName = "ESP-BAJI"
  static let badgeHost = "192.168.4.1"
  static let badgeUploadTcpPort = 3333
  static let badgeTcpUploadMagic: UInt32 = 0x31505542
  static let badgeUploadUrl = "http://192.168.4.1/upload"
  static let badgeStatusUrl = "http://192.168.4.1/status"
  static let badgeBrightnessUrl = "http://192.168.4.1/brightness"
  static let statusTimeout: TimeInterval = 2.5
  static let sdStreamBudgetBytes = 512 * 1024 * 1024
  static let assetTooLargeMessage = "转换后的设备包超过当前素材存储空间，请换短一点的素材。"
  static let maxHistoryItems = 20
  static let historyKey = "history"
  static let width = 480
  static let height = 480
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
  static let qualityStreamBytesPerSecond = 4 * 1024 * 1024
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

private func readLe32(_ data: Data, _ offset: Int) -> UInt32 {
  UInt32(data[offset]) |
    (UInt32(data[offset + 1]) << 8) |
    (UInt32(data[offset + 2]) << 16) |
    (UInt32(data[offset + 3]) << 24)
}
