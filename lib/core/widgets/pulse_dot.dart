import 'package:flutter/widgets.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';

/// Amber dot with a pulsing ring (offline status, unsaved settings).
/// 2.2 s loop; static when animations are disabled.
class PulseDot extends StatefulWidget {
  const PulseDot({super.key, this.size = 9, this.color = AppColors.pulse, this.semanticLabel});

  final double size;
  final Color color;
  final String? semanticLabel;

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: AppMotion.pulse);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.reduceMotion) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        // CSS keyframes: ring 0→9 px by 70 %, alpha .55→0, then rest.
        final p = (_c.value / 0.7).clamp(0.0, 1.0);
        final ring = context.reduceMotion ? 0.0 : 9 * p;
        final alpha = context.reduceMotion ? 0.0 : 0.55 * (1 - p);
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: widget.color.withValues(alpha: alpha), spreadRadius: ring),
            ],
          ),
        );
      },
    );
    if (widget.semanticLabel == null) return ExcludeSemantics(child: dot);
    return Semantics(label: widget.semanticLabel, child: dot);
  }
}
