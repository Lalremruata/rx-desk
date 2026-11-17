/// Manual stock corrections (SPEC §5.3 "Edit batch"). Pure Dart.
///
/// A correction sets a batch to the quantity counted on the shelf and writes
/// an `'adjust'` stock movement whose note says why.
library;

/// Why a batch's quantity was corrected.
enum StockAdjustReason {
  count('Count correction'),
  damaged('Damaged'),
  lost('Lost / theft'),
  other('Other');

  const StockAdjustReason(this.label);

  final String label;

  /// "Other" says nothing on its own, so it needs a note.
  bool get needsNote => this == StockAdjustReason.other;
}

/// The movement note: "Damaged" or "Damaged: 2 strips crushed".
String adjustNote(StockAdjustReason reason, String note) {
  final n = note.trim();
  return n.isEmpty ? reason.label : '${reason.label}: $n';
}
