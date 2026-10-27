import 'package:flutter/material.dart';

/// Brief animated handoff from the native black launch screen to the app.
/// The home page stays mounted underneath so its existing startup work is not
/// delayed by the logo animation.
class StartupLogoSplash extends StatefulWidget {
  const StartupLogoSplash({super.key, required this.child});

  final Widget child;

  @override
  State<StartupLogoSplash> createState() => _StartupLogoSplashState();
}

class _StartupLogoSplashState extends State<StartupLogoSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;
  bool _showLogo = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1250),
    );
    _opacity = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 18,
      ),
      TweenSequenceItem(tween: ConstantTween<double>(1), weight: 52),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1,
          end: 0,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 30,
      ),
    ]).animate(_controller);
    _scale = Tween<double>(begin: .84, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0, .4, curve: Curves.easeOutCubic),
      ),
    );
    _controller.forward().whenComplete(() {
      if (mounted) setState(() => _showLogo = false);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      widget.child,
      if (_showLogo)
        Positioned.fill(
          child: IgnorePointer(
            child: ColoredBox(
              key: const ValueKey('startup-splash-surface'),
              color: Colors.black,
              child: Center(
                child: FadeTransition(
                  opacity: _opacity,
                  child: ScaleTransition(
                    scale: _scale,
                    child: Semantics(
                      label: 'DotLoop',
                      image: true,
                      child: Image.asset(
                        'assets/brand/dotloop_app_icon.png',
                        key: const ValueKey('startup-app-logo'),
                        width: 156,
                        height: 156,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.high,
                        excludeFromSemantics: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}
