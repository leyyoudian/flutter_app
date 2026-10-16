import 'dart:ui';

import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'app_language.dart';

const referenceMuted = Color(0xff999999);
const referenceBlue = Color(0xff3092ce);

AppBar referenceDetailAppBar(
  String title, {
  VoidCallback? onBack,
  Key? backKey,
}) => AppBar(
  backgroundColor: Colors.black,
  surfaceTintColor: Colors.transparent,
  centerTitle: true,
  leading: BackButton(key: backKey, onPressed: onBack),
  title: AppText(
    title,
    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
  ),
);

// Measured from the supplied recordings, rather than the later screenshots.
class ReferencePanel extends StatelessWidget {
  const ReferencePanel({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: const Color(0xff202020),
      borderRadius: BorderRadius.circular(12),
    ),
    child: child,
  );
}

class ReferenceTopNavigation extends StatelessWidget {
  const ReferenceTopNavigation({
    super.key,
    required this.selectedIndex,
    required this.connected,
    required this.onSelected,
  });
  final int selectedIndex;
  final bool connected;
  final ValueChanged<int> onSelected;
  @override
  Widget build(BuildContext context) => ClipRect(
    key: const ValueKey('video-top-nav'),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: .85),
              Colors.black.withValues(alpha: .55),
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            children: [
              _item(4, tr('设置'), 3),
              const SizedBox(width: 18),
              _item(1, tr('首页'), 4),
              const SizedBox(width: 18),
              _item(0, tr('设备'), 3, dot: true),
            ],
          ),
        ),
      ),
    ),
  );
  Widget _item(int index, String label, int flex, {bool dot = false}) {
    final current = selectedIndex == 2
        ? 1
        : selectedIndex == 3
        ? 4
        : selectedIndex;
    return Expanded(
      flex: flex,
      child: Tooltip(
        message: label,
        child: Material(
          color: current == index
              ? const Color(0xff383838)
              : const Color(0xff1d1d1d),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            key: ValueKey('nav-$index'),
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              HapticFeedback.selectionClick();
              onSelected(index);
            },
            child: Semantics(
              label: label,
              button: true,
              selected: current == index,
              child: SizedBox(
                height: 34,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: AppText(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: current == index
                              ? Colors.white
                              : referenceMuted,
                        ),
                      ),
                    ),
                    if (dot) ...[
                      const SizedBox(width: 5),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: connected
                              ? const Color(0xff32d583)
                              : const Color(0xffff4545),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The rounded card and circular display are separate clips: user photos must
/// not fill the square corners or acquire a second black circular outline.
/// Grids decode only the first frame, even for legacy GIF preview files.
class StaticMaterialPreview extends StatefulWidget {
  const StaticMaterialPreview({super.key, required this.image});
  final ImageProvider image;
  @override
  State<StaticMaterialPreview> createState() => _StaticMaterialPreviewState();
}

class _StaticMaterialPreviewState extends State<StaticMaterialPreview> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _frame;
  ImageProvider? _resolved;
  void _replaceFrame(ImageInfo? frame) {
    final previous = _frame;
    _frame = frame;
    WidgetsBinding.instance.addPostFrameCallback((_) => previous?.dispose());
  }

  void _detach() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _open();
  }

  @override
  void didUpdateWidget(covariant StaticMaterialPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) _open();
  }

  void _open() {
    if (_resolved == widget.image) return;
    _detach();
    _resolved = widget.image;
    _replaceFrame(null);
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    _stream = stream;
    _listener = ImageStreamListener(
      (frame, synchronous) {
        if (!mounted || _stream != stream || _frame != null) {
          frame.dispose();
          return;
        }
        // ImageStream transfers ownership of this handle to the listener.
        setState(() => _replaceFrame(frame));
        // Stop listening after frame zero: no GIF animation in the grid.
        scheduleMicrotask(() {
          if (_stream == stream) _detach();
        });
      },
      onError: (Object error, StackTrace? stack) {
        scheduleMicrotask(() {
          if (_stream == stream) _detach();
        });
      },
    );
    stream.addListener(_listener!);
  }

  @override
  void dispose() {
    _detach();
    _frame?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _frame == null
      ? const SizedBox.expand()
      : RawImage(
          image: _frame!.image,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
        );
}

class ReferenceMaterialTile extends StatelessWidget {
  const ReferenceMaterialTile({
    super.key,
    required this.child,
    required this.selected,
    this.onTap,
    this.onLongPress,
    this.overlay,
  });
  final Widget child;
  final Widget? overlay;
  final bool selected;
  final VoidCallback? onTap, onLongPress;
  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xff0d0c0e),
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(
        color: selected ? Colors.white : Colors.transparent,
        width: 1.5,
      ),
    ),
    child: InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(
            padding: const EdgeInsets.all(4),
            child: ClipOval(
              child: ColorFiltered(
                // Bring encoded black padding to exactly the card background.
                // This avoids a separate black disc inside the rounded square.
                colorFilter: const ColorFilter.mode(
                  Color(0xff0d0c0e),
                  BlendMode.lighten,
                ),
                child: child,
              ),
            ),
          ),
          if (overlay != null) overlay!,
        ],
      ),
    ),
  );
}

class ReferenceDeviceDisplay extends StatelessWidget {
  const ReferenceDeviceDisplay({super.key, this.child});
  final Widget? child;
  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 1,
    child: DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xff37353b),
            Color(0xff020203),
            Color(0xff080809),
            Color(0xff242329),
          ],
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black,
            blurRadius: 14,
            spreadRadius: 3,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(1.1),
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xff010102), width: .7),
            gradient: const RadialGradient(
              center: Alignment(0, -.4),
              colors: [Color(0xff09080b), Color(0xff020203), Colors.black],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(.6),
            child: ClipOval(child: child ?? const SizedBox.expand()),
          ),
        ),
      ),
    ),
  );
}

class ReferenceSegmentedBar extends StatelessWidget {
  const ReferenceSegmentedBar({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
  });
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(11),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
      child: Container(
        height: 32,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xb32c2b2f), Color(0xd90d0d10)],
          ),
          border: Border.all(color: const Color(0x25ffffff), width: .6),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          children: [
            for (var i = 0; i < labels.length; ++i)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: selectedIndex == i,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: selectedIndex == i
                            ? const [Color(0xff454448), Color(0xff252528)]
                            : const [Colors.transparent, Colors.transparent],
                      ),
                      border: Border.all(
                        color: selectedIndex == i
                            ? const Color(0x33ffffff)
                            : Colors.transparent,
                        width: .6,
                      ),
                      boxShadow: selectedIndex == i
                          ? const [
                              BoxShadow(
                                color: Color(0x66000000),
                                blurRadius: 4,
                                offset: Offset(0, 2),
                              ),
                            ]
                          : const [],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onSelected(i);
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Center(
                          child: AppText(
                            labels[i],
                            style: TextStyle(
                              fontSize: 13,
                              color: selectedIndex == i
                                  ? Colors.white
                                  : const Color(0xffaaaaaf),
                              shadows: selectedIndex == i
                                  ? const [
                                      Shadow(
                                        color: Color(0x44000000),
                                        offset: Offset(0, 1),
                                        blurRadius: 2,
                                      ),
                                    ]
                                  : null,
                            ),
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
    ),
  );
}

class ReferenceSettingsPage extends StatelessWidget {
  const ReferenceSettingsPage({
    super.key,
    required this.onAlignment,
    required this.onBrightness,
    required this.onMode,
    required this.onDevice,
    required this.onLibrary,
    required this.onPrivacy,
    required this.onSupport,
    required this.onVersion,
    required this.version,
    required this.demoMode,
    required this.onDemo,
    required this.onLanguage,
    required this.onGame,
    required this.onDeviceStatus,
    this.firmwareUpdateAvailable = false,
  });
  final VoidCallback onAlignment, onBrightness, onMode, onDevice, onLibrary;
  final VoidCallback onPrivacy, onSupport, onVersion, onDemo;
  final VoidCallback onLanguage, onGame, onDeviceStatus;
  final String version;
  final bool demoMode;
  final bool firmwareUpdateAvailable;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
    children: [
      const Center(
        child: AppText(
          '设置与隐私',
          style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
        ),
      ),
      const SizedBox(height: 28),
      _group('显示', [
        _row('亮度', onBrightness),
        _row('安装角度校正', onAlignment, key: const ValueKey('settings-alignment')),
        _row('播放模式', onMode),
      ]),
      _group('设备', [
        _row(
          '设备版本',
          onVersion,
          key: const ValueKey('settings-device-version'),
          updateAvailable: firmwareUpdateAvailable,
        ),
        _row(
          '设备状态',
          onDeviceStatus,
          key: const ValueKey('settings-device-status'),
        ),
        _row('我的素材', onLibrary),
        _row('连接管理', onDevice),
      ]),
      _group('隐私与条款', [_row('隐私政策', onPrivacy)]),
      _group('支持', [_row('联系支持', onSupport)]),
      _group('应用', [
        _row('语言', onLanguage, key: const ValueKey('settings-language')),
        _row('游戏', onGame, key: const ValueKey('settings-games')),
        _row(demoMode ? '退出演示模式' : '审核演示', onDemo),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
          child: Row(
            children: [
              const AppText('App 版本', style: TextStyle(fontSize: 14)),
              const Spacer(),
              AppText(
                version,
                style: const TextStyle(color: referenceMuted, fontSize: 13),
              ),
            ],
          ),
        ),
      ]),
    ],
  );
  Widget _group(String title, List<Widget> rows) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 10),
          child: AppText(
            title,
            style: const TextStyle(color: Color(0xffbbbbbb), fontSize: 13),
          ),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Material(
            color: const Color(0xff202020),
            child: Column(
              children: [
                for (var i = 0; i < rows.length; ++i) ...[
                  if (i > 0)
                    const Divider(
                      height: 1,
                      thickness: 1,
                      indent: 18,
                      endIndent: 18,
                      color: Color(0xff292929),
                    ),
                  rows[i],
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );
  Widget _row(
    String title,
    VoidCallback action, {
    Key? key,
    bool updateAvailable = false,
  }) => InkWell(
    key: key,
    onTap: action,
    child: SizedBox(
      height: 48,
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22),
        child: Row(
          children: [
            AppText(
              title,
              style: const TextStyle(fontSize: 14, color: Color(0xffcccccc)),
            ),
            if (updateAvailable) ...[
              const SizedBox(width: 8),
              Semantics(
                label: tr('有新固件'),
                child: Container(
                  key: const ValueKey('settings-firmware-update-dot'),
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xffff453a),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class ReferenceBrightnessPage extends StatefulWidget {
  const ReferenceBrightnessPage({
    super.key,
    required this.initialValue,
    required this.connected,
    required this.onChanged,
  });
  final int initialValue;
  final bool connected;
  final ValueChanged<int> onChanged;
  @override
  State<ReferenceBrightnessPage> createState() =>
      _ReferenceBrightnessPageState();
}

class _ReferenceBrightnessPageState extends State<ReferenceBrightnessPage> {
  late int _value = widget.initialValue;
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: referenceDetailAppBar('亮度'),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 8, bottom: 12),
          child: AppText(
            '屏幕',
            style: TextStyle(color: referenceMuted, fontSize: 12),
          ),
        ),
        ReferencePanel(
          child: Column(
            children: [
              Row(
                children: [
                  const AppText(
                    '亮度',
                    style: TextStyle(color: Color(0xffbbbbbb), fontSize: 13),
                  ),
                  const Spacer(),
                  AppText(
                    '$_value%',
                    style: const TextStyle(color: referenceMuted, fontSize: 12),
                  ),
                ],
              ),
              Slider(
                value: _value.toDouble(),
                min: 0,
                max: 100,
                divisions: 100,
                onChanged: widget.connected
                    ? (value) {
                        setState(() => _value = value.round());
                        widget.onChanged(_value);
                      }
                    : null,
              ),
              if (!widget.connected)
                const AppText(
                  '连接设备后可调整',
                  style: TextStyle(color: referenceMuted, fontSize: 12),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class ReferenceLoopPage extends StatelessWidget {
  const ReferenceLoopPage({
    super.key,
    required this.enabled,
    required this.updating,
    required this.onChanged,
    required this.factoryCount,
    required this.onBack,
  });
  final bool enabled, updating;
  final int factoryCount;
  final ValueChanged<bool> onChanged;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: referenceDetailAppBar('播放模式', onBack: onBack),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
        children: [
          ReferencePanel(
            child: Row(
              children: [
                const Expanded(
                  child: AppText('随机播放', style: TextStyle(fontSize: 14)),
                ),
                if (updating)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Switch(
                    value: enabled,
                    onChanged: onChanged,
                    activeTrackColor: const Color(0xff32d583),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: AppText(
              '轮换 $factoryCount 个出厂素材，保留完整的入场与退场动画。',
              style: const TextStyle(
                color: referenceMuted,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
