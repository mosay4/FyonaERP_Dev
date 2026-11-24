import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../data/branch_api.dart';
import '../../data/branch_scope.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

class BranchInvitationsPage extends ConsumerStatefulWidget {
  const BranchInvitationsPage({super.key, this.initialInvite});
  final String? initialInvite;

  @override
  ConsumerState<BranchInvitationsPage> createState() =>
      _BranchInvitationsPageState();
}

class _BranchInvitationsPageState extends ConsumerState<BranchInvitationsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs =
      TabController(length: 2, vsync: this, initialIndex: 0);
  late Future<List<Map<String, dynamic>>> _incoming =
      ref.read(branchApiProvider).invitations();
  late Future<List<Map<String, dynamic>>> _sent =
      ref.read(branchApiProvider).sentInvitations();
  bool _initialHandled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _openInitial());
  }

  Future<void> _openInitial() async {
    if (_initialHandled || widget.initialInvite == null) return;
    _initialHandled = true;
    try {
      final rows = await ref.read(branchApiProvider).invitations();
      if (!mounted) return;
      final match = rows.where((e) => '${e['id']}' == widget.initialInvite);
      if (match.isEmpty) return;
      final inv = match.first;
      final l10n = AppLocalizations.of(context);
      final accept = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text('${inv['branch_name'] ?? ''}',
              style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 16,
                  fontWeight: FontWeight.w800)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${inv['organization_name'] ?? ''}',
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)),
            const SizedBox(height: 10),
            Text(l10n.translate('branchInviteAccept') + ' / ' +
                l10n.translate('branchInviteReject'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    color: AppColors.textTertiary)),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.translate('branchInviteReject'),
                    style: const TextStyle(
                        fontFamily: 'Cairo', color: AppColors.danger))),
            FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.success),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l10n.translate('branchInviteAccept'),
                    style: const TextStyle(
                        fontFamily: 'Cairo', fontWeight: FontWeight.w800))),
          ],
        ),
      );
      if (accept == null || !mounted) return;
      await _respond(inv, accept);
    } catch (_) {}
  }

  void _reload() {
    setState(() {
      _incoming = ref.read(branchApiProvider).invitations();
      _sent = ref.read(branchApiProvider).sentInvitations();
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(l10n.translate('branchInvitations'),
            style: const TextStyle(
                fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.w800)),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: AppColors.primary,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textTertiary,
          labelStyle:
              const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700),
          tabs: [
            Tab(text: l10n.translate('branchInviteIncoming')),
            Tab(text: l10n.translate('branchInviteSentList')),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        onPressed: _compose,
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: Text(l10n.translate('branchInviteSend'),
            style: const TextStyle(
                fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _list(_incoming, incoming: true),
          _list(_sent, incoming: false),
        ],
      ),
    );
  }

  Widget _list(Future<List<Map<String, dynamic>>> future,
      {required bool incoming}) {
    final l10n = AppLocalizations.of(context);
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
              child: Text('${snap.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)));
        }
        final rows = snap.data ?? const [];
        if (rows.isEmpty) {
          return ListView(children: [
            const SizedBox(height: 120),
            Icon(Icons.mail_outline_rounded,
                size: 60, color: AppColors.primary.withAlpha(110)),
            const SizedBox(height: 10),
            Text(l10n.translate('branchInviteEmpty'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontFamily: 'Cairo', fontSize: 13, color: Colors.grey)),
          ]);
        }
        return FyonaRefresh(
          onRefresh: () async => _reload(),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
            itemCount: rows.length,
            itemBuilder: (context, i) => TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: Duration(milliseconds: 240 + i * 40),
              curve: Curves.easeOutCubic,
              builder: (context, v, child) => Opacity(
                opacity: v,
                child: Transform.translate(
                    offset: Offset(0, 14 * (1 - v)), child: child),
              ),
              child: _card(rows[i], incoming),
            ),
          ),
        );
      },
    );
  }

  Widget _card(Map<String, dynamic> inv, bool incoming) {
    final l10n = AppLocalizations.of(context);
    final status = '${inv['status'] ?? ''}';
    final pending = status == 'pending';
    final dark = Theme.of(context).brightness == Brightness.dark;
    final statusLabel = status == 'accepted'
        ? l10n.translate('branchLinkAccepted')
        : status == 'rejected'
            ? l10n.translate('branchLinkRejected')
            : status == 'revoked'
                ? l10n.translate('branchLinkRevoked')
                : l10n.translate('branchLinkPending');
    final statusColor = status == 'accepted'
        ? AppColors.success
        : status == 'rejected' || status == 'revoked'
            ? AppColors.danger
            : AppColors.warning;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [const Color(0xFF211316), const Color(0xFF141012)]
              : [Colors.white, const Color(0xFFF7F3F4)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withAlpha(dark ? 40 : 14),
              blurRadius: 14,
              offset: const Offset(0, 6)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: AppColors.gradientPrimary),
                borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.storefront_rounded,
                color: Colors.white, size: 21),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${inv['branch_name'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary)),
              Text('${inv['organization_name'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 10.5,
                      color: AppColors.textSecondary)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: statusColor.withAlpha(20),
                borderRadius: BorderRadius.circular(20)),
            child: Text(statusLabel,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    color: statusColor)),
          ),
        ]),
        if ((inv['invited_user_name'] ?? '').toString().isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('${inv['invited_user_name']}',
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11.5,
                  color: AppColors.textSecondary)),
        ],
        if (pending && incoming) ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.success,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
                onPressed: () => _respond(inv, true),
                child: Text(l10n.translate('branchInviteAccept'),
                    style: const TextStyle(
                        fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    side: const BorderSide(color: AppColors.danger),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
                onPressed: () => _respond(inv, false),
                child: Text(l10n.translate('branchInviteReject'),
                    style: const TextStyle(
                        fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
              ),
            ),
          ]),
        ],
        if (pending && !incoming) ...[
          const SizedBox(height: 10),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              onPressed: () => _revoke(inv),
              icon: const Icon(Icons.link_off_rounded,
                  size: 17, color: AppColors.danger),
              label: Text(l10n.translate('branchMemberRevoke'),
                  style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 11,
                      color: AppColors.danger)),
            ),
          ),
        ],
      ]),
    );
  }

  Future<void> _respond(Map<String, dynamic> inv, bool accept) async {
    final l10n = AppLocalizations.of(context);
    try {
      await ref
          .read(branchApiProvider)
          .respondInvitation('${inv['id']}', accept);
      if (!mounted) return;
      if (accept) {
        await BranchScope.setHasMembership(true);
        final orgId = '${inv['organization_id'] ?? ''}';
        final branchId = '${inv['branch_id'] ?? ''}';
        if (orgId.isNotEmpty && branchId.isNotEmpty) {
          await ref.read(branchApiProvider).select(
              branchId: branchId, organizationId: orgId);
          ref.read(branchEpochProvider.notifier).state++;
          ref.invalidate(branchAccessProvider);
        }
      }
      if (!mounted) return;
      showFyonaSnack(
          context,
          l10n.translate(
              accept ? 'branchInviteAccepted' : 'branchInviteRejected'),
          success: accept);
      if (accept) {
        context.go('/dashboard');
        return;
      }
      _reload();
    } catch (e) {
      if (mounted) showFyonaSnack(context, '$e', success: false);
    }
  }

  Future<void> _revoke(Map<String, dynamic> inv) async {
    final l10n = AppLocalizations.of(context);
    try {
      await ref.read(branchApiProvider).revokeInvitation('${inv['id']}');
      if (!mounted) return;
      showFyonaSnack(context, l10n.translate('branchMemberRevoked'),
          success: true);
      _reload();
    } catch (e) {
      if (mounted) showFyonaSnack(context, '$e', success: false);
    }
  }

  Future<void> _compose() async {
    final l10n = AppLocalizations.of(context);
    try {
      final companies = await ref.read(branchApiProvider).access();
      final branches = <Map<String, dynamic>>[];
      for (final c in companies) {
        if ('${c['role']}' != 'owner') continue;
        for (final b in (c['branches'] as List? ?? const [])) {
          if (b is Map) {
            branches.add({...Map<String, dynamic>.from(b),
              'org_name': c['organization_name']});
          }
        }
      }
      if (!mounted) return;
      String? branchId;
      String? phone;
      String? code;
      bool canTransfer = false;
      final result = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setSheet) => Padding(
            padding: EdgeInsets.fromLTRB(
                16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(l10n.translate('branchInviteSend'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                isExpanded: true,
                decoration: _dec(l10n.translate('branchSelectBranch')),
                items: branches
                    .map((b) => DropdownMenuItem(
                        value: '${b['id']}',
                        child: Text('${b['name']} — ${b['org_name']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontFamily: 'Cairo', fontSize: 12))))
                    .toList(),
                onChanged: (v) => setSheet(() => branchId = v),
              ),
              const SizedBox(height: 10),
              FyonaTextField(
                decoration: _dec(l10n.translate('branchInvitePhone')),
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 12.5),
                onChanged: (v) => phone = v,
              ),
              const SizedBox(height: 10),
              FyonaTextField(
                decoration: _dec(l10n.translate('branchInviteCode')),
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 12.5),
                onChanged: (v) => code = v,
              ),
              SwitchListTile(
                value: canTransfer,
                activeTrackColor: AppColors.primary,
                title: Text(l10n.translate('branchInviteTransferPermission'),
                    style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)),
                onChanged: (v) => setSheet(() => canTransfer = v),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13))),
                  onPressed: () async {
                    if (branchId == null) return;
                    if ((phone ?? '').trim().isNotEmpty &&
                        (code ?? '').trim().isNotEmpty) {
                      showFyonaSnack(ctx,
                          l10n.translate('branchInviteIdentifierHint'),
                          success: false);
                      return;
                    }
                    try {
                      await ref.read(branchApiProvider).invite(
                          branchId: branchId!,
                          phone: phone,
                          code: code,
                          canTransfer: canTransfer);
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    } catch (e) {
                      if (ctx.mounted) showFyonaSnack(ctx, '$e', success: false);
                    }
                  },
                  child: Text(l10n.translate('branchInviteSend'),
                      style: const TextStyle(
                          fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
                ),
              ),
            ]),
          ),
        ),
      );
      if (result == true && mounted) {
        showFyonaSnack(context, l10n.translate('branchInviteSent'),
            success: true);
        _reload();
      }
    } catch (e) {
      if (mounted) showFyonaSnack(context, '$e', success: false);
    }
  }

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 11.5),
        filled: true,
        fillColor: AppColors.background,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: AppColors.border)),
      );
}
