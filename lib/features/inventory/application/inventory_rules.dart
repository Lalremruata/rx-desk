import '../../../core/db/app_database.dart';
import '../../../core/db/models.dart';
import '../../../core/money/paise.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/expiry.dart';
import '../../../core/utils/pack.dart';

/// Status badge for an inventory row (prototype order: out → expiring →
/// low → dead → in stock).
(String, StatusTone) stockStatus(StockRow r, {required DateTime now, required int deadStockDays}) {
  if (r.isOut) return ('Out of stock', StatusTone.danger);
  if (r.expiring) return ('Expiring', StatusTone.warning);
  if (r.isLow) return ('Low stock', StatusTone.warning);
  if (isDeadStock(r, now: now, deadStockDays: deadStockDays)) return ('Dead stock', StatusTone.dead);
  return ('In stock', StatusTone.success);
}

bool isDeadStock(StockRow r, {required DateTime now, required int deadStockDays}) {
  if (r.saleable <= 0) return false;
  final last = r.lastSoldAt ?? r.createdAt;
  return last < now.subtract(Duration(days: deadStockDays)).toUtc().millisecondsSinceEpoch;
}

/// Note for a batch row (SPEC §5.3).
(String, StatusTone) batchNote(
  StockBatch b, {
  required int? fefoBatchId,
  required DateTime now,
  required int expiryWindowMonths,
}) {
  if (isExpired(b.expiry, now)) return ('Expired · return to supplier', StatusTone.danger);
  if (b.qty <= 0) return ('Sold out', StatusTone.neutral);
  if (b.id == fefoBatchId) return ('Sell first (FEFO)', StatusTone.accent);
  if (monthsLeft(b.expiry, now) <= expiryWindowMonths) return ('Near expiry', StatusTone.warning);
  return ('OK', StatusTone.neutral);
}

/// First saleable batch by expiry.
int? fefoBatchId(List<StockBatch> batches, DateTime now) {
  final valid = batches.where((b) => b.qty > 0 && !isExpired(b.expiry, now)).toList()
    ..sort((a, b) => a.expiry.compareTo(b.expiry));
  return valid.isEmpty ? null : valid.first.id;
}

/// Expiry text colour level: ≤ 1 month red, ≤ window amber, else normal.
enum ExpiryLevel { ok, near, critical }

ExpiryLevel expiryLevel(String? expiry, DateTime now, int windowMonths) {
  if (expiry == null) return ExpiryLevel.ok;
  final m = monthsLeft(expiry, now);
  if (m <= 1) return ExpiryLevel.critical;
  if (m <= windowMonths) return ExpiryLevel.near;
  return ExpiryLevel.ok;
}

/// Stock bar fill: saleable vs 4 × reorder level (reorder level is in packs).
double stockFraction(StockRow r) => r.saleable / (r.reorderLevel * r.packSize * 4).clamp(1, 1 << 30);

/// "today", "yesterday", "12 days ago", "never".
String lastSoldLabel(int? lastSoldAt, DateTime now) {
  if (lastSoldAt == null) return 'never';
  final d = DateTime.fromMillisecondsSinceEpoch(lastSoldAt).toLocal();
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
  if (days <= 0) return 'today';
  if (days == 1) return 'yesterday';
  return '$days days ago';
}

/// Plain words for a stock movement's reason (Edit batch history).
String movementLabel(String reason) => switch (reason) {
      'sale' => 'Sold',
      'receive' => 'Received',
      'opening' => 'Opening stock',
      'adjust' => 'Corrected',
      'return' => 'Customer return',
      'cancel' => 'Bill cancelled',
      'restore' => 'Restored',
      'supplier_return' => 'Returned to stockist',
      'write_off' => 'Written off',
      'repack' => 'Pack size changed',
      _ => reason,
    };

/// Parses "MM/YYYY", "MM/YY", "MM-YYYY" or "YYYY-MM" into 'YYYY-MM'.
String? parseExpiryInput(String input) {
  final s = input.trim();
  var m = RegExp(r'^(\d{4})-(\d{1,2})$').firstMatch(s);
  if (m != null) return _ym(int.parse(m.group(1)!), int.parse(m.group(2)!));
  m = RegExp(r'^(\d{1,2})\s*[/\-.]\s*(\d{2}|\d{4})$').firstMatch(s);
  if (m == null) return null;
  var y = int.parse(m.group(2)!);
  if (y < 100) y += 2000;
  return _ym(y, int.parse(m.group(1)!));
}

String? _ym(int y, int m) => m < 1 || m > 12 || y < 2000 || y > 2099 ? null : '$y-${m.toString().padLeft(2, '0')}';

/// 'YYYY-MM' → 'MM/YYYY' for editing.
String expiryToInput(String? expiry) =>
    expiry == null || !isValidExpiry(expiry) ? '' : '${expiry.substring(5)}/${expiry.substring(0, 4)}';

String _csv(Object? v) {
  final s = '${v ?? ''}';
  return s.contains(RegExp('[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
}

/// CSV of inventory rows exactly as filtered on screen.
String inventoryCsv(List<StockRow> rows, {required DateTime now, required int deadStockDays}) {
  final b = StringBuffer()
    ..writeln(
      // New columns go at the end so existing spreadsheets keep working.
      ['Medicine', 'Salt', 'Pack', 'Maker', 'Category', 'Schedule', 'Nearest expiry', 'Saleable stock', 'Reorder level', 'MRP', 'GST %', 'HSN', 'Rack', 'Barcode', 'Status', 'Units per pack', 'Saleable (packs + loose)']
          .join(','),
    );
  for (final r in rows) {
    b.writeln(
      [
        r.name,
        r.salt,
        r.pack,
        r.maker,
        r.category,
        r.schedule,
        r.displayExpiry == null ? '' : formatExpiry(r.displayExpiry!),
        r.saleable,
        r.reorderLevel,
        r.mrp.toInputString(),
        r.gstRate,
        r.hsn,
        r.rack,
        r.barcode ?? '',
        stockStatus(r, now: now, deadStockDays: deadStockDays).$1,
        r.packSize,
        formatPackQty(r.saleable, r.packSize, r.category),
      ].map(_csv).join(','),
    );
  }
  return b.toString();
}

/// MRP shown with ₹ (two decimals).
String mrpText(Paise p) => formatInr(p);

/// Confirm text when a medicine with the same name already exists, or null
/// when none does. Same names are allowed (one brand can have several
/// compositions), so this warns rather than blocks.
String? sameNameWarning(String name, String salt, List<SameNameProduct> matches) {
  if (matches.isEmpty) return null;
  final n = name.trim();
  final s = (salt.trim().isEmpty ? n : salt.trim()).toLowerCase();
  String line(SameNameProduct m) =>
      '• ${m.name} — ${[m.salt, m.maker, m.pack].where((x) => x.trim().isNotEmpty).join(' · ')}'
      '${m.isActive ? '' : ' (hidden)'}';
  final list = matches.map(line).join('\n');
  if (matches.any((m) => m.salt.trim().toLowerCase() == s)) {
    return 'This looks like a duplicate of a medicine you already have:\n$list\n\n'
        'Receive stock into the existing one instead, or save anyway to keep both.';
  }
  return '“$n” already exists with a different composition:\n$list\n\n'
      'Save as a separate medicine? Staff will see both in search, told apart by salt and maker.';
}
