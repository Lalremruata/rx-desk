import 'package:flutter/widgets.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';

/// Screen-enter animation: fade 0→1 + rise 12→0 px over 500 ms (emphasised).
///
/// Give children of a screen increasing [index] values to stagger them by
/// 50 ms each (prototype `.stag`). Skipped when animations are disabled.
class PageEnter extends StatefulWidget {
  const PageEnter({super.key, required this.child, this.index = 0});

  final Widget child;

  /// Stagger slot: the animation starts `index × 50 ms` late.
  final int index;

  @override
  State<PageEnter> createState() => _PageEnterState();
}

class _PageEnterState extends State<PageEnter> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _t;

  @override
  void initState() {
    super.initState();
    final delay = AppMotion.stagger * widget.index;
    final total = AppMotion.screenEnter + delay;
    _c = AnimationController(vsync: this, duration: total);
    _t = CurvedAnimation(
      parent: _c,
      curve: Interval(delay.inMicroseconds / total.inMicroseconds, 1, curve: AppMotion.emphasised),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.isAnimating || _c.isCompleted) return;
    if (context.reduceMotion) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: _t.value,
        child: Transform.translate(
          offset: Offset(0, AppMotion.screenEnterDy * (1 - _t.value)),
          child: child,
        ),
      ),
    );
  }
}
