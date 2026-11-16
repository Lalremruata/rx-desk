import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';

part 'app_toast.g.dart';

enum ToastKind { success, warning }

@immutable
class ToastMessage {
  const ToastMessage({required this.id, required this.text, required this.kind});

  final int id;
  final String text;
  final ToastKind kind;
}

/// Toast queue. The first entry is on screen; the rest wait their turn.
///
/// ```dart
/// ref.read(toastsProvider.notifier).show('INV/26-27/00412 saved');
/// ref.read(toastsProvider.notifier).show('Only 3 left in batch', warn: true);
/// ```
@Riverpod(keepAlive: true)
class Toasts extends _$Toasts {
  /// Waiting toasts beyond this are dropped (oldest first) so a burst of
  /// scanner warnings can't build a long backlog.
  static const int maxWaiting = 3;

  int _nextId = 0;

  @override
  List<ToastMessage> build() => const [];

  void show(String text, {bool warn = false}) {
    final msg = ToastMessage(id: _nextId++, text: text, kind: warn ? ToastKind.warning : ToastKind.success);
    var q = [...state, msg];
    if (q.length > 1 + maxWaiting) {
      q = [q.first, ...q.sublist(q.length - maxWaiting)];
    }
    state = q;
  }

  void dismiss(int id) => state = [for (final m in state) if (m.id != id) m];
}

/// The toast's look: dark rounded panel, coloured icon disc, 13/500 text.
class AppToast extends StatelessWidget {
  const AppToast({super.key, required this.text, this.kind = ToastKind.success});

  final String text;
  final ToastKind kind;

  @override
  Widget build(BuildContext context) {
    final warn = kind == ToastKind.warning;
    final disc = warn ? StatusTone.warning.colors.icon : StatusTone.success.colors.icon;
    // The host sits above the Navigator (no Material ancestor), so provide one
    // for a proper default text style.
    return Material(
      type: MaterialType.transparency,
      child: _toastBody(disc, warn),
    );
  }

  Widget _toastBody(Color disc, bool warn) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 400),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: const BoxDecoration(
        color: AppColors.toastBg,
        borderRadius: BorderRadius.all(Radius.circular(14)),
        boxShadow: [AppShadows.toast],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(color: disc, shape: BoxShape.circle),
            child: Icon(
              warn ? Icons.priority_high_rounded : Icons.check_rounded,
              size: 16,
              color: AppColors.toastFg,
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Flexible(
            child: Text(
              text,
              style: AppType.small.copyWith(color: AppColors.toastFg, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows the head of the [toastsProvider] queue over the whole app
/// (above dialogs). Slide up 24 px + scale 0.97→1 in 380 ms; auto-dismiss
/// after 2.8 s.
class ToastHost extends ConsumerStatefulWidget {
  const ToastHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ToastHost> createState() => _ToastHostState();
}

class _ToastHostState extends ConsumerState<ToastHost> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: AppMotion.toast);
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: AppMotion.emphasised, reverseCurve: Curves.easeIn);
  ToastMessage? _shown;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  void _sync(List<ToastMessage> queue) {
    final head = queue.isEmpty ? null : queue.first;
    if (head?.id == _shown?.id) return;
    _timer?.cancel();
    setState(() => _shown = head);
    if (head == null) return;
    _c
      ..duration = context.motion(AppMotion.toast)
      ..reverseDuration = context.motion(const Duration(milliseconds: 200))
      ..forward(from: 0);
    _timer = Timer(AppMotion.toastDismiss, () => _close(head.id));
  }

  Future<void> _close(int id) async {
    _timer?.cancel();
    await _c.reverse();
    if (mounted) ref.read(toastsProvider.notifier).dismiss(id);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(toastsProvider, (_, next) => _sync(next));
    final shown = _shown;
    final compact = MediaQuery.sizeOf(context).width < AppSizes.breakpointRail;

    return Stack(
      children: [
        widget.child,
        if (shown != null)
          Positioned(
            right: compact ? 16 : 24,
            left: compact ? 16 : null,
            // Clear the bottom NavigationBar on phones / narrow tablets.
            bottom: compact ? 96 : 24,
            child: Align(
              alignment: compact ? Alignment.bottomCenter : Alignment.bottomRight,
              child: AnimatedBuilder(
                animation: _t,
                builder: (context, child) => Opacity(
                  opacity: _t.value.clamp(0, 1),
                  child: Transform.translate(
                    offset: Offset(0, AppMotion.toastDy * (1 - _t.value)),
                    child: Transform.scale(
                      scale: AppMotion.toastScaleFrom + (1 - AppMotion.toastScaleFrom) * _t.value,
                      child: child,
                    ),
                  ),
                ),
                // Pointer-transparent so a toast never blocks the control
                // underneath (e.g. Save & print).
                child: IgnorePointer(
                  child: Semantics(
                    liveRegion: true,
                    child: AppToast(key: ValueKey(shown.id), text: shown.text, kind: shown.kind),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
