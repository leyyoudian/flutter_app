import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android asset switching drops stale queued requests', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();

    expect(source, contains('AtomicLong'));
    expect(source, contains('switchRequestGeneration.incrementAndGet()'));
    expect(
      source,
      contains('if (generation != switchRequestGeneration.get())'),
    );
    expect(source, contains('SWITCH_TCP_CONNECT_TIMEOUT_MS'));
    expect(source, contains('SWITCH_TCP_RESPONSE_TIMEOUT_MS'));
    expect(source, contains('SwitchResponseTimeoutException'));
    expect(source, contains('SWITCH_SENT'));
    expect(source, contains('SwitchRequestSupersededException'));
    expect(source, contains('SwitchResponseTimeoutException'));
    expect(source, contains('private fun cachedBadgeNetworkForSwitch()'));
    expect(source, contains('badgeWifiNetwork?.let { return it }'));
    expect(
      source,
      isNot(
        contains(
          'activeBadgeHost != BADGE_AP_HOST && isIpv4Address(activeBadgeHost)',
        ),
      ),
    );
    final switchStart = source.indexOf('private fun switchToAsset');
    final switchEnd = source.indexOf('private fun setRandomMode', switchStart);
    final switchSource = source.substring(switchStart, switchEnd);
    expect(switchSource, contains('cachedBadgeNetworkForSwitch()'));
    expect(
      switchSource,
      isNot(contains('activeBadgeNetworkForRequest(fastUpload = true)')),
    );
    expect(source, contains('s.soTimeout = SWITCH_TCP_RESPONSE_TIMEOUT_MS'));
    expect(source, contains('return "SWITCH_SENT"'));
    expect(switchSource, contains('response.startsWith("SWITCH_SENT")'));
    expect(switchSource, contains('catch (_: SocketTimeoutException)'));
    final sendSwitchStart = source.indexOf('private fun sendSwitchCommand(');
    final sendSwitchEnd = source.indexOf(
      'private fun sendRawTcpCommandWithRetry',
      sendSwitchStart,
    );
    expect(
      source.substring(sendSwitchStart, sendSwitchEnd),
      isNot(contains('readLine()')),
    );
    expect(switchSource, contains("result.success(mapOf(\"pending\" to true"));

    final dart = File('lib/main.dart').readAsStringSync();
    expect(dart, contains('int _switchGeneration = 0;'));
    expect(dart, contains('final switchGeneration = ++_switchGeneration;'));
    expect(dart, contains('switchGeneration != _switchGeneration'));
    expect(
      dart,
      contains(
        'if (!mounted || switchGeneration != _switchGeneration) return;',
      ),
    );
    expect(dart, contains('final leavingUserAsset = _asset != null;'));
    expect(dart, contains('if (!leavingUserAsset &&'));
    expect(dart, contains('_activeFactoryId != null'));
    final factorySwitchStart = dart.indexOf('Future<void> _switchToFactory');
    final factorySwitchEnd = dart.indexOf(
      'Future<void> _refreshRandomMode',
      factorySwitchStart,
    );
    final factorySwitchSource = dart.substring(
      factorySwitchStart,
      factorySwitchEnd,
    );
    expect(factorySwitchSource, contains('final dispatchSwitch ='));
    expect(
      factorySwitchSource.indexOf('final dispatchSwitch ='),
      lessThan(factorySwitchSource.indexOf('setState(() {')),
    );
    final historyStart = dart.indexOf('Future<void> _uploadHistoryEntry');
    final historyEnd = dart.indexOf(
      'Future<void> _deleteHistoryEntry',
      historyStart,
    );
    final historySource = dart.substring(historyStart, historyEnd);
    expect(historySource, isNot(contains('await _pendingDeviceDeletesLoad')));
    expect(dart, contains("result is Map && result['pending'] == true"));
    expect(historySource, contains('final dispatchSwitch ='));
    expect(
      historySource.indexOf('final dispatchSwitch ='),
      lessThan(historySource.indexOf('setState(() {')),
    );
  });
}
