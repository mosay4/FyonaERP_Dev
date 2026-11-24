import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/utils/server_image_url.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../auth/presentation/widgets/app_pin_sheet.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../data/branch_api.dart';
import '../../data/branch_scope.dart';
import '../../../../shared/widgets/fyona_text_field.dart';
import '../../data/branch_epoch.dart';
import '../../../core_business/data/local_directory/directory_database.dart' show BusinessBranchReset;
import '../../../core_business/data/local_directory/directory_pilot.dart'
    show businessLocalLedgerScopeProvider, directoryPilotStoreProvider;

class BranchesPage extends ConsumerWidget {
  const BranchesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final async = ref.watch(branchesProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          l10n.translate('branchManagement'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      floatingActionButton:
          (ref.watch(employeeWorkspaceCompanyProvider) != null ||
              !ref.watch(employeeCanProvider('branches.manage')) ||
              BranchScope.allMode)
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('branch_new'),
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              onPressed: () => _create(context, ref, l10n),
              icon: const Icon(Icons.add_rounded),
              label: Text(
                l10n.translate('branchNew'),
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
      body: async.when(
        skipLoadingOnRefresh: false,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text(
            _branchError(context, e),
            textAlign: TextAlign.center,
            style: const TextStyle(fontFamily: 'Cairo'),
          ),
        ),
        data: (rows) {
          final active = rows.where((b) => b['is_archived'] != true).toList();
          final archived = rows.where((b) => b['is_archived'] == true).toList();
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(branchesProvider),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              children: [
                if (active.length > 1 &&
                    (ref.watch(employeeCanProvider('branches.transfer')))) ...[
                  _transferAction(context, l10n),
                  const SizedBox(height: 14),
                ],
                if (active.isEmpty)
                  _empty(l10n.translate('branchEmpty'))
                else
                  for (final b in active)
                    _card(context, ref, l10n, b, archived: false),
                if (archived.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(
                    l10n.translate('branchArchived'),
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final b in archived)
                    _card(context, ref, l10n, b, archived: true),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _transferAction(BuildContext context, AppLocalizations l10n) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => context.push('/branches/transfers'),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: AppColors.gradientPrimary),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withAlpha(65),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              const Icon(
                Icons.swap_horiz_rounded,
                color: Colors.white,
                size: 26,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.translate('branchTransferAction'),
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      l10n.translate('branchTransfersHint'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 10,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_left_rounded, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty(String text) => Padding(
    padding: const EdgeInsets.only(top: 60),
    child: Column(
      children: [
        Icon(
          Icons.account_tree_outlined,
          size: 54,
          color: AppColors.primary.withAlpha(120),
        ),
        const SizedBox(height: 10),
        Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 13,
            color: Colors.grey,
          ),
        ),
      ],
    ),
  );

  Widget _branchAvatar(
    Map<String, dynamic> b, {
    double size = 52,
    String? fallbackImage,
  }) {
    final raw = '${b['image'] ?? ''}'.trim().isNotEmpty
        ? '${b['image']}'
        : (fallbackImage ?? '');
    final placeholder = Icon(
      b['is_default'] == true
          ? Icons.account_balance_rounded
          : Icons.store_rounded,
      color: Colors.white,
      size: size * .46,
    );
    Widget avatar = placeholder;
    final url = serverImageUrl(raw);
    if (raw.startsWith('local://')) {
      // Saved on this device while offline: shown exactly like the uploaded
      // one until the connection pushes it.
      avatar = Image.file(
        File(raw.substring('local://'.length)),
        fit: BoxFit.cover,
        width: size,
        height: size,
        errorBuilder: (_, _, _) => Center(child: placeholder),
      );
    } else if (url != null) {
      avatar = CachedNetworkImage(
        imageUrl: url,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        fit: BoxFit.cover,
        memCacheWidth: 192,
        width: size,
        height: size,
        placeholder: (_, _) => Center(child: placeholder),
        errorWidget: (_, _, _) => Center(child: placeholder),
      );
    }
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: AppColors.gradientPrimary),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Center(child: avatar),
    );
  }

  Widget _card(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    Map<String, dynamic> b, {
    required bool archived,
  }) {
    final isMain = b['is_default'] == true;
    final name = '${b['name'] ?? ''}';
    final dark = Theme.of(context).brightness == Brightness.dark;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0012)
            ..rotateX((1 - v) * 0.08),
          child: child,
        ),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: dark
                ? [const Color(0xFF221418), const Color(0xFF171113)]
                : [Colors.white, const Color(0xFFF8F3F4)],
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isMain ? AppColors.primary.withAlpha(120) : AppColors.border,
          ),
          boxShadow: [
            BoxShadow(
              color: (isMain ? AppColors.primary : Colors.black).withAlpha(
                dark ? 40 : 16,
              ),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            _branchAvatar(
              b,
              fallbackImage: isMain
                  ? ref.watch(authProvider).user?.organizationAvatar
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: archived ? Colors.grey : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (isMain)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withAlpha(18),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            l10n.translate('branchMain'),
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                      if (archived)
                        Text(
                          l10n.translate('branchArchived'),
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 10,
                            color: Colors.grey,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (ref.watch(employeeWorkspaceCompanyProvider) == null &&
                ref.watch(employeeCanProvider('branches.manage')) &&
                !BranchScope.allMode &&
                archived)
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Colors.grey),
                onSelected: (v) {
                  if (v == 'reactivate') _reactivate(context, ref, l10n, b);
                  if (v == 'edit') _editBranch(context, ref, l10n, b);
                  if (v == 'reset') _reset(context, ref, l10n, b);
                  if (v == 'delete') _delete(context, ref, l10n, b);
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'reactivate',
                    child: Text(
                      l10n.translate('branchReactivate'),
                      style: const TextStyle(fontFamily: 'Cairo'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'edit',
                    child: Text(
                      l10n.translate('branchEdit'),
                      style: const TextStyle(fontFamily: 'Cairo'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'reset',
                    child: Text(
                      l10n.translate('branchReset'),
                      style: const TextStyle(fontFamily: 'Cairo'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      l10n.translate('branchDeletePermanent'),
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        color: AppColors.danger,
                      ),
                    ),
                  ),
                ],
              )
            else if (ref.watch(employeeWorkspaceCompanyProvider) == null &&
                ref.watch(employeeCanProvider('branches.manage')) &&
                !BranchScope.allMode)
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Colors.grey),
                onSelected: (v) {
                  if (v == 'edit') _editBranch(context, ref, l10n, b);
                  if (v == 'archive') _archive(context, ref, l10n, b);
                  if (v == 'reset') _reset(context, ref, l10n, b);
                  if (v == 'delete') _delete(context, ref, l10n, b);
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text(
                      l10n.translate('branchEdit'),
                      style: const TextStyle(fontFamily: 'Cairo'),
                    ),
                  ),
                  if (!isMain)
                    PopupMenuItem(
                      value: 'archive',
                      child: Text(
                        l10n.translate('branchArchive'),
                        style: const TextStyle(fontFamily: 'Cairo'),
                      ),
                    ),
                  PopupMenuItem(
                    value: 'reset',
                    child: Text(
                      l10n.translate('branchReset'),
                      style: const TextStyle(fontFamily: 'Cairo'),
                    ),
                  ),
                  if (!isMain)
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        l10n.translate('branchDeletePermanent'),
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          color: AppColors.danger,
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// A user-facing reason, never the transport library's own English text.
  String _branchError(BuildContext context, Object e) {
    final l10n = AppLocalizations.of(context);
    if (isConnectionError(e)) return l10n.translate('noInternet');
    if (e is DioException) {
      final data = e.response?.data;
      final detail = data is Map ? data['detail'] : null;
      if (detail is String && detail.trim().isNotEmpty) return detail;
      return l10n.translate('networkError');
    }
    return '$e';
  }

  Future<void> _create(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) async {
    final result = await showDialog<_BranchEditResult>(
      context: context,
      builder: (_) => _BranchEditDialog(l10n: l10n),
    );
    if (result == null || result.name.trim().isEmpty) return;
    try {
      final created = await ref
          .read(branchApiProvider)
          .create(result.name.trim());
      final id = '${created['id'] ?? ''}';
      if (id.isNotEmpty && result.image != null) {
        await ref.read(branchApiProvider).uploadImage(id, result.image!);
      }
      ref.invalidate(branchesProvider);
      ref.invalidate(branchAccessProvider);
      if (context.mounted) {
        showFyonaSnack(context, l10n.translate('branchCreated'), success: true);
      }
    } catch (e) {
      if (context.mounted) {
        showFyonaSnack(context, _branchError(context, e), success: false);
      }
    }
  }

  Future<void> _editBranch(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    Map<String, dynamic> b,
  ) async {
    final result = await showDialog<_BranchEditResult>(
      context: context,
      builder: (_) => _BranchEditDialog(
        l10n: l10n,
        initialName: '${b['name'] ?? ''}',
        existingImage: '${b['image'] ?? ''}',
      ),
    );
    if (result == null || result.name.trim().isEmpty) return;
    try {
      await ref
          .read(branchApiProvider)
          .rename('${b['id']}', result.name.trim());
      if (result.image != null) {
        await ref
            .read(branchApiProvider)
            .uploadImage('${b['id']}', result.image!);
      }
      ref.invalidate(branchesProvider);
      ref.invalidate(branchAccessProvider);
      if (BranchScope.branchId == '${b['id']}') {
        await BranchScope.save(
          token: BranchScope.token,
          branchId: '${b['id']}',
          branchName: result.name.trim(),
          allMode: false,
          organizationId: BranchScope.organizationId,
        );
        ref.read(branchEpochProvider.notifier).state++;
      }
      if (context.mounted) {
        showFyonaSnack(context, l10n.translate('branchSaved'), success: true);
      }
    } catch (e) {
      if (context.mounted) {
        showFyonaSnack(context, _branchError(context, e), success: false);
      }
    }
  }

  Future<void> _archive(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    Map<String, dynamic> b,
  ) async {
    if (b['is_default'] == true) {
      if (context.mounted) {
        showFyonaSnack(
          context,
          l10n.translate('branchMainProtected'),
          success: false,
        );
      }
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          l10n.translate('branchArchiveConfirm'),
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 16),
        ),
        content: Text(
          l10n.translate('branchArchiveBody'),
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 12.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.translate('branchCancel'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.translate('branchArchive'),
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final verified = await verifySensitiveAction(
      context,
      ref,
      reason: l10n.translate('branchArchiveBio'),
    );
    if (!verified || !context.mounted) return;
    try {
      await ref.read(branchApiProvider).archive('${b['id']}');
      if (!context.mounted) return;
      await _afterBranchChange(context, ref, b);
      if (context.mounted) {
        showFyonaSnack(
          context,
          l10n.translate('branchArchivedDone'),
          success: true,
        );
      }
    } catch (e) {
      if (context.mounted) {
        showFyonaSnack(context, _branchError(context, e), success: false);
      }
    }
  }

  Future<void> _reset(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    Map<String, dynamic> b,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          l10n.translate('branchResetConfirm'),
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 16),
        ),
        content: Text(
          l10n.translate('branchResetBody'),
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 12.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.translate('branchCancel'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.translate('branchReset'),
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final verified = await verifySensitiveAction(
      context,
      ref,
      reason: l10n.translate('branchResetBio'),
    );
    if (!verified || !context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _BranchResetProgressDialog(),
    );
    try {
      // Device-ledger organization: the branch's data lives on the phone and
      // is cleared here (and on the other devices through the relay).
      final local = ref.read(businessLocalLedgerScopeProvider);
      await Future.wait([
        local != null
            ? ref.read(directoryPilotStoreProvider).withSync(
                local, (db) => db.resetBranchData(local, '${b['id']}'))
            : ref.read(branchApiProvider).resetData('${b['id']}'),
        Future<void>.delayed(const Duration(milliseconds: 1100)),
      ]);
      ref.invalidate(branchesProvider);
      ref.invalidate(branchAccessProvider);
      ref.read(branchEpochProvider.notifier).state++;
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      showFyonaSnack(context, l10n.translate('branchResetDone'), success: true);
    } catch (e) {
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      showFyonaSnack(context, '$e', success: false);
    }
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    Map<String, dynamic> b,
  ) async {
    if (b['is_default'] == true) {
      if (context.mounted) {
        showFyonaSnack(
          context,
          l10n.translate('branchMainProtected'),
          success: false,
        );
      }
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          l10n.translate('branchDeleteConfirmTitle'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          l10n.translate('branchDeleteBody'),
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 12.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              l10n.translate('branchCancel'),
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.translate('branchDeletePermanent'),
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final verified = await verifySensitiveAction(
      context,
      ref,
      reason: l10n.translate('branchDeleteBio'),
    );
    if (!verified || !context.mounted) return;
    try {
      final wasCurrent = BranchScope.branchId == '${b['id']}';
      await ref.read(branchApiProvider).deletePermanently('${b['id']}');
      if (wasCurrent) {
        await ref.read(branchApiProvider).select();
        ref.read(branchEpochProvider.notifier).state++;
      }
      ref.invalidate(branchesProvider);
      ref.invalidate(branchAccessProvider);
      if (context.mounted) {
        showFyonaSnack(
          context,
          l10n.translate('branchDeleteDone'),
          success: true,
        );
        if (wasCurrent) context.go('/dashboard');
      }
    } catch (e) {
      if (context.mounted) {
        showFyonaSnack(context, _branchError(context, e), success: false);
      }
    }
  }

  Future<void> _afterBranchChange(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> b,
  ) async {
    final wasCurrent = BranchScope.branchId == '${b['id']}';
    if (wasCurrent) {
      await ref.read(branchApiProvider).select();
      ref.read(branchEpochProvider.notifier).state++;
    }
    ref.invalidate(branchesProvider);
    ref.invalidate(branchAccessProvider);
    if (wasCurrent && context.mounted) context.go('/dashboard');
  }

  Future<void> _reactivate(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    Map<String, dynamic> b,
  ) async {
    try {
      await ref.read(branchApiProvider).reactivate('${b['id']}');
      ref.invalidate(branchesProvider);
      ref.invalidate(branchAccessProvider);
      if (context.mounted) {
        showFyonaSnack(
          context,
          l10n.translate('branchReactivated'),
          success: true,
        );
      }
    } catch (e) {
      if (context.mounted) {
        showFyonaSnack(context, _branchError(context, e), success: false);
      }
    }
  }
}

class _BranchEditResult {
  const _BranchEditResult(this.name, this.image);
  final String name;
  final Uint8List? image;
}

class _BranchEditDialog extends StatefulWidget {
  const _BranchEditDialog({
    required this.l10n,
    this.initialName = '',
    this.existingImage = '',
  });
  final AppLocalizations l10n;
  final String initialName;
  final String existingImage;

  @override
  State<_BranchEditDialog> createState() => _BranchEditDialogState();
}

class _BranchEditDialogState extends State<_BranchEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );
  Uint8List? _picked;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final hasServerImage = widget.existingImage.trim().isNotEmpty;
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(
        l10n.translate(widget.initialName.isEmpty ? 'branchNew' : 'branchEdit'),
        style: const TextStyle(
          fontFamily: 'Cairo',
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: _pick,
              child: Container(
                width: 86,
                height: 86,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: AppColors.gradientPrimary,
                  ),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: _picked != null
                    ? Image.memory(_picked!, fit: BoxFit.cover)
                    : hasServerImage
                    ? Image.network(
                        _serverUrl(widget.existingImage),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Icon(
                          Icons.add_a_photo_rounded,
                          color: Colors.white,
                          size: 30,
                        ),
                      )
                    : const Icon(
                        Icons.add_a_photo_rounded,
                        color: Colors.white,
                        size: 30,
                      ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.image_outlined, size: 17),
              label: Text(
                l10n.translate('branchPickImage'),
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 11.5),
              ),
            ),
            FyonaTextField(
              controller: _name,
              autofocus: widget.initialName.isEmpty,
              style: const TextStyle(fontFamily: 'Cairo'),
              decoration: InputDecoration(
                labelText: l10n.translate('branchName'),
                labelStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.translate('branchImageHint'),
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 10,
                color: AppColors.textTertiary,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            l10n.translate('branchCancel'),
            style: const TextStyle(fontFamily: 'Cairo'),
          ),
        ),
        FilledButton(
          onPressed: () {
            if (_name.text.trim().length < 2) return;
            Navigator.pop(
              context,
              _BranchEditResult(_name.text.trim(), _picked),
            );
          },
          child: Text(
            l10n.translate('branchSave'),
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }

  String _serverUrl(String raw) => serverImageUrl(raw) ?? '';

  Future<void> _pick() async {
    try {
      final r = await FilePicker.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (r == null || r.files.isEmpty) return;
      final file = r.files.single;
      Uint8List? raw = file.bytes;
      if (raw == null && file.path != null) {
        raw = await File(file.path!).readAsBytes();
      }
      if (raw == null) return;
      if (raw.length > 2 * 1024 * 1024) return;
      if (mounted) setState(() => _picked = raw);
    } catch (_) {}
  }
}

class _BranchResetProgressDialog extends StatefulWidget {
  const _BranchResetProgressDialog();
  @override
  State<_BranchResetProgressDialog> createState() =>
      _BranchResetProgressDialogState();
}

class _BranchResetProgressDialogState extends State<_BranchResetProgressDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const colors = [AppColors.primary, AppColors.success, AppColors.warning];
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                for (var i = 0; i < 3; i++)
                  SlideTransition(
                    position:
                        Tween<Offset>(
                          begin: Offset((i - 1) * 0.9, -1.7),
                          end: Offset((i - 1) * 0.9, -0.1),
                        ).animate(
                          CurvedAnimation(
                            parent: _ctrl,
                            curve: Interval(
                              i * 0.18,
                              0.55 + i * 0.18,
                              curve: Curves.easeIn,
                            ),
                          ),
                        ),
                    child: FadeTransition(
                      opacity: Tween<double>(begin: 1, end: 0).animate(
                        CurvedAnimation(
                          parent: _ctrl,
                          curve: Interval(i * 0.18, 0.55 + i * 0.18),
                        ),
                      ),
                      child: Container(
                        width: 26,
                        height: 10,
                        decoration: BoxDecoration(
                          color: colors[i],
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ScaleTransition(
                  scale: Tween<double>(begin: 1, end: 1.08).animate(
                    CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
                  ),
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: AppColors.danger.withAlpha(15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.delete_outline_rounded,
                      size: 30,
                      color: AppColors.danger,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.translate('branchResetProgress'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
