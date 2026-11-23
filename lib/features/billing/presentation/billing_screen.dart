import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money/paise.dart';
import '../../../core/router/routes.dart';
import '../../../core/shortcuts/intents.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../invoices/application/invoice_list.dart';
import '../../settings/application/settings_providers.dart';
import '../../staff/presentation/owner_override_dialog.dart';
import '../application/bill_controller.dart';
import '../application/new_bill_request.dart';
import 'bill_details.dart';
import 'bill_grid.dart';
import 'held_bills_dialog.dart';
import 'search_panel.dart';

/// Billing / POS (SPEC §5.2): keyboard-first. Left 3/5 search + bill,
/// right 2/5 bill details. F2 F3 F4 F8 F10 Esc are scoped to this route.
class BillingScreen extends ConsumerStatefulWidget {
  const BillingScreen({super.key});

  @override
  ConsumerState<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends ConsumerState<BillingScreen> {
  final FocusNode _search = FocusNode(debugLabel: 'billing-search');
  final FocusNode _customer = FocusNode(debugLabel: 'billing-customer');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _search.requestFocus();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _customer.dispose();
    super.dispose();
  }

  BillController get _bill => ref.read(billControllerProvider.notifier);

  Future<void> _save() async {
    var r = await _bill.save();
    if (r is CreditLimitBlocked && mounted) {
      final e = r.error;
      final allowed = await confirmOwnerOverride(
        context,
        ref,
        title: 'Over the credit limit',
        message: '${ref.read(billControllerProvider).customer.trim()} owes ${formatInr(Paise(e.dues))}. '
            'This bill adds ${formatInr(Paise(e.adding))} — ${formatInr(Paise(e.overBy))} past the limit of ${formatInr(Paise(e.limit))}.',
        allowLabel: 'Allow this bill',
      );
      if (!mounted) return;
      if (!allowed) {
        _search.requestFocus();
        return;
      }
      r = await _bill.save(overrideCreditLimit: true);
    }
    if (r is BillSavedOutcome && mounted) {
      ref.read(invoiceListControllerProvider.notifier).showToday();
      context.go(Routes.invoices);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref
      ..listen(billControllerProvider.select((s) => s.focusSearchToken), (_, _) => _search.requestFocus())
      ..listen(billControllerProvider.select((s) => s.focusCustomerToken), (_, _) => _customer.requestFocus())
      ..listen(newBillRequestProvider, (_, _) => _search.requestFocus())
      ..listen(settingsProvider.select((s) => s.maxDiscountPct), (_, max) => _bill.clampDiscount(max));
    final showHints = ref.watch(settingsProvider.select((s) => s.showKeyHints));

    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SearchPanel(focusNode: _search),
        const HoldBar(),
        const SizedBox(height: AppSpace.lg),
        const BillGrid(),
        if (showHints) ...[const SizedBox(height: AppSpace.md), const _KeyHints()],
      ],
    );
    final right = BillDetails(customerFocus: _customer, onSave: _save);

    return Shortcuts(
      shortcuts: billingShortcuts,
      child: Actions(
        actions: {
          NewBillIntent: CallbackAction<NewBillIntent>(onInvoke: (_) => _bill.newBill()),
          FocusSearchIntent: CallbackAction<FocusSearchIntent>(onInvoke: (_) => _search.requestFocus()),
          FocusCustomerIntent: CallbackAction<FocusCustomerIntent>(onInvoke: (_) => _customer.requestFocus()),
          CyclePaymentIntent: CallbackAction<CyclePaymentIntent>(onInvoke: (_) => _bill.cyclePayment()),
          SaveBillIntent: CallbackAction<SaveBillIntent>(onInvoke: (_) => _save()),
          CloseListIntent: CallbackAction<CloseListIntent>(onInvoke: (_) => _bill.escape()),
          HoldBillIntent: CallbackAction<HoldBillIntent>(
            onInvoke: (_) => ref.read(billControllerProvider).isEmpty ? showHeldBillsDialog(context) : _bill.hold(),
          ),
        },
        child: Focus(
          autofocus: true,
          child: LayoutBuilder(
            builder: (context, c) {
              final compact = MediaQuery.sizeOf(context).width < AppSizes.breakpointRail;
              final x = compact ? AppSpace.lg : AppSpace.pageX;
              if (c.maxWidth < 900) {
                return SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(x, compact ? AppSpace.lg : 0, x, 40),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [PageEnter(child: left), const SizedBox(height: 18), PageEnter(index: 1, child: right)],
                  ),
                );
              }
              return SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(x, 0, x, 40),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: PageEnter(child: left)),
                    const SizedBox(width: 18),
                    Expanded(flex: 2, child: PageEnter(index: 1, child: right)),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _KeyHints extends StatelessWidget {
  const _KeyHints();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Wrap(
          spacing: AppSpace.gap14,
          runSpacing: AppSpace.sm,
          children: [
            KeyHint('F2', label: 'New bill'),
            KeyHint('F3', label: 'Search'),
            KeyHint('F4', label: 'Customer'),
            KeyHint('F6', label: 'Hold / recall'),
            KeyHint('F8', label: 'Payment mode'),
            KeyHint('F10', label: 'Save & print'),
            KeyHint('Esc', label: 'Close list'),
          ],
        ),
      );
}

/// Keys handled by the search box itself (↑ ↓ Enter Esc).
KeyEventResult handleSearchKey(KeyEvent e, BillController bill) {
  if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
  final k = e.logicalKey;
  if (k == LogicalKeyboardKey.arrowDown) {
    bill.moveHighlight(1);
  } else if (k == LogicalKeyboardKey.arrowUp) {
    bill.moveHighlight(-1);
  } else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
    if (e is KeyDownEvent) bill.enter();
  } else if (k == LogicalKeyboardKey.escape) {
    bill.escape();
  } else {
    return KeyEventResult.ignored;
  }
  return KeyEventResult.handled;
}
