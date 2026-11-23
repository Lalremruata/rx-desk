/// Held (parked) bills at the counter (SPEC §5.2 "Hold"). Pure Dart.
///
/// A held bill is not an invoice: it has no number, takes no stock and is
/// deleted when recalled or discarded. Lines keep the MRP and GST the
/// counter showed, so a recall can say what changed meanwhile.
library;

import 'dart:convert';

/// Most bills that can be held at once.
const int maxHeldBills = 10;

/// Thrown when a bill can't be held; [message] is shown to the user.
class HeldBillException implements Exception {
  const HeldBillException(this.message);
  final String message;
  @override
  String toString() => 'HeldBillException: $message';
}

class HeldLine {
  const HeldLine({required this.productId, required this.batchId, required this.qty, this.loose = false, required this.mrpPaise, required this.gstRate});

  final int productId;
  final int batchId;

  /// In units, as on the bill line.
  final int qty;
  final bool loose;
  final int mrpPaise;
  final int gstRate;

  Map<String, Object> toJson() => {'p': productId, 'b': batchId, 'q': qty, 'l': loose, 'm': mrpPaise, 'g': gstRate};

  factory HeldLine.fromJson(Map<String, dynamic> j) => HeldLine(
        productId: j['p'] as int,
        batchId: j['b'] as int,
        qty: j['q'] as int,
        loose: j['l'] as bool? ?? false,
        mrpPaise: j['m'] as int,
        gstRate: j['g'] as int,
      );
}

/// Everything needed to put a bill back on the counter.
class HeldBillData {
  const HeldBillData({
    required this.lines,
    this.customer = '',
    this.phone = '',
    this.doctor = '',
    this.discountPct = 0,
    this.discountCustom = false,
    this.discountKind = 'percent',
    this.discountInput = '',
    this.payment = 'Cash',
    this.paidNow = '',
    this.paidNowMode = 'Cash',
  });

  final List<HeldLine> lines;
  final String customer;
  final String phone;
  final String doctor;
  final int discountPct;
  final bool discountCustom;

  /// 'percent' | 'flat'
  final String discountKind;
  final String discountInput;
  final String payment;
  final String paidNow;
  final String paidNowMode;

  static const int version = 1;

  String encode() => jsonEncode({
        'v': version,
        'lines': [for (final l in lines) l.toJson()],
        'customer': customer,
        'phone': phone,
        'doctor': doctor,
        'discountPct': discountPct,
        'discountCustom': discountCustom,
        'discountKind': discountKind,
        'discountInput': discountInput,
        'payment': payment,
        'paidNow': paidNow,
        'paidNowMode': paidNowMode,
      });

  factory HeldBillData.decode(String s) {
    final j = jsonDecode(s) as Map<String, dynamic>;
    return HeldBillData(
      lines: [for (final l in j['lines'] as List) HeldLine.fromJson(l as Map<String, dynamic>)],
      customer: j['customer'] as String? ?? '',
      phone: j['phone'] as String? ?? '',
      doctor: j['doctor'] as String? ?? '',
      discountPct: j['discountPct'] as int? ?? 0,
      discountCustom: j['discountCustom'] as bool? ?? false,
      discountKind: j['discountKind'] as String? ?? 'percent',
      discountInput: j['discountInput'] as String? ?? '',
      payment: j['payment'] as String? ?? 'Cash',
      paidNow: j['paidNow'] as String? ?? '',
      paidNowMode: j['paidNowMode'] as String? ?? 'Cash',
    );
  }
}

/// The name a held bill is listed under: the customer, else the first item.
String heldBillLabel(String customer, String firstItem, int lineCount) {
  final c = customer.trim();
  if (c.isNotEmpty) return c;
  return lineCount > 1 ? 'Walk-in · $firstItem +${lineCount - 1}' : 'Walk-in · $firstItem';
}
