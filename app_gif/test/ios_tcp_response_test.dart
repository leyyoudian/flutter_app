import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String method(String source, String signature, String next) {
  final start = source.indexOf(signature);
  final end = source.indexOf(next, start + signature.length);
  expect(start, greaterThanOrEqualTo(0));
  expect(end, greaterThan(start));
  return source.substring(start, end);
}

void main() {
  test('iOS identity and switch read a complete TCP response line', () {
    final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final raw = method(
      source,
      '  private func sendRawTcpCommand(',
      '  private func transcodeOnServer(',
    );
    final switching = method(
      source,
      '  private func sendSwitchCommand(',
      '  private func sendRawTcpCommand(',
    );
    expect(raw, contains('self.receiveTcpLine(connection: connection)'));
    expect(raw, contains('== .timedOut'));
    expect(switching, contains('try sendRawTcpCommand(command)'));
  });

  test('iOS upload frames READY and final acknowledgement separately', () {
    final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final upload = method(
      source,
      '  private func uploadAssetOverTcp(',
      '  private func uploadAssetOverHttp(',
    );
    expect(
      'self.receiveTcpLine(connection: connection)'.allMatches(upload),
      hasLength(2),
    );
    expect(upload, contains('BadgeTcpLineBuffer.uploadedAssetID(text)'));
    expect(upload, isNot(contains('replacingOccurrences(of: "OK"')));
    expect(upload, contains('readyText == "READY"'));
  });

  test('iOS upload completes once when connection callbacks race the ACK', () {
    final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final upload = method(
      source,
      '  private func uploadAssetOverTcp(',
      '  private func uploadAssetOverHttp(',
    );
    expect(upload, contains('let completionLock = NSLock()'));
    expect(upload, contains('guard response == nil else { return }'));
    expect(upload, contains('return try response!.get()'));
  });

  test('TCP line parser and real Swift fixtures are checked by Codemagic', () {
    final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(source, contains('struct BadgeTcpLineBuffer'));
    expect(source, contains('buffer.append(data, isComplete: isComplete)'));
    expect(source, contains('bytes.firstIndex(of: 0x0a)'));
    expect(source, contains('lineBytes.count <= maximumBytes'));
    final root = File('../codemagic.yaml').readAsStringSync();
    final nested = File('codemagic.yaml').readAsStringSync();
    expect(root, contains('python3 tool/test_ios_tcp_protocol.py'));
    expect(nested, root);
  });
}
