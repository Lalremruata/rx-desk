import 'dart:io';

import 'package:barcode/barcode.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/motion.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/badges.dart';
import '../../settings/application/app_settings.dart';
import '../application/invoice_document.dart';

/// On-screen invoice, fed by the same [InvoiceDoc] as the PDF. Width tweens
/// when the paper size changes (350 ms).
class InvoicePaperView extends StatelessWidget {
  const InvoicePaperView({super.key, required this.doc});

  final InvoiceDoc doc;

  static double maxWidthFor(InvoicePaper p) => switch (p) {
    InvoicePaper.a4 => 820,
    InvoicePaper.a5 => 560,
    InvoicePaper.t80 => 340,
    InvoicePaper.t58 => 250,
  };

  @override
  Widget build(BuildContext context) {
    final thermal = doc.thermal;
    final pad = thermal
        ? 16.0
        : doc.paper == InvoicePaper.a5
        ? 22.0
        : 32.0;
    return Semantics(
      container: true,
      label: '${doc.docTitle} ${doc.number}',
      child: Align(
        alignment: Alignment.topCenter,
        child: AnimatedContainer(
          duration: context.motion(AppMotion.previewResize),
          curve: AppMotion.emphasised,
          constraints: BoxConstraints(maxWidth: maxWidthFor(doc.paper)),
          padding: EdgeInsets.all(pad),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: AppRadius.cardAll,
            border: Border.all(color: AppColors.border),
            boxShadow: const [AppShadows.dropdown],
          ),
          child: DefaultTextStyle.merge(
            style: AppType.small.copyWith(fontSize: thermal ? 11.5 : 13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: thermal ? _thermal(context) : _page(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _brand(BuildContext context, double size) {
    final hasLogo = doc.logoPath.isNotEmpty && File(doc.logoPath).existsSync();
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.27),
      child: Container(
        width: size,
        height: size,
        color: hasLogo ? AppColors.surface : context.palette.accent,
        alignment: Alignment.center,
        child: hasLogo
            ? Image.file(File(doc.logoPath), fit: BoxFit.contain)
            : Text(
                doc.initials,
                style: AppType.bodyStrong.copyWith(
                  color: AppColors.onAccent,
                  fontSize: size * 0.36,
                  fontWeight: FontWeight.w700,
                ),
              ),
      ),
    );
  }

  Widget _cancelled() => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.symmetric(vertical: 4),
    decoration: BoxDecoration(
      border: Border.all(color: StatusTone.danger.colors.fg),
      borderRadius: AppRadius.tinyAll,
    ),
    alignment: Alignment.center,
    child: Text(
      'CANCELLED',
      style: AppType.badge.copyWith(
        color: StatusTone.danger.colors.fg,
        letterSpacing: 2,
        fontSize: 12,
      ),
    ),
  );

  // ---------------------------------------------------------------- A4/A5

  List<Widget> _page(BuildContext context) {
    final accent = context.palette.accent;
    final muted = AppType.caption;
    return [
      if (doc.cancelled) _cancelled(),
      LayoutBuilder(
        builder: (context, box) => Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 16,
          runSpacing: 12,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _brand(context, 44),
                const SizedBox(width: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: (box.maxWidth - 56).clamp(80, 380),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        doc.storeName,
                        style: AppType.cardTitle.copyWith(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(doc.address, style: muted),
                      if (doc.contact.isNotEmpty)
                        Text(doc.contact, style: muted),
                      if (doc.registrations.isNotEmpty)
                        Text(doc.registrations, style: muted),
                    ],
                  ),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  doc.docTitle,
                  style: AppType.badge.copyWith(
                    color: accent,
                    letterSpacing: 0.9,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  doc.number,
                  style: AppType.cardTitle.copyWith(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text('${doc.dateText} · ${doc.timeText}', style: muted),
                if (doc.against != null) Text(doc.against!, key: const ValueKey('invoice-against'), style: muted),
                if (doc.returnStatus != null) ...[
                  const SizedBox(height: 6),
                  StatusBadge.tag(doc.returnStatus!, tone: StatusTone.warning),
                ],
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: const BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _info('BILLED TO', doc.customer, sub: doc.phone)),
            Expanded(
              child: Opacity(
                opacity: doc.doctor == null ? 0 : 1,
                child: _info('PRESCRIBED BY', doc.doctor ?? '—'),
              ),
            ),
            Expanded(child: _info(doc.paymentLabel.toUpperCase(), doc.payment, sub: doc.paymentSub)),
          ],
        ),
      ),
      const SizedBox(height: 20),
      _table(),
      const SizedBox(height: 20),
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 20,
        runSpacing: 16,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (doc.upiId != null) ...[
                  _QrBlock(doc: doc, size: 92),
                  const SizedBox(width: 14),
                ],
                Flexible(
                  child: Text(doc.footer, style: muted.copyWith(height: 1.6)),
                ),
              ],
            ),
          ),
          SizedBox(width: 240, child: _totals(context, large: true)),
        ],
      ),
      const SizedBox(height: 28),
      Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: 220,
          child: Column(
            children: [
              const Divider(color: AppColors.textMuted, height: 1),
              const SizedBox(height: 6),
              Text(
                doc.signatureLabel,
                textAlign: TextAlign.center,
                style: muted,
              ),
              Text(
                doc.forStore,
                textAlign: TextAlign.center,
                style: AppType.smallStrong,
              ),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _info(String head, String value, {String? sub}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        head,
        style: AppType.overline.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      const SizedBox(height: 3),
      Text(value, style: AppType.smallStrong),
      if (sub != null) Text(sub, style: AppType.caption),
    ],
  );

  Widget _table() {
    final c = doc.columns;
    final heads = <(String, double?, bool)>[
      ('#', 22, false),
      ('Item', null, false),
      if (c.batch) ('Batch', 86, false),
      if (c.expiry) ('Exp', 70, false),
      if (c.hsn) ('HSN', 52, false),
      ('Qty', c.wideQty ? 64 : 34, true),
      ('MRP', 76, true),
      if (c.gst) ('GST', 42, true),
      ('Amount', 90, true),
    ];
    Widget cell((String, double?, bool) h, Widget child) {
      final aligned = Align(
        alignment: h.$3 ? Alignment.centerRight : Alignment.centerLeft,
        child: child,
      );
      return h.$2 == null
          ? Expanded(child: aligned)
          : SizedBox(width: h.$2, child: aligned);
    }

    Widget row(List<Widget> cells, {bool head = false}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: head ? AppColors.text : AppColors.divider,
            width: head ? 1.5 : 1,
          ),
        ),
      ),
      child: Row(
        children: [
          for (final (i, w) in cells.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            cell(heads[i], w),
          ],
        ],
      ),
    );

    final minWidth = heads.fold<double>(0, (a, h) => a + (h.$2 ?? 150) + 8) + 8;
    final table = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row([
          for (final h in heads)
            Text(
              h.$1,
              style: AppType.smallStrong.copyWith(color: AppColors.label),
            ),
        ], head: true),
        for (final l in doc.lines)
          row([
            Text('${l.sl}', style: AppType.caption),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.name, style: AppType.smallStrong),
                if (c.salt && l.salt.isNotEmpty)
                  Text(l.salt, style: AppType.caption.copyWith(fontSize: 11)),
              ],
            ),
            if (c.batch)
              Text(
                l.batch,
                style: AppType.caption.copyWith(color: AppColors.text),
              ),
            if (c.expiry) Text(l.expiry),
            if (c.hsn)
              Text(
                l.hsn,
                style: AppType.caption.copyWith(color: AppColors.text),
              ),
            Text(l.qty),
            Text(l.mrp),
            if (c.gst) Text(l.gst),
            Text(l.amount, style: AppType.smallStrong),
          ]),
      ],
    );
    // Scrolls sideways when the paper is narrower than the columns.
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth >= minWidth
          ? table
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(width: minWidth, child: table),
            ),
    );
  }

  Widget _totals(BuildContext context, {required bool large}) {
    Widget r(String a, String b) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              a,
              style: AppType.caption.copyWith(fontSize: large ? 13 : 11.5),
            ),
          ),
          Text(b),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        r('Subtotal (MRP)', doc.subtotal),
        r('Discount', '− ${doc.discount}'),
        if (doc.showTax) ...[
          r('Taxable value', doc.taxable),
          r('CGST', doc.cgst),
          r('SGST', doc.sgst),
        ],
        if (doc.roundOff != null) r('Round off', doc.roundOff!),
        Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.only(top: 8),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.text, width: 1.5)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  'Grand total',
                  style: AppType.bodyStrong.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                doc.total,
                key: const ValueKey('invoice-total'),
                style: AppType.total.copyWith(fontSize: large ? 22 : 18),
              ),
            ],
          ),
        ),
        if (doc.saved != null)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: context.palette.accentSoft,
              borderRadius: AppRadius.pillAll,
            ),
            alignment: Alignment.center,
            child: Text(
              'You saved ${doc.saved} on MRP',
              style: AppType.label.copyWith(color: context.palette.accent),
            ),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- thermal

  List<Widget> _thermal(BuildContext context) {
    final muted = AppType.caption.copyWith(fontSize: 10.5);
    Widget dash() => const Padding(
      padding: EdgeInsets.symmetric(vertical: 6),
      child: Divider(height: 1, color: AppColors.kbdBorder),
    );
    final c = doc.columns;
    return [
      if (doc.cancelled) _cancelled(),
      Center(child: _brand(context, 30)),
      const SizedBox(height: 6),
      Text(
        doc.storeName,
        textAlign: TextAlign.center,
        style: AppType.bodyStrong.copyWith(fontWeight: FontWeight.w700),
      ),
      Text(doc.address, textAlign: TextAlign.center, style: muted),
      if (doc.contact.isNotEmpty)
        Text(doc.contact, textAlign: TextAlign.center, style: muted),
      if (doc.registrations.isNotEmpty)
        Text(doc.registrations, textAlign: TextAlign.center, style: muted),
      const SizedBox(height: 6),
      Text(
        doc.docTitle,
        textAlign: TextAlign.center,
        style: AppType.badge.copyWith(letterSpacing: 1),
      ),
      dash(),
      Text(
        '${doc.number}  ·  ${doc.dateText} ${doc.timeText}',
        style: AppType.smallStrong.copyWith(fontSize: 11.5),
      ),
      if (doc.against != null) Text(doc.against!, style: muted),
      Text('To: ${doc.customer}'),
      if (doc.doctor != null) Text('Dr: ${doc.doctor}'),
      Text('${doc.paymentLabel}: ${doc.payment}'),
      if (doc.paymentSub != null) Text(doc.paymentSub!, style: muted),
      dash(),
      for (final l in doc.lines) ...[
        Text(
          '${l.sl}. ${l.name}',
          style: AppType.smallStrong.copyWith(fontSize: 11.5),
        ),
        if (c.salt && l.salt.isNotEmpty) Text(l.salt, style: muted),
        Row(
          children: [
            Expanded(
              child: Text(
                c.expiry ? 'Exp ${l.expiry}' : '',
                style: muted,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Flexible(
              flex: 2,
              child: Text(
                '${l.qty} × ${l.mrp}  ',
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(l.amount, style: AppType.smallStrong.copyWith(fontSize: 11.5)),
          ],
        ),
        const SizedBox(height: 4),
      ],
      dash(),
      _totals(context, large: false),
      if (doc.upiId != null) ...[
        const SizedBox(height: 10),
        Center(
          child: _QrBlock(
            doc: doc,
            size: doc.paper == InvoicePaper.t58 ? 84 : 104,
          ),
        ),
      ],
      const SizedBox(height: 8),
      Text(doc.footer, textAlign: TextAlign.center, style: muted),
      const SizedBox(height: 18),
      Text(doc.signatureLabel, textAlign: TextAlign.center, style: muted),
      Text(
        doc.forStore,
        textAlign: TextAlign.center,
        style: AppType.smallStrong.copyWith(fontSize: 11.5),
      ),
    ];
  }
}

class _QrBlock extends StatelessWidget {
  const _QrBlock({required this.doc, required this.size});

  final InvoiceDoc doc;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      child: Column(
        children: [
          if (doc.upiUri != null)
            Semantics(
              label: 'UPI payment QR for ${doc.total}',
              child: CustomPaint(
                size: Size.square(size),
                painter: QrPainter(doc.upiUri!),
              ),
            )
          else
            Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt,
                border: Border.all(color: AppColors.kbdBorder, width: 1.5),
                borderRadius: AppRadius.smallAll,
              ),
              child: Text(
                'UPI QR',
                style: AppType.badge.copyWith(color: AppColors.label),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            doc.upiId!,
            textAlign: TextAlign.center,
            style: AppType.caption.copyWith(fontSize: 10),
          ),
        ],
      ),
    );
  }
}

/// Paints a real QR code (barcode package).
class QrPainter extends CustomPainter {
  QrPainter(this.data);

  final String data;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = AppColors.text;
    for (final e in Barcode.qrCode().make(
      data,
      width: size.width,
      height: size.height,
    )) {
      if (e is BarcodeBar && e.black) {
        canvas.drawRect(Rect.fromLTWH(e.left, e.top, e.width, e.height), paint);
      }
    }
  }

  @override
  bool shouldRepaint(QrPainter old) => old.data != data;
}
