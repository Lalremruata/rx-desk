import 'package:drift/drift.dart';

import '../../money/paise.dart';
import '../../utils/expiry.dart';
import '../app_database.dart';
import '../report_models.dart';

part 'reports_dao.g.dart';

/// One day's net sales from the daily summary.
class DaySales {
  const DaySales(this.day, this.net);
  final String day;
  final Paise net;
}

/// One medicine's month in the consumption register (SPEC §4.12).
class ConsumptionRow {
  const ConsumptionRow({
    required this.productId,
    required this.name,
    required this.category,
    required this.unitsPerPack,
    required this.reorderLevel,
    required this.saleable,
    required this.daily,
  });

  final int productId;
  final String name;
  final String category;
  final int unitsPerPack;

  /// Current setting, in packs.
  final int reorderLevel;

  /// Saleable stock now, in units.
  final int saleable;

  /// Units sold (net of returns) by day of month (1-based).
  final Map<int, int> daily;

  List<int> days(int n) => [for (var d = 1; d <= n; d++) daily[d] ?? 0];
}

class ConsumptionPage {
  const ConsumptionPage({required this.rows, required this.total, required this.ms});
  final List<ConsumptionRow> rows;
  final int total;
  final double ms;
}

class CategorySales {
  const CategorySales(this.category, this.net);
  final String category;
  final Paise net;
}

/// Sales register (SPEC §5.5) and dashboard aggregates (SPEC §5.1). Every
/// document except cancelled bills: credit-note lines are negative and dated
/// on the return day, so they net sales down there (SPEC §4.5). Reads
/// invoice-item snapshots, never live products.
@DriftAccessor(tables: [Invoices, InvoiceItems, DailySalesSummary, Products])
class ReportsDao extends DatabaseAccessor<AppDatabase> with _$ReportsDaoMixin {
  ReportsDao(super.attachedDatabase);

  static const String _from = 'FROM invoice_items i JOIN invoices v ON v.id = i.invoice_id';

  Set<ResultSetImplementation<dynamic, dynamic>> get _reads => {invoices, invoiceItems};

  ({String sql, List<Variable<Object>> vars}) _where(RegisterFilter f) {
    final vars = <Variable<Object>>[Variable.withString(f.from), Variable.withString(f.to)];
    final w = StringBuffer("i.sale_date >= ?1 AND i.sale_date <= ?2 AND v.status <> 'cancelled'");
    String p(Object v) {
      vars.add(v is int ? Variable.withInt(v) : Variable.withString('$v'));
      return '?${vars.length}';
    }

    for (final t in f.search.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty)) {
      final x = p('%$t%');
      w.write(
        ' AND (lower(i.product_name) LIKE $x OR lower(i.salt) LIKE $x OR lower(i.batch_no) LIKE $x'
        ' OR lower(v.number) LIKE $x OR lower(v.customer_name) LIKE $x)',
      );
    }
    if (f.maker != null) w.write(' AND i.manufacturer = ${p(f.maker!)}');
    if (f.category != null) w.write(' AND i.category = ${p(f.category!)}');
    switch (f.schedule) {
      case ScheduleFilter.all:
        break;
      case ScheduleFilter.rx:
        w.write(" AND i.schedule IN ('H', 'H1')");
      case ScheduleFilter.h:
        w.write(" AND i.schedule = 'H'");
      case ScheduleFilter.h1:
        w.write(" AND i.schedule = 'H1'");
      case ScheduleFilter.none:
        w.write(" AND i.schedule = ''");
    }
    if (f.payment != null) w.write(' AND i.payment_mode = ${p(f.payment!)}');
    if (f.doctor != null) {
      w.write(f.doctor == noDoctor ? ' AND i.doctor_name IS NULL' : ' AND i.doctor_name = ${p(f.doctor!)}');
    }
    return (sql: w.toString(), vars: vars);
  }

  static const String noDoctor = '(No prescription)';

  /// Totals for the whole filtered set — one aggregate query.
  Future<RegisterTotals> registerTotals(RegisterFilter f) async {
    final w = _where(f);
    final r = await customSelect(
      '''
      SELECT COUNT(*) AS lines, COUNT(DISTINCT CASE WHEN v.doc_type = 'invoice' THEN i.invoice_id END) AS bills,
        COALESCE(SUM(i.qty), 0) AS units, COALESCE(SUM(i.gross_paise), 0) AS gross,
        COALESCE(SUM(i.discount_paise), 0) AS disc, COALESCE(SUM(i.taxable_paise), 0) AS taxable,
        COALESCE(SUM(i.tax_paise), 0) AS tax, COALESCE(SUM(i.net_paise), 0) AS net
      $_from WHERE ${w.sql}
      ''',
      variables: w.vars,
      readsFrom: _reads,
    ).getSingle();
    return RegisterTotals(
      lines: r.read<int>('lines'),
      bills: r.read<int>('bills'),
      units: r.read<int>('units'),
      gross: Paise(r.read<int>('gross')),
      discount: Paise(r.read<int>('disc')),
      taxable: Paise(r.read<int>('taxable')),
      tax: Paise(r.read<int>('tax')),
      net: Paise(r.read<int>('net')),
    );
  }

  String _lineSortExpr(RegisterSort s) => switch (s) {
        RegisterSort.qty => 'i.qty',
        RegisterSort.net => 'i.net_paise',
        _ => 'i.sale_date',
      };

  /// One page of item lines, keyset on (sort value, line id).
  Future<RegisterLinesPage> registerLines(RegisterFilter f, {RegisterCursor? after, int limit = 50}) async {
    final sw = Stopwatch()..start();
    final w = _where(f);
    final vars = [...w.vars];
    final expr = _lineSortExpr(f.sort);
    final dir = f.descending ? 'DESC' : 'ASC';
    final cmp = f.descending ? '<' : '>';
    var where = w.sql;
    if (after != null) {
      vars
        ..add(after.value is int ? Variable.withInt(after.value as int) : Variable.withString('${after.value}'))
        ..add(Variable.withInt(after.id));
      where += ' AND ($expr, i.id) $cmp (?${vars.length - 1}, ?${vars.length})';
    }
    vars.add(Variable.withInt(limit + 1));
    final rows = await customSelect(
      '''
      SELECT i.id, i.invoice_id, i.sale_date, v.created_at, v.number, v.customer_name, i.doctor_name,
        i.product_name, i.salt, i.manufacturer, i.schedule, i.hsn, i.batch_no, i.qty, i.pack_size, i.category, i.mrp_paise,
        i.discount_paise, i.taxable_paise, i.gst_rate, i.net_paise, i.payment_mode, $expr AS sort_value
      $_from WHERE $where
      ORDER BY $expr $dir, i.id $dir
      LIMIT ?${vars.length}
      ''',
      variables: vars,
      readsFrom: _reads,
    ).get();
    final more = rows.length > limit;
    return RegisterLinesPage(
      rows: [
        for (final r in more ? rows.sublist(0, limit) : rows)
          RegisterLine(
            id: r.read<int>('id'),
            invoiceId: r.read<int>('invoice_id'),
            saleDate: r.read<String>('sale_date'),
            createdAt: r.read<int>('created_at'),
            billNo: r.read<String>('number'),
            customer: r.read<String>('customer_name'),
            doctor: r.readNullable<String>('doctor_name'),
            medicine: r.read<String>('product_name'),
            salt: r.read<String>('salt'),
            maker: r.read<String>('manufacturer'),
            schedule: r.read<String>('schedule'),
            hsn: r.read<String>('hsn'),
            batchNo: r.read<String>('batch_no'),
            qty: r.read<int>('qty'),
            packSize: r.read<int>('pack_size'),
            category: r.read<String>('category'),
            mrp: Paise(r.read<int>('mrp_paise')),
            discount: Paise(r.read<int>('discount_paise')),
            taxable: Paise(r.read<int>('taxable_paise')),
            gstRate: r.read<int>('gst_rate'),
            net: Paise(r.read<int>('net_paise')),
            payment: r.read<String>('payment_mode'),
            sortValue: r.data['sort_value'] as Object,
          ),
      ],
      hasMore: more,
      ms: sw.elapsedMicroseconds / 1000,
    );
  }

  (String key, String label) _groupExprs(RegisterGroup g) => switch (g) {
        RegisterGroup.day => ('i.sale_date', 'i.sale_date'),
        RegisterGroup.medicine => ('CAST(i.product_id AS TEXT)', 'MAX(i.product_name)'),
        RegisterGroup.maker => ('i.manufacturer', 'i.manufacturer'),
        RegisterGroup.category => ('i.category', 'i.category'),
        RegisterGroup.hsn => ("i.hsn || ' @ ' || i.gst_rate || '%'", "i.hsn || ' @ ' || i.gst_rate || '%'"),
        RegisterGroup.gst => ("i.gst_rate || '%'", "i.gst_rate || '%'"),
        RegisterGroup.payment => ('i.payment_mode', 'i.payment_mode'),
        RegisterGroup.doctor => ("COALESCE(i.doctor_name, '$noDoctor')", "COALESCE(i.doctor_name, '$noDoctor')"),
        RegisterGroup.none => throw ArgumentError('no grouping'),
      };

  /// Grouped rows (small enough for LIMIT/OFFSET). [limit] null = all.
  Future<RegisterGroupsPage> registerGroups(RegisterFilter f, {int offset = 0, int? limit = 50}) async {
    final sw = Stopwatch()..start();
    final w = _where(f);
    final (key, label) = _groupExprs(f.group);
    final dir = f.descending ? 'DESC' : 'ASC';
    final order = switch (f.sort) {
      RegisterSort.units => 'units $dir, label',
      RegisterSort.key => f.group == RegisterGroup.day ? 'gkey $dir' : 'lower(label) $dir',
      _ => 'net $dir, label',
    };
    final grouped = '''
      SELECT $key AS gkey, $label AS label, COUNT(DISTINCT CASE WHEN v.doc_type = 'invoice' THEN i.invoice_id END) AS bills, SUM(i.qty) AS units,
        SUM(i.gross_paise) AS gross, SUM(i.taxable_paise) AS taxable, SUM(i.tax_paise) AS tax, SUM(i.net_paise) AS net
      $_from WHERE ${w.sql} GROUP BY gkey
    ''';
    final total = (await customSelect('SELECT COUNT(*) AS c FROM ($grouped)', variables: w.vars, readsFrom: _reads).getSingle())
        .read<int>('c');
    final vars = [...w.vars, Variable.withInt(limit ?? -1), Variable.withInt(offset)];
    final rows = await customSelect(
      'SELECT * FROM ($grouped) ORDER BY $order LIMIT ?${vars.length - 1} OFFSET ?${vars.length}',
      variables: vars,
      readsFrom: _reads,
    ).get();
    return RegisterGroupsPage(
      rows: [
        for (final r in rows)
          RegisterGroupRow(
            key: r.read<String>('gkey'),
            label: f.group == RegisterGroup.day ? dayLabel(r.read<String>('gkey')) : r.read<String>('label'),
            bills: r.read<int>('bills'),
            units: r.read<int>('units'),
            gross: Paise(r.read<int>('gross')),
            taxable: Paise(r.read<int>('taxable')),
            tax: Paise(r.read<int>('tax')),
            net: Paise(r.read<int>('net')),
          ),
      ],
      total: total,
      ms: sw.elapsedMicroseconds / 1000,
    );
  }

  /// Doctors seen on bills (filter options).
  Future<List<String>> doctors() async {
    final rows = await customSelect(
      'SELECT DISTINCT doctor_name FROM invoices WHERE doctor_name IS NOT NULL ORDER BY doctor_name',
      readsFrom: {invoices},
    ).get();
    return rows.map((r) => r.read<String>('doctor_name')).toList();
  }

  /// Makers seen on sold lines (snapshot names).
  Future<List<String>> soldMakers() async {
    final rows = await customSelect('SELECT DISTINCT manufacturer FROM invoice_items ORDER BY manufacturer', readsFrom: {invoiceItems}).get();
    return rows.map((r) => r.read<String>('manufacturer')).toList();
  }

  // -------------------------------------------------------------------------
  // Dashboard (SPEC §5.1) — summary table + small indexed lookups only.

  /// Net sales per day for [from]..[to] from `daily_sales_summary`.
  Future<List<DaySales>> dailyNet(String from, String to) async {
    final rows = await customSelect(
      'SELECT sale_date, SUM(net_paise) AS net FROM daily_sales_summary WHERE sale_date >= ?1 AND sale_date <= ?2 GROUP BY sale_date ORDER BY sale_date',
      variables: [Variable.withString(from), Variable.withString(to)],
      readsFrom: {dailySalesSummary},
    ).get();
    return [for (final r in rows) DaySales(r.read<String>('sale_date'), Paise(r.read<int>('net')))];
  }

  /// This range's net by product category (summary joined to products).
  Future<List<CategorySales>> categoryNet(String from, String to) async {
    final rows = await customSelect(
      '''
      SELECT p.category, SUM(s.net_paise) AS net
      FROM daily_sales_summary s JOIN products p ON p.id = s.product_id
      WHERE s.sale_date >= ?1 AND s.sale_date <= ?2
      GROUP BY p.category ORDER BY net DESC
      ''',
      variables: [Variable.withString(from), Variable.withString(to)],
      readsFrom: {dailySalesSummary, products},
    ).get();
    return [for (final r in rows) CategorySales(r.read<String>('category'), Paise(r.read<int>('net')))];
  }

  /// Bills (tax invoices, not cancelled) and the net total for one day —
  /// refunds on credit notes issued that day are subtracted.
  Future<({int bills, Paise total})> dayTotals(String day) async {
    final r = await customSelect(
      '''
      SELECT COALESCE(SUM(CASE WHEN doc_type = 'invoice' THEN 1 ELSE 0 END), 0) AS c,
             COALESCE(SUM(total_paise), 0) AS t
      FROM invoices WHERE sale_date = ?1 AND status <> 'cancelled'
      ''',
      variables: [Variable.withString(day)],
      readsFrom: {invoices},
    ).getSingle();
    return (bills: r.read<int>('c'), total: Paise(r.read<int>('t')));
  }

  // -------------------------------------------------------------------------
  // Monthly consumption register (SPEC §4.12): daily_sales_summary by day for
  // one month. Units are net of returns (credit notes count on their day).

  /// ?1 first day, ?2 last day, ?3 current month (expiry cut-off),
  /// ?4 search ('' = none), ?5 LIKE pattern.
  static String _consumptionWhere(bool includeAll) {
    const sold = 'SELECT product_id FROM daily_sales_summary WHERE sale_date >= ?1 AND sale_date <= ?2 AND units <> 0';
    return '${includeAll ? '(p.is_active = 1 OR p.id IN ($sold))' : 'p.id IN ($sold)'}'
        " AND (?4 = '' OR lower(p.name) LIKE ?5) AND ?3 IS NOT NULL";
  }

  /// One page of medicines (by name) with their month. [month] is 'YYYY-MM'.
  /// Default: medicines with sales that month; [includeAll] adds every
  /// active medicine (zero rows).
  Future<ConsumptionPage> consumptionPage(
    String month, {
    required DateTime now,
    String search = '',
    bool includeAll = false,
    int page = 1,
    int pageSize = 50,
  }) async {
    final sw = Stopwatch()..start();
    final q = search.trim().toLowerCase();
    final base = [
      Variable.withString('$month-01'),
      Variable.withString('$month-31'),
      Variable.withString(monthKey(now)),
      Variable.withString(q),
      Variable.withString('%$q%'),
    ];
    final where = _consumptionWhere(includeAll);
    final total = (await customSelect('SELECT COUNT(*) AS c FROM products p WHERE $where', variables: base, readsFrom: {products, dailySalesSummary})
            .getSingle())
        .read<int>('c');
    final size = pageSize.clamp(1, 5000);
    final pages = total == 0 ? 1 : (total + size - 1) ~/ size;
    final p = page.clamp(1, pages);
    final rows = await _consumptionRows(month, base, where, limit: size, offset: (p - 1) * size);
    return ConsumptionPage(rows: rows, total: total, ms: sw.elapsedMicroseconds / 1000);
  }

  /// Every row of the month, for the Excel export.
  Future<List<ConsumptionRow>> consumptionAll(String month, {required DateTime now, bool includeAll = false}) {
    final base = [
      Variable.withString('$month-01'),
      Variable.withString('$month-31'),
      Variable.withString(monthKey(now)),
      Variable.withString(''),
      Variable.withString('%%'),
    ];
    return _consumptionRows(month, base, _consumptionWhere(includeAll), limit: -1, offset: 0);
  }

  Future<List<ConsumptionRow>> _consumptionRows(String month, List<Variable<Object>> base, String where, {required int limit, required int offset}) async {
    final prods = await customSelect(
      '''
      SELECT p.id, p.name, p.category, p.units_per_pack, p.reorder_level,
             (SELECT COALESCE(SUM(b.qty), 0) FROM batches b WHERE b.product_id = p.id AND b.expiry >= ?3) AS saleable
      FROM products p WHERE $where
      ORDER BY p.name COLLATE NOCASE, p.id LIMIT ?6 OFFSET ?7
      ''',
      variables: [...base, Variable.withInt(limit), Variable.withInt(offset)],
      readsFrom: {products, dailySalesSummary},
    ).get();
    if (prods.isEmpty) return const [];
    final ids = [for (final r in prods) r.read<int>('id')];
    final daily = <int, Map<int, int>>{};
    final days = await customSelect(
      '''
      SELECT product_id, CAST(substr(sale_date, 9, 2) AS INTEGER) AS d, units FROM daily_sales_summary
      WHERE sale_date >= ?1 AND sale_date <= ?2 AND units <> 0 AND product_id IN (${List.filled(ids.length, '?').join(',')})
      ''',
      variables: [base[0], base[1], for (final id in ids) Variable.withInt(id)],
      readsFrom: {dailySalesSummary},
    ).get();
    for (final r in days) {
      (daily[r.read<int>('product_id')] ??= {})[r.read<int>('d')] = r.read<int>('units');
    }
    return [
      for (final r in prods)
        ConsumptionRow(
          productId: r.read<int>('id'),
          name: r.read<String>('name'),
          category: r.read<String>('category'),
          unitsPerPack: r.read<int>('units_per_pack'),
          reorderLevel: r.read<int>('reorder_level'),
          saleable: r.read<int>('saleable'),
          daily: daily[r.read<int>('id')] ?? const {},
        ),
    ];
  }
}
