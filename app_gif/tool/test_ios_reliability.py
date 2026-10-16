"""Execute production iOS BLE logic and firmware HTTP/validation on macOS.

BLE uses deterministic transport doubles; OTA uses a real loopback HTTP server.
This is a native code regression check, not an iPhone or hardware test.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading

from test_ios_tcp_protocol import extract_block


BLE_DOUBLES = r'''
import Foundation
typealias FlutterResult = (Any?) -> Void
final class FlutterError: NSObject {
  let code: String
  init(code: String, message: String?, details: Any?) { self.code = code }
}
protocol CBCentralManagerDelegate {}
protocol CBPeripheralDelegate {}
struct CBUUID: Equatable { let string: String; init(string: String) { self.string = string } }
enum CBManagerState { case unknown, resetting, poweredOn, poweredOff }
enum CBCharacteristicWriteType { case withResponse }
class CBCharacteristic: NSObject {
  var uuid = CBUUID(string: "control")
  var isNotifying = true
  var value: Data?
}
class CBService: NSObject {
  var uuid = CBUUID(string: "service")
  var characteristics: [CBCharacteristic]?
}
class CBPeripheral: NSObject {
  let identifier = UUID()
  var delegate: CBPeripheralDelegate?
  var services: [CBService]?
  var writeLimit = 185
  var written: Data?
  func discoverServices(_ ids: [CBUUID]) {}
  func discoverCharacteristics(_ ids: [CBUUID], for service: CBService) {}
  func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic) {}
  func readValue(for characteristic: CBCharacteristic) {}
  func maximumWriteValueLength(for type: CBCharacteristicWriteType) -> Int { writeLimit }
  func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) { written = data }
}
class CBCentralManager: NSObject {
  var state = CBManagerState.poweredOn
  var cancellations = 0
  init(delegate: CBCentralManagerDelegate, queue: DispatchQueue) {}
  func scanForPeripherals(withServices ids: [CBUUID]) {}
  func stopScan() {}
  func connect(_ peripheral: CBPeripheral) {}
  func cancelPeripheralConnection(_ peripheral: CBPeripheral) { cancellations += 1 }
}
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
  guard condition() else { fatalError(label) }; checks += 1
}
'''

BLE_FIXTURES = r'''
func connected() -> (GameBluetoothController, CBPeripheral, CBCharacteristic) {
  let controller = GameBluetoothController()
  let device = CBPeripheral(), characteristic = CBCharacteristic()
  var connected = false
  controller.connect { connected = ($0 as? [String: Any])?["connected"] as? Bool == true }
  controller.peripheral = device; controller.control = characteristic
  characteristic.value = Data("hardware=esp32p4 version=0.2.6 dc=1 game=idle sd=1".utf8)
  controller.peripheral(device, didUpdateValueFor: characteristic, error: nil)
  check(connected && controller.ready, "BLE status handshake")
  return (controller, device, characteristic)
}
let (controller, device, characteristic) = connected()
for action in ["start", "flap", "restart", "pause", "resume", "stop", "status"] {
  var answer: Any?
  controller.send(action: action) { answer = $0 }
  let sequence = controller.sequence
  check(String(data: device.written!, encoding: .utf8) == "GB:\(sequence):\(action)", "Wire game action")
  controller.peripheral(device, didWriteValueFor: characteristic, error: nil)
  check(answer == nil, "ATT delivery is not game acceptance")
  characteristic.value = Data("GB:\(sequence + 1):OK".utf8)
  controller.peripheral(device, didUpdateValueFor: characteristic, error: nil)
  check(answer == nil, "Ignore another command's ACK")
  characteristic.value = Data("GB:\(sequence):OK".utf8)
  controller.peripheral(device, didUpdateValueFor: characteristic, error: nil)
  check(answer as? Bool == true && controller.commandResult == nil, "Game command acknowledged once")
}
var identity: Any?
controller.sendDevice(command: "IDENTITY") { identity = $0 }
characteristic.value = Data("GB:\(controller.sequence):OK:OK DEVICE P4-E8F60AE69F29".utf8)
controller.peripheral(device, didUpdateValueFor: characteristic, error: nil)
check(identity as? String == "OK DEVICE P4-E8F60AE69F29", "BLE identity before OTA/AP join")
var rejected: Any?
controller.send(action: "start") { rejected = $0 }
characteristic.value = Data("GB:\(controller.sequence):ERR:103".utf8)
controller.peripheral(device, didUpdateValueFor: characteristic, error: nil)
check((rejected as? FlutterError)?.code == "game_rejected", "Firmware rejection is not success")
check(controller.ready, "Firmware rejection permits correction and retry")
for failure in ["timeout", "unsubscribe", "read", "write", "mtu", "disconnect"] {
  let (session, badge, control) = connected()
  var result: Any?
  session.send(action: "start") { result = $0 }
  switch failure {
  case "timeout": session.commandTimeout!.perform()
  case "unsubscribe":
    control.isNotifying = false
    session.peripheral(badge, didUpdateNotificationStateFor: control, error: nil)
  case "read": session.peripheral(badge, didUpdateValueFor: control, error: NSError(domain: "test", code: 1))
  case "write": session.peripheral(badge, didWriteValueFor: control, error: NSError(domain: "test", code: 2))
  case "mtu":
    control.value = Data("GB:\(session.sequence):OK".utf8)
    session.peripheral(badge, didUpdateValueFor: control, error: nil)
    result = nil; badge.writeLimit = 1
    session.send(action: "flap") { result = $0 }
  default: session.centralManager(session.central!, didDisconnectPeripheral: badge, error: nil)
  }
  check((result as? FlutterError)?.code == "bluetooth_disconnected", "\(failure) returns reconnectable error")
  check(!session.ready && session.peripheral == nil, "\(failure) releases BLE session")
  var later: Any?
  session.send(action: "flap") { later = $0 }
  check((later as? FlutterError)?.code == "bluetooth_disconnected", "No command on stale session")
  session.close()
}
controller.close()
print("PASS: \(checks) production BLE checks with deterministic transport doubles")
'''

OTA_FIXTURES = r'''
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
  guard condition() else { fatalError(label) }; checks += 1
}
func rejected(_ code: String, _ operation: () throws -> Void) {
  do { try operation() } catch {
    check((error as NSError).userInfo["nativeCode"] as? String == code, "Expected \(code), got \(error)")
    return
  }
  fatalError("Expected rejection: \(code)")
}
let base = CommandLine.arguments[1]
let directory = URL(fileURLWithPath: CommandLine.arguments[2])
let file = directory.appendingPathComponent("fixture-firmware.bin")
var image = Data(repeating: 0, count: 512)
image[0] = 0xe9
image.replaceSubrange(48..<53, with: Data("0.2.6".utf8))
let project = Data("esp32-p4c5-dotloop".utf8)
image.replaceSubrange(80..<(80 + project.count), with: project)
try image.write(to: file)
let hash = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
var dictionary: [String: Any] = ["hardware": "esp32p4-2.8", "version": "0.2.6",
  "url": base + "/firmware", "size": image.count, "sha256": hash]
let manifest = try RelayFirmwareManifest(dictionary)
try verifyFirmware(file, manifest: manifest)
checks += 1
let invalidCases: [[String: Any]] = [["hardware": "esp32s3"], ["sha256": "bad"], ["size": 0], ["url": "file:///bad"], ["version": "invalid"]]
for overrideFields in invalidCases {
  let invalid = dictionary.merging(overrideFields) { _, new in new }
  rejected("firmware_invalid") { _ = try RelayFirmwareManifest(invalid) }
}
var badHash = dictionary; badHash["sha256"] = String(repeating: "0", count: 64)
let invalidHash = try RelayFirmwareManifest(badHash)
rejected("firmware_invalid") { try verifyFirmware(file, manifest: invalidHash) }
let status = try firmwareJSONRequest(URLRequest(url: URL(string: base + "/status")!))
check(status["deviceId"] as? String == "P4-E8F60AE69F29", "Read OTA identity on AP")
rejected("firmware_unsupported") {
  _ = try firmwareJSONRequest(URLRequest(url: URL(string: base + "/missing")!), unsupportedOn404: true)
}
func upload(_ path: String) throws -> [String: Any] {
  var request = URLRequest(url: URL(string: base + path)!)
  request.httpMethod = "POST"
  request.setValue(String(image.count), forHTTPHeaderField: "Content-Length")
  request.setValue(hash, forHTTPHeaderField: "X-OTA-SHA256")
  return try firmwareJSONRequest(request, uploadFile: file)
}
let success = try upload("/ota-success")
check(success["success"] as? Bool == true && success["version"] as? String == "0.2.6", "OTA HTTP acknowledgement")
rejected("firmware_result_unknown") { _ = try upload("/ota-invalid") }
rejected("firmware_rejected") { _ = try upload("/redirect") }
rejected("firmware_result_unknown") { _ = try upload("/ota-lost") }
let relay = RelayUploadHarness(base: base, directory: directory)
let arguments = dictionary.merging(["assetPath": file.path, "deviceId": "P4-E8F60AE69F29"]) { _, new in new }
let relayed = try relay.execute(arguments)
check(relayed["success"] as? Bool == true && relayed["version"] as? String == "0.2.6", "Full production OTA upload handler")
for path in ["/wrong-device", "/wrong-hardware", "/too-small"] {
  let other = RelayUploadHarness(base: base + path, directory: directory)
  rejected("firmware_invalid") { _ = try other.execute(arguments) }
}
let busy = RelayUploadHarness(base: base + "/busy", directory: directory)
rejected("firmware_busy") { _ = try busy.execute(arguments) }
let wrongVersion = RelayUploadHarness(base: base + "/wrong-version", directory: directory)
rejected("firmware_rejected") { _ = try wrongVersion.execute(arguments) }
try Data([0xe9]).write(to: file)
rejected("firmware_invalid") { try verifyFirmware(file, manifest: manifest) }
rejected("firmware_invalid") { _ = try relay.execute(arguments) }
print("PASS: \(checks) production firmware manifest, file validation and HTTP checks")
'''


class Handler(BaseHTTPRequestHandler):
    events = []

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/missing':
            self.send_error(404)
            return
        status = {'relay': True, 'hardware': 'esp32p4-2.8', 'deviceId': 'P4-E8F60AE69F29',
                  'maxSize': 3 * 1024 * 1024, 'otaActive': False}
        if self.path.startswith('/wrong-device/'):
            status['deviceId'] = 'P4-000000000000'
        elif self.path.startswith('/wrong-hardware/'):
            status['hardware'] = 'esp32p4-2.5'
        elif self.path.startswith('/too-small/'):
            status['maxSize'] = 1
        elif self.path.startswith('/busy/'):
            status['otaActive'] = True
        self.reply(status)

    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        valid = hashlib.sha256(body).hexdigest() == self.headers['X-OTA-SHA256']
        self.events.append({'path': self.path, 'bodyValid': valid})
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/unexpected-replay')
            self.end_headers()
        elif self.path == '/ota-lost':
            self.close_connection = True
        elif self.path == '/ota-invalid':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'truncated response')
        elif self.path.startswith('/wrong-version/'):
            self.reply({'success': valid, 'version': '0.0.1'})
        else:
            self.reply({'success': valid, 'version': '0.2.6'})

    def reply(self, data):
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-source', action='store_true')
    args = parser.parse_args()
    source = (Path(__file__).resolve().parents[1] / 'ios/Runner/AppDelegate.swift').read_text(encoding='utf-8')
    bluetooth = extract_block(source, 'private final class GameBluetoothController').replace('private ', '')
    signatures = ['private struct RelayFirmwareManifest', 'private func transferFailure(',
                  'private func transferHTTPFailure(', 'private final class RelayNoRedirectDelegate',
                  'private func verifyFirmware(', 'private func firmwareJSONRequest(']
    firmware = '\n'.join(extract_block(source, name).replace('private ', '', 1) for name in signatures)
    upload_case = source[source.index('case "uploadFirmware":'):source.index('case "loadHistory":')]
    upload_block = extract_block(upload_case, 'runFirmwareOperation(')
    upload_body = upload_block[upload_block.index('{') + 1:-1]
    harness = '''
final class RelayUploadHarness {
  let base: String
  let directory: URL
  init(base: String, directory: URL) { self.base = base; self.directory = directory }
  func cacheDirectory(_ name: String) throws -> URL { directory }
  func badgeUrl(_ path: String) -> String { base + path }
  func execute(_ args: [String: Any]) throws -> [String: Any] {
''' + upload_body + '\n}\n' + extract_block(source, 'private func verifyFirmware(') + '\n' + extract_block(source, 'private func firmwareJSONRequest(') + '\n}\n'
    assert 'self?.fail("设备未确认游戏指令，请重新连接")' in bluetooth
    assert 'fail("蓝牙响应读取失败，请重新连接")' in bluetooth
    assert source.count('runFirmwareOperation(result: result, transfer: true)') == 2
    if args.check_source:
        print('PASS: production BLE/OTA source extraction and wiring (Swift not executed)')
        return
    swift = shutil.which('swift')
    if not swift:
        raise SystemExit('Swift and CryptoKit are required; run on macOS CI.')
    with tempfile.TemporaryDirectory(prefix='dotloop-ios-reliability-') as directory:
        script = Path(directory) / 'ble.swift'
        script.write_text(BLE_DOUBLES + '\n' + bluetooth + '\n' + BLE_FIXTURES, encoding='utf-8')
        subprocess.run([swift, str(script)], check=True, timeout=90)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            script = Path(directory) / 'firmware.swift'
            script.write_text('import Foundation\nimport CryptoKit\n' + firmware + '\n' + harness + '\n' + OTA_FIXTURES, encoding='utf-8')
            base = 'http://127.0.0.1:' + str(server.server_port)
            subprocess.run([swift, str(script), base, directory], check=True, timeout=90)
            assert [event['path'] for event in Handler.events] == ['/ota-success', '/ota-invalid', '/redirect', '/ota-lost', '/ota/upload', '/wrong-version/ota/upload'], Handler.events
            assert all(event['bodyValid'] for event in Handler.events), Handler.events
            print('PASS: OTA bodies match SHA256; no redirected or repeated firmware POST')
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
