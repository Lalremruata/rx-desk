import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/db_provider.dart';
import '../../../core/money/paise.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/expiry.dart';
import '../../../core/widgets/widgets.dart';
import '../../settings/application/settings_providers.dart';
import '../application/bill_controller.dart';
import '../application/bill_state.dart';

/// Bill lines: # · Item · Batch · Exp · Qty · MRP · Amount · delete.
class BillGrid extends ConsumerWidget {
  const BillGrid({super.key});

  static const _columns = [
    GridColumn.fixed('#', 28),
    GridColumn('Item', flex: 2.6, minWidth: 200),
    GridColumn.fixed('Batch', 104),
    GridColumn.fixed('Exp', 76),
    GridColumn.fixed('Qty', 150),
    GridColumn.fixed('MRP', 88, alignEnd: true),
    GridColumn.fixed('Amount', 100, alignEnd: true),
    GridColumn.fixed('', 44),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(billControllerProvider.select((s) => s.lines));
    final flashKey = ref.watch(billControllerProvider.select((s) => s.lastAddedKey));
    final token = ref.watch(billControllerProvider.select((s) => s.flashToken));
    final window = ref.watch(settingsProvider.select((s) => s.expiryWindowMonths));
    final now = ref.watch(nowProvider)();

    return AppCard(
      padding: EdgeInsets.zero,
      clip: true,
      child: DataGrid(
        semanticLabel: 'Bill',
        columns: _columns,
        rowCount: lines.length,
        empty: const EmptyState(
          icon: Icons.receipt_long_outlined,
          title: 'Bill is empty',
          message: 'Start typing a medicine or salt name above, or scan a barcode.',
        ),
        cells: (context, i) {
          final l = lines[i];
          final near = monthsLeft(l.expiry, now) <= window;
          return [
            Text('${i + 1}', style: AppType.small.copyWith(color: AppColors.textMuted)),
            _Animated(
              key: ValueKey('line-${l.key}'),
              flash: l.key == flashKey,
              token: token,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(child: Text(l.name, style: AppType.bodyStrong, overflow: TextOverflow.ellipsis)),
                      if (l.schedule.isNotEmpty) ...[const SizedBox(width: 6), RxBadge(l.schedule)],
                    ],
                  ),
                  Text('${l.salt} · ${l.maker}', style: AppType.caption, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Text(l.batchNo, style: AppType.mono),
            Text(
              formatExpiry(l.expiry).replaceFirst(' 20', ' '),
              style: AppType.smallStrong.copyWith(color: near ? StockColors.low : AppColors.body),
            ),
            _QtyField(line: l),
            l.sellsLoose
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(formatInr(l.mrp), style: AppType.small),
                      Text('per ${l.nouns.pack} of ${l.packSize}', style: AppType.caption.copyWith(fontSize: 11)),
                    ],
                  )
                : Text(formatInr(l.mrp), style: AppType.small),
            Text(formatInr(l.amount), style: AppType.bodyStrong.copyWith(fontFeatures: AppType.tabular)),
            IconButton(
              key: ValueKey('remove-${l.key}'),
              tooltip: 'Remove ${l.name}',
              icon: const Icon(Icons.delete_outline_rounded, size: 18, color: AppColors.textMuted),
              onPressed: () => ref.read(billControllerProvider.notifier).removeLine(l.key),
            ),
          ];
        },
      ),
    );
  }
}

/// New lines slide in from x +18 (320 ms); the line just added flashes amber
/// fading over 1.4 s (SPEC §9).
class _Animated extends StatefulWidget {
  const _Animated({super.key, required this.flash, required this.token, required this.child});

  final bool flash;
  final int token;
  final Widget child;

  @override
  State<_Animated> createState() => _AnimatedState();
}

class _AnimatedState extends State<_Animated> with TickerProviderStateMixin {
  late final AnimationController _in = AnimationController(vsync: this, duration: AppMotion.rowIn);
  late final AnimationController _flash = AnimationController(vsync: this, duration: AppMotion.rowFlash);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_in.isAnimating || _in.isCompleted) return;
    if (context.reduceMotion) {
      _in.value = 1;
      _flash.value = 1;
    } else {
      _in.forward();
      if (widget.flash) {
        _flash.forward();
      } else {
        _flash.value = 1;
      }
    }
  }

  @override
  void didUpdateWidget(_Animated old) {
    super.didUpdateWidget(old);
    if (widget.flash && widget.token != old.token && !context.reduceMotion) _flash.forward(from: 0);
  }

  @override
  void dispose() {
    _in.dispose();
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = CurvedAnimation(parent: _in, curve: AppMotion.emphasised);
    return AnimatedBuilder(
      animation: Listenable.merge([_in, _flash]),
      builder: (context, child) => Opacity(
        opacity: t.value,
        child: Transform.translate(
          offset: Offset(AppMotion.rowInDx * (1 - t.value), 0),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Color.lerp(AppColors.flashNewRow, AppColors.transparent, Curves.ease.transform(_flash.value)),
              borderRadius: AppRadius.tinyAll,
            ),
            child: child,
          ),
        ),
      ),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2), child: widget.child),
    );
  }
}

class _QtyField extends ConsumerStatefulWidget {
  const _QtyField({required this.line});

  final BillLine line;

  @override
  ConsumerState<_QtyField> createState() => _QtyFieldState();
}

class _QtyFieldState extends ConsumerState<_QtyField> {
  late final TextEditingController _c = TextEditingController(text: '${widget.line.shownQty}');
  late final FocusNode _f = FocusNode(onKeyEvent: _onKey);

  @override
  void initState() {
    super.initState();
    _f.addListener(() {
      if (!_f.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_QtyField old) {
    super.didUpdateWidget(old);
    final shown = '${widget.line.shownQty}';
    if ((!_f.hasFocus || widget.line.loose != old.line.loose) && _c.text != shown) _c.text = shown;
  }

  BillLine get _current =>
      ref.read(billControllerProvider).lines.firstWhere((l) => l.key == widget.line.key, orElse: () => widget.line);

  void _commit() {
    final v = int.tryParse(_c.text) ?? widget.line.shownQty;
    ref.read(billControllerProvider.notifier).setQty(widget.line.key, v);
    _c.text = '${_current.shownQty}';
  }

  /// S = sell by the strip, T = by the tablet (loose lines only).
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent || !widget.line.sellsLoose) return KeyEventResult.ignored;
    final loose = switch (e.logicalKey) {
      LogicalKeyboardKey.keyT => true,
      LogicalKeyboardKey.keyS => false,
      _ => null,
    };
    if (loose == null) return KeyEventResult.ignored;
    _setLoose(loose);
    return KeyEventResult.handled;
  }

  void _setLoose(bool loose) {
    final n = int.tryParse(_c.text);
    final ctl = ref.read(billControllerProvider.notifier);
    if (n != null && n != widget.line.shownQty) ctl.setQty(widget.line.key, n);
    ctl.setLoose(widget.line.key, loose);
    _c.text = '${_current.shownQty}';
  }

  @override
  void dispose() {
    _c.dispose();
    _f.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.line;
    final field = SizedBox(
      width: 60,
      child: Semantics(
        label: l.sellsLoose ? 'Quantity for ${l.name}, in ${l.loose ? l.nouns.units : l.nouns.packs}' : 'Quantity for ${l.name}',
        child: TextField(
          key: ValueKey('qty-${widget.line.key}'),
          controller: _c,
          focusNode: _f,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(5)],
          style: AppType.bodyStrong,
          // Enter commits and goes back to the search box, keeping focus
          // inside the billing shortcuts (F10 etc.).
          onSubmitted: (_) {
            _commit();
            ref.read(billControllerProvider.notifier).requestSearchFocus();
          },
          decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 10)),
        ),
      ),
    );
    if (!l.sellsLoose) return field;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        field,
        const SizedBox(width: 6),
        _UnitToggle(line: l, onChanged: _setLoose),
      ],
    );
  }
}

/// Strip | Tab switch for a line that can be sold loose (SPEC §4.9).
class _UnitToggle extends StatelessWidget {
  const _UnitToggle({required this.line, required this.onChanged});

  final BillLine line;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final w = line.nouns;
    final label = line.loose ? w.unit : w.pack;
    final other = line.loose ? w.packs : w.units;
    return Tooltip(
      message: 'Selling by the ${line.loose ? w.unit : w.pack} — tap (or press ${line.loose ? 'S' : 'T'} in qty) for $other',
      child: Semantics(
        button: true,
        label: 'Unit: $label. Switch to $other',
        excludeSemantics: true,
        child: Material(
          color: line.loose ? p.accentSoft : AppColors.surfaceAlt,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            side: BorderSide(color: line.loose ? p.accent : AppColors.border),
          ),
          child: InkWell(
            key: ValueKey('unit-${line.key}'),
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            onTap: () => onChanged(!line.loose),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 52, minHeight: 44),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    label[0].toUpperCase() + label.substring(1),
                    style: AppType.smallStrong.copyWith(color: line.loose ? p.accent : AppColors.body),
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

/// Total of one line at MRP, pro-rata when loose (display).
Paise lineAmount(BillLine l) => l.amount;
