import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

// Billing keyboard shortcuts (SPEC §5.2). These are Flutter Intents used
// with a `Shortcuts` + `Actions` pair scoped to the Billing route — not
// global OS hooks. Wired up in phase 4.

class NewBillIntent extends Intent {
  const NewBillIntent();
}

class FocusSearchIntent extends Intent {
  const FocusSearchIntent();
}

class FocusCustomerIntent extends Intent {
  const FocusCustomerIntent();
}

class CyclePaymentIntent extends Intent {
  const CyclePaymentIntent();
}

class SaveBillIntent extends Intent {
  const SaveBillIntent();
}

class CloseListIntent extends Intent {
  const CloseListIntent();
}

/// F2 new bill · F3 search · F4 customer · F8 payment mode ·
/// F10 save & print · Esc close list.
const Map<ShortcutActivator, Intent> billingShortcuts = {
  SingleActivator(LogicalKeyboardKey.f2): NewBillIntent(),
  SingleActivator(LogicalKeyboardKey.f3): FocusSearchIntent(),
  SingleActivator(LogicalKeyboardKey.f4): FocusCustomerIntent(),
  SingleActivator(LogicalKeyboardKey.f8): CyclePaymentIntent(),
  SingleActivator(LogicalKeyboardKey.f10): SaveBillIntent(),
  SingleActivator(LogicalKeyboardKey.escape): CloseListIntent(),
};
