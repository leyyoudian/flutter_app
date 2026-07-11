import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android Wi-Fi upload reuses LAN or badge AP connection', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();

    expect(
      source,
      isNot(contains('private fun publishKnownBadgeWifiDevice()')),
    );
    expect(source, isNot(contains('publishKnownBadgeWifiDevice()')));
    expect(source, contains('private fun publishLanBadgeScanResult()'));
    expect(source, contains('"name" to "\$BADGE_DEVICE_NAME LAN"'));
    expect(source, contains('"rssi" to 0'));
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
    expect(source, contains('private fun findExistingBadgeWifiNetwork('));
    expect(source, contains('private fun isBadgeWifiNetworkUsable('));
    expect(
      source,
      contains('private fun isCachedBadgeWifiNetworkTransportUsable('),
    );
    expect(source, contains('private fun waitForBadgeStatus('));
    expect(source, contains('private fun isCachedBadgeWifiNetworkUsable('));
    expect(source, contains('private fun isStaleBadgeNetworkError('));
    expect(
      source,
      contains('@Volatile private var badgeWifiManagedRequest = false'),
    );
    expect(source, contains('activeBadgeNetworkForRequest(fastUpload = true)'));
    expect(source, contains('UPLOAD_NETWORK_READY_TIMEOUT_MS'));
    expect(source, contains('findExistingBadgeWifiNetwork(manager)?.let'));
    expect(
      source,
      contains('private fun bindBadgeWifiNetwork(network: Network)'),
    );
    expect(source, contains('bindBadgeWifiNetwork(network)'));
    expect(source, contains('@Synchronized'));
    expect(source, contains('private const val HTTP_UPLOAD_ATTEMPTS = 2'));

    final scanStart = source.indexOf('    private fun publishWifiScanResults');
    final scanEnd = source.indexOf('    private val scanCallback', scanStart);
    expect(scanStart, isNot(-1));
    expect(scanEnd, isNot(-1));
    final scanSource = source.substring(scanStart, scanEnd);

    expect(scanSource, contains('"address" to ssid'));
    expect(scanSource, contains('scanResults[ssid] = device'));
    expect(scanSource, isNot(contains('result.BSSID ?: ssid')));

    final uploadStart = source.indexOf('    private fun uploadAssetWithRetry');
    final uploadEnd = source.indexOf(
      '    private fun bindBadgeWifiNetwork',
      uploadStart,
    );
    expect(uploadStart, isNot(-1));
    expect(uploadEnd, isNot(-1));
    final uploadSource = source.substring(uploadStart, uploadEnd);

    expect(
      uploadSource.indexOf('acquireUploadWifiLock()'),
      lessThan(
        uploadSource.indexOf('activeBadgeNetworkForRequest(fastUpload = true)'),
      ),
    );
    expect(
      uploadSource.indexOf('uploadAssetOverTcp(network, packageInfo)'),
      lessThan(
        uploadSource.indexOf('uploadAssetOverHttp(network, packageInfo)'),
      ),
    );
    expect(uploadSource, contains('if (isStaleBadgeNetworkError(tcpError))'));
    expect(uploadSource, contains('if (isStaleBadgeNetworkError(error) && !badgeDirectIpMode)'));
    expect(
      uploadSource,
      contains('releaseUploadWifiLock(keepIfConnected = true)'),
    );
    expect(uploadSource, isNot(contains('bindProcessToNetwork(null)')));
    expect(
      source,
      contains('connectivityManager().bindProcessToNetwork(null)'),
    );
    expect(source, contains('releaseUploadWifiLock(keepIfConnected = false)'));
    expect(
      source,
      contains('if (keepIfConnected && (badgeWifiNetwork != null || badgeDirectIpMode))'),
    );
    expect(source, contains('"已复用 \$BADGE_WIFI_SSID Wi-Fi"'));
    expect(
      source,
      contains('message.contains("failed to connect", ignoreCase = true)'),
    );
    expect(
      source,
      contains('message.contains("timed out", ignoreCase = true)'),
    );
    expect(
      source,
      contains('message.contains("ENETUNREACH", ignoreCase = true)'),
    );
    expect(source, isNot(contains('WebSocket')));

    final ensureStart = source.indexOf(
      '    private fun ensureBadgeWifiNetwork',
    );
    final ensureEnd = source.indexOf(
      '    private fun findExistingBadgeWifiNetwork',
      ensureStart,
    );
    expect(ensureStart, isNot(-1));
    expect(ensureEnd, isNot(-1));
    final ensureSource = source.substring(ensureStart, ensureEnd);
    expect(
      ensureSource,
      contains(
        'reuseBadgeNetworkIfReachable(manager, activeNetwork, "已复用 \$BADGE_WIFI_SSID Wi-Fi")',
      ),
    );
    expect(
      ensureSource,
      contains('if (fastUpload && !badgeWifiManagedRequest)'),
    );
    expect(
      ensureSource,
      contains(
        'reuseBadgeNetworkIfReachable(manager, network, "已复用 \$BADGE_WIFI_SSID Wi-Fi")',
      ),
    );
    expect(
      ensureSource,
      contains(
        'val status = waitForBadgeStatus(network, UPLOAD_NETWORK_READY_TIMEOUT_MS)',
      ),
    );
    expect(
      ensureSource,
      contains('badgeSdAvailable = parseSdAvailable(status)'),
    );
    expect(ensureSource, contains('releaseBadgeWifi()'));
    expect(ensureSource, contains('setActiveBadgeHost(BADGE_AP_HOST)'));
    expect(ensureSource, contains('badgeWifiManagedRequest = true'));
    expect(source, contains('connectedAddress = null'));
    expect(source, contains('badgeSdAvailable = false'));
    expect(source, contains('sendConnectionEvent(false, false, null, "连接断开")'));

    final cachedStart = source.indexOf(
      '    private fun isCachedBadgeWifiNetworkUsable',
    );
    final cachedEnd = source.indexOf(
      '    private fun isBadgeWifiNetworkUsable',
      cachedStart,
    );
    expect(cachedStart, isNot(-1));
    expect(cachedEnd, isNot(-1));
    final cachedSource = source.substring(cachedStart, cachedEnd);
    expect(
      cachedSource,
      contains('return resolveBadgeOnNetwork(manager, network) != null'),
    );
    expect(
      cachedSource,
      isNot(
        contains(
          'return capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)',
        ),
      ),
    );
  });

  test('Android upload runs as a foreground keepalive session', () {
    final activity = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();
    final serviceFile = File(
      'android/app/src/main/kotlin/com/example/app_gif/UploadKeepAliveService.kt',
    );
    expect(serviceFile.existsSync(), isTrue);
    final service = serviceFile.existsSync()
        ? serviceFile.readAsStringSync()
        : '';
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(activity, contains('startUploadKeepAlive()'));
    expect(activity, contains('stopUploadKeepAlive()'));
    expect(activity, contains('UploadKeepAliveService::class.java'));
    expect(manifest, contains('android.permission.FOREGROUND_SERVICE'));
    expect(
      manifest,
      contains('android.permission.FOREGROUND_SERVICE_DATA_SYNC'),
    );
    expect(manifest, contains('android:name=".UploadKeepAliveService"'));
    expect(manifest, contains('android:foregroundServiceType="dataSync"'));
    expect(service, contains('startForeground('));
    expect(service, contains('PowerManager.PARTIAL_WAKE_LOCK'));
    expect(service, contains('NotificationChannel'));
  });

  test(
    'Android TCP fallback waits for firmware READY before streaming payload',
    () {
      final source = File(
        'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
      ).readAsStringSync();

      final tcpStart = source.indexOf('    private fun uploadAssetOverTcp');
      final tcpEnd = source.indexOf(
        '    private fun uploadAssetOverHttp',
        tcpStart,
      );
      expect(tcpStart, isNot(-1));
      expect(tcpEnd, isNot(-1));
      final tcpSource = source.substring(tcpStart, tcpEnd);

      expect(tcpSource, contains('UPLOAD_TCP_CONNECT_TIMEOUT_MS'));
      expect(tcpSource, contains('UPLOAD_READY_TIMEOUT_MS'));
      expect(tcpSource, contains('sockOut.flush()'));
      expect(tcpSource, contains('val ready = reader.readLine().orEmpty()'));
      expect(tcpSource, contains('!ready.startsWith("READY")'));
      expect(
        tcpSource.indexOf('val ready = reader.readLine().orEmpty()'),
        lessThan(
          tcpSource.indexOf(
            'streamPackageToOutput(packageInfo, sockOut, "TCP上传")',
          ),
        ),
      );
      expect(
        tcpSource.indexOf('active.soTimeout = UPLOAD_READY_TIMEOUT_MS'),
        lessThan(tcpSource.indexOf('val ready = reader.readLine().orEmpty()')),
      );
      expect(
        tcpSource.indexOf('active.soTimeout = HTTP_READ_TIMEOUT_MS'),
        lessThan(
          tcpSource.indexOf(
            'streamPackageToOutput(packageInfo, sockOut, "TCP上传")',
          ),
        ),
      );
    },
  );

  test('Android switch commands tolerate transient TCP connect stalls', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();

    final constantsStart = source.indexOf('    companion object');
    expect(constantsStart, isNot(-1));
    final constantsSource = source.substring(constantsStart);
    expect(
      constantsSource,
      contains('private const val UPLOAD_TCP_CONNECT_TIMEOUT_MS = 6000'),
    );
    expect(
      constantsSource,
      contains('private const val SWITCH_TCP_ATTEMPTS = 6'),
    );
    expect(
      constantsSource,
      contains('private const val SWITCH_TCP_RETRY_DELAY_MS = 1000L'),
    );

    final switchStart = source.indexOf('    private fun switchToAsset');
    final switchEnd = source.indexOf(
      '    private fun requestNewUserId',
      switchStart,
    );
    expect(switchStart, isNot(-1));
    expect(switchEnd, isNot(-1));
    final switchSource = source.substring(switchStart, switchEnd);

    expect(switchSource, contains('sendSwitchCommandWithRetry(network, id)'));
    expect(switchSource, isNot(contains(', 2500)')));

    final requestIdStart = source.indexOf('    private fun requestNewUserId');
    final requestIdEnd = source.indexOf(
      '    private fun buildFactoryAnimationList',
      requestIdStart,
    );
    expect(requestIdStart, isNot(-1));
    expect(requestIdEnd, isNot(-1));
    final requestIdSource = source.substring(requestIdStart, requestIdEnd);
    expect(
      requestIdSource,
      contains('sendSwitchCommandWithRetry(network, "NEWID")'),
    );

    final retryStart = source.indexOf('    private fun sendSwitchCommandWithRetry');
    final retryEnd = source.indexOf('    private fun sendSwitchCommand', retryStart + 1);
    expect(retryStart, isNot(-1));
    expect(retryEnd, isNot(-1));
    final retrySource = source.substring(retryStart, retryEnd);
    expect(retrySource, contains('repeat(SWITCH_TCP_ATTEMPTS)'));
    expect(retrySource, contains('Thread.sleep(SWITCH_TCP_RETRY_DELAY_MS)'));
  });

  test('Android connects discovered LAN IPs without opening the system Wi-Fi picker', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();

    final connectStart = source.indexOf('    private fun connect(address: String)');
    final connectEnd = source.indexOf('    @SuppressLint("MissingPermission")\n    private fun disconnect()', connectStart);
    expect(connectStart, isNot(-1));
    expect(connectEnd, isNot(-1));
    final connectSource = source.substring(connectStart, connectEnd);

    expect(connectSource, contains('waitForDirectBadge(address)'));
    expect(connectSource, contains('return@Thread'));

    final ipv4Branch = connectSource.substring(
      connectSource.indexOf('if (isIpv4Address(address))'),
      connectSource.indexOf('val network = ensureBadgeWifiNetwork()'),
    );
    expect(ipv4Branch, isNot(contains('ensureBadgeWifiNetwork')));
    expect(ipv4Branch, contains('badgeDirectIpMode = true'));
    expect(ipv4Branch, contains('rememberDiscoveredBadge(direct, directIpMode = true)'));

    expect(
      source,
      contains('private fun waitForDirectBadge(host: String): DiscoveredBadge'),
    );
    final directStart = source.indexOf('    private fun waitForDirectBadge');
    final directEnd = source.indexOf('    private fun probeBadgeHost', directStart);
    expect(directStart, isNot(-1));
    expect(directEnd, isNot(-1));
    final directSource = source.substring(directStart, directEnd);
    expect(directSource, contains('requestBadgeText(null, badgeUrl("/status", host), FAST_BADGE_STATUS_TIMEOUT_MS)'));
    expect(directSource, contains('DIRECT_BADGE_CONNECT_TIMEOUT_MS'));
    expect(directSource, isNot(contains('ensureBadgeWifiNetwork')));
    expect(directSource, isNot(contains('requestNetwork')));
  });

  test('Android connection state keeps LAN session through short status misses', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();

    expect(source, contains('@Volatile private var connectionStatusMisses = 0'));
    expect(source, contains('private const val CONNECTION_STATUS_MISS_LIMIT = 3'));

    final readStart = source.indexOf('    private fun readConnectionState');
    final readEnd = source.indexOf(
      '    private fun sendConnectionEvent',
      readStart,
    );
    expect(readStart, isNot(-1));
    expect(readEnd, isNot(-1));
    final readSource = source.substring(readStart, readEnd);

    expect(readSource, contains('connectionStatusMisses = 0'));
    expect(readSource, contains('connectionStatusMisses += 1'));
    expect(readSource, contains('if (connectionStatusMisses < CONNECTION_STATUS_MISS_LIMIT)'));
    expect(readSource, contains('"连接检查重试中"'));
    expect(
      readSource.indexOf('if (connectionStatusMisses < CONNECTION_STATUS_MISS_LIMIT)'),
      lessThan(readSource.indexOf('connectedAddress = null')),
    );
  });

  test('Android upload streams packages from disk without whole-file buffers', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();

    final uploadStart = source.indexOf('    private fun uploadAsset(');
    final uploadEnd = source.indexOf(
      '    private fun validatePackageForUpload',
      uploadStart,
    );
    expect(uploadStart, isNot(-1));
    expect(uploadEnd, isNot(-1));
    final uploadSource = source.substring(uploadStart, uploadEnd);

    expect(uploadSource, contains('preparePackageForUpload(file)'));
    expect(uploadSource, isNot(contains('file.readBytes()')));
    expect(source, contains('private data class UploadPackageInfo'));
    expect(
      source,
      contains(
        'private fun preparePackageForUpload(file: File): UploadPackageInfo',
      ),
    );
    expect(source, contains('private fun streamPackageToOutput('));
    expect(source, contains('FileInputStream(packageInfo.file).use'));
    expect(
      source,
      contains('private const val UPLOAD_IO_CHUNK_BYTES = 256 * 1024'),
    );
    expect(
      source,
      contains(
        'private fun uploadAssetOverTcp(network: Network?, packageInfo: UploadPackageInfo)',
      ),
    );
    expect(source, contains('writeLe32(header, 4, packageInfo.size.toLong())'));
    expect(
      source,
      contains(
        'private fun uploadAssetOverHttp(network: Network?, packageInfo: UploadPackageInfo)',
      ),
    );
    final httpStart = source.indexOf(
      '    private fun uploadAssetOverHttp(network: Network?, packageInfo: UploadPackageInfo)',
    );
    final httpEnd = source.indexOf(
      '    private fun streamPackageToOutput',
      httpStart,
    );
    expect(httpStart, isNot(-1));
    expect(httpEnd, isNot(-1));
    final httpSource = source.substring(httpStart, httpEnd);
    expect(
      httpSource,
      contains('(network?.openConnection(url) ?: url.openConnection()) as HttpURLConnection'),
    );
    expect(
      httpSource,
      contains(
        'connection.setFixedLengthStreamingMode(packageInfo.size.toInt())',
      ),
    );
    expect(
      httpSource,
      contains(
        'BufferedOutputStream(connection.outputStream, UPLOAD_IO_CHUNK_BYTES)',
      ),
    );
    expect(
      httpSource,
      isNot(contains('network.socketFactory.createSocket() as Socket')),
    );
    expect(httpSource, isNot(contains('"POST /upload HTTP/1.1\\r\\n"')));
  });

  test('Android upload avoids UI churn and startup repair work', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();

    expect(
      source,
      contains('private const val UPLOAD_PROGRESS_STEP_BYTES = 512 * 1024L'),
    );
    expect(source, contains('if (isUploading) {'));
    expect(source, contains('return@Thread'));

    final loadStart = source.indexOf('    private fun loadAndRepairHistory');
    final loadEnd = source.indexOf('    private fun historyMap', loadStart);
    expect(loadStart, isNot(-1));
    expect(loadEnd, isNot(-1));
    final loadSource = source.substring(loadStart, loadEnd);

    expect(loadSource, isNot(contains('repairHistoryItem')));
    expect(loadSource, isNot(contains('EbajEncoder')));
    expect(loadSource, isNot(contains('buildVideoAnimatedPreview')));
  });
}
