import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../data/branch_api.dart';
import '../../data/branch_scope.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

class BranchMembersPage extends ConsumerStatefulWidget {
  const BranchMembersPage({super.key});

  @override
  ConsumerState<BranchMembersPage> createState() => _BranchMembersPageState();
}

class _BranchMembersPageState extends ConsumerState<BranchMembersPage> {
  final _busyMembers = <String>{};

  late Future<List<Map<String, dynamic>>> _future = _readMembers();

  Future<List<Map<String, dynamic>>> _readMembers() {
    final reading = ref.read(branchApiProvider).members();
    // A refresh may supersede a read before the next frame's
    // FutureBuilder subscribes. Observe every request; the original future still
    // carries its error to the visible FutureBuilder (not an empty fake roster).
    reading.ignore();
    return reading;
  }

  void _reload() {
    setState(() {
      _future = _readMembers();
    });
  }

  @override
  Widget build(BuildContext context) {

    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(l10n.translate('branchMembers'),
            style: const TextStyle(
                fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.w800)),
        actions: [

          IconButton(
            tooltip: l10n.translate('branchInvitations'),
            onPressed: () => context.push('/branches/invitations'),
            icon: const Icon(Icons.mail_outline_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        onPressed: () => context.push('/branches/invitations'),
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: Text(l10n.translate('branchInviteSend'),
            style: const TextStyle(
                fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
      ),
      body: Column(children: [

        Expanded(child: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
                child: Text('${snap.error}',
                    style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)));
          }
          final rows = snap.data ?? const [];
          if (rows.isEmpty) {
            return ListView(children: [
              const SizedBox(height: 120),
              Icon(Icons.group_outlined,
                  size: 60, color: AppColors.primary.withAlpha(110)),
              const SizedBox(height: 10),
              Text(l10n.translate('branchMemberNone'),
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
                duration: Duration(milliseconds: 240 + (i % 6) * 40),
                curve: Curves.easeOutCubic,
                builder: (context, v, child) => Opacity(
                  opacity: v,
                  child: Transform.translate(
                      offset: Offset(0, 14 * (1 - v)), child: child),
                ),
                child: _card(rows[i]),
              ),
            ),
          );
        },
      ),
        ),
      ]),
    );
  }

  Widget _card(Map<String, dynamic> m) {
    final l10n = AppLocalizations.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final active = '${m['status']}' == 'active';
    final displayName = '${m['name'] ?? ''}'.trim();

    final editing = _busyMembers.contains('${m['id']}') || BranchScope.readOnly;
    final branchNames =
        (m['branch_names'] as List? ?? const []).map((e) => '$e').join(' · ');
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
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                gradient: const LinearGradient(colors: AppColors.gradientPrimary),
                borderRadius: BorderRadius.circular(13)),
            child: Text(
                displayName.isEmpty ? '?' : displayName[0],
                style: const TextStyle(
                    fontFamily: 'Cairo',
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${m['name'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: active ? AppColors.textPrimary : Colors.grey)),
              Text(
                  '${m['phone'] ?? ''}${(m['phone'] ?? '').toString().isEmpty ? '' : ' · '}${m['code'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 10.5,
                      color: AppColors.textSecondary)),
            ]),
          ),
          if (!active)
            Text(l10n.translate('branchLinkRevoked'),
                style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 10,
                    color: AppColors.danger)),
        ]),
        if (branchNames.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(branchNames,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 10.5,
                  color: AppColors.textTertiary)),
        ],
        if (active)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: ValueKey('branch_member_branches_${m['id']}'),
              onPressed: editing ? null : () => _editBranches(m),
              icon: const Icon(Icons.account_tree_outlined,
                  size: 16, color: AppColors.primary),
              label: Text(l10n.translate('branchMemberBranches'),
                  style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 11,
                      color: AppColors.primary)),
            ),
          ),
        if (active) ...[
          SwitchListTile(
            key: ValueKey('branch_member_transfer_${m['id']}'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: m['can_transfer'] == true,
            activeTrackColor: AppColors.primary,
            title: Text(l10n.translate('branchMemberTransfer'),
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)),
            onChanged: editing ? null : (v) => _update(m, canTransfer: v),
          ),
          SwitchListTile(
            key: ValueKey('branch_member_all_${m['id']}'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: m['all_branches'] == true,
            activeTrackColor: AppColors.primary,
            title: Text(l10n.translate('branchMemberAllBranches'),
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)),
            onChanged: editing ? null : (v) => _update(m, allBranches: v),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              key: ValueKey('branch_member_revoke_${m['id']}'),
              onPressed: editing ? null : () => _revoke(m),
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
        if (!active) TextButton.icon(key: ValueKey('branch_member_restore_${m['id']}'),
          onPressed: editing ? null : () => _update(m, status: 'active'),
          icon: const Icon(Icons.link), label: const Text('طلب إعادة تفعيل العضوية')),
      ]),
    );
  }

  Future<void> _editBranches(Map<String, dynamic> m) async {
    final l10n = AppLocalizations.of(context);
    try {

      final branches = await ref.read(branchApiProvider).list();
      final selected = (m['branch_ids'] as List? ?? const [])
          .map((e) => '$e')
          .toSet();
      if (!mounted) return;
      final result = await showDialog<Set<String>>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: Text(l10n.translate('branchMemberBranches'),
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 15)),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final b in branches)
                    CheckboxListTile(
                      key: ValueKey('branch_member_select_${b['id']}'),
                      value: selected.contains('${b['id']}'),
                      activeColor: AppColors.primary,
                      title: Text('${b['name'] ?? ''}',
                          style: const TextStyle(
                              fontFamily: 'Cairo', fontSize: 12)),
                      onChanged: (v) {
                        setLocal(() {
                          if (v == true) {
                            selected.add('${b['id']}');
                          } else {
                            selected.remove('${b['id']}');
                          }
                        });
                      },
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  key: const ValueKey('branch_member_edit_cancel'),
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(l10n.translate('branchCancel'),
                      style: const TextStyle(fontFamily: 'Cairo'))),
              FilledButton(
                  key: const ValueKey('branch_member_edit_save'),
                  style:
                      FilledButton.styleFrom(backgroundColor: AppColors.primary),
                  onPressed: () => Navigator.pop(ctx, selected),
                  child: Text(l10n.translate('branchSave'),
                      style: const TextStyle(
                          fontFamily: 'Cairo', fontWeight: FontWeight.w800))),
            ],
          ),
        ),
      );
      if (result == null || !mounted) return;
      await _update(m, branchIds: result.toList(), allBranches: false);
    } catch (e) {
      if (mounted) showFyonaSnack(context, '$e', success: false);
    }
  }

  Future<void> _update(Map<String, dynamic> m,
      {bool? canTransfer, bool? allBranches, List<String>? branchIds, String? status}) async {
    final id = '${m['id']}';
    if (_busyMembers.contains(id) || BranchScope.readOnly) return;

    setState(() => _busyMembers.add(id));
    try {
      final api = ref.read(branchApiProvider);

      await api.updateMember(id, canTransfer: canTransfer, allBranches: allBranches,
          branchIds: branchIds, status: status);
      if (!mounted) return;

      showFyonaSnack(
          context, AppLocalizations.of(context).translate('branchSaved'),
          success: true);
      _reload();
    } catch (e) {
      if (mounted) showFyonaSnack(context, '$e', success: false);
    } finally {
      if (mounted) setState(() => _busyMembers.remove(id));
    }
  }

  Future<void> _revoke(Map<String, dynamic> m) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(l10n.translate('branchMemberRevoke'),
            style: const TextStyle(fontFamily: 'Cairo', fontSize: 15)),
        content: Text(l10n.translate('branchArchiveBody'),
            style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)),
        actions: [
          TextButton(
              key: const ValueKey('branch_member_revoke_cancel'),
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.translate('branchCancel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              key: const ValueKey('branch_member_revoke_confirm'),
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.translate('branchMemberRevoke'),
                  style: const TextStyle(
                      fontFamily: 'Cairo', fontWeight: FontWeight.w800))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _update(m, status: 'revoked');
  }
}
