import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// Label-above text field (prototype `.lbl` + `.inp`) that stays in sync
/// with an external [value] — e.g. a settings draft that can be discarded.
class AppTextField extends StatefulWidget {
  const AppTextField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
    this.error,
    this.helper,
    this.maxLength,
    this.maxLines = 1,
    this.minLines,
    this.keyboardType,
    this.inputFormatters,
    this.textCapitalization = TextCapitalization.none,
    this.focusNode,
    this.autofocus = false,
    this.onSubmitted,
    this.prefixIcon,
    this.enabled = true,
    this.labelColor,
    this.borderColor,
    this.textInputAction,
    this.height,
    this.fieldKey,
    this.obscure = false,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final String? error;
  final String? helper;
  final int? maxLength;
  final int maxLines;
  final int? minLines;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final TextCapitalization textCapitalization;
  final FocusNode? focusNode;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final IconData? prefixIcon;
  final bool enabled;

  /// Overrides (e.g. red "required" label for the doctor field).
  final Color? labelColor;
  final Color? borderColor;
  final TextInputAction? textInputAction;

  /// Fixed field height (search box 56).
  final double? height;

  /// Key for the inner TextField (tests).
  final Key? fieldKey;

  /// Hides what's typed (PINs).
  final bool obscure;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late final TextEditingController _c = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(AppTextField old) {
    super.didUpdateWidget(old);
    if (widget.value != _c.text) {
      _c.value = TextEditingValue(text: widget.value, selection: TextSelection.collapsed(offset: widget.value.length));
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    OutlineInputBorder? border(Color? c) => c == null
        ? null
        : OutlineInputBorder(borderRadius: AppRadius.controlAll, borderSide: BorderSide(color: c));
    final field = TextField(
      key: widget.fieldKey,
      controller: _c,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      maxLines: widget.maxLines,
      minLines: widget.minLines,
      keyboardType: widget.keyboardType,
      obscureText: widget.obscure,
      inputFormatters: [
        if (widget.maxLength != null) LengthLimitingTextInputFormatter(widget.maxLength),
        ...?widget.inputFormatters,
      ],
      textCapitalization: widget.textCapitalization,
      textInputAction: widget.textInputAction,
      style: AppType.body,
      decoration: InputDecoration(
        hintText: widget.hint,
        errorText: widget.error,
        errorMaxLines: 2,
        helperText: widget.helper,
        prefixIcon: widget.prefixIcon == null ? null : Icon(widget.prefixIcon, size: 18, color: AppColors.textMuted),
        enabledBorder: border(widget.borderColor),
        constraints: widget.height == null ? null : BoxConstraints(minHeight: widget.height!),
        contentPadding: widget.height == null ? null : EdgeInsets.symmetric(horizontal: 12, vertical: (widget.height! - 20) / 2),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label.isNotEmpty) ...[
          Text(widget.label, style: AppType.label.copyWith(color: widget.labelColor)),
          const SizedBox(height: 6),
        ],
        field,
      ],
    );
  }
}

/// Lays fields out in two columns on wide screens, one on narrow; children
/// marked with [FieldSpan.full] take the whole row.
class FieldGrid extends StatelessWidget {
  const FieldGrid({super.key, required this.children, this.minColumnWidth = 260, this.gap = AppSpace.gap14});

  final List<Widget> children;
  final double minColumnWidth;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final two = c.maxWidth >= minColumnWidth * 2 + gap;
        final half = two ? (c.maxWidth - gap) / 2 : c.maxWidth;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final w in children)
              SizedBox(width: w is FieldSpan && w.full ? c.maxWidth : half, child: w),
          ],
        );
      },
    );
  }
}

/// Marks a [FieldGrid] child as full width.
class FieldSpan extends StatelessWidget {
  const FieldSpan({super.key, required this.child, this.full = true});

  final Widget child;
  final bool full;

  @override
  Widget build(BuildContext context) => child;
}
