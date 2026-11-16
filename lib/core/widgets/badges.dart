import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Coloured status label.
///
/// * default — rounded pill, 12/700, padding 4×10 (inventory "Status" column)
/// * [StatusBadge.tag] — 6 px radius, 11/700, padding 3×8 (batch notes:
///   "Sell first (FEFO)", "Near expiry", "Expired · return to supplier")
/// * [StatusBadge.count] — small count pill, 11/700, padding 2×8 (tab counts)
class StatusBadge extends StatelessWidget {
  const StatusBadge(this.label, {super.key, this.tone = StatusTone.neutral})
      : _shape = _BadgeShape.pill;

  const StatusBadge.tag(this.label, {super.key, this.tone = StatusTone.neutral})
      : _shape = _BadgeShape.tag;

  const StatusBadge.count(this.label, {super.key, this.tone = StatusTone.neutral})
      : _shape = _BadgeShape.count;

  final String label;
  final StatusTone tone;
  final _BadgeShape _shape;

  @override
  Widget build(BuildContext context) {
    final c = context.palette.tone(tone);
    final (EdgeInsets pad, BorderRadius radius, TextStyle style) = switch (_shape) {
      _BadgeShape.pill => (
          const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          AppRadius.pillAll,
          AppType.label.copyWith(fontWeight: FontWeight.w700),
        ),
      _BadgeShape.tag => (
          const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          AppRadius.tinyAll,
          AppType.badge,
        ),
      _BadgeShape.count => (
          const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          AppRadius.pillAll,
          AppType.badge,
        ),
    };
    return Container(
      padding: pad,
      decoration: BoxDecoration(color: c.bg, borderRadius: radius),
      child: Text(label, style: style.copyWith(color: c.fg), maxLines: 1, softWrap: false),
    );
  }
}

enum _BadgeShape { pill, tag, count }

/// Drug schedule badge ("H", "H1", "X") in rose. Renders nothing for an
/// empty schedule.
class RxBadge extends StatelessWidget {
  const RxBadge(this.schedule, {super.key});

  final String schedule;

  @override
  Widget build(BuildContext context) {
    if (schedule.isEmpty) return const SizedBox.shrink();
    final c = StatusTone.rx.colors;
    return Tooltip(
      message: schedule == 'X'
          ? 'Schedule X — cannot be sold from RxDesk'
          : 'Schedule $schedule — prescription required',
      child: Semantics(
        label: 'Schedule $schedule',
        excludeSemantics: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(color: c.bg, borderRadius: const BorderRadius.all(Radius.circular(4))),
          child: Text(schedule, style: AppType.badge.copyWith(color: c.fg)),
        ),
      ),
    );
  }
}

/// Keyboard key chip, optionally followed by a label: [F2] New bill.
class KeyHint extends StatelessWidget {
  const KeyHint(this.keyLabel, {super.key, this.label});

  final String keyLabel;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final kbd = Container(
      constraints: const BoxConstraints(minWidth: 26),
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.tinyAll,
        border: Border(
          top: BorderSide(color: AppColors.kbdBorder),
          left: BorderSide(color: AppColors.kbdBorder),
          right: BorderSide(color: AppColors.kbdBorder),
          bottom: BorderSide(color: AppColors.kbdBorder, width: 2),
        ),
      ),
      child: Center(
        widthFactor: 1,
        child: Text(keyLabel, style: AppType.mono.copyWith(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.body)),
      ),
    );
    final row = label == null
        ? kbd
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [kbd, const SizedBox(width: 6), Text(label!, style: AppType.caption)],
          );
    return Semantics(
      label: label == null ? 'Key $keyLabel' : '$keyLabel: $label',
      excludeSemantics: true,
      child: row,
    );
  }
}
