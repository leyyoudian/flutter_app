import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'factory_catalog_sync.dart';
import 'preview_player.dart';
import 'device_asset_delete.dart';
import 'device_control.dart';
import 'transcode_policy.dart';
import 'backend_failover.dart';
import 'calibration.dart';
import 'reference_ui.dart';
import 'app_language.dart';
import 'fly_bird.dart';
import 'firmware_update.dart';
import 'p4_asset_target.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(LanguageSettings.load());
  runApp(const BadgeApp());
}

class BadgeApp extends StatelessWidget {
  const BadgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    const scheme = ColorScheme.dark(
      primary: Colors.white,
      onPrimary: Colors.black,
      surface: Color(0xff111111),
      onSurface: Colors.white,
    );

    return ValueListenableBuilder<AppLanguage>(
      valueListenable: LanguageSettings.current,
      builder: (context, language, child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: language == AppLanguage.system
            ? null
            : LanguageSettings.localeFor(language),
        supportedLocales: const [
          Locale('en'),
          Locale('zh', 'CN'),
          Locale('zh', 'TW'),
          Locale('ja'),
          Locale('ru'),
        ],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        localeResolutionCallback: (locale, supported) =>
            LanguageSettings.localeFor(
              language == AppLanguage.system
                  ? LanguageSettings.resolve(locale ?? const Locale('en'))
                  : language,
            ),
        title: 'ESP Baji',
        theme: ThemeData(
          useMaterial3: true,
          platform: TargetPlatform.android,
          brightness: Brightness.dark,
          colorScheme: scheme,
          fontFamily: 'Roboto',
          scaffoldBackgroundColor: Colors.black,
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          sliderTheme: SliderThemeData(
            activeTrackColor: Colors.white,
            inactiveTrackColor: Colors.white.withValues(alpha: 0.18),
            thumbColor: Colors.white,
            overlayColor: Colors.white.withValues(alpha: 0.12),
          ),
        ),
        home: const BadgeHomePage(),
      ),
    );
  }
}

class BadgeHomePage extends StatefulWidget {
  const BadgeHomePage({super.key});

  @override
  State<BadgeHomePage> createState() => _BadgeHomePageState();
}

class _BadgeHomePageState extends State<BadgeHomePage>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('esp_baji/native');
  static const _privacyPolicyUrl =
      'https://leyyoudian.github.io/flutter_app/privacy.html';
  static const _backendBaseOverride = String.fromEnvironment(
    'ESP_BAJI_API_BASE',
    defaultValue: '',
  );
  static const _appVersion = '1.0.32';

  final List<BadgeDevice> _devices = [];
  final List<HistoryEntry> _history = [];
  Timer? _brightnessTimer;
  Timer? _connectionTimer;
  final Map<String, Completer<String?>> _assetPreviewWaiters = {};
  int _pageIndex = 1;
  int _libraryFilter = 0;
  int _alignmentAngleTenths = 0;
  int _brightness = 70;
  bool _scanning = false;
  bool _connecting = false;
  bool _connected = false;
  bool _bluetoothControl = false;
  String? _deviceFirmwareVersion;
  String? _deviceFirmwareHardware;
  FirmwareManifest? _firmwareManifest;
  Future<FirmwareManifest>? _firmwareCheck;
  DateTime? _firmwareCheckedAt;
  int _firmwareSession = 0;
  late final _deviceControl = DeviceControl((command) async {
    final reply = await _channel.invokeMethod<String>(
      'deviceBluetoothCommand',
      {'command': command},
    );
    if (reply == null) {
      throw PlatformException(
        code: 'bluetooth_disconnected',
        message: '设备未返回蓝牙响应',
      );
    }
    return reply;
  });
  bool _sdAvailable = false;
  bool _preparing = false;
  bool _uploading = false;
  bool _appActive = true;
  bool _demoMode = false;
  bool _checkingVersion = false;
  bool _reviewRefreshInFlight = false;
  bool _randomEnabled = false;
  bool _randomUpdating = false;
  int _randomOperationGeneration = 0;
  bool _pendingDeviceDeletesLoaded = false;
  Completer<void>? _deviceDeleteSync;
  Future<void>? _pendingDeviceDeletesLoad;
  double _prepareProgress = 0;
  double _uploadProgress = 0;
  String _status = '未连接';
  String? _connectedAddress;
  String _connectedHardware = 'esp32p4';
  SelectedMedia? _media;
  PreparedAsset? _asset;
  CropTransform _cropTransform = const CropTransform();
  String _draftAssetName = '';
  List<FactoryAnimation> _factoryAnims = [];
  final List<PendingDeviceDeletion> _pendingDeviceDeletes = [];
  String? _connectedDeviceKey;
  String? _selectedFactoryId;
  String? _activeFactoryId; // currently playing on dial
  List<String> _videoQueue = []; // pending video sequence
  int _videoIndex = 0;
  int _switchGeneration = 0;

  bool get _previewActive => _appActive && !_preparing;
  bool get _firmwareUpdateAvailable =>
      _connected &&
      _bluetoothControl &&
      !_demoMode &&
      _deviceFirmwareVersion != null &&
      _firmwareManifest != null &&
      firmwareIsOlder(_deviceFirmwareVersion!, _firmwareManifest!.version);
  bool get _hasPendingReviewStatuses => _history.any(
    (entry) =>
        entry.reviewId != null &&
        entry.reviewStatus != 'approved' &&
        entry.reviewStatus != 'rejected',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler(_handleNativeCall);
    unawaited(_loadHistory());
    _pendingDeviceDeletesLoad = _loadPendingDeviceDeletes();
    unawaited(_refreshConnectionState());
    unawaited(_loadFactoryAnimations());
    unawaited(_checkRemoteVersion());
    _restartConnectionTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _brightnessTimer?.cancel();
    _connectionTimer?.cancel();
    for (final waiter in _assetPreviewWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.complete(null);
      }
    }
    _assetPreviewWaiters.clear();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final appActive = state == AppLifecycleState.resumed;
    if (_appActive == appActive) {
      return;
    }
    setState(() => _appActive = appActive);
    _restartConnectionTimer();
    if (appActive) {
      unawaited(_refreshConnectionState());
      unawaited(_refreshHistoryReviewStatuses());
      unawaited(_refreshFirmwareAvailability(force: true));
    }
  }

  void _restartConnectionTimer() {
    _connectionTimer?.cancel();
    _connectionTimer = null;
    if (!_appActive) {
      return;
    }
    _connectionTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_appActive || _preparing || _uploading) {
        return;
      }
      if (_hasPendingReviewStatuses) {
        unawaited(_refreshHistoryReviewStatuses());
      }
      if (_connected || _connecting) {
        unawaited(_refreshConnectionState());
      }
    });
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'nativeEvent') {
      return;
    }
    final event = _asStringMap(call.arguments);
    switch (event['type']) {
      case 'scanState':
        setState(() => _scanning = event['scanning'] == true);
        break;
      case 'scanResult':
        final device = BadgeDevice.fromMap(_asStringMap(event['device']));
        final index = _devices.indexWhere(
          (item) => item.address == device.address,
        );
        setState(() {
          if (index >= 0) {
            _devices[index] = device;
          } else {
            _devices.add(device);
          }
          _devices.sort((a, b) => b.rssi.compareTo(a.rssi));
        });
        break;
      case 'connectionState':
        if (_bluetoothControl) {
          break; // AP bulk transport is not the control connection.
        }
        final wasConnected = _connected;
        final previousHardware = _connectedHardware;
        setState(() {
          if (event['connected'] != true ||
              _connectedAddress != event['address']) {
            _connectedDeviceKey = null;
          }
          _connected = event['connected'] == true;
          _connecting = event['connecting'] == true;
          _sdAvailable = event['sdAvailable'] == true;
          _connectedAddress = event['address'] as String?;
          _connectedHardware = _normalizeHardware(event['hardware']);
          _status =
              (event['message'] as String?) ?? (_connected ? '已连接' : '未连接');
        });
        if (_connected && !wasConnected) {
          unawaited(_refreshAlignmentAngle());
          unawaited(_refreshRandomMode());
          unawaited(_reconcilePendingDeviceDeletes());
        }
        if (_connected && previousHardware != _connectedHardware) {
          unawaited(_loadFactoryAnimations());
        }
        break;
      case 'status':
        setState(() => _status = (event['message'] as String?) ?? _status);
        break;
      case 'prepareProgress':
        setState(() => _prepareProgress = _readDouble(event['progress']));
        break;
      case 'uploadProgress':
        setState(() {
          _uploadProgress = _readDouble(event['progress']);
          _status = (event['message'] as String?) ?? _status;
        });
        break;
      case 'videoPreviewReady':
        final warmPreviewPath = _readNullableString(
          event['animatedPreviewPath'],
        );
        if (event['uri'] == _media?.uri && _hasPreviewPath(warmPreviewPath)) {
          setState(() {
            _media = _media?.copyWith(animatedPreviewPath: warmPreviewPath);
          });
        }
        break;
      case 'assetPreviewReady':
        final assetPreviewPath = _readNullableString(
          event['animatedPreviewPath'],
        );
        final uri = event['uri'] as String?;
        final assetPath = event['assetPath'] as String?;
        if (_hasPreviewPath(assetPreviewPath)) {
          final waiter = assetPath == null
              ? null
              : _assetPreviewWaiters.remove(assetPath);
          if (waiter != null && !waiter.isCompleted) {
            waiter.complete(assetPreviewPath);
          }
          setState(() {
            if (_asset?.assetPath == assetPath) {
              _asset = _asset?.copyWith(animatedPreviewPath: assetPreviewPath);
            }
            for (var index = 0; index < _history.length; index++) {
              final entry = _history[index];
              if (entry.assetPath == assetPath ||
                  (assetPath == null && entry.sourceUri == uri)) {
                _history[index] = entry.copyWith(
                  animatedPreviewPath: assetPreviewPath,
                );
                break;
              }
            }
          });
          unawaited(_saveHistory());
        }
        break;
    }
  }

  Future<void> _loadHistory() async {
    final result = await _invokeNative<List<dynamic>>('loadHistory');
    if (!mounted || result == null) {
      return;
    }
    setState(() {
      _history
        ..clear()
        ..addAll(
          result.map((item) => HistoryEntry.fromMap(_asStringMap(item))),
        );
    });
    unawaited(_refreshHistoryReviewStatuses());
  }

  Future<void> _loadFactoryAnimations() async {
    final builtIn = <Map<String, dynamic>>[];
    try {
      final jsonStr = await DefaultAssetBundle.of(
        context,
      ).loadString('assets/factory_previews/manifest.json');
      final list = json.decode(jsonStr) as List<dynamic>;
      builtIn.addAll(list.map((item) => _asStringMap(item)));
      if (!mounted) return;
      setState(() {
        _factoryAnims = builtIn
            .map((item) => FactoryAnimation.fromMap(_asStringMap(item)))
            .toList();
        if (_asset == null &&
            _selectedFactoryId == null &&
            _factoryAnims.isNotEmpty) {
          _selectedFactoryId = _factoryAnims.first.id;
          final video =
              _factoryAnims.first.firstVideo ?? _factoryAnims.first.loopVideo;
          _videoQueue = video == null ? [] : [video];
          _videoIndex = 0;
        }
      });
    } catch (_) {
      // Fallback: manifest not found, leave empty
    }
    try {
      final cacheRoot = await _invokeNative<String>('factoryCacheRoot');
      if (cacheRoot == null || cacheRoot.isEmpty) {
        return;
      }
      final synced = await FactoryCatalogSync.syncOnce(
        backendBases: _backendBases,
        cacheRoot: Directory(cacheRoot),
        builtIn: builtIn,
        hardware: _connectedHardware,
      );
      if (!mounted) return;
      setState(() {
        _factoryAnims = synced
            .map((item) => FactoryAnimation.fromMap(_asStringMap(item)))
            .toList();
      });
    } catch (_) {
      // Network/cache failures should not block built-in factory animations.
    }
  }

  Future<void> _switchToFactory(FactoryAnimation anim) async {
    final switchGeneration = ++_switchGeneration;
    // The device switches from a user asset directly to the factory first
    // half; there is no factory exit animation to preview in that case.
    final leavingUserAsset = _asset != null;
    // Build video sequence: current exit/third_half + target entrance.
    final queue = <String>[];
    bool isThirdHalf = false;
    final targetIsLoop = anim.isLoop;
    if (!leavingUserAsset &&
        _activeFactoryId != null &&
        _activeFactoryId != anim.id) {
      final current = _factoryAnims.cast<FactoryAnimation?>().firstWhere(
        (a) => a?.id == _activeFactoryId,
        orElse: () => null,
      );
      if (current?.isLoop != true && !targetIsLoop) {
        isThirdHalf = current?.transitions.containsKey(anim.id) ?? false;
        final exitVid = current?.exitVideo(anim.id);
        if (exitVid != null) queue.add(exitVid);
      }
    }
    // Third_half replaces both exit and entrance — skip target first_half
    if (targetIsLoop) {
      if (anim.loopVideo != null) queue.add(anim.loopVideo!);
    } else if (!isThirdHalf && anim.firstVideo != null) {
      queue.add(anim.firstVideo!);
    }

    // Dispatch the device command before rebuilding the video preview.  The
    // preview can tear down/create video controllers and hold the Flutter
    // event loop long enough to make the physical switch feel delayed.
    final dispatchSwitch = !_demoMode && _connected
        ? _invokeNative<dynamic>('switchToAsset', {'id': anim.id})
        : null;
    setState(() {
      _selectedFactoryId = anim.id;
      _asset = null;
      _videoQueue = queue;
      _videoIndex = 0;
      _activeFactoryId = anim.id;
    });
    if (_demoMode) {
      setState(() => _status = '演示切换 ${anim.name}');
      return;
    }
    // Send switch command to device
    if (dispatchSwitch == null) return;
    setState(() => _status = '切换中...');
    try {
      final result = await dispatchSwitch;
      if (!mounted || switchGeneration != _switchGeneration) return;
      if (result == true) {
        setState(() => _status = '已切换');
      } else if (result is Map && result['pending'] == true) {
        // The device accepts SWITCH before its exit/entry animation completes.
        // Treat the accepted command as success so a slow animation does not
        // surface as a false timeout in the app.
        setState(() => _status = '切换已提交');
      } else if (result is Map && result['needsUpload'] == true) {
        _showSnack('设备缺少该素材，需先上传');
        setState(() => _status = '素材缺失');
      }
    } catch (e) {
      if (!mounted || switchGeneration != _switchGeneration) return;
      _showSnack('切换失败: $e');
    }
  }

  Future<void> _refreshRandomMode() async {
    if (_demoMode || !_connected || _randomUpdating) {
      return;
    }
    final refreshGeneration = ++_randomOperationGeneration;
    try {
      final enabled = await _invokeNative<bool>('getRandomMode');
      if (!mounted ||
          enabled == null ||
          _randomUpdating ||
          refreshGeneration != _randomOperationGeneration) {
        return;
      }
      setState(() => _randomEnabled = enabled);
    } catch (_) {
      // Keep the current UI state if the device is temporarily unreachable.
    }
  }

  Future<void> _setRandomMode(bool enabled) async {
    if (_demoMode) {
      setState(() {
        _randomEnabled = enabled;
        _status = enabled ? '随机播放' : '顺序播放';
      });
      return;
    }
    if (!_connected) {
      _showSnack('请先连接设备');
      return;
    }
    if (_randomUpdating) {
      return;
    }
    final previous = _randomEnabled;
    final operationGeneration = ++_randomOperationGeneration;
    setState(() {
      _randomUpdating = true;
      _randomEnabled = enabled;
      _status = enabled ? '随机播放' : '顺序播放';
    });
    try {
      final deviceEnabled = await _invokeNative<bool>('setRandomMode', {
        'enabled': enabled,
      });
      if (!mounted) return;
      if (deviceEnabled != null &&
          operationGeneration == _randomOperationGeneration) {
        setState(() => _randomEnabled = deviceEnabled);
      }
    } catch (e) {
      if (!mounted) return;
      if (operationGeneration == _randomOperationGeneration) {
        setState(() => _randomEnabled = previous);
      }
      _showSnack('随机播放设置失败: $e');
    } finally {
      if (mounted) {
        setState(() => _randomUpdating = false);
      }
    }
  }

  Future<void> _saveHistory() async {
    await _invokeNative<void>(
      'saveHistory',
      _history.map((entry) => entry.toMap()).toList(),
    );
  }

  Future<void> _loadPendingDeviceDeletes() async {
    final result = await _invokeNative<List<dynamic>>(
      'loadPendingDeviceDeletes',
    );
    _pendingDeviceDeletes
      ..clear()
      ..addAll(
        (result ?? const <dynamic>[]).map((item) {
          try {
            return PendingDeviceDeletion.fromMap(_asStringMap(item));
          } on FormatException {
            return null;
          }
        }).whereType<PendingDeviceDeletion>(),
      );
    final coalesced = coalescePendingDeviceDeletions(_pendingDeviceDeletes);
    _pendingDeviceDeletes
      ..clear()
      ..addAll(coalesced);
    _pendingDeviceDeletesLoaded = true;
    if (_connected) {
      unawaited(_reconcilePendingDeviceDeletes());
    }
  }

  Future<void> _savePendingDeviceDeletes() async {
    await _invokeNative<void>(
      'savePendingDeviceDeletes',
      _pendingDeviceDeletes.map((item) => item.toMap()).toList(),
    );
  }

  Future<Map<dynamic, dynamic>> _packageIdentity({
    required String assetPath,
    required String? reviewId,
    required String name,
  }) async {
    if (assetPath.isNotEmpty && File(assetPath).existsSync()) {
      try {
        final result = await _invokeNative<Map<dynamic, dynamic>>(
          'inspectLocalPackage',
          {'assetPath': assetPath},
        );
        if (result != null) return result;
      } on PlatformException {
        // A damaged local cache may be replaced by its approved server package.
        // Without a review ID, retain the deletion for a safe future retry.
        if (reviewId == null) rethrow;
      }
    }
    if (reviewId == null) {
      throw PlatformException(
        code: 'package_missing',
        message: '缺少素材包，无法安全识别设备文件',
      );
    }
    final result = await _invokeBackendNative<Map<dynamic, dynamic>>(
      'downloadApprovedPackage',
      {'assetId': reviewId, 'name': name, 'hardware': _connectedHardware},
    );
    if (result == null ||
        result['crc32'] is! num ||
        result['packageSize'] is! num) {
      throw PlatformException(code: 'package_invalid', message: '素材包缺少校验信息');
    }
    return result;
  }

  Future<HistoryEntry> _repairHistoryIdentity(HistoryEntry entry) async {
    if (entry.packageSize > 0 && entry.frameCount > 0) return entry;
    final data = await _packageIdentity(
      assetPath: entry.assetPath,
      reviewId: entry.reviewId,
      name: entry.name,
    );
    final repaired = entry.copyWith(
      assetPath: data['assetPath'] as String?,
      crc32: (data['crc32'] as num).toInt(),
      packageSize: (data['packageSize'] as num).toInt(),
      frameCount: (data['frameCount'] as num?)?.toInt(),
      fps: (data['fps'] as num?)?.toInt(),
    );
    final index = _history.indexOf(entry);
    if (index >= 0) _history[index] = repaired;
    await _saveHistory();
    return repaired;
  }

  Future<void> _reconcilePendingDeviceDeletes() {
    final existing = _deviceDeleteSync;
    if (existing != null) {
      return existing.future;
    }
    final completer = Completer<void>();
    _deviceDeleteSync = completer;
    unawaited(_runPendingDeviceDeleteReconciliation(completer));
    return completer.future;
  }

  Future<void> _runPendingDeviceDeleteReconciliation(
    Completer<void> completer,
  ) async {
    try {
      if (!_pendingDeviceDeletesLoaded ||
          !_connected ||
          _demoMode ||
          _uploading ||
          _pendingDeviceDeletes.isEmpty) {
        return;
      }
      final deviceKey = await _invokeNative<String>('getDeviceIdentity');
      if (deviceKey == null || deviceKey.isEmpty) {
        return;
      }
      _connectedDeviceKey = deviceKey;

      for (final original in List<PendingDeviceDeletion>.from(
        _pendingDeviceDeletes,
      )) {
        if (_uploading || !_connected) break;
        var deletion = original;
        if (deletion.deviceKey != null && !deletion.matchesDevice(deviceKey)) {
          continue;
        }
        if (deletion.needsPackageIdentity) {
          Map<dynamic, dynamic> metadata;
          try {
            metadata = await _packageIdentity(
              assetPath: '',
              reviewId: deletion.reviewId,
              name: deletion.name,
            );
          } on PlatformException {
            // One unavailable legacy package must not block other valid deletes.
            continue;
          }
          deletion = deletion.copyWith(
            crc32: (metadata['crc32'] as num).toInt(),
            needsPackageIdentity: false,
          );
          final index = _pendingDeviceDeletes.indexOf(original);
          if (index >= 0) _pendingDeviceDeletes[index] = deletion;
          await _savePendingDeviceDeletes();
          if (_uploading || !_connected) break;
        }
        if (deletion.deviceKey == null) {
          final response = await _invokeNative<String>('statDeviceAsset', {
            'id': deletion.deviceAssetId,
            'crc32': crc32Hex(deletion.crc32),
          });
          final status = parseDeviceAssetStatusResponse(response ?? '');
          if (status == DeviceAssetStatus.retry) {
            break;
          }
          if (status == DeviceAssetStatus.rejected) {
            _pendingDeviceDeletes.removeWhere(
              (item) => item.operationKey == deletion.operationKey,
            );
            await _savePendingDeviceDeletes();
            continue;
          }
          if (status != DeviceAssetStatus.match) {
            continue;
          }
          final previousOperationKey = deletion.operationKey;
          deletion = deletion.copyWith(deviceKey: deviceKey);
          final index = _pendingDeviceDeletes.indexWhere(
            (item) => item.operationKey == previousOperationKey,
          );
          if (index >= 0) {
            _pendingDeviceDeletes[index] = deletion;
            await _savePendingDeviceDeletes();
          }
        }
        if (!deletion.matchesDevice(deviceKey)) {
          continue;
        }

        if (_uploading || !_connected) break;
        final response = await _invokeNative<String>('deleteDeviceAsset', {
          'id': deletion.deviceAssetId,
          'crc32': crc32Hex(deletion.crc32),
        });
        final outcome = parseDeviceAssetDeleteResponse(response ?? '');
        if (!isTerminalDeviceAssetDeleteOutcome(outcome)) {
          break;
        }
        _pendingDeviceDeletes.removeWhere(
          (item) => item.operationKey == deletion.operationKey,
        );
        await _savePendingDeviceDeletes();
      }
    } on PlatformException {
      // Keep the durable tombstones for the next connection/retry.
    } finally {
      _deviceDeleteSync = null;
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

  void _enterDemoMode() {
    _resetFirmwareAvailability();
    setState(() {
      _demoMode = true;
      _devices
        ..clear()
        ..add(
          const BadgeDevice(
            name: 'Demo DotLoop',
            address: '192.168.4.1',
            rssi: -38,
            serviceMatch: true,
          ),
        );
      _connected = true;
      _connecting = false;
      _sdAvailable = true;
      _connectedAddress = 'Demo DotLoop';
      _status = '审核演示模式';
      _pageIndex = 1;
    });
    _showSnack('已进入演示模式');
  }

  void _exitDemoMode() {
    setState(() {
      _demoMode = false;
      _connected = false;
      _connecting = false;
      _connectedAddress = null;
      _sdAvailable = false;
      _status = '未连接';
      _devices.clear();
    });
    unawaited(_refreshConnectionState());
  }

  Future<void> _simulateDemoScan() async {
    setState(() {
      _scanning = true;
      _status = '审核演示扫描';
      _devices.clear();
    });
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _devices.add(
        const BadgeDevice(
          name: 'Demo DotLoop',
          address: '192.168.4.1',
          rssi: -38,
          serviceMatch: true,
        ),
      );
      _status = '已发现演示设备';
    });
  }

  Future<Map<String, Object?>> _simulateDemoUpload(PreparedAsset asset) async {
    setState(() {
      _uploading = true;
      _uploadProgress = 0.12;
      _status = '演示上传中';
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (mounted) {
      setState(() => _uploadProgress = 0.68);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return {'assignedId': asset.reviewId ?? 'demo-approved'};
  }

  Future<void> _refreshConnectionState() async {
    if (_bluetoothControl) {
      final info = await _channel.invokeMapMethod<String, dynamic>(
        'deviceBluetoothState',
      );
      if (!mounted) return;
      if (info?['connected'] != true) {
        setState(() {
          _connected = false;
          _deviceFirmwareVersion = null;
          _resetFirmwareAvailability();
          _status = '蓝牙已断开，请重新连接';
        });
      } else if (_connected) {
        final status = info?['status']?.toString() ?? '';
        final version = RegExp(r'version=([^ ]+)').firstMatch(status)?.group(1);
        if (version != null && version != _deviceFirmwareVersion) {
          setState(() {
            _readDeviceFirmwareStatus(status);
            _resetFirmwareAvailability();
          });
        }
        unawaited(_refreshFirmwareAvailability());
      }
      return;
    }
    if (_demoMode) {
      setState(() {
        _connected = true;
        _sdAvailable = true;
        _connectedAddress = 'Demo DotLoop';
        _status = '审核演示模式';
      });
      return;
    }
    final result = await _invokeNative<Map<dynamic, dynamic>>(
      'connectionState',
    );
    if (!mounted || result == null) {
      return;
    }
    final state = _asStringMap(result);
    final wasConnected = _connected;
    final previousHardware = _connectedHardware;
    setState(() {
      if (state['connected'] != true || _connectedAddress != state['address']) {
        _connectedDeviceKey = null;
      }
      _connected = state['connected'] == true;
      _sdAvailable = state['sdAvailable'] == true;
      _connectedAddress = state['address'] as String?;
      _connectedHardware = _normalizeHardware(state['hardware']);
      _status =
          (state['message'] as String?) ??
          (_connected ? '已连接' : (wasConnected ? '断开连接' : '未连接'));
    });
    if (_connected && !wasConnected) {
      unawaited(_refreshAlignmentAngle());
      unawaited(_refreshRandomMode());
      unawaited(_reconcilePendingDeviceDeletes());
    }
    if (_connected && previousHardware != _connectedHardware) {
      unawaited(_loadFactoryAnimations());
    }
  }

  Future<void> _scan() async {
    if (_demoMode) {
      await _simulateDemoScan();
      return;
    }
    setState(() {
      _resetFirmwareAvailability();
      _deviceFirmwareVersion = null;
      _connectedDeviceKey = null;
      _devices.clear();
      _scanning = true;
      _status = '扫描 DotLoop';
    });
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>(
        'ensureDeviceBluetooth',
      );
      if (!mounted) return;
      final status = info?['status']?.toString() ?? '';
      if (info?['connected'] != true ||
          !status.contains('hardware=esp32p4') ||
          !status.contains('dc=1')) {
        await _channel.invokeMethod<void>('releaseGameBluetooth');
        throw PlatformException(
          code: 'firmware_update_required',
          message: '请先更新设备的蓝牙控制固件',
        );
      }
      setState(() {
        _bluetoothControl = true;
        _connected = true;
        _scanning = false;
        _connecting = false;
        _connectedHardware = 'esp32p4';
        _sdAvailable = status.contains('sd=1');
        _connectedAddress = info?['address']?.toString();
        _readDeviceFirmwareStatus(status);
        _status = '蓝牙已连接';
      });
      unawaited(_refreshAlignmentAngle());
      unawaited(_refreshRandomMode());
      unawaited(_reconcilePendingDeviceDeletes());
      unawaited(_loadFactoryAnimations());
      unawaited(_refreshBrightness());
      unawaited(_refreshFirmwareAvailability());
    } on PlatformException catch (error) {
      _showSnack(error.message ?? error.code);
      setState(() => _scanning = false);
    }
  }

  Future<void> _connect(BadgeDevice device) async {
    _resetFirmwareAvailability();
    _deviceFirmwareVersion = null;
    _connectedDeviceKey = null;
    _bluetoothControl = false; // Explicit S3/legacy Wi-Fi entry.
    if (_demoMode) {
      setState(() {
        _connected = true;
        _connecting = false;
        _sdAvailable = true;
        _connectedAddress = device.address;
        _status = '审核演示模式';
      });
      return;
    }
    setState(() {
      _connecting = true;
      _status = '连接 ${device.name}';
    });
    try {
      await _invokeNative<void>('connect', {'address': device.address});
    } on PlatformException catch (error) {
      _showSnack(error.message ?? error.code);
      setState(() => _connecting = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() {
      _resetFirmwareAvailability();
      _deviceFirmwareVersion = null;
    });
    _connectedDeviceKey = null;
    if (_demoMode) {
      setState(() {
        _connected = false;
        _connectedAddress = null;
        _status = '演示设备已断开';
      });
      return;
    }
    if (_bluetoothControl) {
      await _channel.invokeMethod<void>('releaseGameBluetooth');
      await _channel.invokeMethod<void>('leaveDeviceAccessPoint');
      setState(() {
        _bluetoothControl = false;
        _connected = false;
        _connectedAddress = null;
        _deviceFirmwareVersion = null;
      });
    }
    await _invokeNative<void>('disconnect');
    await _refreshConnectionState();
  }

  Future<bool> _prepareDeviceTransfer({bool firmware = false}) async {
    if (!_bluetoothControl || _demoMode) return true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xff202020),
        title: const AppText('连接设备传输热点'),
        content: AppText(
          '${firmware ? '固件已下载并校验。' : '素材已准备好。'}接下来设备会开启 DotLoop Wi-Fi，允许系统连接后即可传输。传输期间没有互联网是正常的，蓝牙控制仍保持连接。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const AppText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const AppText('连接并传输'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return false;
    final key = await _invokeNative<String>('getDeviceIdentity');
    await _invokeNative<String>('startTransferAccessPoint');
    await _channel.invokeMethod<bool>('joinDeviceAccessPoint');
    if (!_connected) {
      throw PlatformException(
        code: 'device_disconnected',
        message: '蓝牙设备已断开，请重新连接',
      );
    }
    // Verify Wi-Fi and BLE are the SAME badge before writing any file.
    final wifiKey = await _channel.invokeMethod<String>('getDeviceIdentity');
    if (key == null || wifiKey != key) {
      throw PlatformException(
        code: 'wrong_device',
        message: '热点不是当前蓝牙设备，已停止传输',
      );
    }
    _connectedDeviceKey = key;
    return true;
  }

  Future<void> _pickMedia() async {
    try {
      final picked = await _invokeNative<Map<dynamic, dynamic>>('pickMedia');
      if (!mounted || picked == null) {
        return;
      }
      final media = SelectedMedia.fromMap(_asStringMap(picked));
      setState(() {
        if (_draftAssetName.trim().isEmpty || _draftAssetName == _media?.name) {
          _draftAssetName = media.name;
        }
        _media = media;
        _asset = null;
        _cropTransform = const CropTransform();
        _prepareProgress = 0;
        _pageIndex = 2;
        _status = '素材已导入';
      });
      unawaited(_warmSelectedVideoPreview(media));
    } on PlatformException catch (error) {
      _showSnack(error.message ?? error.code);
    }
  }

  Future<void> _warmSelectedVideoPreview(SelectedMedia media) async {
    if (!_isVideoMime(media.mime) ||
        _hasPreviewPath(media.animatedPreviewPath)) {
      return;
    }
    try {
      await _invokeNative<void>('warmVideoAnimatedPreview', {
        'uri': media.uri,
        'name': media.name,
      });
    } on PlatformException {
      // Preview warmup is opportunistic; saving can still regenerate it.
    }
  }

  Future<void> _saveMakerAsset() async {
    if (_preparing || _uploading) {
      return;
    }
    final media = _media;
    if (media == null) {
      _showSnack('请先导入 GIF、图片或视频');
      return;
    }
    final assetName = _draftAssetName.trim().isEmpty
        ? media.name
        : _draftAssetName.trim();
    setState(() {
      _preparing = true;
      _prepareProgress = 0;
      _status = '保存素材';
    });
    try {
      final useServerTranscode =
          _isVideoMime(media.mime) || media.mime.startsWith('image/');
      if (useServerTranscode) {
        /* Server-side transcoding: the phone uploads the original media
         * and crop params. The server selects the S3 indexed or P4 JPEG
         * EBAJ4 payload from the connected hardware. */
        setState(() => _status = '上传服务器解码');
        final transcodeResult =
            await withLocalTranscodeFallback<Map<dynamic, dynamic>?>(
              () => _invokeBackendNative<Map<dynamic, dynamic>>(
                'transcodeOnServer',
                {
                  'uri': media.uri,
                  'name': assetName,
                  'maxFps': _connectedHardware == 'esp32s3'
                      ? s3MaxTranscodeFps
                      : p4MaxTranscodeFps,
                  'cropScale': _cropTransform.scale,
                  'cropOffsetX': _cropTransform.offset.dx,
                  'cropOffsetY': _cropTransform.offset.dy,
                  'hardware': _connectedHardware,
                  // A user import is intended for a device even when the
                  // device is offline right now. The package remains local
                  // until a device is connected, but the server must produce
                  // and approve the hardware-specific payload immediately.
                  'deviceTransfer': !_demoMode,
                },
              ),
              () async {
                if (mounted) setState(() => _status = '服务器无法连接，改为本地处理');
                return null;
              },
            );
        if (!mounted) return;
        if (transcodeResult != null) {
          final reviewId = _readNullableString(transcodeResult['reviewId']);
          if (reviewId == null) {
            throw PlatformException(
              code: 'transcode_failed',
              message: '服务器转码失败',
            );
          }
          final actualFps = resolveServerTranscodeFps(transcodeResult['fps']);
          final asset = PreparedAsset(
            assetPath: '',
            previewPath: _readNullableString(transcodeResult['previewPath']),
            animatedPreviewPath: media.animatedPreviewPath,
            sourceUri: media.uri,
            mime: media.mime,
            name: assetName,
            packageSize: 0,
            frameCount: 0,
            fps: actualFps,
            crc32: 0,
            cropScale: _cropTransform.scale,
            cropOffsetX: _cropTransform.offset.dx,
            cropOffsetY: _cropTransform.offset.dy,
            reviewId: reviewId,
            reviewStatus:
                _readNullableString(transcodeResult['reviewStatus']) ??
                'pending',
          );
          final entry = HistoryEntry.fromAsset(
            asset,
            cropTransform: _cropTransform,
          );
          setState(() {
            _asset = asset;
            _preparing = false;
            _prepareProgress = 1;
            _pageIndex = 1;
            _history.removeWhere((item) => item.reviewId == asset.reviewId);
            _history.insert(0, entry);
            if (_history.length > 20) {
              _history.removeRange(20, _history.length);
            }
            _status = asset.reviewStatus == 'approved' ? '已转码，可上传' : '处理中';
          });
          _showSnack(
            asset.reviewStatus == 'approved' ? '素材已转码，可直接上传' : '服务器正在处理素材',
          );
          unawaited(_saveHistory());
          return;
        }
      }
      final prepared = await _invokeNative<Map<dynamic, dynamic>>(
        'prepareAsset',
        {
          'uri': media.uri,
          'name': assetName,
          'fps': 40,
          'maxPackageBytes': resolveBadgePackageBudget(
            sdAvailable: _sdAvailable,
          ),
          'cropScale': _cropTransform.scale,
          'cropOffsetX': _cropTransform.offset.dx,
          'cropOffsetY': _cropTransform.offset.dy,
          'warmPreviewPath': _isDefaultCrop ? media.animatedPreviewPath : null,
        },
      );
      if (!mounted || prepared == null) {
        return;
      }
      final rawAsset = PreparedAsset.fromMap(_asStringMap(prepared));
      var asset = rawAsset.copyWith(cropTransform: _cropTransform);
      var saveMessage = '素材已保存并同步服务器';
      if (_isVideoMime(asset.mime) &&
          !_hasPreviewPath(asset.animatedPreviewPath)) {
        setState(() => _status = '生成素材预览');
        asset = await _withReviewPreviewReady(asset);
        if (!mounted) {
          return;
        }
      }
      try {
        setState(() => _status = '同步素材到服务器');
        asset = await _submitAssetForReview(asset);
        if (!mounted) {
          return;
        }
        if (asset.reviewStatus == 'approved') {
          saveMessage = '素材已保存，可直接上传';
        } else if (asset.reviewStatus == 'rejected') {
          saveMessage = '素材已保存，但服务器拒绝此素材';
        }
      } catch (_) {
        if (!mounted) {
          return;
        }
        saveMessage = '素材已本地保存，联网后将同步服务器';
      }
      final entry = HistoryEntry.fromAsset(
        asset,
        cropTransform: _cropTransform,
      );
      setState(() {
        _asset = asset;
        _preparing = false;
        _prepareProgress = 1;
        _pageIndex = 1;
        _history.removeWhere((item) => item.assetPath == asset.assetPath);
        _history.insert(0, entry);
        if (_history.length > 20) {
          _history.removeRange(20, _history.length);
        }
        _status = asset.reviewStatus == 'pending' ? '处理中' : '已保存';
      });
      _showSnack(saveMessage);
      unawaited(_saveHistory());
    } on PlatformException catch (error) {
      setState(() {
        _preparing = false;
        _status = '素材处理失败';
      });
      _showSnack(error.message ?? error.code);
    }
  }

  Future<void> _uploadAsset(PreparedAsset asset) async {
    if (_uploading || _preparing) return;
    if (!_connected) {
      _showSnack('请先连接设备');
      setState(() => _pageIndex = 0);
      return;
    }
    // Mark the whole operation busy before review/package download. This
    // prevents a second tap from starting another backend/device transfer and
    // makes the spinner cover the actual waiting period.
    setState(() {
      _uploading = true;
      _uploadProgress = 0;
      _status = '准备上传';
    });
    await _pendingDeviceDeletesLoad;
    // Deletion tombstones are durable and retried on every connection. They
    // must not block a user-initiated upload behind identity/delete retries.
    if (_pendingDeviceDeletes.isNotEmpty) {
      unawaited(_reconcilePendingDeviceDeletes());
    }
    if (!mounted) {
      return;
    }
    var approvedAsset = await _ensureP4Asset(asset);
    if (approvedAsset != null) {
      approvedAsset = await _ensureAssetApproved(approvedAsset);
    }
    if (!mounted || approvedAsset == null) {
      if (mounted) {
        setState(() => _uploading = false);
      }
      return;
    }
    /* Server-transcoded assets hold no local package yet: download it from
     * the backend before pushing to the device. */
    if (approvedAsset.assetPath.isEmpty && approvedAsset.reviewId != null) {
      setState(() => _status = '下载素材包');
      Map<dynamic, dynamic>? downloadResult;
      try {
        downloadResult = await _invokeBackendNative<Map<dynamic, dynamic>>(
          'downloadApprovedPackage',
          {
            'assetId': approvedAsset.reviewId,
            'name': approvedAsset.name,
            'hardware': _connectedHardware,
          },
        );
      } on PlatformException catch (error) {
        if (mounted) {
          setState(() {
            _uploading = false;
            _status = '下载失败';
          });
          _showSnack(error.message ?? '素材包下载失败');
        }
        return;
      }
      if (!mounted || downloadResult == null) {
        if (mounted) {
          setState(() {
            _uploading = false;
            _status = '下载失败';
          });
        }
        return;
      }
      final downloadedPath = _readNullableString(downloadResult['assetPath']);
      if (downloadedPath == null || downloadedPath.isEmpty) {
        setState(() {
          _uploading = false;
          _status = '下载失败';
        });
        _showSnack('素材包下载失败');
        return;
      }
      approvedAsset = PreparedAsset(
        assetPath: downloadedPath,
        previewPath: approvedAsset.previewPath,
        animatedPreviewPath: approvedAsset.animatedPreviewPath,
        sourceUri: approvedAsset.sourceUri,
        mime: approvedAsset.mime,
        name: approvedAsset.name,
        packageSize: (downloadResult['packageSize'] as num).toInt(),
        frameCount: (downloadResult['frameCount'] as num).toInt(),
        fps: (downloadResult['fps'] as num).toInt(),
        crc32: (downloadResult['crc32'] as num).toInt(),
        cropScale: approvedAsset.cropScale,
        cropOffsetX: approvedAsset.cropOffsetX,
        cropOffsetY: approvedAsset.cropOffsetY,
        reviewId: approvedAsset.reviewId,
        reviewStatus: approvedAsset.reviewStatus,
      );
      if (!mounted) {
        return;
      }
      for (var i = 0; i < _history.length; i++) {
        if (_history[i].reviewId == approvedAsset.reviewId) {
          _history[i] = _history[i].copyWith(
            assetPath: downloadedPath,
            packageSize: approvedAsset.packageSize,
            frameCount: approvedAsset.frameCount,
            fps: approvedAsset.fps,
            crc32: approvedAsset.crc32,
          );
        }
      }
      await _saveHistory();
    }
    try {
      final uploadTarget = approvedAsset;
      if (!await _prepareDeviceTransfer()) {
        if (mounted) setState(() => _uploading = false);
        return;
      }
      // Capture the identity verified for THIS upload, never a prior device.
      final uploadDeviceKey = !_demoMode && _bluetoothControl
          ? _connectedDeviceKey
          : null; // Legacy S3 does not implement the P4 identity command.
      final result = _demoMode
          ? await _simulateDemoUpload(uploadTarget)
          : await _invokeNative<Map<dynamic, dynamic>>('uploadAsset', {
              'assetPath': uploadTarget.assetPath,
            });
      if (!mounted) return;
      final assignedId = _readNullableString(result?['assignedId']);
      final deviceKey = _readNullableString(result?['deviceKey']);
      if (deviceKey != null) {
        _connectedDeviceKey = deviceKey;
      }
      setState(() {
        _uploading = false;
        _uploadProgress = 1;
        _status = '已切换';
        // Store assigned device ID on the history entry
        for (var i = 0; i < _history.length; i++) {
          if (uploadMatchesHistory(
            historyAssetPath: _history[i].assetPath,
            historyReviewId: _history[i].reviewId,
            uploadedAssetPath: uploadTarget.assetPath,
            uploadedReviewId: uploadTarget.reviewId,
          )) {
            _history[i] = _history[i].copyWith(
              deviceId: assignedId,
              deviceKey: deviceKey ?? uploadDeviceKey,
              assetPath: uploadTarget.assetPath,
              packageSize:
                  (result?['packageSize'] as num?)?.toInt() ??
                  uploadTarget.packageSize,
              crc32: (result?['crc32'] as num?)?.toInt() ?? uploadTarget.crc32,
            );
            break;
          }
        }
      });
      if (assignedId != null) unawaited(_saveHistory());
    } on PlatformException catch (error) {
      setState(() {
        _uploading = false;
        _status = '上传失败';
      });
      _showSnack(error.message ?? error.code);
    } finally {
      if (_bluetoothControl) {
        await _channel.invokeMethod<void>('leaveDeviceAccessPoint');
      }
    }
  }

  Future<void> _setBrightness(int value) async {
    setState(() => _brightness = value);
    if (!_connected || _demoMode) {
      return;
    }
    _brightnessTimer?.cancel();
    _brightnessTimer = Timer(const Duration(milliseconds: 120), () {
      unawaited(_sendBrightness(value));
    });
  }

  Future<void> _sendBrightness(int value) async {
    try {
      await _invokeNative<void>('setBrightness', {'value': value});
    } on PlatformException catch (error) {
      _showSnack(error.message ?? error.code);
    }
  }

  Future<void> _refreshBrightness() async {
    if (!_connected || !_bluetoothControl || _demoMode) return;
    final address = _connectedAddress;
    final previous = _brightness;
    try {
      final value = await _deviceControl.invoke('getBrightness') as int;
      if (mounted &&
          _connected &&
          address == _connectedAddress &&
          previous == _brightness) {
        setState(() => _brightness = value);
      }
    } on PlatformException {
      // Older firmware does not expose BRIGHT GET; keep its existing controls.
    }
  }

  Future<void> _refreshAlignmentAngle() async {
    if (_demoMode || _connectedHardware == 'esp32s3') return;
    final address = _connectedAddress;
    try {
      final response = await _invokeNative<Map<dynamic, dynamic>>(
        'calibrationStatus',
      );
      if (response != null && mounted && _connectedAddress == address) {
        setState(
          () => _alignmentAngleTenths = CalibrationSnapshot.fromMap(
            response,
          ).angleTenths,
        );
      }
    } on PlatformException {
      // Older firmware can still connect without the optional calibration API.
    }
  }

  Future<void> _openAlignment() async {
    if (_uploading) {
      _showSnack('请等待当前传输完成后再校正');
      return;
    }
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => AlignmentPage(
          connected: _connected,
          enter: () async {
            final response = await _invokeNative<Map<dynamic, dynamic>>(
              'enterCalibration',
            );
            if (response == null) {
              throw StateError('设备未返回校正状态');
            }
            final snapshot = CalibrationSnapshot.fromMap(response);
            if (mounted) {
              setState(() => _alignmentAngleTenths = snapshot.angleTenths);
            }
            return snapshot;
          },
          preview: (angleTenths) => _invokeNative<void>('previewCalibration', {
            'angleTenths': angleTenths,
          }),
          save: (angleTenths) async {
            await _invokeNative<void>('saveCalibration', {
              'angleTenths': angleTenths,
            });
            if (mounted) setState(() => _alignmentAngleTenths = angleTenths);
          },
          cancel: () => _invokeNative<void>('cancelCalibration'),
        ),
      ),
    );
  }

  List<Uri> get _backendBases =>
      backendBaseCandidates(overrideBase: _backendBaseOverride);

  void _openSettings() {
    setState(() => _pageIndex = 4);
    unawaited(_refreshFirmwareAvailability());
  }

  void _readDeviceFirmwareStatus(String status) {
    _deviceFirmwareVersion = RegExp(
      r'version=(\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?)(?: |$)',
    ).firstMatch(status)?.group(1);
    final hardware = RegExp(r'hardware=([^ ]+)').firstMatch(status)?.group(1);
    // Existing P4 control firmware reports its chip name for the 2.8-inch board.
    _deviceFirmwareHardware = switch (hardware) {
      'esp32p4' || 'esp32p4-2.8' => 'esp32p4-2.8',
      'esp32p4-2.5' => 'esp32p4-2.5',
      _ => null,
    };
  }

  void _resetFirmwareAvailability() {
    ++_firmwareSession;
    _firmwareManifest = null;
    _firmwareCheck = null;
    _firmwareCheckedAt = null;
  }

  Future<void> _refreshFirmwareAvailability({bool force = false}) async {
    if (!_connected ||
        !_bluetoothControl ||
        _demoMode ||
        !_appActive ||
        _uploading ||
        _preparing ||
        _deviceFirmwareVersion == null ||
        _deviceFirmwareHardware == null ||
        _firmwareCheck != null) {
      return;
    }
    final now = DateTime.now();
    final checkedAt = _firmwareCheckedAt;
    final interval = _firmwareManifest == null
        ? const Duration(seconds: 30)
        : const Duration(minutes: 5);
    if (!force && checkedAt != null && now.difference(checkedAt) < interval) {
      return;
    }
    final session = _firmwareSession;
    _firmwareCheckedAt = now;
    final request = checkFirmwareManifest(
      hardware: _deviceFirmwareHardware!,
      backendBases: _backendBases,
    );
    _firmwareCheck = request;
    try {
      final manifest = await request;
      if (!mounted || session != _firmwareSession) return;
      setState(() => _firmwareManifest = manifest);
    } catch (_) {
      // Background checks stay quiet; the update page exposes errors and retry.
    } finally {
      if (session == _firmwareSession) _firmwareCheck = null;
    }
  }

  void _openBrightness() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReferenceBrightnessPage(
          initialValue: _brightness,
          connected: _connected,
          onChanged: _setBrightness,
        ),
      ),
    );
  }

  void _openDeviceStatus() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xff202020),
        title: const AppText('设备状态'),
        content: Row(
          children: [
            const AppText('TF 卡'),
            const Spacer(),
            AppText(
              !_connected
                  ? '未连接'
                  : _sdAvailable
                  ? '可用'
                  : '不可用',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const AppText('完成'),
          ),
        ],
      ),
    );
  }

  void _openVersionInfo() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xff202020),
        title: const AppText('设备版本'),
        content: AppText(
          'DotLoop $_appVersion\n设备：$_connectedHardware\n固件：${_deviceFirmwareVersion ?? (_connected ? '读取中' : '未连接')}${_firmwareUpdateAvailable ? '\n发现新版本 ${_firmwareManifest!.version}' : ''}',
        ),
        actions: [
          if (_connected &&
              _bluetoothControl &&
              !_demoMode &&
              _deviceFirmwareHardware != null)
            TextButton(
              onPressed: _uploading || _preparing
                  ? null
                  : () {
                      Navigator.pop(context);
                      _openFirmwareUpdate();
                    },
              child: AppText(_firmwareUpdateAvailable ? '查看固件更新' : '检查固件更新'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const AppText('完成'),
          ),
        ],
      ),
    );
  }

  void _openSupport() => unawaited(
    _invokeNative<void>('openUrl', {
      'url': 'https://leyyoudian.github.io/flutter_app/support.html',
    }),
  );

  void _openFirmwareUpdate() {
    if (!_connected ||
        !_bluetoothControl ||
        _uploading ||
        _preparing ||
        _deviceFirmwareHardware == null) {
      return;
    }
    final session = _firmwareSession;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FirmwareUpdatePage(
          hardware: _deviceFirmwareHardware!,
          currentVersion: _deviceFirmwareVersion ?? '0.0.0',
          backendBases: _backendBases,
          initialManifest: _firmwareManifest,
          onManifest: (manifest) {
            if (!mounted || session != _firmwareSession) return;
            setState(() {
              _firmwareManifest = manifest;
              _firmwareCheckedAt = DateTime.now();
            });
          },
          prepareTransfer: () async {
            await _channel.invokeMethod<void>('gameCommand', {
              'action': 'stop',
            });
            await _invokeNative<void>('cancelCalibration');
            return _prepareDeviceTransfer(firmware: true);
          },
          setBusy: (busy) {
            if (mounted) setState(() => _uploading = busy);
          },
          deviceIdentity: () => _invokeNative<String>('getDeviceIdentity'),
        ),
      ),
    );
  }

  bool _retryBackendError(Object error) {
    return isRetryableBackendError(error);
  }

  Future<Map<String, dynamic>?> _getBackendJson(String path) async {
    return withBackendFailover<Map<String, dynamic>?>(
      _backendBases,
      (base) => _requestBackendJson(base.resolve(path)),
      shouldRetry: _retryBackendError,
    );
  }

  Future<Map<String, dynamic>?> _postBackendJson(
    String path,
    Map<String, Object?> body,
  ) async {
    return withBackendFailover<Map<String, dynamic>?>(
      _backendBases,
      (base) => _requestBackendJson(base.resolve(path), body: body),
      shouldRetry: _retryBackendError,
    );
  }

  Future<Map<String, dynamic>> _requestBackendJson(
    Uri uri, {
    Map<String, Object?>? body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = body == null
          ? await client.getUrl(uri)
          : await client.postUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        request.write(json.encode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw BackendRequestException(
          text.isEmpty ? 'HTTP ${response.statusCode}' : text,
          retryable: response.statusCode >= 500,
        );
      }
      return _asStringMap(json.decode(text));
    } finally {
      client.close(force: true);
    }
  }

  bool _isNewerVersion(String latest, String current) {
    final latestParts = latest
        .split('.')
        .map((item) => int.tryParse(item) ?? 0)
        .toList(growable: false);
    final currentParts = current
        .split('.')
        .map((item) => int.tryParse(item) ?? 0)
        .toList(growable: false);
    for (
      var index = 0;
      index < math.max(latestParts.length, currentParts.length);
      index++
    ) {
      final left = index < latestParts.length ? latestParts[index] : 0;
      final right = index < currentParts.length ? currentParts[index] : 0;
      if (left != right) {
        return left > right;
      }
    }
    return false;
  }

  Future<void> _checkRemoteVersion() async {
    if (_checkingVersion) {
      return;
    }
    _checkingVersion = true;
    try {
      final platform = Platform.isIOS ? 'ios' : 'android';
      final manifest = await _getBackendJson(
        '/api/version?platform=$platform&current=$_appVersion',
      );
      if (!mounted || manifest == null) {
        return;
      }
      final latestVersion = _readNullableString(manifest['latestVersion']);
      if (latestVersion != null &&
          _isNewerVersion(latestVersion, _appVersion)) {
        final force = manifest['force'] == true;
        final storeUrl = _readNullableString(manifest['storeUrl']);
        _showUpdateSnack(latestVersion, force: force, storeUrl: storeUrl);
      }
    } catch (_) {
      // The app remains fully usable if the public server is temporarily offline.
    } finally {
      _checkingVersion = false;
    }
  }

  Future<PreparedAsset> _submitAssetForReview(PreparedAsset asset) async {
    final packageBytes = await File(asset.assetPath).readAsBytes();
    String? previewBase64;
    final reviewPreviewPath = _preferredReviewPreviewPath(asset);
    if (reviewPreviewPath != null && File(reviewPreviewPath).existsSync()) {
      previewBase64 = base64Encode(await File(reviewPreviewPath).readAsBytes());
    }
    final result = await _postBackendJson('/api/assets', {
      'userId': Platform.isIOS ? 'ios-user' : 'android-user',
      'name': asset.name,
      'packageBase64': base64Encode(packageBytes),
      'previewBase64': previewBase64,
      'previewMime': _guessMimeFromPath(reviewPreviewPath),
      'crc32': asset.crc32.toRadixString(16).padLeft(8, '0'),
      'packageSize': asset.packageSize,
      'frameCount': asset.frameCount,
      'fps': asset.fps,
      'hardware': _connectedHardware,
    });
    final reviewId = _readNullableString(result?['id']);
    final reviewStatus = _readNullableString(result?['status']);
    if (reviewStatus == null || reviewStatus == 'pending') {
      return asset.copyWith(reviewId: reviewId, reviewStatus: 'pending');
    }
    return asset.copyWith(reviewId: reviewId, reviewStatus: reviewStatus);
  }

  Future<PreparedAsset> _withReviewPreviewReady(PreparedAsset asset) async {
    if (!_isVideoMime(asset.mime) ||
        _hasPreviewPath(asset.animatedPreviewPath)) {
      return asset;
    }
    if (asset.assetPath.isEmpty) {
      return asset;
    }
    final previous = _assetPreviewWaiters.remove(asset.assetPath);
    if (previous != null && !previous.isCompleted) {
      previous.complete(null);
    }
    final waiter = Completer<String?>();
    _assetPreviewWaiters[asset.assetPath] = waiter;
    final previewPath = await waiter.future
        .timeout(const Duration(seconds: 6), onTimeout: () => null)
        .whenComplete(() {
          if (identical(_assetPreviewWaiters[asset.assetPath], waiter)) {
            _assetPreviewWaiters.remove(asset.assetPath);
          }
        });
    if (_hasPreviewPath(previewPath)) {
      return asset.copyWith(animatedPreviewPath: previewPath);
    }
    return asset;
  }

  Future<PreparedAsset> _refreshReviewStatus(PreparedAsset asset) async {
    final reviewId = asset.reviewId;
    if (reviewId == null) {
      return asset;
    }
    final result = await _getBackendJson('/api/assets/$reviewId');
    return asset.copyWith(
      reviewStatus:
          _readNullableString(result?['status']) ?? asset.reviewStatus,
    );
  }

  String? _preferredReviewPreviewPath(PreparedAsset asset) {
    if (_hasPreviewPath(asset.animatedPreviewPath)) {
      return asset.animatedPreviewPath;
    }
    if (_hasPreviewPath(asset.previewPath)) {
      return asset.previewPath;
    }
    return null;
  }

  Future<void> _refreshHistoryReviewStatuses() async {
    if (_reviewRefreshInFlight || _demoMode || !_hasPendingReviewStatuses) {
      return;
    }
    _reviewRefreshInFlight = true;
    try {
      final updates = <String, String>{};
      for (final entry in _history) {
        if (entry.reviewId == null ||
            entry.reviewStatus == 'approved' ||
            entry.reviewStatus == 'rejected') {
          continue;
        }
        try {
          final result = await _getBackendJson('/api/assets/${entry.reviewId}');
          final status = _readNullableString(result?['status']);
          if (status != null && status != entry.reviewStatus) {
            updates[entry.reviewId!] = status;
          }
        } catch (_) {
          // Keep local status if the review server is temporarily unavailable.
        }
      }
      if (!mounted || updates.isEmpty) {
        return;
      }
      setState(() {
        for (var index = 0; index < _history.length; index++) {
          final reviewId = _history[index].reviewId;
          final status = reviewId == null ? null : updates[reviewId];
          if (status != null) {
            _history[index] = _history[index].copyWith(reviewStatus: status);
          }
        }
      });
      unawaited(_saveHistory());
    } finally {
      _reviewRefreshInFlight = false;
    }
  }

  void _rememberReviewedAsset(PreparedAsset asset) {
    setState(() {
      if (_asset != null &&
          uploadMatchesHistory(
            historyAssetPath: _asset!.assetPath,
            historyReviewId: _asset!.reviewId,
            uploadedAssetPath: asset.assetPath,
            uploadedReviewId: asset.reviewId,
          )) {
        _asset = asset;
      }
      for (var index = 0; index < _history.length; index++) {
        if (uploadMatchesHistory(
          historyAssetPath: _history[index].assetPath,
          historyReviewId: _history[index].reviewId,
          uploadedAssetPath: asset.assetPath,
          uploadedReviewId: asset.reviewId,
        )) {
          _history[index] = _history[index].copyWith(
            reviewId: asset.reviewId,
            reviewStatus: asset.reviewStatus,
          );
          break;
        }
      }
    });
    unawaited(_saveHistory());
  }

  Future<PreparedAsset?> _ensureAssetApproved(PreparedAsset asset) async {
    if (_demoMode) {
      return asset.copyWith(
        reviewId: asset.reviewId ?? 'demo-approved',
        reviewStatus: 'approved',
      );
    }
    if (asset.reviewStatus == 'approved' && asset.reviewId != null) {
      return asset;
    }
    try {
      PreparedAsset reviewed;
      if (asset.reviewId == null) {
        setState(() => _status = '同步素材到服务器');
        reviewed = await _submitAssetForReview(asset);
        if (!mounted) return null;
        _rememberReviewedAsset(reviewed);
      } else {
        setState(() => _status = '检查素材状态');
        reviewed = await _refreshReviewStatus(asset);
      }
      if (!mounted) return null;
      _rememberReviewedAsset(reviewed);
      if (reviewed.reviewStatus == 'approved') {
        return reviewed;
      }
      if (reviewed.reviewStatus == 'rejected') {
        _showSnack('素材审核未通过，请更换内容');
      } else {
        _showSnack('服务器仍在处理素材，请稍后重试');
      }
    } catch (error) {
      if (isRetryableBackendError(error) &&
          asset.reviewId == null &&
          asset.assetPath.isNotEmpty &&
          File(asset.assetPath).existsSync()) {
        final local = asset.copyWith(reviewStatus: 'approved');
        if (mounted) {
          _rememberReviewedAsset(local);
          _showSnack('服务器无法连接，使用本地已处理的素材');
        }
        return local;
      }
      if (mounted) {
        _showSnack('素材服务器暂时不可用，请稍后再试');
      }
    }
    return null;
  }

  Future<PreparedAsset?> _ensureP4Asset(PreparedAsset original) async {
    if (_demoMode ||
        _connectedHardware != 'esp32p4' ||
        original.reviewId == null ||
        original.reviewStatus == 'rejected') {
      return original;
    }
    if (await hasP4JpegPackage(original.assetPath)) return original;
    try {
      // Internet requests must precede joining the badge's transfer hotspot.
      if (_bluetoothControl) {
        await _channel.invokeMethod<void>('leaveDeviceAccessPoint');
      }
      final rebuilt = await rebuildLegacyP4Asset(
        assetId: original.reviewId!,
        sourceUri: original.sourceUri,
        name: original.name,
        cropScale: original.cropScale,
        cropOffsetX: original.cropOffsetX,
        cropOffsetY: original.cropOffsetY,
        metadata: (id) => _getBackendJson('/api/assets/$id'),
        transcode: (arguments) async {
          if (mounted) setState(() => _status = '正在将旧素材转换为 P4 格式');
          return _invokeBackendNative<Map<dynamic, dynamic>>(
            'transcodeOnServer',
            arguments,
          );
        },
      );
      if (!mounted) return null;
      if (rebuilt == null) return original;
      final asset = PreparedAsset(
        assetPath: '',
        previewPath:
            _readNullableString(rebuilt['previewPath']) ?? original.previewPath,
        animatedPreviewPath: original.animatedPreviewPath,
        sourceUri: original.sourceUri,
        mime: original.mime,
        name: original.name,
        packageSize: 0,
        frameCount: 0,
        fps: resolveServerTranscodeFps(rebuilt['fps']),
        crc32: 0,
        cropScale: original.cropScale,
        cropOffsetX: original.cropOffsetX,
        cropOffsetY: original.cropOffsetY,
        reviewId: rebuilt['reviewId'] as String,
        reviewStatus: 'approved',
      );
      setState(() {
        if (_asset != null &&
            uploadMatchesHistory(
              historyAssetPath: _asset!.assetPath,
              historyReviewId: _asset!.reviewId,
              uploadedAssetPath: original.assetPath,
              uploadedReviewId: original.reviewId,
            )) {
          _asset = asset;
        }
        for (var i = 0; i < _history.length; i++) {
          final entry = _history[i];
          if (!uploadMatchesHistory(
            historyAssetPath: entry.assetPath,
            historyReviewId: entry.reviewId,
            uploadedAssetPath: original.assetPath,
            uploadedReviewId: original.reviewId,
          )) {
            continue;
          }
          _history[i] = entry.copyWith(
            assetPath: '',
            packageSize: 0,
            frameCount: 0,
            fps: asset.fps,
            crc32: 0,
            reviewId: asset.reviewId,
            reviewStatus: 'approved',
            clearDeviceIdentity: true,
          );
        }
      });
      await _saveHistory();
      return asset;
    } catch (error) {
      if (mounted) {
        _showSnack(
          error is PlatformException
              ? error.message ?? '旧素材转换失败，请重新选择原素材'
              : '素材型号检查失败，请稍后重试',
        );
      }
      return null;
    }
  }

  Future<T?> _invokeNative<T>(String method, [Object? arguments]) async {
    try {
      if (_bluetoothControl && DeviceControl.methods.contains(method)) {
        final value = await _deviceControl.invoke(
          method,
          arguments is Map ? arguments : const {},
        );
        return value as T?;
      }
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    }
  }

  Future<T?> _invokeBackendNative<T>(
    String method,
    Map<String, Object?> arguments,
  ) async {
    if (_bluetoothControl) {
      await _channel.invokeMethod<void>('leaveDeviceAccessPoint');
    }
    return withBackendFailover<T?>(
      _backendBases,
      (base) => _invokeNative<T>(method, {
        ...arguments,
        'backendBase': base.toString(),
      }),
      shouldRetry: _retryBackendError,
    );
  }

  Future<void> _openPrivacyPolicyUrl() async {
    try {
      await _invokeNative<void>('openUrl', {'url': _privacyPolicyUrl});
    } on PlatformException catch (error) {
      if (mounted) {
        _showSnack(error.message ?? error.code);
      }
    }
  }

  void _showPrivacyPolicy() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xff171717),
        title: const AppText('隐私政策'),
        content: SingleChildScrollView(
          child: AppText(
            'ESP Baji 不收集、出售或分享个人信息。\n\n'
            '导入的图片、GIF 和视频会提交到 ESP Baji 服务器处理；服务器无法连接时可在本机处理。'
            '处理完成后，应用仅在用户操作时通过本地 Wi-Fi 发送到已连接的 ESP 设备。'
            '应用不会上传素材到第三方服务器，也不使用广告或分析 SDK。\n\n'
            '公开隐私政策链接：\n$_privacyPolicyUrl',
            style: const TextStyle(height: 1.45),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const AppText('关闭'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              unawaited(_openPrivacyPolicyUrl());
            },
            child: const AppText('打开网页'),
          ),
        ],
      ),
    );
  }

  void _advanceVideo() {
    if (_videoIndex + 1 < _videoQueue.length) {
      setState(() => _videoIndex++);
    }
  }

  /// The factory animation currently selected (used by both the library page
  /// and the device page preview dial so they stay in sync).
  FactoryAnimation? get _selectedFactory {
    return _selectedFactoryId != null
        ? _factoryAnims.cast<FactoryAnimation?>().firstWhere(
            (a) => a?.id == _selectedFactoryId,
            orElse: () => null,
          )
        : null;
  }

  bool get _isDefaultCrop {
    return (_cropTransform.scale - 1).abs() < 0.0001 &&
        _cropTransform.offset.distance < 0.0001;
  }

  Future<void> _uploadHistoryEntry(HistoryEntry entry) async {
    if (_preparing || _uploading) {
      return;
    }
    if (entry.deviceId != null &&
        _connected &&
        (entry.packageSize <= 0 || entry.frameCount <= 0)) {
      try {
        entry = await _repairHistoryIdentity(entry);
      } on PlatformException catch (error) {
        _showSnack(error.message ?? '素材身份校验失败');
        return;
      }
    }
    // If already uploaded, just switch to it
    if (entry.deviceId != null && _connected) {
      final switchGeneration = ++_switchGeneration;
      // Tombstone cleanup is best-effort background work. It must not delay
      // the user-selected asset switch behind identity/delete network calls.
      if (_pendingDeviceDeletes.isNotEmpty) {
        unawaited(_reconcilePendingDeviceDeletes());
      }
      if (!mounted || switchGeneration != _switchGeneration) {
        return;
      }
      // A deviceId proves that this exact package was already accepted by
      // the device. Do not poll the backend review endpoint before sending a
      // local SWITCH command; if the device no longer has it, the command
      // returns NEED_UPLOAD and the normal upload path below takes over.
      final reviewed = PreparedAsset(
        assetPath: entry.assetPath,
        previewPath: entry.previewPath,
        animatedPreviewPath: entry.animatedPreviewPath,
        sourceUri: entry.sourceUri,
        mime: entry.mime,
        name: entry.name,
        packageSize: entry.packageSize,
        frameCount: entry.frameCount,
        fps: entry.fps,
        crc32: entry.crc32,
        cropScale: entry.cropScale,
        cropOffsetX: entry.cropOffsetX,
        cropOffsetY: entry.cropOffsetY,
        reviewId: entry.reviewId,
        reviewStatus: entry.reviewStatus,
      );
      final previousAsset = _asset;
      // Start the local device switch before updating the preview state.  A
      // large user preview can otherwise delay the native TCP command.
      final dispatchSwitch = _demoMode
          ? null
          : _invokeNative<dynamic>('switchToAsset', {
              'id': entry.deviceId,
              'crc32': crc32Hex(entry.crc32),
            });
      setState(() {
        _status = '切换中...';
        _selectedFactoryId = null;
        // Reflect the selected history item immediately. The device command
        // is asynchronous because it may still be finishing a factory exit
        // animation; waiting for its ACK made the grid feel unresponsive.
        _asset = reviewed;
      });
      if (_demoMode) {
        setState(() {
          _status = '演示已切换';
          _asset = reviewed;
        });
        return;
      }
      try {
        final switchResult = await dispatchSwitch;
        if (!mounted || switchGeneration != _switchGeneration) return;
        final switchPending =
            switchResult is Map && switchResult['pending'] == true;
        if (!switchResultNeedsUpload(switchResult)) {
          setState(() {
            _status = switchPending ? '切换已提交' : '已切换';
            _asset = PreparedAsset(
              assetPath: entry.assetPath,
              previewPath: entry.previewPath,
              animatedPreviewPath: entry.animatedPreviewPath,
              sourceUri: entry.sourceUri,
              mime: entry.mime,
              name: entry.name,
              packageSize: entry.packageSize,
              frameCount: entry.frameCount,
              fps: entry.fps,
              crc32: entry.crc32,
              reviewId: entry.reviewId,
              reviewStatus: entry.reviewStatus,
            );
          });
          return;
        }
        setState(() => _status = '设备缺少素材，重新上传');
      } catch (e) {
        if (!mounted || switchGeneration != _switchGeneration) return;
        setState(() => _asset = previousAsset);
        _showSnack('切换失败: $e');
        setState(() => _status = '切换失败');
        return;
      }
    }
    final asset = PreparedAsset(
      assetPath: entry.assetPath,
      previewPath: entry.previewPath,
      animatedPreviewPath: entry.animatedPreviewPath,
      sourceUri: entry.sourceUri,
      mime: entry.mime,
      name: entry.name,
      packageSize: entry.packageSize,
      frameCount: entry.frameCount,
      fps: entry.fps,
      crc32: entry.crc32,
      cropScale: entry.cropScale,
      cropOffsetX: entry.cropOffsetX,
      cropOffsetY: entry.cropOffsetY,
      reviewId: entry.reviewId,
      reviewStatus: entry.reviewStatus,
    );
    setState(() {
      _media = null;
      _asset = asset;
      _pageIndex = 1;
      _status = '上传历史素材';
      _selectedFactoryId =
          null; // clear factory selection when uploading user content
    });
    await _uploadAsset(asset);
  }

  Future<void> _deleteHistoryEntry(HistoryEntry entry) async {
    await _pendingDeviceDeletesLoad;
    if (isUserDeviceAssetId(entry.deviceId) &&
        (entry.packageSize <= 0 || entry.frameCount <= 0) &&
        (_connected ||
            (entry.assetPath.isNotEmpty &&
                File(entry.assetPath).existsSync()))) {
      try {
        entry = await _repairHistoryIdentity(entry);
      } on PlatformException {
        // Preserve review identity in the durable offline queue; never delete
        // a reused device ID using the old placeholder CRC.
      }
    }
    if (isUserDeviceAssetId(entry.deviceId)) {
      final deletion = PendingDeviceDeletion(
        deviceKey: entry.deviceKey,
        deviceAssetId: entry.deviceId!,
        crc32: entry.crc32,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        reviewId: entry.reviewId,
        name: entry.name,
        needsPackageIdentity: entry.packageSize <= 0 || entry.frameCount <= 0,
      );
      final updated = coalescePendingDeviceDeletions(<PendingDeviceDeletion>[
        ..._pendingDeviceDeletes,
        deletion,
      ]);
      _pendingDeviceDeletes
        ..clear()
        ..addAll(updated);
      try {
        await _savePendingDeviceDeletes();
      } on PlatformException catch (error) {
        if (mounted) {
          _showSnack(error.message ?? '删除队列保存失败');
        }
        return;
      }
    }
    await _deleteNativeAssetFiles(entry);
    setState(() {
      _history.removeWhere(
        (item) => historyEntriesMatch(
          leftAssetPath: item.assetPath,
          leftReviewId: item.reviewId,
          leftCreatedAt: item.createdAt,
          rightAssetPath: entry.assetPath,
          rightReviewId: entry.reviewId,
          rightCreatedAt: entry.createdAt,
        ),
      );
      if (_asset != null &&
          uploadMatchesHistory(
            historyAssetPath: entry.assetPath,
            historyReviewId: entry.reviewId,
            uploadedAssetPath: _asset!.assetPath,
            uploadedReviewId: _asset!.reviewId,
          )) {
        _asset = null;
      }
      _status = '已删除历史记录';
    });
    await _saveHistory();
    if (_connected) {
      await _reconcilePendingDeviceDeletes();
      if (mounted &&
          _pendingDeviceDeletes.any(
            (item) => item.deviceAssetId == entry.deviceId,
          )) {
        _showSnack('已从手机删除，设备删除任务将在重连后重试');
      }
    }
  }

  Future<void> _deleteNativeAssetFiles(HistoryEntry entry) async {
    await _invokeNative<void>('deleteAssetFiles', {
      'assetPath': entry.assetPath,
      'previewPath': entry.previewPath,
      'animatedPreviewPath': entry.animatedPreviewPath,
    });
  }

  Future<void> _confirmDeleteHistoryEntry(HistoryEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xff151515),
        title: const AppText('删除素材'),
        content: AppText(
          entry.name,
          translate: false,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const AppText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const AppText('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _deleteHistoryEntry(entry);
    }
  }

  void _resetCrop() {
    setState(() => _cropTransform = const CropTransform());
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: AppText(
          message,
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w700,
          ),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.white,
        showCloseIcon: true,
        closeIconColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  void _showUpdateSnack(
    String latestVersion, {
    required bool force,
    required String? storeUrl,
  }) {
    if (!mounted) {
      return;
    }
    final message = force ? '发现必须更新版本 $latestVersion' : '发现新版本 $latestVersion';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: AppText(
          message,
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w700,
          ),
        ),
        action: storeUrl == null
            ? null
            : SnackBarAction(
                label: tr('更新'),
                textColor: Colors.black,
                onPressed: () {
                  unawaited(_invokeNative<void>('openUrl', {'url': storeUrl}));
                },
              ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.white,
        showCloseIcon: true,
        closeIconColor: Colors.black,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Future<void> _openGame() async {
    if (_uploading || _preparing) return;
    // BLE game discovery validates its own service. A Wi-Fi connection is
    // neither required nor sufficient to control the P4 game.
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FlyBirdPage(retainConnection: _bluetoothControl),
      ),
    );
    if (mounted) unawaited(_refreshConnectionState());
  }

  void _openLanguage() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppText(
                '语言',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              for (final language in AppLanguage.values)
                ListTile(
                  title: Text(LanguageSettings.label(language)),
                  trailing: LanguageSettings.current.value == language
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () async {
                    try {
                      await LanguageSettings.select(language);
                      if (context.mounted) Navigator.pop(context);
                    } catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: AppText('$error')));
                      }
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppLanguage>(
    valueListenable: LanguageSettings.current,
    builder: (context, language, child) => _buildPage(context),
  );

  Widget _buildPage(BuildContext context) {
    final previewActive = _previewActive;
    final pages = [
      _DevicePage(
        devices: _devices,
        scanning: _scanning,
        connecting: _connecting,
        connected: _connected,
        status: _status,
        sdAvailable: _sdAvailable,
        brightness: _brightness,
        connectedAddress: _connectedAddress,
        onScan: _scan,
        onConnect: _connect,
        onDisconnect: _disconnect,
        onBrightness: _setBrightness,
        supportsAlignment: true,
        alignmentAngleTenths: _alignmentAngleTenths,
        onAlignment: () => unawaited(_openAlignment()),
        onPrivacyPolicy: _showPrivacyPolicy,
        demoMode: _demoMode,
        onEnterDemoMode: _enterDemoMode,
        onExitDemoMode: _exitDemoMode,
        onOpenBrightness: _openBrightness,
        onImport: () => setState(() => _pageIndex = 2),
        onLibrary: () => setState(() {
          _libraryFilter = 1;
          _pageIndex = 1;
        }),
        preview: _PreviewDial(
          active: previewActive && _pageIndex == 0,
          media: null,
          asset: _asset,
          /* The device page shows the same content as the library page: the
           * selected factory animation's video sequence, or the user's own
           * asset. Without this the dial had nothing to draw and fell back to
           * its empty placeholder, which looked like the preview had been
           * removed entirely. */
          factoryVideo:
              _videoQueue.isNotEmpty && _videoIndex < _videoQueue.length
              ? _videoQueue[_videoIndex]
              : null,
          factoryPreview: _selectedFactory?.previewAsset,
          nextVideo:
              _videoQueue.isNotEmpty && _videoIndex + 1 < _videoQueue.length
              ? _videoQueue[_videoIndex + 1]
              : null,
          looping: _selectedFactory?.isLoop == true,
          onFactoryVideoDone:
              _selectedFactory?.isLoop == true || _videoQueue.isEmpty
              ? null
              : _advanceVideo,
          preparing: _uploading,
          progress: _uploadProgress,
        ),
      ),
      _DisplayLibraryPage(
        onAssetUpload: (asset) => unawaited(_uploadAsset(asset)),
        active: previewActive && _pageIndex == 1,
        connected: _connected,
        status: _status,
        asset: _asset,
        history: _history,
        uploading: _uploading,
        uploadProgress: _uploadProgress,
        factoryAnims: _factoryAnims,
        selectedFactoryId: _selectedFactoryId,
        videoQueue: _videoQueue,
        videoIndex: _videoIndex,
        onVideoDone: _advanceVideo,
        onHistoryTap: (entry) => unawaited(_uploadHistoryEntry(entry)),
        onHistoryDelete: (entry) =>
            unawaited(_confirmDeleteHistoryEntry(entry)),
        onFactoryTap: (anim) => unawaited(_switchToFactory(anim)),
        randomEnabled: _randomEnabled,
        randomUpdating: _randomUpdating,
        onRandomToggle: (enabled) => unawaited(_setRandomMode(enabled)),
        filter: _libraryFilter,
        onFilter: (filter) => setState(() => _libraryFilter = filter),
        onImport: () => setState(() => _pageIndex = 2),
      ),
      _MakerPage(
        key: ValueKey('maker-${_media?.uri ?? "empty"}'),
        active: previewActive && _pageIndex == 2,
        media: _media,
        asset: _asset,
        cropTransform: _cropTransform,
        preparing: _preparing,
        uploading: _uploading,
        prepareProgress: _prepareProgress,
        onPick: _pickMedia,
        onSave: _saveMakerAsset,
        onCropChanged: (value) => setState(() => _cropTransform = value),
        onResetCrop: _resetCrop,
        draftName: _draftAssetName,
        onNameChanged: (value) => _draftAssetName = value,
        onClose: () => setState(() => _pageIndex = 1),
      ),
      ReferenceLoopPage(
        enabled: _randomEnabled,
        updating: _randomUpdating,
        factoryCount: _factoryAnims.length,
        onChanged: (enabled) => unawaited(_setRandomMode(enabled)),
        onBack: () => setState(() => _pageIndex = 4),
      ),
      ReferenceSettingsPage(
        onAlignment: () => unawaited(_openAlignment()),
        onBrightness: _openBrightness,
        onMode: () => setState(() => _pageIndex = 3),
        onDevice: () => setState(() => _pageIndex = 0),
        onLibrary: () => setState(() {
          _libraryFilter = 1;
          _pageIndex = 1;
        }),
        onPrivacy: _showPrivacyPolicy,
        onSupport: _openSupport,
        onVersion: _openVersionInfo,
        version: _appVersion,
        firmwareUpdateAvailable: _firmwareUpdateAvailable,
        demoMode: _demoMode,
        onDemo: () => _demoMode ? _exitDemoMode() : _enterDemoMode(),
        onLanguage: _openLanguage,
        onGame: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => GamesPage(onFlyBird: () => unawaited(_openGame())),
          ),
        ),
        onDeviceStatus: _openDeviceStatus,
      ),
    ];

    return Scaffold(
      extendBody: false,
      body: Stack(
        children: [
          const _Backdrop(),
          SafeArea(
            child: Stack(
              children: [
                Positioned.fill(
                  child: IndexedStack(
                    index: _pageIndex == 2 ? 1 : _pageIndex,
                    children: [
                      for (var i = 0; i < pages.length; ++i)
                        i == 2
                            ? const SizedBox.shrink()
                            : ExcludeSemantics(
                                excluding: _pageIndex == 2,
                                child: i == 1
                                    ? pages[i]
                                    : Padding(
                                        padding: const EdgeInsets.only(top: 58),
                                        child: pages[i],
                                      ),
                              ),
                    ],
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: ReferenceTopNavigation(
                    selectedIndex: _pageIndex,
                    connected: _connected,
                    onSelected: (index) => index == 4
                        ? _openSettings()
                        : setState(() => _pageIndex = index),
                  ),
                ),
                if (_pageIndex == 2) ...[
                  const Positioned.fill(
                    child: ColoredBox(color: Colors.black54),
                  ),
                  Positioned.fill(
                    top: 80,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(22),
                      ),
                      child: ColoredBox(color: Colors.black, child: pages[2]),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DisplayLibraryPage extends StatelessWidget {
  const _DisplayLibraryPage({
    required this.active,
    required this.filter,
    required this.onFilter,
    required this.onImport,
    required this.onAssetUpload,
    required this.connected,
    required this.status,
    required this.asset,
    required this.history,
    required this.uploading,
    required this.uploadProgress,
    required this.factoryAnims,
    required this.selectedFactoryId,
    required this.videoQueue,
    required this.videoIndex,
    required this.onVideoDone,
    required this.onHistoryTap,
    required this.onHistoryDelete,
    required this.onFactoryTap,
    required this.randomEnabled,
    required this.randomUpdating,
    required this.onRandomToggle,
  });

  final bool active;
  final bool connected;
  final String status;
  final PreparedAsset? asset;
  final List<HistoryEntry> history;
  final bool uploading;
  final double uploadProgress;
  final List<FactoryAnimation> factoryAnims;
  final String? selectedFactoryId;
  final List<String> videoQueue;
  final int videoIndex;
  final VoidCallback onVideoDone;
  final ValueChanged<HistoryEntry> onHistoryTap;
  final ValueChanged<HistoryEntry> onHistoryDelete;
  final ValueChanged<FactoryAnimation> onFactoryTap;
  final bool randomEnabled;
  final bool randomUpdating;
  final ValueChanged<bool> onRandomToggle;

  final int filter;
  final ValueChanged<int> onFilter;
  final VoidCallback onImport;
  final ValueChanged<PreparedAsset> onAssetUpload;
  void _openSearch(BuildContext context) {
    var query = '';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .86,
        minChildSize: .5,
        maxChildSize: .96,
        builder: (context, controller) => StatefulBuilder(
          builder: (context, update) {
            final factories = factoryAnims
                .where(
                  (item) =>
                      '${item.name} ${item.id}'.toLowerCase().contains(query),
                )
                .toList();
            final users = history
                .where(
                  (item) => '${item.name} ${item.deviceId ?? ""}'
                      .toLowerCase()
                      .contains(query),
                )
                .toList();
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
                    child: Row(
                      children: [
                        const Expanded(
                          child: AppText(
                            '查找动画',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    child: TextField(
                      key: const ValueKey('material-search-input'),
                      onChanged: (value) =>
                          update(() => query = value.trim().toLowerCase()),
                      decoration: InputDecoration(
                        hintText: tr('搜索名称或编号'),
                        prefixIcon: const Icon(Icons.search_rounded),
                        filled: true,
                        fillColor: const Color(0xff171717),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: users.isEmpty && factories.isEmpty
                        ? const Center(
                            child: AppText(
                              '未找到匹配素材',
                              style: TextStyle(color: referenceMuted),
                            ),
                          )
                        : GridView.builder(
                            controller: controller,
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
                                ),
                            itemCount: users.length + factories.length,
                            itemBuilder: (context, index) {
                              if (index < users.length) {
                                final entry = users[index];
                                return _HistoryGridTile(
                                  active: false,
                                  entry: entry,
                                  selected: false,
                                  onLongPress: () {},
                                  onTap: uploading
                                      ? null
                                      : () {
                                          Navigator.pop(context);
                                          onHistoryTap(entry);
                                        },
                                );
                              }
                              final item = factories[index - users.length];
                              return _FactoryGridTile(
                                anim: item,
                                selected: item.id == selectedFactoryId,
                                onTap: uploading
                                    ? null
                                    : () {
                                        Navigator.pop(context);
                                        onFactoryTap(item);
                                      },
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedFactory = selectedFactoryId != null
        ? factoryAnims.cast<FactoryAnimation?>().firstWhere(
            (a) => a?.id == selectedFactoryId,
            orElse: () => null,
          )
        : null;
    final userItems = filter == 2 ? <HistoryEntry>[] : history;
    final factoryItems = filter == 1 ? <FactoryAnimation>[] : factoryAnims;
    final addTile = filter == 1;
    final tabIndex = filter == 1
        ? 0
        : filter == 2
        ? 1
        : 2;
    return Padding(
      padding: const EdgeInsets.only(top: 58),
      child: LayoutBuilder(
        builder: (context, viewport) {
          final double previewHeight = math.min<double>(
            math.max(0, viewport.maxHeight * .51),
            math.max(0.0, viewport.maxWidth - 32),
          );
          return Column(
            children: [
              SizedBox(
                key: const ValueKey('fixed-home-preview'),
                height: previewHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: GestureDetector(
                        key: const ValueKey('home-circle-preview'),
                        onTap: uploading
                            ? null
                            : selectedFactory != null
                            ? () => onFactoryTap(selectedFactory)
                            : asset != null
                            ? () => onAssetUpload(asset!)
                            : onImport,
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: 1,
                            child: FittedBox(
                              child: _PreviewDial(
                                active: active,
                                media: null,
                                asset: asset,
                                factoryPreview: selectedFactory?.previewAsset,
                                factoryVideo:
                                    videoQueue.isNotEmpty &&
                                        videoIndex < videoQueue.length
                                    ? videoQueue[videoIndex]
                                    : null,
                                nextVideo:
                                    videoQueue.isNotEmpty &&
                                        videoIndex + 1 < videoQueue.length
                                    ? videoQueue[videoIndex + 1]
                                    : null,
                                looping: selectedFactory?.isLoop == true,
                                onFactoryVideoDone:
                                    selectedFactory?.isLoop == true ||
                                        videoQueue.isEmpty
                                    ? null
                                    : onVideoDone,
                                preparing: uploading,
                                progress: uploadProgress,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      height: 35,
                      child: IgnorePointer(
                        child: ClipRect(
                          key: const ValueKey('preview-filter-frost'),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.black.withValues(alpha: .05),
                                    Colors.black,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (uploading)
                      Positioned(
                        left: 24,
                        right: 24,
                        bottom: 0,
                        child: LinearProgressIndicator(
                          value: _clamp01(uploadProgress),
                          minHeight: 2,
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: ReferenceSegmentedBar(
                  labels: [tr('我的素材'), tr('出厂素材'), tr('全部素材')],
                  selectedIndex: tabIndex,
                  onSelected: (index) => onFilter([1, 2, 0][index]),
                ),
              ),
              Expanded(
                child: Stack(
                  children: [
                    CustomScrollView(
                      key: const ValueKey('home-material-grid'),
                      slivers: [
                        if (userItems.isEmpty &&
                            factoryItems.isEmpty &&
                            !addTile)
                          const SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: AppText(
                                '还没有素材，添加图片或视频开始制作',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: referenceMuted,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
                          sliver: SliverGrid(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  mainAxisSpacing: 10,
                                  crossAxisSpacing: 10,
                                ),
                            delegate: SliverChildBuilderDelegate(
                              (context, gridIndex) {
                                if (addTile && gridIndex == 0) {
                                  return Material(
                                    color: Colors.black,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      side: const BorderSide(
                                        color: Color(0xff252525),
                                      ),
                                    ),
                                    child: InkWell(
                                      key: const ValueKey('add-material'),
                                      onTap: uploading ? null : onImport,
                                      borderRadius: BorderRadius.circular(14),
                                      child: const Center(
                                        child: Icon(
                                          Icons.add_circle_outline_rounded,
                                          color: referenceMuted,
                                          size: 44,
                                        ),
                                      ),
                                    ),
                                  );
                                }
                                final index = gridIndex - (addTile ? 1 : 0);
                                if (index < userItems.length) {
                                  final entry = userItems[index];
                                  return _HistoryGridTile(
                                    key: ValueKey(
                                      historyEntryIdentity(
                                        assetPath: entry.assetPath,
                                        reviewId: entry.reviewId,
                                        createdAt: entry.createdAt,
                                      ),
                                    ),
                                    active: active,
                                    entry: entry,
                                    selected:
                                        asset != null &&
                                        uploadMatchesHistory(
                                          historyAssetPath: entry.assetPath,
                                          historyReviewId: entry.reviewId,
                                          uploadedAssetPath: asset!.assetPath,
                                          uploadedReviewId: asset!.reviewId,
                                        ),
                                    onTap: uploading
                                        ? null
                                        : () => onHistoryTap(entry),
                                    onLongPress: () => onHistoryDelete(entry),
                                  );
                                }
                                final anim =
                                    factoryItems[index - userItems.length];
                                return _FactoryGridTile(
                                  key: ValueKey('fac_${anim.id}'),
                                  anim: anim,
                                  selected: selectedFactoryId == anim.id,
                                  onTap: uploading
                                      ? null
                                      : () => onFactoryTap(anim),
                                );
                              },
                              childCount:
                                  userItems.length +
                                  factoryItems.length +
                                  (addTile ? 1 : 0),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Positioned(
                      left: 32,
                      right: 32,
                      bottom: 16,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                          child: Material(
                            color: const Color(
                              0xff202020,
                            ).withValues(alpha: .88),
                            child: InkWell(
                              key: const ValueKey('find-animation'),
                              onTap: () => _openSearch(context),
                              child: const SizedBox(
                                height: 46,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.search_rounded, size: 20),
                                    SizedBox(width: 8),
                                    AppText(
                                      '查找动画',
                                      style: TextStyle(fontSize: 14),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MakerPage extends StatefulWidget {
  const _MakerPage({
    super.key,
    required this.active,
    required this.media,
    required this.asset,
    required this.cropTransform,
    required this.preparing,
    required this.uploading,
    required this.prepareProgress,
    required this.onPick,
    required this.onSave,
    required this.onCropChanged,
    required this.onResetCrop,
    required this.draftName,
    required this.onNameChanged,
    required this.onClose,
  });
  final bool active, preparing, uploading;
  final SelectedMedia? media;
  final PreparedAsset? asset;
  final CropTransform cropTransform;
  final double prepareProgress;
  final VoidCallback onPick, onSave, onResetCrop, onClose;
  final ValueChanged<CropTransform> onCropChanged;
  final String draftName;
  final ValueChanged<String> onNameChanged;
  @override
  State<_MakerPage> createState() => _MakerPageState();
}

class _MakerPageState extends State<_MakerPage> {
  late final _name = TextEditingController(text: widget.draftName);
  late int _kind =
      widget.media != null &&
          !_isVideoMime(widget.media!.mime) &&
          widget.media!.mime != 'image/gif'
      ? 1
      : 0;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.preparing || widget.uploading;
    return ListView(
      key: const ValueKey('video-upload-sheet'),
      padding: EdgeInsets.fromLTRB(
        24,
        8,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      children: [
        Row(
          children: [
            const SizedBox(width: 32),
            Expanded(
              child: GestureDetector(
                onVerticalDragEnd: disabled
                    ? null
                    : (details) {
                        if ((details.primaryVelocity ?? 0) > 400) {
                          widget.onClose();
                        }
                      },
                child: Center(
                  child: Container(
                    width: 58,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xff666666),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('close-maker'),
              onPressed: disabled ? null : widget.onClose,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
        const SizedBox(height: 10),
        const AppText(
          '上传动画',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w800,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: 10),
        const AppText(
          '添加素材，调整圆形画面并保存到我的素材。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: referenceMuted),
        ),
        const SizedBox(height: 24),
        ReferenceSegmentedBar(
          labels: const ['动画', '图片'],
          selectedIndex: _kind,
          onSelected: (index) {
            if (disabled) return;
            setState(() => _kind = index);
            widget.onPick();
          },
        ),
        const SizedBox(height: 28),
        const AppText(
          '素材名称',
          style: TextStyle(
            color: Color(0xff777777),
            fontSize: 11,
            letterSpacing: 2,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('maker-name'),
          controller: _name,
          enabled: !disabled,
          onChanged: widget.onNameChanged,
          decoration: InputDecoration(
            hintText: tr('为这个动画取个名字'),
            hintStyle: const TextStyle(fontSize: 13, color: Color(0xff555555)),
            filled: true,
            fillColor: const Color(0xff111111),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xff333333)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xff333333)),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 16,
            ),
          ),
        ),
        const SizedBox(height: 28),
        const AppText(
          '动画素材',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Color(0xff777777),
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 12),
        if (widget.media == null)
          Center(
            child: InkWell(
              key: const ValueKey('maker-pick'),
              onTap: disabled ? null : widget.onPick,
              customBorder: const CircleBorder(),
              child: Container(
                width: 252,
                height: 252,
                decoration: BoxDecoration(
                  color: const Color(0xff0b0b0b),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xff202020)),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.movie_creation_outlined,
                      color: referenceMuted,
                      size: 25,
                    ),
                    SizedBox(height: 10),
                    AppText(
                      '点击添加素材',
                      style: TextStyle(fontSize: 12, color: Color(0xff666666)),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          Center(
            child: _CropPreview(
              active: widget.active && !widget.preparing,
              media: widget.media,
              asset: widget.asset,
              transform: widget.cropTransform,
              preparing: widget.preparing,
              progress: widget.prepareProgress,
              onChanged: disabled ? null : widget.onCropChanged,
            ),
          ),
        const SizedBox(height: 12),
        if (widget.media != null) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: disabled ? null : widget.onPick,
                child: const AppText(
                  '更换素材',
                  style: TextStyle(color: referenceMuted, fontSize: 12),
                ),
              ),
              const SizedBox(width: 20),
              TextButton(
                onPressed: disabled ? null : widget.onResetCrop,
                child: const AppText(
                  '重置裁剪',
                  style: TextStyle(color: referenceMuted, fontSize: 12),
                ),
              ),
            ],
          ),
          Slider(
            value: widget.cropTransform.scale,
            min: 1,
            max: 4,
            divisions: 30,
            onChanged: disabled
                ? null
                : (value) => widget.onCropChanged(
                    widget.cropTransform.copyWith(scale: value),
                  ),
          ),
          const AppText(
            '拖动、双指缩放调整画面',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: referenceMuted),
          ),
        ],
        const SizedBox(height: 28),
        SizedBox(
          height: 42,
          child: FilledButton.icon(
            key: const ValueKey('maker-save'),
            onPressed: disabled || widget.media == null ? null : widget.onSave,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xff12341b),
              foregroundColor: const Color(0xffb8dcb8),
              disabledBackgroundColor: const Color(0xff101510),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            icon: const Icon(Icons.save_alt_rounded, size: 15),
            label: AppText(
              widget.preparing ? '处理中…' : '保存到我的素材',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ),
        if (widget.preparing) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: widget.prepareProgress == 0
                ? null
                : _clamp01(widget.prepareProgress),
            minHeight: 3,
          ),
        ],
        const SizedBox(height: 12),
        const AppText(
          '素材由服务器处理后直接下发',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 10, color: Color(0xff666666)),
        ),
      ],
    );
  }
}

class _DevicePage extends StatefulWidget {
  const _DevicePage({
    required this.preview,
    required this.onOpenBrightness,
    required this.onImport,
    required this.onLibrary,
    required this.devices,
    required this.scanning,
    required this.connecting,
    required this.connected,
    required this.status,
    required this.sdAvailable,
    required this.brightness,
    required this.connectedAddress,
    required this.onScan,
    required this.onConnect,
    required this.onDisconnect,
    required this.onBrightness,
    required this.supportsAlignment,
    required this.alignmentAngleTenths,
    required this.onAlignment,
    required this.onPrivacyPolicy,
    required this.demoMode,
    required this.onEnterDemoMode,
    required this.onExitDemoMode,
  });

  final List<BadgeDevice> devices;
  final bool scanning;
  final bool connecting;
  final bool connected;
  final String status;
  final bool sdAvailable;
  final int brightness;
  final String? connectedAddress;
  final VoidCallback onScan;
  final ValueChanged<BadgeDevice> onConnect;
  final VoidCallback onDisconnect;
  final ValueChanged<int> onBrightness;
  final bool supportsAlignment;
  final VoidCallback onAlignment;
  final VoidCallback onPrivacyPolicy;
  final bool demoMode;
  final VoidCallback onEnterDemoMode;
  final VoidCallback onExitDemoMode;

  final int alignmentAngleTenths;
  final Widget preview;
  final VoidCallback onOpenBrightness, onImport, onLibrary;
  @override
  State<_DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<_DevicePage> {
  int _tab = 0;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
    children: [
      SizedBox(
        height: 166,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xff080809),
            border: Border.all(color: const Color(0xff131315), width: .6),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Stack(
            children: [
              Center(
                child: FractionallySizedBox(
                  heightFactor: .82,
                  child: widget.connected
                      ? ReferenceDeviceDisplay(
                          child: FittedBox(child: widget.preview),
                        )
                      : const ReferenceDeviceDisplay(),
                ),
              ),
              Positioned(
                left: 12,
                bottom: 12,
                child: SizedBox.square(
                  dimension: 28,
                  child: IconButton.filled(
                    padding: EdgeInsets.zero,
                    onPressed: widget.onOpenBrightness,
                    icon: const Icon(Icons.lightbulb_outline, size: 18),
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xff222222),
                      foregroundColor: referenceMuted,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 18),
      const AppText(
        'DotLoop',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 3),
      AppText(
        widget.connected ? '已连接' : '未连接',
        textAlign: TextAlign.center,
        style: const TextStyle(color: referenceMuted, fontSize: 12),
      ),
      const SizedBox(height: 16),
      ReferenceSegmentedBar(
        labels: const ['设置', '上传', '已下载'],
        selectedIndex: _tab,
        onSelected: (value) => setState(() => _tab = value),
      ),
      const SizedBox(height: 12),
      if (_tab == 0) ...[
        SizedBox(
          height: 40,
          child: FilledButton(
            onPressed: widget.scanning
                ? null
                : widget.connected
                ? widget.onDisconnect
                : widget.onScan,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xff202020),
              foregroundColor: referenceBlue,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: widget.scanning
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : AppText(
                    widget.connected ? '断开设备' : '连接设备',
                    style: const TextStyle(fontSize: 13),
                  ),
          ),
        ),
        if (widget.devices.isEmpty && !widget.connected)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Column(
              children: [
                AppText(
                  '未发现设备',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 6),
                AppText(
                  '确认设备已开机并在附近',
                  style: TextStyle(color: referenceMuted, fontSize: 12),
                ),
              ],
            ),
          ),
        for (final device in widget.devices)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: ReferencePanel(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.memory_outlined, size: 30),
                title: AppText(
                  device.name,
                  translate: false,
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: AppText(
                  device.address,
                  style: const TextStyle(fontSize: 11, color: referenceMuted),
                ),
                trailing: TextButton(
                  onPressed: widget.connecting
                      ? null
                      : () => widget.onConnect(device),
                  child: AppText(
                    widget.connectedAddress == device.address ? '已连接' : '连接',
                    style: const TextStyle(color: referenceBlue, fontSize: 12),
                  ),
                ),
              ),
            ),
          ),
        if (widget.connected) ...[
          const SizedBox(height: 20),
          ReferencePanel(
            child: Column(
              children: [
                _row('屏幕亮度', '${widget.brightness}%', widget.onOpenBrightness),
                if (widget.supportsAlignment) ...[
                  const Divider(height: 18, color: Color(0xff2b2b2b)),
                  _row(
                    '安装角度校正',
                    '${(widget.alignmentAngleTenths / 10).toStringAsFixed(1)}°',
                    widget.onAlignment,
                    key: const ValueKey('device-alignment'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ] else if (_tab == 1) ...[
        ReferencePanel(
          child: Column(
            children: [
              const AppText(
                '上传动画',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const AppText(
                '添加图片或视频，调整画面后保存并上传到设备。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: referenceMuted,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: widget.onImport,
                child: const AppText(
                  '添加素材',
                  style: TextStyle(color: referenceBlue),
                ),
              ),
            ],
          ),
        ),
      ] else
        ReferencePanel(
          child: Column(
            children: [
              const AppText(
                '我的素材',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const AppText(
                '查看已导入的素材，并切换设备画面。',
                style: TextStyle(color: referenceMuted, fontSize: 12),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: widget.onLibrary,
                child: const AppText(
                  '查看我的素材',
                  style: TextStyle(color: referenceBlue),
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 24),
      Center(
        child: Wrap(
          spacing: 16,
          children: [
            TextButton(
              onPressed: widget.demoMode
                  ? widget.onExitDemoMode
                  : widget.onEnterDemoMode,
              child: AppText(
                widget.demoMode ? '退出演示模式' : '审核演示',
                style: const TextStyle(color: referenceMuted, fontSize: 11),
              ),
            ),
            TextButton(
              key: const ValueKey('privacy-policy-link'),
              onPressed: widget.onPrivacyPolicy,
              child: const AppText(
                '隐私政策',
                style: TextStyle(color: referenceMuted, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _row(String label, String value, VoidCallback action, {Key? key}) =>
      InkWell(
        key: key,
        onTap: action,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              AppText(label, style: const TextStyle(fontSize: 13)),
              const Spacer(),
              AppText(
                value,
                style: const TextStyle(color: referenceMuted, fontSize: 12),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, size: 15, color: referenceMuted),
            ],
          ),
        ),
      );
}

class _HistoryGridTile extends StatelessWidget {
  const _HistoryGridTile({
    super.key,
    required this.active,
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final bool active;
  final HistoryEntry entry;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final previewPath = entry.previewPath ?? entry.animatedPreviewPath;
    final overlayColor = _reviewOverlayColor(entry);
    final reviewLabel = _reviewStatusLabel(entry);
    return ReferenceMaterialTile(
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: [
            _HistoryPreview(
              active: active,
              entry: entry,
              previewPath: previewPath,
              transform: entry.cropTransform,
            ),
            if (overlayColor != null) ColoredBox(color: overlayColor),
            if (reviewLabel != null)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .65),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: AppText(
                    reviewLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CropPreview extends StatefulWidget {
  const _CropPreview({
    required this.active,
    required this.media,
    required this.asset,
    required this.transform,
    required this.preparing,
    required this.progress,
    required this.onChanged,
  });

  final bool active;
  final SelectedMedia? media;
  final PreparedAsset? asset;
  final CropTransform transform;
  final bool preparing;
  final double progress;
  final ValueChanged<CropTransform>? onChanged;

  @override
  State<_CropPreview> createState() => _CropPreviewState();
}

class _CropPreviewState extends State<_CropPreview> {
  CropTransform _startTransform = const CropTransform();
  final Map<int, Offset> _activePointers = {};
  Offset _startFocalPoint = Offset.zero;
  double _startPointerDistance = 1;
  double _previewSize = 284;

  @override
  void dispose() {
    _activePointers.clear();
    super.dispose();
  }

  void _beginPointerTransform() {
    _startTransform = widget.transform;
    _startFocalPoint = _currentFocalPoint();
    _startPointerDistance = _currentPointerDistance();
  }

  void _handlePointerDown(PointerDownEvent event) {
    final onChanged = widget.onChanged;
    if (onChanged == null) {
      return;
    }
    _activePointers[event.pointer] = event.localPosition;
    _beginPointerTransform();
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final onChanged = widget.onChanged;
    if (onChanged == null || !_activePointers.containsKey(event.pointer)) {
      return;
    }
    _activePointers[event.pointer] = event.localPosition;
    final focalPoint = _currentFocalPoint();
    final scaleDelta = _currentPointerDistance() / _startPointerDistance;
    final nextScale = (_startTransform.scale * scaleDelta)
        .clamp(1.0, 4.0)
        .toDouble();
    final delta = focalPoint - _startFocalPoint;
    final nextOffset =
        _startTransform.offset +
        Offset(delta.dx / _previewSize, delta.dy / _previewSize);
    onChanged(_startTransform.copyWith(scale: nextScale, offset: nextOffset));
  }

  void _handlePointerUp(PointerEvent event) {
    if (_activePointers.remove(event.pointer) != null &&
        _activePointers.isNotEmpty) {
      _beginPointerTransform();
    }
  }

  Offset _currentFocalPoint() {
    if (_activePointers.isEmpty) {
      return Offset.zero;
    }
    var dx = 0.0;
    var dy = 0.0;
    for (final point in _activePointers.values) {
      dx += point.dx;
      dy += point.dy;
    }
    return Offset(dx / _activePointers.length, dy / _activePointers.length);
  }

  double _currentPointerDistance() {
    if (_activePointers.length < 2) {
      return 1;
    }
    final points = _activePointers.values.take(2).toList(growable: false);
    return (points[0] - points[1]).distance.clamp(1.0, double.infinity);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _previewSize = math
            .min(
              284,
              constraints.maxWidth.isFinite ? constraints.maxWidth : 284,
            )
            .toDouble();
        return Container(
          width: _previewSize,
          height: _previewSize,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.18),
                Colors.white.withValues(alpha: 0.03),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.white.withValues(alpha: 0.08),
                blurRadius: 36,
                spreadRadius: 2,
              ),
            ],
          ),
          child: RawGestureDetector(
            gestures: widget.onChanged == null
                ? const <Type, GestureRecognizerFactory>{}
                : <Type, GestureRecognizerFactory>{
                    EagerGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          EagerGestureRecognizer
                        >(() => EagerGestureRecognizer(), (recognizer) {}),
                  },
            child: ClipOval(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _handlePointerDown,
                onPointerMove: _handlePointerMove,
                onPointerUp: _handlePointerUp,
                onPointerCancel: _handlePointerUp,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DecoratedBox(
                      decoration: const BoxDecoration(color: Colors.black),
                    ),
                    _TransformedPreviewMedia(
                      active: widget.active,
                      media: widget.media,
                      asset: widget.asset,
                      transform: widget.transform,
                    ),
                    if (widget.media == null &&
                        widget.asset == null &&
                        !widget.preparing)
                      const Center(
                        child: Icon(
                          Icons.add_photo_alternate_outlined,
                          size: 72,
                          color: Colors.white,
                        ),
                      ),
                    if (widget.preparing)
                      ColoredBox(
                        color: Colors.black54,
                        child: Center(
                          child: SizedBox(
                            width: 88,
                            height: 88,
                            child: CircularProgressIndicator(
                              value: widget.progress == 0
                                  ? null
                                  : _clamp01(widget.progress),
                              strokeWidth: 6,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TransformedPreviewMedia extends StatelessWidget {
  const _TransformedPreviewMedia({
    required this.active,
    required this.media,
    required this.asset,
    required this.transform,
  });

  final bool active;
  final SelectedMedia? media;
  final PreparedAsset? asset;
  final CropTransform transform;

  @override
  Widget build(BuildContext context) {
    final child = _previewChild();
    if (child == null) {
      return const SizedBox.expand();
    }
    return _CropTransformView(transform: transform, child: child);
  }

  Widget? _previewChild() {
    final selected = media;
    if (selected != null && _isVideoMime(selected.mime)) {
      return _VideoPreview(
        key: ValueKey('maker-video-${selected.uri}'),
        uri: selected.uri,
        active: active,
      );
    }
    if (active && _hasPreviewPath(selected?.animatedPreviewPath)) {
      return Image.file(
        File(selected!.animatedPreviewPath!),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: _blackPreviewFallback,
      );
    }
    if (selected?.previewBytes != null) {
      return Image.memory(
        selected!.previewBytes!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }
    if (active && _hasPreviewPath(asset?.animatedPreviewPath)) {
      return Image.file(
        File(asset!.animatedPreviewPath!),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: _blackPreviewFallback,
      );
    }
    if (_hasPreviewPath(asset?.previewPath)) {
      return Image.file(
        File(asset!.previewPath!),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: _blackPreviewFallback,
      );
    }
    return null;
  }
}

class _CropTransformView extends StatelessWidget {
  const _CropTransformView({required this.transform, required this.child});

  final CropTransform transform;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = math.min(
          constraints.maxWidth.isFinite ? constraints.maxWidth : 0,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 0,
        );
        return Transform.translate(
          offset: Offset(
            transform.offset.dx * size,
            transform.offset.dy * size,
          ),
          child: Transform.scale(scale: transform.scale, child: child),
        );
      },
    );
  }
}

class _PreviewDial extends StatelessWidget {
  const _PreviewDial({
    required this.active,
    required this.media,
    required this.asset,
    this.factoryVideo,
    this.factoryPreview,
    this.nextVideo,
    this.looping = false,
    this.onFactoryVideoDone,
    required this.preparing,
    required this.progress,
  });

  final bool active;
  final SelectedMedia? media;
  final PreparedAsset? asset;
  final String? factoryVideo;
  final String? factoryPreview;
  final String? nextVideo;
  final bool looping;
  final VoidCallback? onFactoryVideoDone;
  final bool preparing;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final transform = asset?.cropTransform ?? const CropTransform();

    return SizedBox(
      width: 284,
      height: 284,
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(decoration: const BoxDecoration(color: Colors.black)),
            if (asset == null && media == null && factoryPreview != null)
              StaticMaterialPreview(
                key: const ValueKey('factory-preview-fallback'),
                image: _isLocalFilePath(factoryPreview!)
                    ? FileImage(_fileFromPath(factoryPreview!))
                    : AssetImage(factoryPreview!),
              ),
            if (media != null &&
                _isVideoMime(media!.mime) &&
                media!.previewBytes != null)
              Image.memory(
                media!.previewBytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              )
            else if (asset != null &&
                _isVideoMime(asset!.mime) &&
                _hasPreviewPath(asset!.previewPath))
              StaticMaterialPreview(
                image: FileImage(File(asset!.previewPath!)),
              ),
            if (active && media != null && _isVideoMime(media!.mime))
              _VideoPreview(
                key: ValueKey('dial-media-video-${media!.uri}'),
                uri: media!.uri,
                active: active,
              )
            else if (active &&
                asset != null &&
                _isVideoMime(asset!.mime) &&
                asset!.sourceUri != null)
              _CropTransformView(
                transform: transform,
                child: _VideoPreview(
                  key: ValueKey('dial-asset-video-${asset!.sourceUri}'),
                  uri: asset!.sourceUri!,
                  active: active,
                ),
              )
            else if (media?.previewBytes != null)
              Image.memory(
                media!.previewBytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              )
            else if (active && _hasPreviewPath(media?.animatedPreviewPath))
              Image.file(
                File(media!.animatedPreviewPath!),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: _blackPreviewFallback,
              )
            else if (active && _hasPreviewPath(asset?.animatedPreviewPath))
              _CropTransformView(
                transform: transform,
                child: Image.file(
                  File(asset!.animatedPreviewPath!),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: _blackPreviewFallback,
                ),
              )
            else if (_hasPreviewPath(asset?.previewPath))
              Image.file(
                File(asset!.previewPath!),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: _blackPreviewFallback,
              )
            else if (active && factoryVideo != null)
              FactoryVideoPreview(
                currentVideo: factoryVideo!,
                nextVideo: nextVideo,
                active: active,
                looping: looping,
                onDone: onFactoryVideoDone,
              )
            else if (factoryPreview == null)
              const Center(
                child: Icon(
                  Icons.perm_media_outlined,
                  size: 72,
                  color: Colors.white,
                ),
              ),
            if (preparing)
              ColoredBox(
                color: Colors.black54,
                child: Center(
                  child: SizedBox(
                    width: 88,
                    height: 88,
                    child: CircularProgressIndicator(
                      value: progress == 0 ? null : _clamp01(progress),
                      strokeWidth: 6,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _VideoPreview extends StatefulWidget {
  const _VideoPreview({super.key, required this.uri, required this.active});

  final String uri;
  final bool active;

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  VideoPlayerController? _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(covariant _VideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri) {
      _controller?.dispose();
      _controller = null;
      _ready = false;
      _open();
    } else if (oldWidget.active != widget.active) {
      unawaited(_syncPlayback());
    }
  }

  Future<void> _open() async {
    final uri = Uri.parse(widget.uri);
    final controller = uri.scheme == 'content'
        ? VideoPlayerController.contentUri(uri)
        : VideoPlayerController.file(File(uri.toFilePath()));
    _controller = controller;
    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0);
      await _syncPlayback(controller);
      if (mounted && identical(_controller, controller)) {
        setState(() => _ready = true);
      }
    } catch (_) {
      await controller.dispose();
      if (mounted && identical(_controller, controller)) {
        setState(() {
          _controller = null;
          _ready = false;
        });
      }
    }
  }

  Future<void> _syncPlayback([VideoPlayerController? pendingController]) async {
    final controller = pendingController ?? _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    try {
      if (widget.active) {
        await controller.play();
      } else {
        await controller.pause();
      }
    } catch (_) {
      // Preview playback is best-effort; native codecs may reject stale handles.
    }
  }

  @override
  void deactivate() {
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      unawaited(controller.pause());
    }
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    unawaited(_syncPlayback());
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (!_ready || controller == null) {
      return const SizedBox.expand();
    }
    return RepaintBoundary(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: controller.value.size.width,
          height: controller.value.size.height,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }
}

class _HistoryPreview extends StatelessWidget {
  const _HistoryPreview({
    required this.active,
    required this.entry,
    required this.previewPath,
    required this.transform,
  });

  final bool active;
  final HistoryEntry entry;
  final String? previewPath;
  final CropTransform transform;

  @override
  Widget build(BuildContext context) {
    Widget? child;
    if (_hasPreviewPath(previewPath)) {
      child = StaticMaterialPreview(image: FileImage(File(previewPath!)));
    }

    if (child == null) {
      return const ColoredBox(
        color: Color(0xff0d0c0e),
        child: Icon(Icons.image, color: Colors.white),
      );
    }

    return _CropTransformView(transform: transform, child: child);
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.black, Colors.black],
        ),
      ),
      child: const SizedBox.expand(),
    );
  }
}

class BadgeDevice {
  const BadgeDevice({
    required this.address,
    required this.name,
    required this.rssi,
    required this.serviceMatch,
  });

  factory BadgeDevice.fromMap(Map<String, dynamic> map) {
    return BadgeDevice(
      address: (map['address'] as String?) ?? '',
      name: (map['name'] as String?)?.isNotEmpty == true
          ? map['name'] as String
          : 'DotLoop',
      rssi: (map['rssi'] as num?)?.toInt() ?? -127,
      serviceMatch: map['serviceMatch'] == true,
    );
  }

  final String address;
  final String name;
  final int rssi;
  final bool serviceMatch;
}

class SelectedMedia {
  const SelectedMedia({
    required this.uri,
    required this.name,
    required this.size,
    required this.mime,
    required this.previewBytes,
    required this.animatedPreviewPath,
  });

  factory SelectedMedia.fromMap(Map<String, dynamic> map) {
    return SelectedMedia(
      uri: (map['uri'] as String?) ?? '',
      name: (map['name'] as String?) ?? '素材',
      size: (map['size'] as num?)?.toInt() ?? 0,
      mime: (map['mime'] as String?) ?? 'image/*',
      previewBytes: map['previewBytes'] as Uint8List?,
      animatedPreviewPath: _readNullableString(map['animatedPreviewPath']),
    );
  }

  final String uri;
  final String name;
  final int size;
  final String mime;
  final Uint8List? previewBytes;
  final String? animatedPreviewPath;

  SelectedMedia copyWith({String? animatedPreviewPath}) {
    return SelectedMedia(
      uri: uri,
      name: name,
      size: size,
      mime: mime,
      previewBytes: previewBytes,
      animatedPreviewPath: animatedPreviewPath ?? this.animatedPreviewPath,
    );
  }
}

class PreparedAsset {
  const PreparedAsset({
    required this.assetPath,
    required this.previewPath,
    required this.animatedPreviewPath,
    required this.sourceUri,
    required this.mime,
    required this.name,
    required this.packageSize,
    required this.frameCount,
    required this.fps,
    required this.crc32,
    this.cropScale = 1,
    this.cropOffsetX = 0,
    this.cropOffsetY = 0,
    this.reviewId,
    this.reviewStatus = 'local',
  });

  factory PreparedAsset.fromMap(Map<String, dynamic> map) {
    return PreparedAsset(
      assetPath: (map['assetPath'] as String?) ?? '',
      previewPath: _readNullableString(map['previewPath']),
      animatedPreviewPath: _readNullableString(map['animatedPreviewPath']),
      sourceUri: _readNullableString(map['sourceUri']),
      mime: (map['mime'] as String?) ?? 'application/octet-stream',
      name: (map['name'] as String?) ?? '素材',
      packageSize: (map['packageSize'] as num?)?.toInt() ?? 0,
      frameCount: (map['frameCount'] as num?)?.toInt() ?? 1,
      fps: (map['fps'] as num?)?.toInt() ?? 1,
      crc32: (map['crc32'] as num?)?.toInt() ?? 0,
      cropScale: (map['cropScale'] as num?)?.toDouble() ?? 1,
      cropOffsetX: (map['cropOffsetX'] as num?)?.toDouble() ?? 0,
      cropOffsetY: (map['cropOffsetY'] as num?)?.toDouble() ?? 0,
      reviewId: _readNullableString(map['reviewId']),
      reviewStatus: (map['reviewStatus'] as String?) ?? 'local',
    );
  }

  final String assetPath;
  final String? previewPath;
  final String? animatedPreviewPath;
  final String? sourceUri;
  final String mime;
  final String name;
  final int packageSize;
  final int frameCount;
  final int fps;
  final int crc32;
  final double cropScale;
  final double cropOffsetX;
  final double cropOffsetY;
  final String? reviewId;
  final String reviewStatus;

  PreparedAsset copyWith({
    CropTransform? cropTransform,
    String? animatedPreviewPath,
    String? reviewId,
    String? reviewStatus,
  }) {
    return PreparedAsset(
      assetPath: assetPath,
      previewPath: previewPath,
      animatedPreviewPath: animatedPreviewPath ?? this.animatedPreviewPath,
      sourceUri: sourceUri,
      mime: mime,
      name: name,
      packageSize: packageSize,
      frameCount: frameCount,
      fps: fps,
      crc32: crc32,
      cropScale: cropTransform?.scale ?? cropScale,
      cropOffsetX: cropTransform?.offset.dx ?? cropOffsetX,
      cropOffsetY: cropTransform?.offset.dy ?? cropOffsetY,
      reviewId: reviewId ?? this.reviewId,
      reviewStatus: reviewStatus ?? this.reviewStatus,
    );
  }

  CropTransform get cropTransform {
    return CropTransform(
      scale: cropScale,
      offset: Offset(cropOffsetX, cropOffsetY),
    );
  }
}

class CropTransform {
  const CropTransform({this.scale = 1, this.offset = Offset.zero});

  final double scale;
  final Offset offset;

  CropTransform copyWith({double? scale, Offset? offset}) {
    return CropTransform(
      scale: (scale ?? this.scale).clamp(1.0, 4.0).toDouble(),
      offset: _clampCropOffset(offset ?? this.offset),
    );
  }
}

class HistoryEntry {
  const HistoryEntry({
    required this.assetPath,
    required this.previewPath,
    required this.animatedPreviewPath,
    required this.sourceUri,
    required this.mime,
    required this.name,
    required this.packageSize,
    required this.frameCount,
    required this.fps,
    required this.crc32,
    required this.createdAt,
    required this.cropScale,
    required this.cropOffsetX,
    required this.cropOffsetY,
    this.deviceId,
    this.deviceKey,
    this.reviewId,
    this.reviewStatus = 'local',
  });

  factory HistoryEntry.fromAsset(
    PreparedAsset asset, {
    CropTransform cropTransform = const CropTransform(),
  }) {
    return HistoryEntry(
      assetPath: asset.assetPath,
      previewPath: asset.previewPath,
      animatedPreviewPath: asset.animatedPreviewPath,
      sourceUri: asset.sourceUri,
      mime: asset.mime,
      name: asset.name,
      packageSize: asset.packageSize,
      frameCount: asset.frameCount,
      fps: asset.fps,
      crc32: asset.crc32,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      cropScale: cropTransform.scale,
      cropOffsetX: cropTransform.offset.dx,
      cropOffsetY: cropTransform.offset.dy,
      reviewId: asset.reviewId,
      reviewStatus: asset.reviewStatus,
    );
  }

  factory HistoryEntry.fromMap(Map<String, dynamic> map) {
    return HistoryEntry(
      assetPath: (map['assetPath'] as String?) ?? '',
      previewPath: _readNullableString(map['previewPath']),
      animatedPreviewPath: _readNullableString(map['animatedPreviewPath']),
      sourceUri: _readNullableString(map['sourceUri']),
      mime: (map['mime'] as String?) ?? 'application/octet-stream',
      name: (map['name'] as String?) ?? '素材',
      packageSize: (map['packageSize'] as num?)?.toInt() ?? 0,
      frameCount: (map['frameCount'] as num?)?.toInt() ?? 1,
      fps: (map['fps'] as num?)?.toInt() ?? 1,
      crc32: (map['crc32'] as num?)?.toInt() ?? 0,
      createdAt: (map['createdAt'] as num?)?.toInt() ?? 0,
      cropScale: (map['cropScale'] as num?)?.toDouble() ?? 1,
      cropOffsetX: (map['cropOffsetX'] as num?)?.toDouble() ?? 0,
      cropOffsetY: (map['cropOffsetY'] as num?)?.toDouble() ?? 0,
      deviceId: _readNullableString(map['deviceId']),
      deviceKey: _readNullableString(map['deviceKey']),
      reviewId: _readNullableString(map['reviewId']),
      reviewStatus: (map['reviewStatus'] as String?) ?? 'local',
    );
  }

  Map<String, Object?> toMap() {
    return {
      'assetPath': assetPath,
      'previewPath': previewPath,
      'animatedPreviewPath': animatedPreviewPath,
      'sourceUri': sourceUri,
      'mime': mime,
      'name': name,
      'packageSize': packageSize,
      'frameCount': frameCount,
      'fps': fps,
      'crc32': crc32,
      'createdAt': createdAt,
      'cropScale': cropScale,
      'cropOffsetX': cropOffsetX,
      'cropOffsetY': cropOffsetY,
      if (deviceId != null) 'deviceId': deviceId,
      if (deviceKey != null) 'deviceKey': deviceKey,
      if (reviewId != null) 'reviewId': reviewId,
      'reviewStatus': reviewStatus,
    };
  }

  final String assetPath;
  final String? previewPath;
  final String? animatedPreviewPath;
  final String? sourceUri;
  final String mime;
  final String name;
  final int packageSize;
  final int frameCount;
  final int fps;
  final int crc32;
  final int createdAt;
  final double cropScale;
  final double cropOffsetX;
  final double cropOffsetY;
  final String? deviceId;
  final String? deviceKey;
  final String? reviewId;
  final String reviewStatus;

  CropTransform get cropTransform {
    return CropTransform(
      scale: cropScale,
      offset: Offset(cropOffsetX, cropOffsetY),
    );
  }

  HistoryEntry copyWith({
    String? assetPath,
    int? packageSize,
    int? frameCount,
    int? fps,
    int? crc32,
    String? animatedPreviewPath,
    String? deviceId,
    String? deviceKey,
    String? reviewId,
    String? reviewStatus,
    bool clearDeviceIdentity = false,
  }) {
    return HistoryEntry(
      assetPath: assetPath ?? this.assetPath,
      previewPath: previewPath,
      animatedPreviewPath: animatedPreviewPath ?? this.animatedPreviewPath,
      sourceUri: sourceUri,
      mime: mime,
      name: name,
      packageSize: packageSize ?? this.packageSize,
      frameCount: frameCount ?? this.frameCount,
      fps: fps ?? this.fps,
      crc32: crc32 ?? this.crc32,
      createdAt: createdAt,
      cropScale: cropScale,
      cropOffsetX: cropOffsetX,
      cropOffsetY: cropOffsetY,
      deviceId: clearDeviceIdentity ? null : deviceId ?? this.deviceId,
      deviceKey: clearDeviceIdentity ? null : deviceKey ?? this.deviceKey,
      reviewId: reviewId ?? this.reviewId,
      reviewStatus: reviewStatus ?? this.reviewStatus,
    );
  }
}

Map<String, dynamic> _asStringMap(Object? value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return <String, dynamic>{};
}

double _readDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return 0;
}

double _clamp01(double value) => value.clamp(0.0, 1.0).toDouble();

Offset _clampCropOffset(Offset value) {
  return Offset(
    value.dx.clamp(-1.5, 1.5).toDouble(),
    value.dy.clamp(-1.5, 1.5).toDouble(),
  );
}

int resolveBadgePackageBudget({required bool sdAvailable}) {
  const legacyFlashBudget = 10 * 1024 * 1024;
  const sdStreamBudget = 512 * 1024 * 1024;
  return sdAvailable ? sdStreamBudget : legacyFlashBudget;
}

Color? _reviewOverlayColor(HistoryEntry entry) {
  if (entry.reviewStatus == 'approved') {
    return null;
  }
  if (entry.reviewStatus == 'rejected') {
    return Colors.redAccent.withValues(alpha: 0.34);
  }
  return Colors.black.withValues(alpha: 0.48);
}

String? _reviewStatusLabel(HistoryEntry entry) {
  if (entry.reviewStatus == 'approved') {
    return null;
  }
  if (entry.reviewStatus == 'rejected') {
    return '违规';
  }
  return '处理中';
}

String? _readNullableString(Object? value) {
  if (value is String && value.isNotEmpty && value != 'null') {
    return value;
  }
  return null;
}

String _normalizeHardware(Object? value) {
  final hardware = value?.toString().trim().toLowerCase() ?? '';
  return hardware.startsWith('esp32s3') ? 'esp32s3' : 'esp32p4';
}

bool _hasPreviewPath(String? path) =>
    path != null && path.isNotEmpty && _previewFileExists(path);

bool _previewFileExists(String path) {
  try {
    return _fileFromPath(path).existsSync();
  } on FileSystemException {
    return false;
  } on FormatException {
    return false;
  }
}

bool _isLocalFilePath(String path) {
  if (path.startsWith('file://')) {
    return true;
  }
  if (path.startsWith('/')) {
    return true;
  }
  return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
}

File _fileFromPath(String path) {
  if (path.startsWith('file://')) {
    return File(Uri.parse(path).toFilePath());
  }
  return File(path);
}

Widget _blackPreviewFallback(
  BuildContext context,
  Object error,
  StackTrace? stackTrace,
) {
  return const ColoredBox(color: Colors.black);
}

bool _isVideoMime(String mime) => mime.toLowerCase().startsWith('video/');

String? _guessMimeFromPath(String? path) {
  if (path == null || path.isEmpty) {
    return null;
  }
  final lower = path.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.mp4')) return 'video/mp4';
  return 'application/octet-stream';
}

class FactoryAnimation {
  const FactoryAnimation({
    required this.id,
    required this.name,
    required this.previewAsset,
    this.type = 'split',
    this.firstVideo,
    this.secondVideo,
    this.loopVideo,
    this.protected = false,
    this.transitions = const {},
  });

  final String id;
  final String name;
  final String previewAsset;
  final String type;
  final String? firstVideo;
  final String? secondVideo;
  final String? loopVideo;
  final bool protected;
  final Map<String, String> transitions;

  bool get isLoop => type == 'loop';

  factory FactoryAnimation.fromMap(Map<String, dynamic> map) {
    return FactoryAnimation(
      id: (map['id'] as String?) ?? '',
      name: (map['name'] as String?) ?? '',
      previewAsset: (map['previewAsset'] as String?) ?? '',
      type: (map['type'] as String?) ?? 'split',
      firstVideo: _readNullableString(map['firstVideo']),
      secondVideo: _readNullableString(map['secondVideo']),
      loopVideo: _readNullableString(map['loopVideo']),
      protected: map['protected'] == true,
      transitions: _asStringMap(
        map['transitions'],
      ).map((k, v) => MapEntry(k, v.toString())),
    );
  }

  /// Get the exit animation video for switching to [targetId].
  /// Returns third_half if a special transition exists, else secondVideo.
  String? exitVideo(String? targetId) {
    if (targetId != null && transitions.containsKey(targetId)) {
      return transitions[targetId];
    }
    return secondVideo;
  }
}

class _FactoryGridTile extends StatelessWidget {
  const _FactoryGridTile({
    super.key,
    required this.anim,
    required this.selected,
    this.onTap,
  });

  final FactoryAnimation anim;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ReferenceMaterialTile(
    selected: selected,
    onTap: onTap,
    child: SizedBox.expand(
      child: StaticMaterialPreview(
        image: _isLocalFilePath(anim.previewAsset)
            ? FileImage(_fileFromPath(anim.previewAsset))
            : AssetImage(anim.previewAsset),
      ),
    ),
  );
}
