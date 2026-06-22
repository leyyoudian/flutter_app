import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
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

class _BadgeHomePageState extends State<BadgeHomePage> {
  static const _channel = MethodChannel('esp_baji/native');

  final List<BadgeDevice> _devices = [];
  final List<HistoryEntry> _history = [];
  Timer? _brightnessTimer;
  Timer? _connectionTimer;
  int _pageIndex = 1;
  int _brightness = 70;
  bool _scanning = false;
  bool _connecting = false;
  bool _connected = false;
  bool _sdAvailable = false;
  bool _preparing = false;
  bool _uploading = false;
  double _prepareProgress = 0;
  double _uploadProgress = 0;
  String _status = '未连接';
  String? _connectedAddress;
  SelectedMedia? _media;
  PreparedAsset? _asset;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_handleNativeCall);
    unawaited(_loadHistory());
    unawaited(_refreshConnectionState());
    _connectionTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if ((_connected || _connecting) && !_preparing && !_uploading) {
        unawaited(_refreshConnectionState());
      }
    });
  }

  @override
  void dispose() {
    _brightnessTimer?.cancel();
    _connectionTimer?.cancel();
    super.dispose();
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
  }

  Future<void> _saveHistory() async {
    await _invokeNative<void>(
      'saveHistory',
      _history.map((entry) => entry.toMap()).toList(),
    );
  }

  Future<void> _refreshConnectionState() async {
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
    await _invokeNative<void>('disconnect');
    await _refreshConnectionState();
  }

  Future<void> _pickMedia() async {
    try {
      final picked = await _invokeNative<Map<dynamic, dynamic>>('pickMedia');
      if (!mounted || picked == null) {
        return;
      }
      setState(() {
        _media = SelectedMedia.fromMap(_asStringMap(picked));
        _asset = null;
        _prepareProgress = 0;
      });
      await _prepareSelectedMedia();
    } on PlatformException catch (error) {
      _showSnack(error.message ?? error.code);
    }
  }

  Future<void> _prepareSelectedMedia() async {
    final media = _media;
    if (media == null) {
      return;
    }
    setState(() {
      _preparing = true;
      _prepareProgress = 0;
      _status = '处理素材';
    });
    try {
      final prepared = await _invokeNative<Map<dynamic, dynamic>>(
        'prepareAsset',
        {
          'uri': media.uri,
          'name': media.name,
          'fps': 30,
          'maxPackageBytes': resolveBadgePackageBudget(
            sdAvailable: _sdAvailable,
          ),
        },
      );
      if (!mounted || prepared == null) {
        return;
      }
      final asset = PreparedAsset.fromMap(_asStringMap(prepared));
      final entry = HistoryEntry.fromAsset(asset);
      setState(() {
        _asset = asset;
        _preparing = false;
        _prepareProgress = 1;
        _history.removeWhere((item) => item.assetPath == asset.assetPath);
        _history.insert(0, entry);
        if (_history.length > 20) {
          _history.removeRange(20, _history.length);
        }
        _status = '素材就绪';
      });
      unawaited(_saveHistory());
    } on PlatformException catch (error) {
      setState(() {
        _preparing = false;
        _status = '素材处理失败';
      });
      _showSnack(error.message ?? error.code);
    }
  }

  Future<void> _uploadCurrentAsset() async {
    final asset = _asset;
    if (asset == null) {
      _showSnack('请先导入 GIF、图片或视频');
      return;
    }
    await _uploadAsset(asset);
  }

  Future<void> _uploadAsset(PreparedAsset asset) async {
    setState(() {
      _uploading = true;
      _uploadProgress = 0;
      _status = '连接 ESP-BAJI';
    });
    try {
      await _invokeNative<void>('uploadAsset', {'assetPath': asset.assetPath});
      if (!mounted) {
        return;
      }
      setState(() {
        _uploading = false;
        _uploadProgress = 1;
        _status = '已切换显示';
      });
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
    if (!_connected) {
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

  Future<T?> _invokeNative<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> _uploadHistoryEntry(HistoryEntry entry) async {
    if (_preparing || _uploading) {
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
    );
    setState(() {
      _media = null;
      _asset = asset;
      _pageIndex = 1;
      _status = '上传历史素材';
    });
    await _uploadAsset(asset);
  }

  Future<void> _deleteHistoryEntry(HistoryEntry entry) async {
    setState(() {
      _history.removeWhere((item) => item.assetPath == entry.assetPath);
      if (_asset?.assetPath == entry.assetPath) {
        _asset = null;
      }
      _status = '已删除历史记录';
    });
    await _saveHistory();
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

  @override
  Widget build(BuildContext context) {
    final pages = [
      _ConnectionPage(
        devices: _devices,
        scanning: _scanning,
        connecting: _connecting,
        connectedAddress: _connectedAddress,
        onScan: _scan,
        onConnect: _connect,
        onDisconnect: _disconnect,
      ),
      _GifPage(
        connected: _connected,
        status: _status,
        media: _media,
        asset: _asset,
        history: _history,
        preparing: _preparing,
        uploading: _uploading,
        prepareProgress: _prepareProgress,
        uploadProgress: _uploadProgress,
        onPick: _pickMedia,
        onUpload: _uploadCurrentAsset,
        onHistoryTap: (entry) => unawaited(_uploadHistoryEntry(entry)),
        onHistoryDelete: (entry) => unawaited(_deleteHistoryEntry(entry)),
      ),
      _ControlPage(
        connected: _connected,
        status: _status,
        brightness: _brightness,
        onBrightness: _setBrightness,
        onDisconnect: _disconnect,
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
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: NavigationBar(
              selectedIndex: _pageIndex,
              height: 64,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              indicatorColor: Colors.white,
              labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
              onDestinationSelected: (index) =>
                  setState(() => _pageIndex = index),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.wifi_find),
                  selectedIcon: Icon(Icons.wifi, color: Colors.black),
                  label: '连接',
                ),
                NavigationDestination(
                  icon: Icon(Icons.perm_media_outlined),
                  selectedIcon: Icon(Icons.perm_media, color: Colors.black),
                  label: '素材',
                ),
                NavigationDestination(
                  icon: Icon(Icons.tune),
                  selectedIcon: Icon(Icons.tune, color: Colors.black),
                  label: '控制',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GifPage extends StatelessWidget {
  const _GifPage({
    required this.connected,
    required this.status,
    required this.media,
    required this.asset,
    required this.history,
    required this.preparing,
    required this.uploading,
    required this.prepareProgress,
    required this.uploadProgress,
    required this.onPick,
    required this.onUpload,
    required this.onHistoryTap,
    required this.onHistoryDelete,
  });

  final bool connected;
  final String status;
  final SelectedMedia? media;
  final PreparedAsset? asset;
  final List<HistoryEntry> history;
  final bool preparing;
  final bool uploading;
  final double prepareProgress;
  final double uploadProgress;
  final VoidCallback onPick;
  final VoidCallback onUpload;
  final ValueChanged<HistoryEntry> onHistoryTap;
  final ValueChanged<HistoryEntry> onHistoryDelete;

  @override
  Widget build(BuildContext context) {
    final assetInfo = asset == null
        ? '480 x 480'
        : '${asset!.frameCount} 帧  ${asset!.fps} fps  ${_formatBytes(asset!.packageSize)}';

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 104),
      children: [
        Row(
          children: [
            _ConnectionStatusText(
              connected: connected,
              text: connected ? '已连接' : '未连接',
            ),
            const Spacer(),
            IconButton.filled(
              tooltip: '导入',
              onPressed: preparing || uploading ? null : onPick,
              icon: const Icon(Icons.add_photo_alternate_outlined),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Center(
          child: _PreviewDial(
            media: media,
            asset: asset,
            preparing: preparing,
            progress: prepareProgress,
          ),
        ),
        const SizedBox(height: 22),
        Text(
          asset?.name ?? media?.name ?? 'ESP-BAJI',
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          assetInfo,
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.62)),
        ),
        const SizedBox(height: 22),
        _GlassPanel(
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: preparing || uploading ? null : onPick,
                      icon: const Icon(Icons.file_open_outlined),
                      label: const Text('导入'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: preparing || uploading || asset == null
                          ? null
                          : onUpload,
                      icon: const Icon(Icons.upload_rounded),
                      label: Text(uploading ? '上传中' : '上传'),
                    ),
                  ),
                ],
              ),
              if (preparing || uploading) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: preparing
                      ? _clamp01(prepareProgress)
                      : _clamp01(uploadProgress),
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(99),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        Text(
          '历史导入',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        if (history.isEmpty)
          const _EmptyHistory()
        else
          ...history.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Dismissible(
                key: ValueKey(entry.assetPath),
                direction: DismissDirection.endToStart,
                background: const SizedBox.shrink(),
                secondaryBackground: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xffff5b5b).withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: EdgeInsets.only(right: 18),
                      child: Icon(Icons.delete_outline, color: Colors.white),
                    ),
                  ),
                ),
                onDismissed: (_) => onHistoryDelete(entry),
                child: _HistoryTile(
                  entry: entry,
                  onTap: () => onHistoryTap(entry),
                  onLongPress: () => onHistoryDelete(entry),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ConnectionPage extends StatelessWidget {
  const _ConnectionPage({
    required this.devices,
    required this.scanning,
    required this.connecting,
    required this.connectedAddress,
    required this.onScan,
    required this.onConnect,
    required this.onDisconnect,
  });

  final List<BadgeDevice> devices;
  final bool scanning;
  final bool connecting;
  final String? connectedAddress;
  final VoidCallback onScan;
  final ValueChanged<BadgeDevice> onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final connected = connectedAddress != null;

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 104),
      children: [
        _PageHeader(
          title: '设备连接',
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
          child: Row(
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
                      connected ? '已连接' : '未连接',
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
              if (connectedAddress != null)
                IconButton(
                  tooltip: '断开',
                  onPressed: onDisconnect,
                  icon: const Icon(Icons.link_off),
                ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (devices.isEmpty)
          _GlassPanel(
            child: SizedBox(
              height: 180,
              child: Center(
                child: Text(
                  scanning ? '扫描中' : '未发现 ESP-BAJI',
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
      ],
    );
  }
}

class _ControlPage extends StatelessWidget {
  const _ControlPage({
    required this.connected,
    required this.status,
    required this.brightness,
    required this.onBrightness,
    required this.onDisconnect,
  });

  final bool connected;
  final String status;
  final int brightness;
  final ValueChanged<int> onBrightness;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 104),
      children: [
        const _PageHeader(title: '设备控制'),
        const SizedBox(height: 18),
        _GlassPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    connected ? Icons.power_settings_new : Icons.power_off,
                    color: _connectionColor(connected),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      connected ? status : '未连接',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _connectionColor(connected),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
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
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: connected ? onDisconnect : null,
          icon: const Icon(Icons.link_off),
          label: const Text('断开连接'),
        ),
      ],
    );
  }
}

class _PreviewDial extends StatelessWidget {
  const _PreviewDial({
    required this.media,
    required this.asset,
    required this.preparing,
    required this.progress,
  });

  final SelectedMedia? media;
  final PreparedAsset? asset;
  final bool preparing;
  final double progress;

  @override
  Widget build(BuildContext context) {
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
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [Colors.white.withValues(alpha: 0.18), Colors.black],
                ),
              ),
            ),
            if (media != null && _isVideoMime(media!.mime))
              _VideoPreview(uri: media!.uri)
            else if (_hasPreviewPath(media?.animatedPreviewPath))
              Image.file(
                File(media!.animatedPreviewPath!),
                fit: BoxFit.cover,
                gaplessPlayback: true,
              )
            else if (_hasPreviewPath(asset?.animatedPreviewPath))
              Image.file(
                File(asset!.animatedPreviewPath!),
                fit: BoxFit.cover,
                gaplessPlayback: true,
              )
            else if (media?.previewBytes != null)
              Image.memory(
                media!.previewBytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              )
            else if (_hasPreviewPath(asset?.previewPath))
              Image.file(
                File(asset!.previewPath!),
                fit: BoxFit.cover,
                gaplessPlayback: true,
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
  const _VideoPreview({required this.uri});

  final String uri;

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
      await controller.play();
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

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.entry,
    required this.onTap,
    required this.onLongPress,
  });

  final HistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final previewPath = entry.animatedPreviewPath ?? entry.previewPath;

    return _GlassPanel(
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(18),
        child: Row(
          children: [
            ClipOval(
              child: SizedBox.square(
                dimension: 44,
                child: _HistoryPreview(entry: entry, previewPath: previewPath),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${entry.frameCount} 帧  ${entry.fps} fps  ${_formatBytes(entry.packageSize)}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.58),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

class _HistoryPreview extends StatelessWidget {
  const _HistoryPreview({required this.entry, required this.previewPath});

  final HistoryEntry entry;
  final String? previewPath;

  @override
  Widget build(BuildContext context) {
    if (_isVideoMime(entry.mime) && entry.sourceUri != null) {
      return _VideoPreview(uri: entry.sourceUri!);
    }
    if (_hasPreviewPath(previewPath)) {
      return Image.file(
        File(previewPath!),
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }
    return const ColoredBox(
      color: Colors.white,
      child: Icon(Icons.image, color: Colors.black),
    );
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
  });

  factory HistoryEntry.fromAsset(PreparedAsset asset) {
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

int resolveBadgePackageBudget({required bool sdAvailable}) {
  const legacyFlashBudget = 10 * 1024 * 1024;
  const sdStreamBudget = 512 * 1024 * 1024;
  return sdAvailable ? sdStreamBudget : legacyFlashBudget;
}

Color _connectionColor(bool connected) {
  return connected ? const Color(0xff32d583) : const Color(0xffff5b5b);
}

String? _readNullableString(Object? value) {
  if (value is String && value.isNotEmpty && value != 'null') {
    return value;
  }
  return null;
}

bool _hasPreviewPath(String? path) => path != null && path.isNotEmpty;

bool _isVideoMime(String mime) => mime.toLowerCase().startsWith('video/');

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}
