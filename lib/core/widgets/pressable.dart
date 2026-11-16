import 'package:flutter/widgets.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';

/// Shrinks its child to [scale] while a pointer is down (SPEC §9: button
/// press, scale 0.97, 150 ms). Purely visual — wrap a real button or
/// InkWell for semantics, focus and keyboard activation.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.enabled = true,
    this.scale = AppMotion.pressScale,
  });

  final Widget child;
  final bool enabled;
  final double scale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: context.motion(AppMotion.press),
        curve: Curves.ease,
        child: widget.child,
      ),
    );
  }
}
