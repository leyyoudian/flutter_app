"""Compile production iOS animation/game installation code on macOS.

Exercises actual URLSession upload/ACK validation against a loopback server.
--check-source performs extraction and wiring checks only; it does not run Swift.
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


BOOTSTRAP = r'''
import Foundation
import CryptoKit
typealias FlutterResult = (Any?) -> Void
final class FlutterError: NSObject {
  let code: String
  init(code: String, message: String?, details: Any?) { self.code = code }
}
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
  guard value() else { fatalError(label) }; checks += 1
}
'''

HARNESS = r'''
final class FactoryHarness {
  var isUploading = false
  let activeBadgeHost: String
  var deviceKey = "P4-E8F60AE69F29"
  private let lock = NSLock()
  private var recorded: [Double] = []
  init(_ host: String) { activeBadgeHost = host }
  func beginUploadBackgroundTask() {}
  func endUploadBackgroundTask() {}
  func sendRawTcpCommand(_ command: String) throws -> String { "OK DEVICE " + deviceKey }
  func sendEvent(_ event: [String: Any]) {
    guard let value = event["progress"] as? Double else { return }
    lock.lock(); recorded.append(value); lock.unlock()
  }
  func progress() -> [Double] { lock.lock(); defer { lock.unlock() }; return recorded }
'''

FIXTURES = r'''
let host = CommandLine.arguments[1], directory = URL(fileURLWithPath: CommandLine.arguments[2])
let payload = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
let package = directory.appendingPathComponent("factory.dlf")
try payload.write(to: package)
let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
var args: [String: Any] = ["assetPath": package.path, "id": "S010",
  "deviceKey": "P4-E8F60AE69F29", "sha256": hash]

func install(_ harness: FactoryHarness, _ arguments: [String: Any], game: Bool = false) -> Any? {
  var finished = false, value: Any?
  harness.installFactoryPackage(args: arguments, isGame: game) { value = $0; finished = true }
  let deadline = Date().addingTimeInterval(15)
  while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
  check(finished, "Installation callback completed exactly once")
  return value
}
let good = FactoryHarness(host + "/good")
let reply = install(good, args) as? [String: Any]
check(reply?["installed"] as? Bool == true, "Device acknowledgement returned")
check(reply?["id"] as? String == "S010", "Exact installed ID")
let progress = good.progress()
check(progress.count >= 2, "Upload reports progress and acknowledgement")
check(progress.dropLast().allSatisfy { $0 >= 0.45 && $0 <= 0.95 }, "Wire progress never claims installation complete")
check(progress.last == 0.98, "Validated acknowledgement precedes installed progress")
for mode in ["wrong-capability", "wrong-reply", "missing", "malformed", "redirect"] {
  let answer = install(FactoryHarness(host + "/" + mode), args)
  check(answer is FlutterError, "Reject " + mode)
}
let corrupt = FactoryHarness(host + "/corrupt")
var invalid = args; invalid["sha256"] = String(repeating: "0", count: 64)
check(install(corrupt, invalid) is FlutterError, "Reject corrupt local payload before networking")
let wrongDevice = FactoryHarness(host + "/wrong-device")
wrongDevice.deviceKey = "P4-000000000000"
check(install(wrongDevice, args) is FlutterError, "Reject another device before upload")
let busy = FactoryHarness(host + "/busy"); busy.isUploading = true
check((install(busy, args) as? FlutterError)?.code == "factory_invalid", "Reject concurrent transfer")

let gameFile = directory.appendingPathComponent("game.json")
let gameBytes = Data("test-game-package".utf8); try gameBytes.write(to: gameFile)
let gameHash = SHA256.hash(data: gameBytes).map { String(format: "%02x", $0) }.joined()
let gameArgs: [String: Any] = ["assetPath": gameFile.path, "id": "fixture_game",
  "deviceKey": "P4-E8F60AE69F29", "sha256": gameHash]
check((install(FactoryHarness(host + "/game"), gameArgs, game: true) as? [String: Any])?["installed"] as? Bool == true,
  "Generic game transport uses the same installation pipeline")

private var meter = RelayInstallProgress()
check(meter.update(sent: 10, total: 0, now: 0) == nil, "Unknown length ignored")
check(meter.update(sent: -1, total: 1000, now: 0) == nil, "Negative count ignored")
check(meter.update(sent: 0, total: 1000, now: 0) == 0.45, "Upload begins at 45 percent")
check(meter.update(sent: 10, total: 1000, now: 0.01) == nil, "Progress notifications throttled")
check(meter.update(sent: 500, total: 1000, now: 0.11) == 0.7, "Intermediate wire progress")
check(meter.update(sent: 400, total: 1000, now: 0.3) == nil, "Late counter does not go backwards")
check(meter.update(sent: 2000, total: 1000, now: 0.31) == 0.95, "Last bytes remain below completion")
check(meter.update(sent: 3000, total: 1000, now: 0.5) == nil, "Repeated completion ignored")
print("PASS: \(checks) production install, ACK and progress checks")
'''


class Handler(BaseHTTPRequestHandler):
    events = []

    def log_message(self, *_):
        pass

    def reply(self, payload, status=200):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.events.append(('GET', self.path, None))
        key = 'P4-000000000000' if self.path.startswith('/wrong-capability/') else 'P4-E8F60AE69F29'
        self.reply({'protocol': 1, 'deviceKey': key}, 404 if self.path.startswith('/missing/') else 200)

    def do_POST(self):
        data = self.rfile.read(int(self.headers['Content-Length']))
        self.events.append(('POST', self.path, hashlib.sha256(data).hexdigest()))
        if self.path.startswith('/redirect/'):
            self.send_response(307)
            self.send_header('Location', '/must-not-follow')
            self.send_header('Content-Length', '0')
            self.end_headers()
        elif self.path.startswith('/malformed/'):
            self.send_response(200)
            self.send_header('Content-Length', '1')
            self.end_headers()
            self.wfile.write(b'{')
        else:
            game = self.path.startswith('/game/')
            if game:
                assert self.headers['X-Game-Id'] == 'fixture_game'
                assert self.headers['X-Content-SHA256'] == hashlib.sha256(data).hexdigest()
            self.reply({'installed': True, 'id': 'wrong' if self.path.startswith('/wrong-reply/') else ('fixture_game' if game else 'S010'),
                        'deviceKey': 'P4-E8F60AE69F29'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-source', action='store_true')
    args = parser.parse_args()
    source = (Path(__file__).resolve().parents[1] / 'ios/Runner/AppDelegate.swift').read_text(encoding='utf-8')
    install = extract_block(source, 'private func installFactoryPackage(')
    request = extract_block(source, 'private func factoryInstallRequest(')
    identity = extract_block(source, 'private func parseDeviceKey(')
    common = '\n'.join(extract_block(source, name) for name in [
        'private func transferFailure(', 'private struct RelayInstallProgress',
        'private final class RelayNoRedirectDelegate'])
    assert 'self.transferFailure(' not in install, 'transferFailure is a global function, not an AppDelegate method'
    assert 'onUploadProgress:' in request and 'RelayInstallProgress()' in request
    assert 'reply["installed"] as? Bool == true' in install
    assert 'self.parseDeviceKey(try self.sendRawTcpCommand("IDENTITY\\n")) == key' in install
    assert 'uploadFile: file' in install and 'totalBytesExpectedToSend' in common
    if args.check_source:
        print('PASS: installation/progress production source extraction and wiring (Swift not executed)')
        return
    swift = shutil.which('swift')
    if not swift:
        raise SystemExit('Swift and CryptoKit required: run this check on macOS CI.')
    with tempfile.TemporaryDirectory(prefix='dotloop-ios-install-') as directory:
        script = Path(directory) / 'main.swift'
        script.write_text(BOOTSTRAP + common + '\n' + HARNESS + install.replace('private func', 'func', 1) + '\n' + request + '\n' + identity + '\n}\n' + FIXTURES, encoding='utf-8')
        Handler.events = []
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            subprocess.run([swift, str(script), '127.0.0.1:' + str(server.server_port), directory], check=True, timeout=120)
            posts = [event for event in Handler.events if event[0] == 'POST']
            assert [x[1] for x in posts] == ['/good/factory/install', '/wrong-reply/factory/install', '/malformed/factory/install', '/redirect/factory/install', '/game/games/install'], posts
            expected = hashlib.sha256(bytes(i % 251 for i in range(1024 * 1024))).hexdigest()
            assert all(x[2] == expected for x in posts[:-1]), posts
            print('PASS: exact upload bodies; no redirected or repeated installation POST')
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
