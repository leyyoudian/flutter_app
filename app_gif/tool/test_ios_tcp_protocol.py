"""Run the production Swift TCP parser against recorded and fragmented replies.

macOS CI: python3 tool/test_ios_tcp_protocol.py
Windows source/wiring check only: add --check-source (does not run Swift).
"""

import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


def extract_block(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


FIXTURES = r'''
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError(message) }
  checks += 1
}
func expectFailure(_ message: String, _ operation: () throws -> Void) {
  do { try operation() } catch { checks += 1; return }
  fatalError("Expected rejection: \(message)")
}
let key = "P4-E8F60AE69F29"
let identity = Data("OK DEVICE \(key)\nOK\n".utf8)
var combined = BadgeTcpLineBuffer()
let first = try combined.append(identity, isComplete: true)
check(first == "OK DEVICE \(key)", "Ignore generic trailing OK")
check(parseDeviceKey(first!) == key, "Recorded identity accepted")
for split in 0..<identity.count {
  var buffer = BadgeTcpLineBuffer()
  let head = try buffer.append(Data(identity.prefix(split)), isComplete: false)
  let line: String?
  if let head { line = head } else {
    line = try buffer.append(Data(identity.dropFirst(split)), isComplete: true)
  }
  check(line == first, "Identity split at byte \(split)")
}
var singles = BadgeTcpLineBuffer()
var singleLine: String?
for byte in identity {
  if let line = try singles.append(Data([byte]), isComplete: false) {
    singleLine = line
    break
  }
}
check(singleLine == first, "Identity arrives one byte at a time")
for text in ["READY\n", "READY\r\n", "OK U001\nOK\n", "ERR 素材不存在\nOK\n"] {
  let data = Data(text.utf8)
  let expected = text.components(separatedBy: "\n")[0]
    .trimmingCharacters(in: .whitespacesAndNewlines)
  for split in 0..<data.count {
    var buffer = BadgeTcpLineBuffer()
    let head = try buffer.append(Data(data.prefix(split)), isComplete: false)
    let line: String?
    if let head { line = head } else {
      line = try buffer.append(Data(data.dropFirst(split)), isComplete: true)
    }
    check(line == expected, "Fragmented READY/ACK/UTF-8 at \(split)")
  }
}
check(parseDeviceKey("OK DEVICE P4-E8F60AE69F2Z") == nil, "Reject invalid device key")
check(parseDeviceKey("OK DEVICE P4-E8F60AE69F29\nOK") == nil, "Identity validation stays strict")
check(parseDeviceKey("OK") == nil, "Reject missing identity")
let firstID = try BadgeTcpLineBuffer.uploadedAssetID("OK U001")
let lastID = try BadgeTcpLineBuffer.uploadedAssetID("OK U999")
let legacyID = try BadgeTcpLineBuffer.uploadedAssetID("OK")
check(firstID == "U001", "Assigned upload ID")
check(lastID == "U999", "Three digit upload ID")
check(legacyID == nil, "Legacy firmware ACK")
for text in ["OK U001\nOK", "OK DEVICE \(key)", "OK U01", "OK U0001", "OKAY", "ERR CRC", ""] {
  expectFailure("Invalid ACK \(text)") { _ = try BadgeTcpLineBuffer.uploadedAssetID(text) }
}
for data in [Data(), Data("READY".utf8), Data("\n".utf8), Data([0xff, 0x0a]),
             Data(repeating: 0x41, count: 257), Data((String(repeating: "A", count: 257) + "\n").utf8)] {
  expectFailure("Empty, truncated, malformed or oversized reply") {
    var buffer = BadgeTcpLineBuffer()
    _ = try buffer.append(data, isComplete: true)
  }
}
var maximum = BadgeTcpLineBuffer()
let maximumLine = try maximum.append(Data((String(repeating: "A", count: 256) + "\nOK\n").utf8), isComplete: true)
check(maximumLine?.utf8.count == 256, "Maximum length first line accepted")
print("PASS: \(checks) checks using the production Swift parser and identity validator")
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-source', action='store_true')
    args = parser.parse_args()
    source = (Path(__file__).resolve().parents[1] / 'ios/Runner/AppDelegate.swift').read_text(encoding='utf-8')
    line_buffer = extract_block(source, 'struct BadgeTcpLineBuffer')
    device_key = extract_block(source, 'private func parseDeviceKey').replace('private func', 'func', 1)
    raw = extract_block(source, 'private func sendRawTcpCommand(')
    upload = extract_block(source, 'private func uploadAssetOverTcp(')
    receiver = extract_block(source, 'private func receiveTcpLine(')
    assert 'self.receiveTcpLine(connection: connection)' in raw
    assert '== .timedOut' in raw
    assert upload.count('self.receiveTcpLine(connection: connection)') == 2
    assert 'BadgeTcpLineBuffer.uploadedAssetID(text)' in upload
    assert 'buffer.append(data, isComplete: isComplete)' in receiver
    if args.check_source:
        print('PASS: production Swift source extraction and call-site wiring (Swift not executed)')
        return
    swift = shutil.which('swift')
    if not swift:
        raise SystemExit('Swift is required to run protocol fixtures; use macOS CI.')
    with tempfile.TemporaryDirectory(prefix='dotloop-ios-tcp-') as folder:
        script = Path(folder) / 'main.swift'
        script.write_text('import Foundation\n' + line_buffer + '\n' + device_key + '\n' + FIXTURES, encoding='utf-8')
        subprocess.run([swift, str(script)], check=True, timeout=90)


if __name__ == '__main__':
    main()
