import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../data/employee_api.dart';
import '../../data/employee_permissions.dart';
import '../providers/employee_providers.dart';
import '../widgets/employee_link_settings.dart';
import '../../../../core/services/connectivity_service.dart';

import '../../../core_business/presentation/widgets/business_online_gate.dart';

class EmployeeLinkPage extends ConsumerStatefulWidget {
  const EmployeeLinkPage({
    super.key,
    required this.employeeId,
    required this.employeeName,
  });
  final String employeeId;
  final String employeeName;
  @override
  ConsumerState<EmployeeLinkPage> createState() => _EmployeeLinkPageState();
}

class _EmployeeLinkPageState extends ConsumerState<EmployeeLinkPage> {
  EmployeeLinkDraft _draft = EmployeeLinkDraft(
    permissions: defaultEmployeePermissions(),
  );
  bool _saving = false;

  Future<void> _save() async {
    if (!_draft.ready || _draft.code == null || _saving) return;
    if (!await ensureBusinessOnline(context) || !mounted) return;
    setState(() => _saving = true);
    try {
      await ref.read(employeeApiProvider).invite(
            widget.employeeId,
            _draft.code!,
            _draft.permissions,
            branchIds: _draft.branchIds,
          );
      ref.invalidate(employeesProvider);
      if (!mounted) return;
      showFyonaSnack(
        context,
        'أرسلنا طلب الربط، ننتظر موافقة الموظف',
        success: true,
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        showFyonaSnack(context, EmployeeApi.message(e), success: false);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {

    final connectivity = ref.watch(connectivityServiceProvider);
    return StreamBuilder<bool>(stream: connectivity.onConnectivityChanged,
      builder: (context, _) => Scaffold(
    backgroundColor: AppColors.background,
    appBar: AppBar(
      backgroundColor: AppColors.background,
      title: const Text(
        'ربط الموظف',
        style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          widget.employeeName,
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 16),
        if (connectivity.isOnline)
          EmployeeLinkSettings(
            employeeId: widget.employeeId,
            onChanged: (v) => setState(() => _draft = v),
          )
        else
          const Text('يتطلب إرسال طلب الربط اتصالًا بالإنترنت'),
        const SizedBox(height: 20),
        if (connectivity.isOnline && _draft.code != null)
          FilledButton.icon(
            onPressed: !_draft.ready || _saving ? null : _save,
            style: FilledButton.styleFrom(backgroundColor: AppColors.success),
            icon: const Icon(Icons.send_rounded),
            label: Text(
              _saving ? 'نرسل الطلب…' : 'إرسال طلب الربط',
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
      ],
    ),
    ));
  }
}
