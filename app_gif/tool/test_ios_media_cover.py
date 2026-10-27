"""Run production GIF timing, cover rendering and file writing on macOS.

Uses ImageIO/CoreGraphics/AVFoundation; UIKit's black color is replaced with the
same CGColor because UIKit is unavailable to a macOS command-line executable.
--check-source checks extraction/wiring only and does not execute Swift.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

from test_ios_tcp_protocol import extract_block


BOOTSTRAP = r'''
import Foundation
import ImageIO
import CoreGraphics
import AVFoundation
import UniformTypeIdentifiers
enum BadgeConstants { static let previewSize = 480 }
enum BadgeError: Error { case message(String) }
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
  guard value() else { fatalError(label) }; checks += 1
}
final class CoverHarness {
  let root: URL
  init(_ root: URL) { self.root = root }
  func assetRootDirectory() throws -> URL { root }
'''

FIXTURES = r'''
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let harness = CoverHarness(directory)
let gifURL = directory.appendingPathComponent("unequal-delays.gif")
let bytes = NSMutableData()
let destination = CGImageDestinationCreateWithData(bytes, UTType.gif.identifier as CFString, 3, nil)!
let colors: [[CGFloat]] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1]]
let delays: [Double] = [0.1, 0.9, 0.2]
for index in 0..<3 {
  let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
    bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: colors[index])!)
  context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
  let properties: [CFString: Any] = [kCGImagePropertyGIFDictionary: [
    kCGImagePropertyGIFDelayTime: delays[index], kCGImagePropertyGIFUnclampedDelayTime: delays[index]]]
  CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
}
check(CGImageDestinationFinalize(destination), "Generate a three-frame GIF with unequal frame delays")
try (bytes as Data).write(to: gifURL)
let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil)!
check(harness.gifFrameDelaysMs(source) == [100, 900, 200], "Use each GIF frame's actual delay")
check(harness.mediaDurationMs(gifURL, mime: "image/gif") == 1200, "Total GIF duration")
check(harness.mediaDurationMs(gifURL, mime: "image/png") == 0, "Static images have no timeline")

func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
  let context = CGContext(data: nil, width: image.width, height: image.height,
    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  let data = context.data!.assumingMemoryBound(to: UInt8.self)
  let offset = (y * image.width + x) * 4
  return Array(UnsafeBufferPointer(start: data + offset, count: 4))
}
for (time, channel) in [(0, 0), (99, 0), (100, 1), (600, 1), (999, 1), (1000, 2), (1199, 2)] {
  let image = try harness.renderFirstFrame(url: gifURL, mime: "image/gif", size: 32,
    crop: .default, frameTimeMs: time)
  let rgba = pixel(image, 16, 16)
  check(rgba[channel] > 240 && rgba[(channel + 1) % 3] < 15 && rgba[(channel + 2) % 3] < 15,
    "GIF frame at \(time) ms")
}
for scale in [0.5, 1.0, 4.0] {
  let png = try harness.buildPreviewData(url: gifURL, mime: "image/gif",
    crop: CropTransform(scale: scale, offsetX: 0, offsetY: 0), frameTimeMs: 1199)
  let path = try harness.writeCacheFile(data: png, directoryName: "ebaj", stem: UUID().uuidString + "_cover", ext: "png")
  check(path.hasPrefix(directory.appendingPathComponent("ebaj").path + "/"), "Cover is stored under managed files")
  let savedBytes = try Data(contentsOf: URL(fileURLWithPath: path))
  check(savedBytes == png, "Saved PNG matches extracted cover")
  let saved = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
  let image = CGImageSourceCreateImageAtIndex(saved, 0, nil)!
  check(image.width == 480 && image.height == 480, "Cover dimensions")
  check(pixel(image, 240, 240)[2] > 240, "Saved cover retains selected last blue frame")
  let edge = pixel(image, 8, 8)
  check(scale == 0.5 ? edge.prefix(3).allSatisfy { $0 < 15 } : edge[2] > 240,
    "Zoom out pads black; default and enlarged crops remain filled")
}
let offset = try harness.renderFirstFrame(url: gifURL, mime: "image/gif", size: 32,
  crop: CropTransform(scale: 0.5, offsetX: 0.25, offsetY: 0), frameTimeMs: 600)
check(pixel(offset, 16, 16)[1] > 240 && pixel(offset, 8, 16)[1] < 15,
  "Zoomed out crop respects horizontal offset")
do {
  _ = try harness.renderFirstFrame(url: directory.appendingPathComponent("missing.gif"),
    mime: "image/gif", size: 32, crop: .default)
  fatalError("Missing input must fail")
} catch { checks += 1 }
print("PASS: \(checks) checks using production Swift GIF timing, rendering and cover persistence")
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-source', action='store_true')
    args = parser.parse_args()
    source = (Path(__file__).resolve().parents[1] / 'ios/Runner/AppDelegate.swift').read_text(encoding='utf-8')
    methods = '\n'.join(extract_block(source, name) for name in [
        'private func gifFrameDelaysMs(', 'private func videoDurationMs(',
        'private func mediaDurationMs(', 'private func isVideoMime(',
        'private func renderFirstFrame(', 'private func renderImage(',
        'private func buildPreviewData(', 'private func writeCacheFile(',
        'private func cacheDirectory('])
    transform = extract_block(source, 'private struct CropTransform').replace('private struct', 'struct', 1)
    preview = extract_block(source, 'private func videoFramePreview(')
    picked = extract_block(source, 'private func preparePickedMedia(')
    prepared = extract_block(source, 'private func prepareAsset(')
    for block in [preview, picked, prepared]:
        assert 'mediaDurationMs(' in block, 'GIF timing must be available throughout import/preview/save'
    assert 'durationMs - 1' in preview and 'frameTimeMs: timeMs' in preview
    assert 'frameTimeMs: coverTimeMs' in prepared
    save = source[source.index('case "saveMaterialCover":'):source.index('case "warmVideoAnimatedPreview":')]
    assert 'writeCacheFile(' in save and 'UUID().uuidString' in save
    assert 'applicationSupportDirectory' in extract_block(source, 'private func assetRootDirectory(')
    assert methods.count('UIColor.black.cgColor') == 1
    if args.check_source:
        print('PASS: GIF/video cover production extraction and import/preview/save wiring (Swift not executed)')
        return
    swift = shutil.which('swift')
    if not swift:
        raise SystemExit('Swift with ImageIO/CoreGraphics/AVFoundation required; run on macOS CI.')
    methods = methods.replace('private func', 'func').replace('UIColor.black.cgColor', 'CGColor(gray: 0, alpha: 1)')
    with tempfile.TemporaryDirectory(prefix='dotloop-ios-cover-') as folder:
        script = Path(folder) / 'main.swift'
        script.write_text(BOOTSTRAP + methods + '\n}\n' + transform + '\n' + FIXTURES, encoding='utf-8')
        subprocess.run([swift, str(script), folder], check=True, timeout=120)


if __name__ == '__main__':
    main()
