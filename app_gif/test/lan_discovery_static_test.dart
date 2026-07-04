import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Android native layer discovers badge on the current LAN before AP fallback',
    () {
      final source = File(
        'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
      ).readAsStringSync();

      expect(
        source,
        contains('@Volatile private var activeBadgeHost = BADGE_AP_HOST'),
      );
      expect(
        source,
        contains(
          'private fun badgeUrl(path: String, host: String = activeBadgeHost): String',
        ),
      );
      expect(source, contains('private fun discoverBadgeOnLan('));
      expect(
        source,
        contains(
          'private fun probeBadgeHost(network: Network, host: String): DiscoveredBadge?',
        ),
      );
      expect(
        source,
        contains('private fun isBadgeStatusText(status: String): Boolean'),
      );
      expect(source, contains('private fun publishLanBadgeScanResult()'));
      expect(source, contains('private data class DiscoveredBadge'));
      expect(source, contains('setActiveBadgeHost(discovered.host)'));
      expect(source, contains('connectedAddress = activeBadgeHost'));
      expect(source, contains('URL(badgeUrl("/upload"))'));
      expect(source, contains('badgeUrl("/status")'));
      expect(source, contains('badgeUrl("/brightness")'));
      expect(
        source,
        contains('InetSocketAddress(activeBadgeHost, BADGE_UPLOAD_TCP_PORT)'),
      );
      expect(
        source,
        contains('private const val BADGE_AP_HOST = "192.168.4.1"'),
      );
      expect(
        source,
        isNot(contains('private const val BADGE_HOST = "192.168.4.1"')),
      );
      expect(
        source,
        isNot(
          contains(
            'private const val BADGE_STATUS_URL = "http://192.168.4.1/status"',
          ),
        ),
      );
      expect(
        source,
        isNot(
          contains(
            'private const val BADGE_UPLOAD_URL = "http://192.168.4.1/upload"',
          ),
        ),
      );
    },
  );

  test(
    'iOS native layer discovers badge on the current LAN before AP fallback',
    () {
      final source = File('ios/Runner/AppDelegate.swift').readAsStringSync();

      expect(
        source,
        contains('private var activeBadgeHost = BadgeConstants.badgeApHost'),
      );
      expect(
        source,
        contains(
          'private func badgeUrl(_ path: String, host: String? = nil) -> String',
        ),
      );
      expect(
        source,
        contains('private func discoverBadgeOnLan() -> DiscoveredBadge?'),
      );
      expect(
        source,
        contains(
          'private func probeBadgeHost(_ host: String) -> DiscoveredBadge?',
        ),
      );
      expect(
        source,
        contains('private func isBadgeStatusText(_ status: String) -> Bool'),
      );
      expect(source, contains('private func publishLanBadgeScanResult()'));
      expect(source, contains('private struct DiscoveredBadge'));
      expect(source, contains('setActiveBadgeHost(discovered.host)'));
      expect(source, contains('connectedAddress = activeBadgeHost'));
      expect(source, contains('URL(string: badgeUrl("/upload"))'));
      expect(source, contains('NWEndpoint.Host(activeBadgeHost)'));
      expect(source, contains('static let badgeApHost = "192.168.4.1"'));
      expect(source, isNot(contains('static let badgeHost = "192.168.4.1"')));
      expect(
        source,
        isNot(
          contains('static let badgeStatusUrl = "http://192.168.4.1/status"'),
        ),
      );
      expect(
        source,
        isNot(
          contains('static let badgeUploadUrl = "http://192.168.4.1/upload"'),
        ),
      );
    },
  );
}
