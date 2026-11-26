import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_colors.dart';
import '../auth2_api.dart';
import '../auth2_models.dart';
import '../auth2_service.dart';
import '../auth2_strings.dart';
import 'approval_dialog.dart' show formatApprovalTime;

/// Settings → Trusted devices: primary badge, trusted state, last seen,
/// current device; rename, revoke (confirm), make primary (from the primary
/// only) and «I lost my primary device» (48 h pending claim, cancellable).
class DevicesPage extends ConsumerStatefulWidget {
  const DevicesPage({super.key});

  @override
  ConsumerState<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends ConsumerState<DevicesPage> {
  List<TrustedDevice>? _devices;
  String? _error;
  bool _busy = false;

  Auth2Api get _api => ref.read(auth2ApiProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _api.devices();
      list.sort((a, b) {
        if (a.isPrimary != b.isPrimary) return a.isPrimary ? -1 : 1;
        if (a.current != b.current) return a.current ? -1 : 1;
        final la = a.lastSeen ?? DateTime(2000);
        final lb = b.lastSeen ?? DateTime(2000);
        return lb.compareTo(la);
      });
      if (!mounted) return;
      setState(() {
        _devices = list;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = auth2ErrorTextOf(context, e));
    }
  }

  void _snack(String text, {bool ok = true}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text, style: const TextStyle(fontFamily: 'Cairo')),
      backgroundColor: ok ? AppColors.success : AppColors.danger,
    ));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) _snack(auth2ErrorTextOf(context, e), ok: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String body, {bool danger = false}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(title,
            style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
        content: Text(body, style: const TextStyle(fontFamily: 'Cairo', height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(a2(ctx, 'cancel'), style: const TextStyle(fontFamily: 'Cairo')),
          ),
          FilledButton(
            key: const Key('confirm_ok'),
            style: FilledButton.styleFrom(
                backgroundColor: danger ? AppColors.danger : AppColors.primary),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(a2(ctx, 'confirm'), style: const TextStyle(fontFamily: 'Cairo')),
          ),
        ],
      ),
    );
    return ok == true;
  }

  String _label(TrustedDevice d) {
    if (d.name.isNotEmpty) return d.name;
    return d.model.isNotEmpty ? d.model : d.os;
  }

  Future<void> _rename(TrustedDevice d) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: d.name),
    );
    if (name == null || name.isEmpty || name == d.name) return;
    await _run(() => _api.renameDevice(d.deviceId, name));
  }

  Future<void> _revoke(TrustedDevice d) async {
    final ok = await _confirm(
      a2(context, 'deviceRevokeTitle'),
      a2(context, 'deviceRevokeBody', {'device': _label(d)}),
      danger: true,
    );
    if (!ok) return;
    await _run(() => _api.revokeDevice(d.deviceId));
  }

  Future<void> _makePrimary(TrustedDevice d) async {
    final ok = await _confirm(
      a2(context, 'deviceMakePrimaryTitle'),
      a2(context, 'deviceMakePrimaryBody', {'device': _label(d)}),
    );
    if (!ok) return;
    await _run(() => ref.read(auth2ServiceProvider).makePrimary(d.deviceId));
  }

  Future<void> _claim() async {
    final ok = await _confirm(a2(context, 'lostPrimaryTitle'), a2(context, 'lostPrimaryBody'));
    if (!ok) return;
    await _run(() async {
      await _api.claimPrimary();
    });
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices;
    final me = devices?.where((d) => d.current).firstOrNull;
    final iAmPrimary = me?.isPrimary ?? false;
    final claimer = devices?.where((d) => d.primaryClaimUntil != null && !d.isPrimary).firstOrNull;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(a2(context, 'devicesTitle'),
            style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
        leading: BackButton(onPressed: () => context.canPop() ? context.pop() : null),
      ),
      body: devices == null
          ? Center(
              child: _error != null
                  ? Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error!, style: const TextStyle(fontFamily: 'Cairo')),
                      TextButton(onPressed: _load, child: Text(a2(context, 'retry'))),
                    ])
                  : const CircularProgressIndicator(),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    a2(context, 'devicesSubtitle'),
                    style: TextStyle(
                        fontFamily: 'Cairo', fontSize: 12.5, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  if (claimer != null) _claimBanner(claimer, mine: claimer.current, iAmPrimary: iAmPrimary),
                  if (devices.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(child: Text(a2(context, 'devicesEmpty'))),
                    ),
                  for (final d in devices) _card(d, iAmPrimary: iAmPrimary),
                  if (me != null && !me.isPrimary && claimer == null) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      key: const Key('lost_primary'),
                      onPressed: _busy ? null : _claim,
                      icon: const Icon(Icons.phonelink_erase_rounded),
                      label: Text(a2(context, 'lostPrimary'),
                          style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _claimBanner(TrustedDevice claimer, {required bool mine, required bool iAmPrimary}) {
    final until = claimer.primaryClaimUntil!;
    final text = mine
        ? a2(context, 'claimPending', {'t': formatApprovalTime(until)})
        : a2(context, 'claimOther', {'device': _label(claimer)});
    return Container(
      key: const Key('claim_banner'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withAlpha(24),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.hourglass_top_rounded, color: AppColors.warning, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontFamily: 'Cairo', fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.warning)),
          ),
          if (mine || iAmPrimary)
            TextButton(
              key: const Key('claim_cancel'),
              onPressed: _busy ? null : () => _run(_api.cancelClaimPrimary),
              child: Text(a2(context, 'claimCancel'), style: const TextStyle(fontFamily: 'Cairo')),
            ),
        ],
      ),
    );
  }

  Widget _badge(String text, Color color, {Key? key}) => Container(
        key: key,
        margin: const EdgeInsetsDirectional.only(end: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withAlpha(30),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: TextStyle(
                fontFamily: 'Cairo', fontSize: 10.5, fontWeight: FontWeight.w800, color: color)),
      );

  Widget _card(TrustedDevice d, {required bool iAmPrimary}) {
    final sub = [d.model != d.name ? d.model : '', [d.os, d.osVersion].where((s) => s.isNotEmpty).join(' ')]
        .where((s) => s.isNotEmpty)
        .join(' · ');
    final canMakePrimary = iAmPrimary && !d.isPrimary && d.trusted;
    return Card(
      key: Key('device_${d.deviceId}'),
      color: AppColors.surface,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: d.isPrimary
            ? const BorderSide(color: AppColors.primary, width: 1.2)
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(d.os.toLowerCase().contains('ios') ? Icons.phone_iphone : Icons.phone_android,
                color: d.isPrimary ? AppColors.primary : AppColors.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_label(d),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary)),
                  if (sub.isNotEmpty)
                    Text(sub,
                        style: TextStyle(
                            fontFamily: 'Cairo', fontSize: 12, color: AppColors.textSecondary)),
                  const SizedBox(height: 4),
                  Wrap(
                    runSpacing: 4,
                    children: [
                      if (d.isPrimary)
                        _badge(a2(context, 'devicePrimary'), AppColors.primary,
                            key: Key('badge_primary_${d.deviceId}')),
                      if (d.current)
                        _badge(a2(context, 'deviceCurrent'), AppColors.info,
                            key: Key('badge_current_${d.deviceId}')),
                      _badge(
                        a2(context, d.trusted ? 'deviceTrusted' : 'deviceUntrusted'),
                        d.trusted ? AppColors.success : AppColors.warning,
                      ),
                    ],
                  ),
                  if (d.lastSeen != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        a2(context, 'deviceLastSeen', {'t': formatApprovalTime(d.lastSeen!)}),
                        style: TextStyle(
                            fontFamily: 'Cairo', fontSize: 11, color: AppColors.textTertiary),
                      ),
                    ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              key: Key('device_menu_${d.deviceId}'),
              enabled: !_busy,
              onSelected: (v) {
                switch (v) {
                  case 'rename':
                    _rename(d);
                  case 'revoke':
                    _revoke(d);
                  case 'primary':
                    _makePrimary(d);
                }
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(
                  key: const Key('menu_rename'),
                  value: 'rename',
                  child: Text(a2(ctx, 'deviceRename'), style: const TextStyle(fontFamily: 'Cairo')),
                ),
                if (canMakePrimary)
                  PopupMenuItem(
                    key: const Key('menu_primary'),
                    value: 'primary',
                    child: Text(a2(ctx, 'deviceMakePrimary'),
                        style: const TextStyle(fontFamily: 'Cairo')),
                  ),
                if (!d.current)
                  PopupMenuItem(
                    key: const Key('menu_revoke'),
                    value: 'revoke',
                    child: Text(a2(ctx, 'deviceRevoke'),
                        style: const TextStyle(fontFamily: 'Cairo', color: AppColors.danger)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});
  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(a2(context, 'deviceRename'),
          style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
      content: TextField(
        key: const Key('rename_input'),
        controller: _ctrl,
        autofocus: true,
        maxLength: 40,
        decoration: InputDecoration(hintText: a2(context, 'deviceNameHint')),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(a2(context, 'cancel'), style: const TextStyle(fontFamily: 'Cairo')),
        ),
        FilledButton(
          key: const Key('rename_save'),
          onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
          child: Text(a2(context, 'save'), style: const TextStyle(fontFamily: 'Cairo')),
        ),
      ],
    );
  }
}
