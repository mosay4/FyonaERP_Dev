import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_colors.dart';
import '../auth2_api.dart';
import '../auth2_models.dart';
import '../auth2_strings.dart';
import 'approval_dialog.dart';

/// `/security/approvals?id=…` — opened from the notification center (and
/// push taps). Lists pending sign-in requests; with `id` the matching
/// request pops up directly. Expired / handled requests never show a code.
class ApprovalsPage extends ConsumerStatefulWidget {
  const ApprovalsPage({super.key, this.focusId});
  final String? focusId;

  @override
  ConsumerState<ApprovalsPage> createState() => _ApprovalsPageState();
}

class _ApprovalsPageState extends ConsumerState<ApprovalsPage> {
  List<PendingApproval>? _items;
  String? _error;
  bool _autoOpened = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await ref.read(auth2ApiProvider).pendingApprovals();
      if (!mounted) return;
      final open = list.where((a) => !a.isExpired()).toList();
      setState(() {
        _items = open;
        _error = null;
      });
      if (!_autoOpened && widget.focusId != null) {
        _autoOpened = true;
        for (final a in open) {
          if (a.approvalId == widget.focusId) {
            await _open(a);
            break;
          }
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = auth2ErrorTextOf(context, e));
    }
  }

  Future<void> _open(PendingApproval a) async {
    final denied = await showApprovalDialog(context, a);
    if (!mounted) return;
    if (denied == true) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(a2(context, 'approvalDenied'),
            style: const TextStyle(fontFamily: 'Cairo')),
      ));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(a2(context, 'approvalsPageTitle'),
            style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
        leading: BackButton(onPressed: () {
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/account-entry');
          }
        }),
      ),
      body: items == null
          ? Center(
              child: _error != null
                  ? Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error!, style: const TextStyle(fontFamily: 'Cairo')),
                      TextButton(onPressed: _load, child: Text(a2(context, 'retry'))),
                    ])
                  : const CircularProgressIndicator(),
            )
          : items.isEmpty
              ? Center(
                  child: Text(a2(context, 'approvalsEmpty'),
                      key: const Key('approvals_empty'),
                      style: TextStyle(
                          fontFamily: 'Cairo', color: AppColors.textSecondary)),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final a in items)
                        Card(
                          color: AppColors.surface,
                          child: ListTile(
                            key: Key('approval_${a.approvalId}'),
                            leading: const Icon(Icons.shield_outlined,
                                color: AppColors.primary),
                            title: Text(
                              [a.deviceName, a.deviceModel]
                                  .where((s) => s.isNotEmpty)
                                  .toSet()
                                  .join(' · '),
                              style: const TextStyle(
                                  fontFamily: 'Cairo', fontWeight: FontWeight.w700),
                            ),
                            subtitle: Text(formatApprovalTime(a.createdAt),
                                style: const TextStyle(fontFamily: 'Cairo')),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _open(a),
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }
}
