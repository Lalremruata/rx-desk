import 'package:flutter/widgets.dart';

/// Reduced-motion helpers. When the OS asks for fewer animations
/// (`MediaQuery.disableAnimationsOf`), non-essential motion is skipped.
extension MotionX on BuildContext {
  bool get reduceMotion => MediaQuery.maybeDisableAnimationsOf(this) ?? false;

  /// [d], or [Duration.zero] when animations are disabled.
  Duration motion(Duration d) => reduceMotion ? Duration.zero : d;
}
