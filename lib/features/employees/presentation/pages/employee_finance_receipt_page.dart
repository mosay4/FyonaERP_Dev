import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/employee_device_finance.dart';
import '../providers/employee_providers.dart';
import '../providers/employee_device_finance_provider.dart';

/// Exact self-owned financial record. No active merchant workspace is required
/// for a notification opened after a cold start; the API checks the employment.
class EmployeeFinanceReceiptPage extends ConsumerStatefulWidget {
  const EmployeeFinanceReceiptPage({
    super.key,
    required this.employeeId,
    required this.recordId,
    required this.kind,
  });
  final String employeeId, recordId, kind;

  @override
  ConsumerState<EmployeeFinanceReceiptPage> createState() =>
      _EmployeeFinanceReceiptPageState();
}

class _EmployeeFinanceReceiptPageState
    extends ConsumerState<EmployeeFinanceReceiptPage> {
  late final EmployeeReadSelection? _deviceScope;
  static const _unavailable = Center(
    child: Text('العملية غير متاحة أو تم إلغاء الارتباط'),
  );

  @override
  void initState() {
    super.initState();
    _deviceScope = ref.read(employeeDeviceSelectionProvider);
  }

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(employeeDeviceSelectionProvider);
    final EmployeeFinanceReceiptPage(:employeeId, :recordId, :kind) = widget;
    return Scaffold(
      appBar: AppBar(title: const Text('تفاصيل العملية')),
      backgroundColor: AppColors.background,
      body: _deviceScope != null && _deviceScope != selected
          ? _unavailable
          : ref
                .watch(employeeFinanceForProvider(employeeId))
                .when(
                  skipLoadingOnRefresh: selected == null,
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, _) => _unavailable,
                  data: (data) {
                    final rows =
                        data[kind == 'salary' ? 'salary' : 'debts'] as List? ??
                        const [];
                    final row = rows
                        .whereType<Map>()
                        .where((row) => '${row['id']}' == recordId)
                        .firstOrNull;
                    if (row == null ||
                        !const ['salary', 'debt'].contains(kind)) {
                      return const Center(child: Text('العملية غير موجودة'));
                    }
                    final entries = <String, String>{
                      'رقم العملية':
                          '${row['invoice_no'] ?? row['operation_no'] ?? recordId}',
                      'المتجر': '${row['organization_name'] ?? ''}',
                      'الموظف': '${row['employee_name'] ?? ''}',
                      'الفرع': '${row['branch_name'] ?? ''}',
                      'الحساب': '${row['bank_name'] ?? ''}',
                      'المبلغ':
                          '${row['payment_amount'] ?? row['amount']} ${row['payment_currency'] ?? row['currency']}',
                      if (row['base_salary'] != null)
                        'الراتب الأساسي':
                            '${row['base_salary']} ${row['base_currency'] ?? row['currency']}',
                      if (row['converted_amount'] != null)
                        'المعادل':
                            '${row['converted_amount']} ${row['base_currency']}',
                      if (row['exchange_rate'] != null)
                        'سعر الصرف': '${row['exchange_rate']}',
                      if (row['remaining_salary'] != null)
                        'المتبقي من الراتب':
                            '${row['remaining_salary']} ${row['base_currency'] ?? row['currency']}',
                      if (row['remaining_amount'] != null)
                        'المتبقي':
                            '${row['remaining_amount']} ${row['base_currency'] ?? row['currency']}',
                      'ملاحظات': '${row['notes'] ?? ''}',
                    };
                    return ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        for (final entry in entries.entries)
                          ListTile(
                            title: Text(entry.key),
                            subtitle: Text(
                              entry.value,
                              textDirection: TextDirection.ltr,
                            ),
                          ),
                      ],
                    );
                  },
                ),
    );
  }
}
