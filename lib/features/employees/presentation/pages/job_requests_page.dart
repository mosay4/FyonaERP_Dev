import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../data/employee_api.dart';
import '../providers/employee_providers.dart';
import '../providers/employee_device_finance_provider.dart';
import '../widgets/employee_avatar.dart';
import 'employment_invitation_page.dart';

class JobRequestsPage extends ConsumerStatefulWidget {
  const JobRequestsPage({super.key, this.inviteId});
  final String? inviteId;

  @override
  ConsumerState<JobRequestsPage> createState() => _JobRequestsPageState();
}

class _JobRequestsPageState extends ConsumerState<JobRequestsPage> {
  final Set<String> _opened = {};

  @override
  void initState() {
    super.initState();
    _queueInvite();
  }

  @override
  void didUpdateWidget(covariant JobRequestsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inviteId != widget.inviteId) _queueInvite();
  }

  void _queueInvite() {
    final id = widget.inviteId;
    if (id == null || id.isEmpty || !_opened.add(id)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _open(id);
    });
  }

  void _open(String id) => Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => EmploymentInvitationPage(inviteId: id)),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    appBar: AppBar(
      title: const Text(
        'التوظيف',
        style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800),
      ),
    ),
    body: ref
        .watch(myInvitationsProvider)
        .when(
          skipLoadingOnRefresh: ref.watch(employeeDeviceSelectionProvider) == null,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text(EmployeeApi.message(e))),
          data: (items) => RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(myInvitationsProvider);
              await ref.read(myInvitationsProvider.future);
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 80),
                    child: Center(
                      child: Text(
                        'لا توجد طلبات توظيف حالياً',
                        style: TextStyle(fontFamily: 'Cairo'),
                      ),
                    ),
                  ),
                for (final accepted in [true, false]) ...[
                  if (items.any((i) => (i['status'] == 'accepted') == accepted))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        accepted ? 'متاجري' : 'طلبات الانضمام',
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  for (final inv in items.where(
                    (i) => (i['status'] == 'accepted') == accepted,
                  ))
                    _card(inv, accepted),
                ],
              ],
            ),
          ),
        ),
  );

  Widget _card(Map inv, bool accepted) {
    final org = inv['organization'] as Map? ?? const {};
    final merchant = inv['merchant'] as Map? ?? const {};
    final salary = num.tryParse('${inv['salary']}') ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 220),
        builder: (_, value, child) => Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - value)),
            child: child,
          ),
        ),
        child: Card(
          color: AppColors.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: AppColors.border),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.all(14),
            leading: EmployeeAvatar(
              photo: (org['photo_url'] ?? merchant['photo_url']) as String?,
              size: 52,
            ),
            title: Text(
              '${org['name'] ?? merchant['name'] ?? 'متجر'}',
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w800,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  accepted ? 'مربوط' : 'بانتظار موافقتك',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    color: accepted ? AppColors.success : AppColors.primary,
                  ),
                ),
                if (!accepted && salary > 0)
                  Text(
                    '${fmtNum(salary)} ${currencySymbol('${inv['salary_currency'] ?? 'SAR'}')}',
                    style: const TextStyle(fontFamily: 'Cairo'),
                  ),
              ],
            ),
            trailing: const Icon(Icons.chevron_left_rounded),
            onTap: () => _open('${inv['id']}'),
          ),
        ),
      ),
    );
  }
}
