import 'package:flutter/material.dart';
import '../../../branches/data/branch_scope.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../data/employee_branch_context.dart';
import '../../../business_banks/data/business_bank_models.dart';
import '../../../business_banks/presentation/providers/business_banks_providers.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../data/employee_api.dart';
import '../providers/employee_providers.dart';
import '../providers/employee_device_finance_provider.dart';
import '../../data/employee_device_finance.dart';
import '../widgets/employee_avatar.dart';
import '../widgets/salary_receipt.dart';
import 'employee_payment_page.dart';

class EmployeeSalaryPage extends ConsumerStatefulWidget {
  const EmployeeSalaryPage({
    super.key,
    required this.employeeId,
    required this.employeeName,
    this.photo,
    this.organizationName,
    this.branchId,
    this.branchName,
    this.readOnly = false,
  });
  final String employeeId;
  final String employeeName;
  final String? photo;
  final String? organizationName;
  final String? branchId;
  final String? branchName;
  final bool readOnly;
  @override
  ConsumerState<EmployeeSalaryPage> createState() => _EmployeeSalaryPageState();
}

class _EmployeeSalaryPageState extends ConsumerState<EmployeeSalaryPage> {
  EmployeeBranchContext get _branch => EmployeeBranchContext.payment(
    branchId: widget.branchId,
    branchName: widget.branchName,
  );
  List<Map<String, dynamic>> _payments = [];
  bool _loading = true;
  bool _paying = false;
  String _period = 'month';
  DateTime? _from;
  DateTime? _to;
  BusinessBankAccount? _bank;
  final _amount = TextEditingController();
  final _notes = TextEditingController();
  late final EmployeeReadSelection? _deviceScope;

  @override
  void initState() {
    super.initState();
    _deviceScope = widget.readOnly
        ? ref.read(employeeDeviceSelectionProvider)
        : null;
    if (_deviceScope == null) _load();
  }

  @override
  void dispose() {
    _amount.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final api = ref.read(employeeApiProvider);
      final data = widget.readOnly
          ? await ref.read(employeeFinanceForProvider(widget.employeeId).future)
          : await api.salary(widget.employeeId);
      if (mounted)
        setState(() {
          _payments =
              ((data['salary'] as List?) ??
                      (data['payments'] as List?) ??
                      const [])
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList();
          _loading = false;
        });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showFyonaSnack(context, EmployeeApi.message(e), success: false);
      }
    }
  }

  List<Map<String, dynamic>> _filtered(List<Map<String, dynamic>> payments) {
    final now = DateTime.now();
    final from = _period == 'month'
        ? DateTime(now.year, now.month)
        : _period == 'year'
        ? DateTime(now.year)
        : _from;
    final to = _period == 'range' ? _to : null;
    return payments.where((p) {
      final d = DateTime.tryParse('${p['paid_at'] ?? ''}');
      if (d == null) return true;
      if (from != null && d.isBefore(from)) return false;
      if (to != null && d.isAfter(to.add(const Duration(days: 1))))
        return false;
      return true;
    }).toList();
  }

  Future<void> _pickBank() async {
    // On a registered branch the payroll writer is the device ledger, so the
    // picker lists that ledger's own accounts instead of the legacy REST form.
    if (ref.read(businessLocalLedgerScopeProvider) != null) {
      List<BusinessBankAccount> accounts;
      try {
        final rows = await ref
            .read(employeeLocalFinanceProvider)
            .bankAccounts();
        accounts = [
          for (final row in rows)
            BusinessBankAccount(
              id: '${row['id']}',
              bankName: '${row['bank_name']}',
              accountName: '${row['account_name']}',
              accountNumber: '${row['account_number']}',
              balance: (row['balance_minor'] as int) / 100.0,
              currency: '${row['currency']}',
              isActive: true,
            ),
        ];
      } catch (e) {
        if (mounted) {
          showFyonaSnack(context, EmployeeApi.message(e), success: false);
        }
        return;
      }
      if (!mounted) return;
      final picked = await _chooseBank(accounts);
      if (picked != null && mounted) setState(() => _bank = picked);
      return;
    }
    final source = ref.read(businessBanksProvider.notifier);
    if (source.isLocal) {
      showFyonaSnack(
        context,
        AppLocalizations.of(context).translate('txOperationFailed'),
        success: false,
      );
      return;
    }
    await source.load();
    if (!mounted || !source.isCurrent) return;
    final accounts = ref
        .read(businessBanksProvider)
        .accounts
        .where((a) => a.isActive)
        .toList();
    if (!mounted) return;
    final picked = await _chooseBank(accounts);
    if (picked != null && mounted && source.isCurrent)
      setState(() => _bank = picked);
  }

  Future<BusinessBankAccount?> _chooseBank(List<BusinessBankAccount> accounts) {
    return showModalBottomSheet<BusinessBankAccount>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'من وين نطلع الراتب؟',
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            for (final a in accounts)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppColors.primary.withAlpha(20),
                  child: Text(
                    currencyFlagEmoji(a.currency),
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
                title: Text(
                  a.bankName,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Text(
                  '${fmtNum(a.balance)} ${currencySymbol(a.currency)}',
                  style: const TextStyle(fontFamily: 'Cairo', fontSize: 11),
                ),
                onTap: () => Navigator.pop(ctx, a),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pay() async {
    final branch = _branch;
    if (branch.id == null) {
      showFyonaSnack(context, 'ادخل فرع محدد أولاً', success: false);
      return;
    }
    final amount = num.tryParse(_amount.text.replaceAll(',', '')) ?? 0;
    if (amount <= 0) {
      showFyonaSnack(context, 'اكتب مبلغ الراتب أول', success: false);
      return;
    }
    if (_bank == null) {
      showFyonaSnack(
        context,
        'اختر الحساب اللي بنطلع منه الراتب',
        success: false,
      );
      return;
    }
    setState(() => _paying = true);
    try {
      final res = await ref
          .read(employeeApiProvider)
          .paySalary(widget.employeeId, {
            'amount': amount,
            'currency': _bank!.currency,
            'bank_account_id': _bank!.id,
            'notes': _notes.text.trim(),
            'branch_id': branch.id,
          });
      if (res.isEmpty) throw StateError('empty');
      final payment = {...res, 'paid_at': DateTime.now().toIso8601String()};
      ref.invalidate(employeesProvider);
      ref.invalidate(myEmployeeFinanceProvider);
      await _load();
      if (!mounted) return;
      _amount.clear();
      _notes.clear();
      showSalaryReceipt(
        context,
        payment,
        employeeName: widget.employeeName,
        organizationName: widget.organizationName,
        branchName: branch.name,
      );
    } catch (e) {
      if (mounted)
        showFyonaSnack(context, EmployeeApi.message(e), success: false);
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  Future<void> _range() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: Theme.of(
            ctx,
          ).colorScheme.copyWith(primary: AppColors.primary),
        ),
        child: child!,
      ),
    );
    if (picked != null)
      setState(() {
        _period = 'range';
        _from = picked.start;
        _to = picked.end;
      });
  }

  @override
  Widget build(BuildContext context) {
    final local = _deviceScope;
    final copy =
        local != null && local == ref.watch(employeeDeviceSelectionProvider)
        ? ref.watch(employeeFinanceForProvider(widget.employeeId))
        : null;
    final rows = local == null
        ? _payments
        : [
            for (final row
                in (copy?.asData?.value['salary'] as List? ?? const [])
                    .whereType<Map>())
              Map<String, dynamic>.from(row),
          ];
    final filtered = _filtered(rows);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        title: Text(
          widget.readOnly ? 'رواتبي' : 'رواتب ${widget.employeeName}',
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body: (local == null ? _loading : copy?.isLoading == true)
          ? const Center(child: CircularProgressIndicator())
          : local != null && copy?.asData == null
          ? Center(
              child: Text(EmployeeApi.message(const DirectoryAccessDenied())),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (!widget.readOnly && !BranchScope.readOnly) _payEntry(),
                if (!widget.readOnly) const SizedBox(height: 16),
                Text(
                  widget.readOnly ? 'فلتر رواتبي' : 'فلتر الرواتب',
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _chip('هذا الشهر', 'month'),
                    _chip('هذه السنة', 'year'),
                    ActionChip(
                      avatar: const Icon(Icons.date_range_rounded, size: 16),
                      label: Text(
                        _period == 'range' && _from != null
                            ? '${DateFormat('dd/MM').format(_from!)} - ${DateFormat('dd/MM').format(_to!)}'
                            : 'بين تاريخين',
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 11,
                        ),
                      ),
                      onPressed: _range,
                    ),
                    _chip('كل الرواتب', 'all'),
                  ],
                ),
                const SizedBox(height: 10),
                if (filtered.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(28),
                    alignment: Alignment.center,
                    child: Text(
                      widget.readOnly
                          ? 'ما لك رواتب مسجلة لهذه الفترة'
                          : 'ما في رواتب مسجلة لهذه الفترة',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        color: AppColors.textSecondary,
                      ),
                    ),
                  )
                else
                  for (final p in filtered) _paymentTile(p),
              ],
            ),
    );
  }

  Widget _chip(String label, String value) => ChoiceChip(
    selected: _period == value,
    label: Text(
      label,
      style: const TextStyle(fontFamily: 'Cairo', fontSize: 11),
    ),
    onSelected: (_) => setState(() => _period = value),
  );

  Widget _payEntry() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            EmployeeAvatar(photo: widget.photo, size: 42),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'راتب الموظف',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    'صرف الراتب من الكاش أو البنك، ونطلع لك فاتورة.',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 10,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () async {
              final payment = await Navigator.of(context).push<Map>(
                MaterialPageRoute(
                  builder: (_) => EmployeePaymentPage(
                    mode: 'salary',
                    employeeId: widget.employeeId,
                    employeeName: widget.employeeName,
                    organizationName: widget.organizationName,
                    branchId: _branch.id,
                    branchName: _branch.name,
                  ),
                ),
              );
              if (payment != null) {
                await _load();
                if (!mounted) return;
                showSalaryReceipt(
                  context,
                  payment,
                  employeeName: widget.employeeName,
                  organizationName: widget.organizationName,
                  branchName: _branch.name,
                );
              }
            },
            icon: const Icon(Icons.payments_rounded),
            label: const Text(
              'صرف راتب',
              style: TextStyle(
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w800,
              ),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.success,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _payCard() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            EmployeeAvatar(photo: widget.photo, size: 38),
            const SizedBox(width: 8),
            Text(
              'صرف راتب',
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        InkWell(
          onTap: _pickBank,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
              color: AppColors.background,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.account_balance_wallet_rounded,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _bank == null
                        ? 'اختر الحساب البنكي والعملة'
                        : '${_bank!.bankName} • ${currencyFlagEmoji(_bank!.currency)} ${currencySymbol(_bank!.currency)}',
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_left_rounded),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'المبلغ',
            labelStyle: const TextStyle(fontFamily: 'Cairo'),
            filled: true,
            fillColor: AppColors.background,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _notes,
          maxLines: 2,
          decoration: InputDecoration(
            labelText: 'ملاحظات (اختياري)',
            labelStyle: const TextStyle(fontFamily: 'Cairo'),
            filled: true,
            fillColor: AppColors.background,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _paying ? null : _pay,
            icon: _paying
                ? const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.payments_rounded),
            label: Text(
              _paying ? 'نحسب ونطلع الفاتورة…' : 'صرف راتب',
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _paymentTile(Map p) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.border),
    ),
    child: Material(
      color: Colors.transparent,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppColors.success.withAlpha(20),
          child: const Icon(
            Icons.receipt_long_rounded,
            color: AppColors.success,
          ),
        ),
        title: Text(
          '${fmtNum(num.tryParse('${p['amount']}') ?? 0)} ${currencySymbol('${p['currency']}')}',
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Text(
          '${p['invoice_no'] ?? p['operation_no']} • ${'${p['paid_at']}'.split('T').first}',
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 10),
        ),
        trailing: const Icon(Icons.chevron_left_rounded),
        onTap: () => showSalaryReceipt(
          context,
          p,
          employeeName: widget.employeeName,
          organizationName: widget.organizationName,
          branchName: _branch.name,
          protect: _deviceScope == null
              ? null
              : (receipt) => protectEmployeeReceipt(
                  _deviceScope,
                  '${p['id']}',
                  'salary',
                  receipt,
                ),
        ),
      ),
    ),
  );
}
