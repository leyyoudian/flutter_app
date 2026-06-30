import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android Wi-Fi upload reuses the badge AP connection', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();

    expect(
      source,
      isNot(contains('private fun publishKnownBadgeWifiDevice()')),
    );
    expect(source, isNot(contains('publishKnownBadgeWifiDevice()')));
    expect(source, isNot(contains('"rssi" to 0')));
    expect(source, contains('private fun findExistingBadgeWifiNetwork('));
    expect(source, contains('private fun isBadgeWifiNetworkUsable('));
    expect(source, contains('private fun isCachedBadgeWifiNetworkTransportUsable('));
    expect(source, contains('private fun waitForBadgeStatus('));
    expect(source, contains('private fun isCachedBadgeWifiNetworkUsable('));
    expect(source, contains('private fun isStaleBadgeNetworkError('));
    expect(source, contains('@Volatile private var badgeWifiManagedRequest = false'));
    expect(source, contains('ensureBadgeWifiNetwork(fastUpload = true)'));
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
      lessThan(uploadSource.indexOf('ensureBadgeWifiNetwork(fastUpload = true)')),
    );
    expect(
      uploadSource.indexOf('uploadAssetOverHttp(network, packageInfo)'),
      lessThan(uploadSource.indexOf('uploadAssetOverTcp(network, packageInfo)')),
    );
    expect(uploadSource, contains('if (isStaleBadgeNetworkError(httpError))'));
    expect(uploadSource, contains('if (isStaleBadgeNetworkError(error))'));
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
      contains('if (keepIfConnected && badgeWifiNetwork != null)'),
    );
    expect(source, contains('"已复用 \$BADGE_WIFI_SSID Wi-Fi"'));
    expect(source, contains('message.contains("failed to connect", ignoreCase = true)'));
    expect(source, contains('message.contains("timed out", ignoreCase = true)'));
    expect(source, contains('message.contains("ENETUNREACH", ignoreCase = true)'));
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
      contains('if (fastUpload && isCachedBadgeWifiNetworkTransportUsable(manager, network))'),
    );
    expect(
      ensureSource,
      contains('if (fastUpload && !badgeWifiManagedRequest)'),
    );
    expect(
      ensureSource,
      contains('val status = waitForBadgeStatus(network, UPLOAD_NETWORK_READY_TIMEOUT_MS)'),
    );
    expect(ensureSource, contains('badgeSdAvailable = parseSdAvailable(status)'));
    expect(
      ensureSource,
      contains('if (isCachedBadgeWifiNetworkUsable(manager, network))'),
    );
    expect(ensureSource, contains('releaseBadgeWifi()'));
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
      contains(
        'requestBadgeText(network, BADGE_STATUS_URL, FAST_BADGE_STATUS_TIMEOUT_MS)',
      ),
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
    final service = serviceFile.existsSync() ? serviceFile.readAsStringSync() : '';
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    expect(activity, contains('startUploadKeepAlive()'));
    expect(activity, contains('stopUploadKeepAlive()'));
    expect(activity, contains('UploadKeepAliveService::class.java'));
    expect(manifest, contains('android.permission.FOREGROUND_SERVICE'));
    expect(manifest, contains('android.permission.FOREGROUND_SERVICE_DATA_SYNC'));
    expect(manifest, contains('android:name=".UploadKeepAliveService"'));
    expect(manifest, contains('android:foregroundServiceType="dataSync"'));
    expect(service, contains('startForeground('));
    expect(service, contains('PowerManager.PARTIAL_WAKE_LOCK'));
    expect(service, contains('NotificationChannel'));
  });

  test('Android TCP fallback waits for firmware READY before streaming payload', () {
    final source = File(
      'android/app/src/main/kotlin/com/example/app_gif/MainActivity.kt',
    ).readAsStringSync();

    final tcpStart = source.indexOf('    private fun uploadAssetOverTcp');
    final tcpEnd = source.indexOf('    private fun uploadAssetOverHttp', tcpStart);
    expect(tcpStart, isNot(-1));
    expect(tcpEnd, isNot(-1));
    final tcpSource = source.substring(tcpStart, tcpEnd);

    expect(tcpSource, contains('UPLOAD_TCP_CONNECT_TIMEOUT_MS'));
    expect(tcpSource, contains('UPLOAD_READY_TIMEOUT_MS'));
    expect(tcpSource, contains('output.flush()'));
    expect(tcpSource, contains('val ready = reader.readLine().orEmpty()'));
    expect(tcpSource, contains('!ready.startsWith("READY")'));
    expect(
      tcpSource.indexOf('val ready = reader.readLine().orEmpty()'),
      lessThan(tcpSource.indexOf('streamPackageToOutput(packageInfo, output, "TCP上传")')),
    );
    expect(
      tcpSource.indexOf('active.soTimeout = UPLOAD_READY_TIMEOUT_MS'),
      lessThan(tcpSource.indexOf('val ready = reader.readLine().orEmpty()')),
    );
    expect(
      tcpSource.indexOf('active.soTimeout = HTTP_READ_TIMEOUT_MS'),
      lessThan(tcpSource.indexOf('streamPackageToOutput(packageInfo, output, "TCP上传")')),
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
    expect(source, contains('private const val UPLOAD_IO_CHUNK_BYTES = 256 * 1024'));
    expect(
      source,
      contains(
        'private fun uploadAssetOverTcp(network: Network, packageInfo: UploadPackageInfo)',
      ),
    );
    expect(source, contains('writeLe32(header, 4, packageInfo.size.toLong())'));
    expect(
      source,
      contains(
        'private fun uploadAssetOverHttp(network: Network, packageInfo: UploadPackageInfo)',
      ),
    );
    final httpStart = source.indexOf(
      '    private fun uploadAssetOverHttp(network: Network, packageInfo: UploadPackageInfo)',
    );
    final httpEnd = source.indexOf('    private fun streamPackageToOutput', httpStart);
    expect(httpStart, isNot(-1));
    expect(httpEnd, isNot(-1));
    final httpSource = source.substring(httpStart, httpEnd);
    expect(httpSource, contains('network.openConnection(url) as HttpURLConnection'));
    expect(httpSource, contains('connection.setFixedLengthStreamingMode(packageInfo.size.toInt())'));
    expect(httpSource, contains('BufferedOutputStream(connection.outputStream, UPLOAD_IO_CHUNK_BYTES)'));
    expect(httpSource, isNot(contains('network.socketFactory.createSocket() as Socket')));
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
