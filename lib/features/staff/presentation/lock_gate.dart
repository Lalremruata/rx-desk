import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../settings/application/app_settings.dart';
import '../../settings/application/settings_providers.dart';
import '../application/pin_hash.dart';
import '../application/session.dart';
import '../data/staff_repository.dart';

/// Staff accounts (Drift row type → declared by hand).
final staffAccountsProvider = StreamProvider<List<StaffMember>>((ref) => ref.watch(staffRepositoryProvider).watchAll());

/// Shows Owner setup on first run, the PIN lock screen while locked, and
/// auto-locks after `autoLockMinutes` without input (SPEC §5.8).
class LockGate extends ConsumerStatefulWidget {
  const LockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate> {
  Timer? _idle;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _idle?.cancel();
    super.dispose();
  }

  bool _onKey(KeyEvent _) {
    _bump();
    return false;
  }

  void _bump() {
    _idle?.cancel();
    final minutes = ref.read(settingsProvider).autoLockMinutes;
    if (minutes <= 0 || ref.read(sessionProvider) == null) return;
    _idle = Timer(Duration(minutes: minutes), () {
      if (mounted) ref.read(sessionProvider.notifier).lock();
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(sessionProvider);
    ref.listen(sessionProvider, (_, u) => u == null ? _idle?.cancel() : _bump());
    final locked = user == null;
    // The app stays mounted under the lock (nothing in progress is lost) but
    // can't be seen, focused or animated while locked.
    final app = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _bump(),
      onPointerSignal: (_) => _bump(),
      child: Offstage(
        offstage: locked,
        child: TickerMode(enabled: !locked, child: ExcludeFocus(excluding: locked, child: widget.child)),
      ),
    );
    if (!locked) return app;
    // StackFit.expand: an offstage child is 0×0, which would otherwise
    // shrink the Stack and stop taps reaching the lock layer.
    return Stack(
      fit: StackFit.expand,
      children: [
        app,
        // Own Overlay (this sits above the app's Navigator and text fields
        // need one). The entry builds from providers, so it stays current.
        Positioned.fill(child: Overlay(initialEntries: [OverlayEntry(builder: (_) => const _LockLayer())])),
      ],
    );
  }
}

class _LockLayer extends ConsumerWidget {
  const _LockLayer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final staff = ref.watch(staffAccountsProvider);
    return Material(
      color: AppColors.background,
      child: switch (staff) {
        AsyncData(:final value) when value.isEmpty => const OwnerSetupView(),
        AsyncData(:final value) => LockView(staff: value.where((s) => s.active).toList()),
        AsyncError(:final error) => Center(child: Text('Couldn’t load staff: $error')),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _Brand extends ConsumerWidget {
  const _Brand({required this.subtitle});
  final String subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(settingsProvider.select((s) => s.name));
    return Column(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(color: context.palette.accent, borderRadius: const BorderRadius.all(Radius.circular(15))),
          child: const Icon(Icons.medication_outlined, color: AppColors.onAccent, size: 28),
        ),
        const SizedBox(height: AppSpace.md),
        Text(name, style: AppType.pageTitle, textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Text(subtitle, style: AppType.small.copyWith(color: AppColors.textSecondary), textAlign: TextAlign.center),
      ],
    );
  }
}

/// First run: create the Owner (name + 4-digit PIN).
class OwnerSetupView extends ConsumerStatefulWidget {
  const OwnerSetupView({super.key});

  @override
  ConsumerState<OwnerSetupView> createState() => _OwnerSetupViewState();
}

class _OwnerSetupViewState extends ConsumerState<OwnerSetupView> {
  String _name = '', _pin = '', _confirm = '';
  String? _error;
  bool _busy = false;

  Future<void> _create() async {
    if (_name.trim().isEmpty) return setState(() => _error = 'Enter your name');
    if (!isValidPin(_pin)) return setState(() => _error = 'PIN must be 4 digits');
    if (_pin != _confirm) return setState(() => _error = 'PINs don’t match');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await ref.read(staffRepositoryProvider).add(name: _name, role: StaffRole.owner, pin: _pin);
      ref.read(sessionProvider.notifier).signIn(SessionUser(staffId: id, name: _name.trim(), role: StaffRole.owner));
    } on StaffException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: AppCard(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Brand(subtitle: 'Welcome to RxDesk. Create the owner account to start.'),
                const SizedBox(height: AppSpace.xl),
                AppTextField(key: const ValueKey('owner-name'), label: 'Your name', value: _name, autofocus: true, onChanged: (v) => setState(() => _name = v)),
                const SizedBox(height: AppSpace.md),
                AppTextField(
                  key: const ValueKey('owner-pin'),
                  label: '4-digit PIN',
                  value: _pin,
                  maxLength: 4,
                  keyboardType: TextInputType.number,
                  inputFormatters: digits,
                  onChanged: (v) => setState(() => _pin = v),
                ),
                const SizedBox(height: AppSpace.md),
                AppTextField(
                  key: const ValueKey('owner-confirm'),
                  label: 'Confirm PIN',
                  value: _confirm,
                  maxLength: 4,
                  keyboardType: TextInputType.number,
                  inputFormatters: digits,
                  error: _error,
                  onChanged: (v) => setState(() => _confirm = v),
                  onSubmitted: (_) => _create(),
                ),
                const SizedBox(height: AppSpace.lg),
                AppButton(key: const ValueKey('owner-create'), label: _busy ? 'Creating…' : 'Create owner account', height: AppSizes.primaryCta, onPressed: _busy ? null : _create),
                const SizedBox(height: AppSpace.sm),
                Text('The PIN is stored only as a salted hash. Add pharmacists and cashiers later in Settings › Staff & roles.', style: AppType.caption, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Lock screen: pick your tile, enter your PIN (pad or keyboard).
class LockView extends ConsumerStatefulWidget {
  const LockView({super.key, required this.staff});

  final List<StaffMember> staff;

  @override
  ConsumerState<LockView> createState() => _LockViewState();
}

class _LockViewState extends ConsumerState<LockView> {
  StaffMember? _who;
  String _pin = '';
  String? _error;
  bool _checking = false;
  int _fails = 0;
  DateTime? _blockedUntil;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    if (widget.staff.length == 1) _who = widget.staff.first;
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  bool get _blocked => _blockedUntil != null && DateTime.now().isBefore(_blockedUntil!);

  Future<void> _digit(String d) async {
    if (_who == null || _checking || _blocked || _pin.length >= 4) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length == 4) await _check();
  }

  void _back() {
    if (_pin.isNotEmpty) setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _check() async {
    final who = _who!;
    setState(() => _checking = true);
    final m = await ref.read(staffRepositoryProvider).verify(who.id, _pin);
    if (!mounted) return;
    if (m != null) {
      ref.read(sessionProvider.notifier).signIn(SessionUser(staffId: m.id, name: m.name, role: StaffRole.fromLabel(m.role)));
      return;
    }
    _fails++;
    setState(() {
      _checking = false;
      _pin = '';
      if (_fails >= 5) {
        _blockedUntil = DateTime.now().add(const Duration(seconds: 30));
        _fails = 0;
        _error = 'Too many wrong PINs — try again in 30 seconds';
      } else {
        _error = 'Wrong PIN';
      }
    });
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final ch = e.character;
    if (ch != null && RegExp(r'^\d$').hasMatch(ch)) {
      _digit(ch);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.backspace) {
      _back();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              children: [
                const _Brand(subtitle: 'Locked — choose your name and enter your PIN'),
                const SizedBox(height: AppSpace.xl),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
                  children: [
                    for (final s in widget.staff)
                      _StaffTile(
                        member: s,
                        selected: _who?.id == s.id,
                        onTap: () => setState(() {
                          _who = s;
                          _pin = '';
                          _error = null;
                          _focus.requestFocus();
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpace.xl),
                Semantics(
                  label: 'PIN, ${_pin.length} of 4 digits entered',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < 4; i++)
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 8),
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i < _pin.length ? p.accent : AppColors.surface,
                            border: Border.all(color: i < _pin.length ? p.accent : AppColors.kbdBorder, width: 2),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 32,
                  child: Center(
                    child: Text(
                      _error ?? (_who == null ? 'Choose your name' : ''),
                      key: const ValueKey('lock-message'),
                      style: AppType.small.copyWith(color: _error == null ? AppColors.textSecondary : StatusTone.danger.colors.fg),
                    ),
                  ),
                ),
                SizedBox(
                  width: 280,
                  child: GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: AppSpace.sm,
                    crossAxisSpacing: AppSpace.sm,
                    childAspectRatio: 1.6,
                    children: [
                      for (final d in ['1', '2', '3', '4', '5', '6', '7', '8', '9']) _PadKey(label: d, onTap: () => _digit(d)),
                      const SizedBox.shrink(),
                      _PadKey(label: '0', onTap: () => _digit('0')),
                      _PadKey(icon: Icons.backspace_outlined, label: 'Delete', onTap: _back),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StaffTile extends StatelessWidget {
  const _StaffTile({required this.member, required this.selected, required this.onTap});

  final StaffMember member;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final c = AppColors.role[member.role] ?? StatusTone.neutral.colors;
    return Semantics(
      button: true,
      selected: selected,
      label: '${member.name}, ${member.role}',
      excludeSemantics: true,
      child: Pressable(
        child: Material(
          color: selected ? p.accentSoft : AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: AppRadius.cardAll,
            side: BorderSide(color: selected ? p.accent : AppColors.border, width: selected ? 1.5 : 1),
          ),
          child: InkWell(
            key: ValueKey('staff-tile-${member.id}'),
            borderRadius: AppRadius.cardAll,
            onTap: onTap,
            child: SizedBox(
              width: 150,
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: c.bg,
                      child: Text(member.name.isEmpty ? '?' : member.name[0].toUpperCase(), style: AppType.bodyStrong.copyWith(color: c.fg)),
                    ),
                    const SizedBox(height: 6),
                    Text(member.name, style: AppType.smallStrong, overflow: TextOverflow.ellipsis),
                    Text(member.role, style: AppType.caption),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PadKey extends StatelessWidget {
  const _PadKey({required this.label, required this.onTap, this.icon});

  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Pressable(
        child: Material(
          color: AppColors.surface,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.controlAll, side: BorderSide(color: AppColors.border)),
          child: InkWell(
            key: ValueKey('pad-$label'),
            borderRadius: AppRadius.controlAll,
            onTap: onTap,
            child: Center(child: icon != null ? Icon(icon, size: 20) : Text(label, style: AppType.cardTitle.copyWith(fontSize: 20))),
          ),
        ),
      ),
    );
  }
}
