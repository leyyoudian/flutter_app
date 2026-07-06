import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ESP Baji',
      theme: ThemeData(
        useMaterial3: true,
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
  static const _backendBaseUrl = String.fromEnvironment(
    'ESP_BAJI_API_BASE',
    defaultValue: 'http://60.205.122.153',
  );
  static const _appVersion = '1.0.8';

  final List<BadgeDevice> _devices = [];
  final List<HistoryEntry> _history = [];
  Timer? _brightnessTimer;
  Timer? _connectionTimer;
  final Map<String, Completer<String?>> _assetPreviewWaiters = {};
  int _pageIndex = 1;
  int _brightness = 70;
  bool _scanning = false;
  bool _connecting = false;
  bool _connected = false;
  bool _sdAvailable = false;
  bool _preparing = false;
  bool _uploading = false;
  bool _appActive = true;
  bool _demoMode = false;
  bool _checkingVersion = false;
  bool _reviewRefreshInFlight = false;
  double _prepareProgress = 0;
  double _uploadProgress = 0;
  String _status = '未连接';
  String? _connectedAddress;
  SelectedMedia? _media;
  PreparedAsset? _asset;
  CropTransform _cropTransform = const CropTransform();
  List<FactoryAnimation> _factoryAnims = [];
  String? _selectedFactoryId;
  String? _activeFactoryId; // currently playing on dial
  List<String> _videoQueue = []; // pending video sequence
  int _videoIndex = 0;

  bool get _previewActive => _appActive && !_preparing;
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
        setState(() {
          _connected = event['connected'] == true;
          _connecting = event['connecting'] == true;
          _sdAvailable = event['sdAvailable'] == true;
          _connectedAddress = event['address'] as String?;
          _status =
              (event['message'] as String?) ?? (_connected ? '已连接' : '未连接');
        });
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
    try {
      final jsonStr = await DefaultAssetBundle.of(
        context,
      ).loadString('assets/factory_previews/manifest.json');
      final list = json.decode(jsonStr) as List<dynamic>;
      if (!mounted) return;
      setState(() {
        _factoryAnims = list
            .map((item) => FactoryAnimation.fromMap(_asStringMap(item)))
            .toList();
      });
    } catch (_) {
      // Fallback: manifest not found, leave empty
    }
  }

  Future<void> _switchToFactory(FactoryAnimation anim) async {
    setState(() {
      _selectedFactoryId = anim.id;
      _asset = null;
    });
    // Build video sequence: current exit/third_half + target entrance.
    final queue = <String>[];
    bool isThirdHalf = false;
    if (_activeFactoryId != null && _activeFactoryId != anim.id) {
      final current = _factoryAnims.cast<FactoryAnimation?>().firstWhere(
        (a) => a?.id == _activeFactoryId,
        orElse: () => null,
      );
      isThirdHalf = current?.transitions.containsKey(anim.id) ?? false;
      final exitVid = current?.exitVideo(anim.id);
      if (exitVid != null) queue.add(exitVid);
    }
    // Third_half replaces both exit and entrance — skip target first_half
    if (!isThirdHalf && anim.firstVideo != null) queue.add(anim.firstVideo!);
    setState(() {
      _videoQueue = queue;
      _videoIndex = 0;
      _activeFactoryId = anim.id;
    });
    if (_demoMode) {
      setState(() => _status = '演示切换 ${anim.name}');
      return;
    }
    // Send switch command to device
    if (!_connected) return;
    setState(() => _status = '切换中...');
    try {
      final result = await _invokeNative<dynamic>('switchToAsset', {
        'id': anim.id,
      });
      if (!mounted) return;
      if (result == true) {
        setState(() => _status = '已切换');
      } else if (result is Map && result['needsUpload'] == true) {
        _showSnack('设备缺少该素材，需先上传');
        setState(() => _status = '素材缺失');
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack('切换失败: $e');
    }
  }

  Future<void> _saveHistory() async {
    await _invokeNative<void>(
      'saveHistory',
      _history.map((entry) => entry.toMap()).toList(),
    );
  }

  void _enterDemoMode() {
    setState(() {
      _demoMode = true;
      _devices
        ..clear()
        ..add(
          const BadgeDevice(
            name: 'Demo ESP-BAJI',
            address: '192.168.4.1',
            rssi: -38,
            serviceMatch: true,
          ),
        );
      _connected = true;
      _connecting = false;
      _sdAvailable = true;
      _connectedAddress = 'Demo ESP-BAJI';
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
          name: 'Demo ESP-BAJI',
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
    if (_demoMode) {
      setState(() {
        _connected = true;
        _sdAvailable = true;
        _connectedAddress = 'Demo ESP-BAJI';
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
    setState(() {
      _connected = state['connected'] == true;
      _sdAvailable = state['sdAvailable'] == true;
      _connectedAddress = state['address'] as String?;
      _status =
          (state['message'] as String?) ??
          (_connected ? '已连接' : (wasConnected ? '断开连接' : '未连接'));
    });
  }

  Future<void> _scan() async {
    if (_demoMode) {
      await _simulateDemoScan();
      return;
    }
    setState(() {
      _devices.clear();
      _scanning = true;
      _status = '扫描 ESP-BAJI';
    });
    try {
      await _invokeNative<void>('startScan');
    } on PlatformException catch (error) {
      _showSnack(error.message ?? error.code);
      setState(() => _scanning = false);
    }
  }

  Future<void> _connect(BadgeDevice device) async {
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
    if (_demoMode) {
      setState(() {
        _connected = false;
        _connectedAddress = null;
        _status = '演示设备已断开';
      });
      return;
    }
    await _invokeNative<void>('disconnect');
    await _refreshConnectionState();
  }

  Future<void> _pickMedia() async {
    try {
      final picked = await _invokeNative<Map<dynamic, dynamic>>('pickMedia');
      if (!mounted || picked == null) {
        return;
      }
      final media = SelectedMedia.fromMap(_asStringMap(picked));
      setState(() {
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
    final media = _media;
    if (media == null) {
      _showSnack('请先导入 GIF、图片或视频');
      return;
    }
    setState(() {
      _preparing = true;
      _prepareProgress = 0;
      _status = '保存素材';
    });
    try {
      final prepared = await _invokeNative<Map<dynamic, dynamic>>(
        'prepareAsset',
        {
          'uri': media.uri,
          'name': media.name,
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
      var saveMessage = '素材已保存，已提交审核';
      if (_isVideoMime(asset.mime) && !_hasPreviewPath(asset.animatedPreviewPath)) {
        setState(() => _status = '生成审核预览');
        asset = await _withReviewPreviewReady(asset);
        if (!mounted) {
          return;
        }
      }
      try {
        setState(() => _status = '提交审核');
        asset = await _submitAssetForReview(asset);
        if (!mounted) {
          return;
        }
        if (asset.reviewStatus == 'approved') {
          saveMessage = '素材已保存，审核已通过';
        } else if (asset.reviewStatus == 'rejected') {
          saveMessage = '素材已保存，但审核未通过';
        }
      } catch (_) {
        if (!mounted) {
          return;
        }
        saveMessage = '素材已本地保存，联网后将重新提交审核';
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
        _status = asset.reviewStatus == 'pending' ? '待审核' : '已保存';
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
    if (!_connected) {
      _showSnack('请先连接设备');
      setState(() => _pageIndex = 0);
      return;
    }
    final approvedAsset = await _ensureAssetApproved(asset);
    if (!mounted || approvedAsset == null) {
      return;
    }
    setState(() {
      _uploading = true;
      _uploadProgress = 0;
      _status = '准备上传';
    });
    try {
      final result = _demoMode
          ? await _simulateDemoUpload(approvedAsset)
          : await _invokeNative<Map<dynamic, dynamic>>('uploadAsset', {
              'assetPath': approvedAsset.assetPath,
            });
      if (!mounted) return;
      final assignedId = _readNullableString(result?['assignedId']);
      setState(() {
        _uploading = false;
        _uploadProgress = 1;
        _status = '已切换';
        // Store assigned device ID on the history entry
        for (var i = 0; i < _history.length; i++) {
          if (_history[i].assetPath == approvedAsset.assetPath) {
            _history[i] = _history[i].copyWith(deviceId: assignedId);
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

  Uri _backendUri(String path) {
    final base = Uri.parse(_backendBaseUrl);
    return base.resolve(path);
  }

  Future<Map<String, dynamic>?> _getBackendJson(String path) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(_backendUri(path));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(text, uri: _backendUri(path));
      }
      return _asStringMap(json.decode(text));
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>?> _postBackendJson(
    String path,
    Map<String, Object?> body,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(_backendUri(path));
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.write(json.encode(body));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(text, uri: _backendUri(path));
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
    });
    final reviewId = _readNullableString(result?['id']);
    final reviewStatus = _readNullableString(result?['status']);
    if (reviewStatus == null || reviewStatus == 'pending') {
      return asset.copyWith(reviewId: reviewId, reviewStatus: 'pending');
    }
    return asset.copyWith(reviewId: reviewId, reviewStatus: reviewStatus);
  }

  Future<PreparedAsset> _withReviewPreviewReady(PreparedAsset asset) async {
    if (!_isVideoMime(asset.mime) || _hasPreviewPath(asset.animatedPreviewPath)) {
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
      if (_asset?.assetPath == asset.assetPath) {
        _asset = asset;
      }
      for (var index = 0; index < _history.length; index++) {
        if (_history[index].assetPath == asset.assetPath) {
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
    if (asset.reviewStatus == 'approved') {
      return asset;
    }
    try {
      PreparedAsset reviewed;
      if (asset.reviewId == null) {
        setState(() => _status = '提交审核');
        reviewed = await _submitAssetForReview(asset);
        if (!mounted) return null;
        _rememberReviewedAsset(reviewed);
        _showSnack('素材已提交审核，管理员审核通过后可上传');
        return null;
      }

      setState(() => _status = '检查审核状态');
      reviewed = await _refreshReviewStatus(asset);
      if (!mounted) return null;
      _rememberReviewedAsset(reviewed);
      if (reviewed.reviewStatus == 'approved') {
        return reviewed;
      }
      if (reviewed.reviewStatus == 'rejected') {
        _showSnack('素材审核未通过，请更换内容');
      } else {
        _showSnack('素材仍在审核中');
      }
    } catch (_) {
      if (mounted) {
        _showSnack('审核服务暂时不可用，请稍后再试');
      }
    }
    return null;
  }

  Future<T?> _invokeNative<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    }
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
        title: const Text('隐私政策'),
        content: SingleChildScrollView(
          child: Text(
            'ESP Baji 不收集、出售或分享个人信息。\n\n'
            '导入的图片、GIF 和视频会在本机处理。用户自定义素材在上传到 ESP 设备前，需要提交到 ESP Baji 服务器审核。'
            '审核通过后，应用仅在用户操作时通过本地 Wi-Fi 发送到已连接的 ESP 设备。'
            '应用不会上传素材到第三方服务器，也不使用广告或分析 SDK。\n\n'
            '公开隐私政策链接：\n$_privacyPolicyUrl',
            style: const TextStyle(height: 1.45),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              unawaited(_openPrivacyPolicyUrl());
            },
            child: const Text('打开网页'),
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

  bool get _isDefaultCrop {
    return (_cropTransform.scale - 1).abs() < 0.0001 &&
        _cropTransform.offset.distance < 0.0001;
  }

  Future<void> _uploadHistoryEntry(HistoryEntry entry) async {
    if (_preparing || _uploading) {
      return;
    }
    // If already uploaded, just switch to it
    if (entry.deviceId != null && _connected) {
      final reviewed = await _ensureAssetApproved(
        PreparedAsset(
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
        ),
      );
      if (!mounted || reviewed == null) {
        return;
      }
      setState(() {
        _status = '切换中...';
        _selectedFactoryId = null;
      });
      if (_demoMode) {
        setState(() {
          _status = '演示已切换';
          _asset = reviewed;
        });
        return;
      }
      try {
        await _invokeNative<dynamic>('switchToAsset', {'id': entry.deviceId});
        if (!mounted) return;
        setState(() {
          _status = '已切换';
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
      } catch (e) {
        if (!mounted) return;
        _showSnack('切换失败: $e');
        setState(() => _status = '切换失败');
      }
      return;
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
    await _deleteNativeAssetFiles(entry);
    setState(() {
      _history.removeWhere((item) => item.assetPath == entry.assetPath);
      if (_asset?.assetPath == entry.assetPath) {
        _asset = null;
      }
      _status = '已删除历史记录';
    });
    await _saveHistory();
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
        title: const Text('删除素材'),
        content: Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
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
        content: Text(
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
        content: Text(
          message,
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w700,
          ),
        ),
        action: storeUrl == null
            ? null
            : SnackBarAction(
                label: '更新',
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

  @override
  Widget build(BuildContext context) {
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
        onPrivacyPolicy: _showPrivacyPolicy,
        demoMode: _demoMode,
        onEnterDemoMode: _enterDemoMode,
        onExitDemoMode: _exitDemoMode,
      ),
      _DisplayLibraryPage(
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
      ),
      _MakerPage(
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
      ),
    ];

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          const _Backdrop(),
          SafeArea(
            child: IndexedStack(index: _pageIndex, children: pages),
          ),
        ],
      ),
      bottomNavigationBar: _FloatingBottomNav(
        selectedIndex: _pageIndex,
        onSelected: (index) => setState(() => _pageIndex = index),
      ),
    );
  }
}

class _FloatingBottomNav extends StatelessWidget {
  const _FloatingBottomNav({
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final bottomPadding = math.max(8.0, bottomInset + 6.0);

    return Padding(
      padding: EdgeInsets.fromLTRB(18, 0, 18, bottomPadding),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xff181818).withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: Colors.white.withValues(alpha: 0.035)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.34),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: SizedBox(
              key: const ValueKey('floating-bottom-nav'),
              height: 62,
              child: Row(
                children: [
                  _BottomNavButton(
                    index: 0,
                    selectedIndex: selectedIndex,
                    icon: Icons.wifi_find,
                    selectedIcon: Icons.wifi,
                    tooltip: '设备',
                    onSelected: onSelected,
                  ),
                  _BottomNavButton(
                    index: 1,
                    selectedIndex: selectedIndex,
                    icon: Icons.grid_view_rounded,
                    selectedIcon: Icons.grid_view_rounded,
                    tooltip: '主页',
                    onSelected: onSelected,
                  ),
                  _BottomNavButton(
                    index: 2,
                    selectedIndex: selectedIndex,
                    icon: Icons.add_photo_alternate_outlined,
                    selectedIcon: Icons.add_photo_alternate,
                    tooltip: '制作',
                    onSelected: onSelected,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomNavButton extends StatelessWidget {
  const _BottomNavButton({
    required this.index,
    required this.selectedIndex,
    required this.icon,
    required this.selectedIcon,
    required this.tooltip,
    required this.onSelected,
  });

  final int index;
  final int selectedIndex;
  final IconData icon;
  final IconData selectedIcon;
  final String tooltip;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final selected = index == selectedIndex;

    return Expanded(
      child: Center(
        child: Tooltip(
          message: tooltip,
          child: InkResponse(
            radius: 34,
            onTap: () => onSelected(index),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              width: selected ? 76 : 54,
              height: 44,
              decoration: BoxDecoration(
                color: selected ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(
                selected ? selectedIcon : icon,
                color: selected ? Colors.black : Colors.white,
                size: 22,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DisplayLibraryPage extends StatelessWidget {
  const _DisplayLibraryPage({
    required this.active,
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

  @override
  Widget build(BuildContext context) {
    final selectedFactory = selectedFactoryId != null
        ? factoryAnims.cast<FactoryAnimation?>().firstWhere(
            (a) => a?.id == selectedFactoryId,
            orElse: () => null,
          )
        : null;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: connected
                          ? const Color(0xff32d583)
                          : const Color(0xffff5b5b),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Center(
                child: _PreviewDial(
                  active: active,
                  media: null,
                  asset: asset,
                  factoryVideo:
                      videoQueue.isNotEmpty && videoIndex < videoQueue.length
                      ? videoQueue[videoIndex]
                      : null,
                  nextVideo:
                      videoQueue.isNotEmpty &&
                          videoIndex + 1 < videoQueue.length
                      ? videoQueue[videoIndex + 1]
                      : null,
                  onFactoryVideoDone: videoQueue.isNotEmpty
                      ? onVideoDone
                      : null,
                  preparing: uploading,
                  progress: uploadProgress,
                ),
              ),
              const SizedBox(height: 16),
              if (uploading) ...[
                LinearProgressIndicator(
                  value: _clamp01(uploadProgress),
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(99),
                ),
                const SizedBox(height: 18),
              ],
            ],
          ),
        ),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xff171717).withValues(alpha: 0),
                  const Color(0xff060606).withValues(alpha: 0.98),
                  Colors.black,
                ],
                stops: const [0, 0.12, 1],
              ),
            ),
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 104),
              itemCount: factoryAnims.length + history.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1,
              ),
              itemBuilder: (context, index) {
                if (index < history.length) {
                  final entry = history[index];
                  return _HistoryGridTile(
                    active: active,
                    entry: entry,
                    selected: asset?.assetPath == entry.assetPath,
                    onTap: uploading ? null : () => onHistoryTap(entry),
                    onLongPress: () => onHistoryDelete(entry),
                  );
                }
                final anim = factoryAnims[index - history.length];
                final isSelected = selectedFactoryId == anim.id;
                return _FactoryGridTile(
                  key: ValueKey('fac_${anim.id}'),
                  anim: anim,
                  selected: isSelected,
                  onTap: uploading ? null : () => onFactoryTap(anim),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _MakerPage extends StatelessWidget {
  const _MakerPage({
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
  });

  final bool active;
  final SelectedMedia? media;
  final PreparedAsset? asset;
  final CropTransform cropTransform;
  final bool preparing;
  final bool uploading;
  final double prepareProgress;
  final VoidCallback onPick;
  final VoidCallback onSave;
  final ValueChanged<CropTransform> onCropChanged;
  final VoidCallback onResetCrop;

  @override
  Widget build(BuildContext context) {
    final disabled = preparing || uploading;

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 104),
      children: [
        _PageHeader(
          title: '制作',
          trailing: IconButton.filled(
            tooltip: '导入',
            onPressed: disabled ? null : onPick,
            icon: const Icon(Icons.file_open_outlined),
          ),
        ),
        const SizedBox(height: 22),
        Center(
          child: _CropPreview(
            active: active && !preparing,
            media: media,
            asset: asset,
            transform: cropTransform,
            preparing: preparing,
            progress: prepareProgress,
            onChanged: disabled ? null : onCropChanged,
          ),
        ),
        const SizedBox(height: 24),
        _GlassPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.zoom_in_map),
                  const SizedBox(width: 10),
                  Text('${cropTransform.scale.toStringAsFixed(2)}x'),
                  const Spacer(),
                  IconButton(
                    tooltip: '重置',
                    onPressed: disabled ? null : onResetCrop,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              Slider(
                value: cropTransform.scale,
                min: 1,
                max: 4,
                divisions: 30,
                onChanged: disabled
                    ? null
                    : (value) =>
                          onCropChanged(cropTransform.copyWith(scale: value)),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: disabled ? null : onPick,
                      icon: const Icon(Icons.file_open_outlined),
                      label: const Text('导入素材'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: disabled || media == null ? null : onSave,
                      icon: const Icon(Icons.save_alt),
                      label: Text(preparing ? '保存中' : '保存'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '素材需审核，请勿上传非法素材',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.48),
                  height: 1.25,
                ),
              ),
              if (preparing) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: prepareProgress == 0
                      ? null
                      : _clamp01(prepareProgress),
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(99),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _DevicePage extends StatelessWidget {
  const _DevicePage({
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
  final VoidCallback onPrivacyPolicy;
  final bool demoMode;
  final VoidCallback onEnterDemoMode;
  final VoidCallback onExitDemoMode;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 104),
      children: [
        _PageHeader(
          title: '设备',
          trailing: IconButton.filled(
            tooltip: '扫描',
            onPressed: scanning ? null : onScan,
            icon: scanning
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.radar),
          ),
        ),
        const SizedBox(height: 18),
        _GlassPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    connected ? Icons.wifi : Icons.wifi_off,
                    color: _connectionColor(connected),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          connected ? status : '未连接',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _connectionColor(connected),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (connectedAddress != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            connectedAddress!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.56),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (connected)
                    IconButton(
                      tooltip: '断开',
                      onPressed: onDisconnect,
                      icon: const Icon(Icons.link_off),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(
                    sdAvailable ? Icons.sd_card : Icons.sd_card_alert,
                    size: 20,
                    color: sdAvailable
                        ? const Color(0xff32d583)
                        : Colors.white.withValues(alpha: 0.54),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    sdAvailable ? 'TF 卡可用' : 'TF 卡未确认',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.72),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Icon(Icons.brightness_6_outlined),
                  const SizedBox(width: 10),
                  Text('$brightness%'),
                ],
              ),
              Slider(
                value: brightness.toDouble(),
                min: 0,
                max: 100,
                divisions: 20,
                onChanged: connected
                    ? (value) => onBrightness(value.round())
                    : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (devices.isEmpty)
          _GlassPanel(
            child: SizedBox(
              height: 170,
              child: Center(
                child: Text(
                  scanning ? '扫描中' : '未发现设备',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.62)),
                ),
              ),
            ),
          )
        else
          ...devices.map(
            (device) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _GlassPanel(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: Colors.white,
                    child: Icon(
                      device.serviceMatch ? Icons.verified : Icons.wifi,
                      color: Colors.black,
                    ),
                  ),
                  title: Text(
                    device.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${device.address}   RSSI ${device.rssi}'),
                  trailing: FilledButton(
                    onPressed: connecting ? null : () => onConnect(device),
                    child: Text(
                      connectedAddress == device.address ? '已连接' : '连接',
                    ),
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 8),
        Center(
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 6,
            children: [
              TextButton.icon(
                onPressed: demoMode ? onExitDemoMode : onEnterDemoMode,
                icon: Icon(demoMode ? Icons.visibility_off : Icons.visibility),
                label: Text(demoMode ? '退出演示模式' : '审核演示'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white.withValues(alpha: 0.62),
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
              TextButton(
                key: const ValueKey('privacy-policy-link'),
                onPressed: onPrivacyPolicy,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white.withValues(alpha: 0.46),
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(fontSize: 12),
                ),
                child: const Text('隐私政策'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HistoryGridTile extends StatelessWidget {
  const _HistoryGridTile({
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: Colors.black,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected ? Colors.white : Colors.transparent,
                  width: selected ? 1.5 : 1,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: ClipOval(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _HistoryPreview(
                        active: active,
                        entry: entry,
                        previewPath: previewPath,
                        transform: entry.cropTransform,
                      ),
                      if (overlayColor != null)
                        ColoredBox(color: overlayColor),
                      if (reviewLabel != null)
                        Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.58),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.2),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              child: Text(
                                reviewLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
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
    this.nextVideo,
    this.onFactoryVideoDone,
    required this.preparing,
    required this.progress,
  });

  final bool active;
  final SelectedMedia? media;
  final PreparedAsset? asset;
  final String? factoryVideo;
  final String? nextVideo;
  final VoidCallback? onFactoryVideoDone;
  final bool preparing;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final transform = asset?.cropTransform ?? const CropTransform();

    return Container(
      width: 284,
      height: 284,
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
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(decoration: const BoxDecoration(color: Colors.black)),
            if (media != null && _isVideoMime(media!.mime))
              _VideoPreview(
                key: ValueKey('dial-media-video-${media!.uri}'),
                uri: media!.uri,
                active: active,
              )
            else if (asset != null &&
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
            else if (factoryVideo != null)
              _DualVideoPlayer(
                currentVideo: factoryVideo!,
                nextVideo: nextVideo,
                active: active,
                onDone: onFactoryVideoDone,
              )
            else
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
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: controller.value.size.width,
        height: controller.value.size.height,
        child: VideoPlayer(controller),
      ),
    );
  }
}

class _DualVideoPlayer extends StatefulWidget {
  const _DualVideoPlayer({
    super.key,
    required this.currentVideo,
    this.nextVideo,
    required this.active,
    this.onDone,
  });

  final String currentVideo;
  final String? nextVideo;
  final bool active;
  final VoidCallback? onDone;

  @override
  State<_DualVideoPlayer> createState() => _DualVideoPlayerState();
}

class _DualVideoPlayerState extends State<_DualVideoPlayer> {
  VideoPlayerController? _active; // currently displayed (always initialized)
  VideoPlayerController? _preloaded; // next video ready to go
  String? _activePath;
  String? _preloadedPath;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _loadCurrent();
    _maybePreload();
  }

  @override
  void didUpdateWidget(covariant _DualVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentVideo != widget.currentVideo) {
      _done = false;
      _switchTo(widget.currentVideo);
    }
    if (oldWidget.nextVideo != widget.nextVideo) {
      _maybePreload();
    }
    if (oldWidget.active != widget.active) {
      unawaited(_syncActive());
    }
  }

  void _maybePreload() {
    final nv = widget.nextVideo;
    if (nv == null || nv == _activePath || nv == _preloadedPath) return;
    _preloaded?.removeListener(_onUpdate);
    _preloaded?.dispose();
    _preloaded = null;
    _preloadedPath = null;
    final c = VideoPlayerController.asset(nv);
    _preloaded = c;
    _preloadedPath = nv;
    c
        .initialize()
        .then((_) {
          if (!mounted || _preloaded != c) return;
          c.setLooping(false);
          c.setVolume(0);
        })
        .catchError((_) {
          c.dispose();
          if (mounted && _preloaded == c) {
            _preloaded = null;
            _preloadedPath = null;
          }
        });
  }

  Future<void> _loadCurrent() async {
    _done = false;
    await _activate(widget.currentVideo);
    _maybePreload();
  }

  Future<void> _switchTo(String path) async {
    if (_activePath == path && _active != null) return;

    // If preloaded has this, instant swap
    if (_preloadedPath == path && _preloaded?.value.isInitialized == true) {
      final old = _active;
      _active = _preloaded;
      _activePath = _preloadedPath;
      _preloaded = old;
      _preloadedPath = null;
      _active?.removeListener(_onUpdate);
      _active?.addListener(_onUpdate);
      await _active!.seekTo(Duration.zero);
      await _active!.play();
      if (mounted) setState(() {});
      _disposeAfter(old, 500);
      _maybePreload();
      return;
    }

    // Load new without touching _active — no flicker
    await _activate(path);
    _maybePreload();
  }

  Future<void> _activate(String path) async {
    // Load new controller while keeping _active displayed
    final c = VideoPlayerController.asset(path);
    try {
      await c.initialize();
      await c.setLooping(false);
      await c.setVolume(0);
      if (!mounted) {
        c.dispose();
        return;
      }
      c.addListener(_onUpdate);
      // Swap: new becomes active, old goes to disposal
      final old = _active;
      _active = c;
      _activePath = path;
      if (mounted) setState(() {});
      await c.seekTo(Duration.zero);
      await c.play();
      _disposeAfter(old, 500);
    } catch (_) {
      await c.dispose();
    }
  }

  void _disposeAfter(VideoPlayerController? c, int ms) {
    if (c == null) return;
    c.removeListener(_onUpdate);
    Future.delayed(Duration(milliseconds: ms), () {
      if (_active != c && _preloaded != c) c.dispose();
    });
  }

  void _onUpdate() {
    if (_done || _active == null || !_active!.value.isInitialized) return;
    if (_active!.value.position >=
        _active!.value.duration - const Duration(milliseconds: 100)) {
      _done = true;
      widget.onDone?.call();
    }
  }

  Future<void> _syncActive() async {
    final c = _active;
    if (c == null || !c.value.isInitialized) return;
    try {
      if (widget.active) {
        await c.play();
      } else {
        await c.pause();
      }
    } catch (_) {}
  }

  @override
  void deactivate() {
    final c = _active;
    if (c != null && c.value.isInitialized) unawaited(c.pause());
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    unawaited(_syncActive());
  }

  @override
  void dispose() {
    _active?.removeListener(_onUpdate);
    _active?.dispose();
    _preloaded?.removeListener(_onUpdate);
    _preloaded?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _active;
    if (c == null || !c.value.isInitialized) return const SizedBox.expand();
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: c.value.size.width,
        height: c.value.size.height,
        child: VideoPlayer(c),
      ),
    );
  }
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    const radius = 8.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    );
  }
}

class _ConnectionStatusText extends StatelessWidget {
  const _ConnectionStatusText({required this.connected, required this.text});

  final bool connected;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = _connectionColor(connected);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(connected ? Icons.wifi : Icons.wifi_off, size: 18, color: color),
        const SizedBox(width: 7),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 150),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: 0,
          ),
        ),
        const Spacer(),
        if (trailing != null) trailing!,
      ],
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
    if (active && _hasPreviewPath(entry.animatedPreviewPath)) {
      child = Image.file(
        File(entry.animatedPreviewPath!),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: _blackPreviewFallback,
      );
    } else if (_hasPreviewPath(previewPath)) {
      child = Image.file(
        File(previewPath!),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: _blackPreviewFallback,
      );
    }

    if (child == null) {
      return const ColoredBox(
        color: Colors.black,
        child: Icon(Icons.image, color: Colors.white),
      );
    }

    return _CropTransformView(transform: transform, child: child);
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return _GlassPanel(
      child: SizedBox(
        height: 72,
        child: Center(
          child: Text(
            '暂无记录',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.58)),
          ),
        ),
      ),
    );
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
          colors: [Color(0xff050505), Color(0xff171717), Color(0xff030303)],
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
          : 'ESP-BAJI',
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
  final String? reviewId;
  final String reviewStatus;

  CropTransform get cropTransform {
    return CropTransform(
      scale: cropScale,
      offset: Offset(cropOffsetX, cropOffsetY),
    );
  }

  HistoryEntry copyWith({
    String? animatedPreviewPath,
    String? deviceId,
    String? reviewId,
    String? reviewStatus,
  }) {
    return HistoryEntry(
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
      createdAt: createdAt,
      cropScale: cropScale,
      cropOffsetX: cropOffsetX,
      cropOffsetY: cropOffsetY,
      deviceId: deviceId ?? this.deviceId,
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

Color _connectionColor(bool connected) {
  return connected ? const Color(0xff32d583) : const Color(0xffff5b5b);
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
  return '未审核';
}

String? _readNullableString(Object? value) {
  if (value is String && value.isNotEmpty && value != 'null') {
    return value;
  }
  return null;
}

bool _hasPreviewPath(String? path) =>
    path != null && path.isNotEmpty && _previewFileExists(path);

bool _previewFileExists(String path) {
  try {
    return File(path).existsSync();
  } on FileSystemException {
    return false;
  }
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
    this.firstVideo,
    this.secondVideo,
    this.transitions = const {},
  });

  final String id;
  final String name;
  final String previewAsset;
  final String? firstVideo;
  final String? secondVideo;
  final Map<String, String> transitions;

  factory FactoryAnimation.fromMap(Map<String, dynamic> map) {
    return FactoryAnimation(
      id: (map['id'] as String?) ?? '',
      name: (map['name'] as String?) ?? '',
      previewAsset: (map['previewAsset'] as String?) ?? '',
      firstVideo: _readNullableString(map['firstVideo']),
      secondVideo: _readNullableString(map['secondVideo']),
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
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Material(
        color: selected
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.12),
                width: selected ? 2 : 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: SizedBox.expand(
                  child: Image.asset(
                    anim.previewAsset,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const ColoredBox(color: Color(0xff1a1a1a)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Colors.white.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}
