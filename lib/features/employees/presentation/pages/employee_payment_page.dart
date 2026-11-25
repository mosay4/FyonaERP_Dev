import 'package:flutter/material.dart';
import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../data/employee_branch_context.dart';
import '../../../dashboard/presentation/providers/business_dashboard_providers.dart';
import '../../../personal/data/models/personal_models.dart';
import '../../../personal/domain/services/personal_finance_service.dart';
import '../../data/employee_api.dart';
import '../providers/employee_providers.dart';
import '../../../branches/data/branch_epoch.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../../../core/services/currency/business_currency_scope.dart';
import '../../../core_business/data/local_directory/directory_pilot.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';

double? parseEmployeeNumber(String value) {
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  const eastern = '۰۱۲۳۴۵۶۷۸۹';
  for (var i = 0; i < 10; i++) {
    value = value.replaceAll(arabic[i], '$i').replaceAll(eastern[i], '$i');
  }
  final number = double.tryParse(
    value.replaceAll(',', '').replaceAll('٬', '').replaceAll('٫', '.').trim(),
  );
  return number != null && number.isFinite ? number : null;
}

class EmployeePaymentPage extends ConsumerStatefulWidget {
  const EmployeePaymentPage({
    super.key,
    required this.mode,
    required this.employeeId,
    required this.employeeName,
    this.organizationName,
    this.branchId,
    this.branchName,
    this.direction = 'employer_owes',
    this.kind = 'charge',
    this.debt,
  });
  final String mode; // salary | debt
  final String employeeId;
  final String employeeName;
  final String? organizationName;
  final String? branchId;
  final String? branchName;
  final String direction;
  final String kind;
  final Map<String, dynamic>? debt;
  @override
  ConsumerState<EmployeePaymentPage> createState() =>
      _EmployeePaymentPageState();
}

class _EmployeePaymentPageState extends ConsumerState<EmployeePaymentPage> {
  final _idempotencyKey =
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  final _amount = TextEditingController();
  final _notes = TextEditingController();
  final _fx = TextEditingController();
  String? _branchId;
  String? _originalCurrency;
  String? _method;
  String? _bankName;
  String? _currency;
  String? _accountType;
  bool _saving = false;
  late final DirectoryAccess? _localScope;

  @override
  void initState() {
    super.initState();
    _localScope = ref.read(businessLocalLedgerScopeProvider);
  }

  bool _sameSource(DirectoryAccess? selected) =>
      sameDirectoryScope(_localScope, selected) &&
      (_localScope == null ||
          _branch.id == _localScope.branchId);

  bool get _isSalary => widget.mode == 'salary';
  bool get _onEmployee => widget.direction == 'employee_owes';
  EmployeeBranchContext get _branch => EmployeeBranchContext.payment(
    branchId: widget.branchId, branchName: widget.branchName,
  );

  @override
  void dispose() {
    _amount.dispose();
    _notes.dispose();
    _fx.dispose();
    super.dispose();
  }

  List<PersonalBankAccount> _cash(List<PersonalBankAccount> a) =>
      PersonalFinanceService.canonicalCashAccounts(a);

  List<String> _bankNames(List<PersonalBankAccount> a) {
    final seen = <String>{};
    return [
      for (final x in a)
        if (!isCashAccount(x.bankName) && seen.add(x.bankName)) x.bankName,
    ];
  }

  List<PersonalBankAccount> _bankRows(
    List<PersonalBankAccount> a,
    String bank,
  ) {
    final seen = <String>{};
    return [
      for (final x in a)
        if (x.bankName == bank &&
            !isCashAccount(x.bankName) &&
            seen.add('${x.currency}|${x.accountType}'))
          x,
    ];
  }

  String? _accountId(List<PersonalBankAccount> accounts) {
    if (_method == 'cash') {
      final cur =
          _currency ??
          (_cash(accounts).isNotEmpty ? _cash(accounts).first.currency : null);
      if (cur == null) return null;
      for (final x in _cash(accounts)) {
        if (x.currency == cur && x.id.isNotEmpty) return x.id;
      }
      return _cash(accounts).isNotEmpty ? _cash(accounts).first.id : null;
    }
    if (_bankName == null || _currency == null) return null;
    for (final x in accounts) {
      if (x.bankName == _bankName &&
          x.currency == _currency &&
          (_accountType == null || x.accountType == _accountType))
        return x.id;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(branchEpochProvider);
    final branch = _branch;
    final selected = ref.watch(businessLocalLedgerScopeProvider);
    final local = _localScope != null;
    if (!_sameSource(selected)) {
      return Scaffold(
        appBar: AppBar(title: const Text('مدفوعات الموظف')),
        body: Center(child: Text(EmployeeApi.message(const DirectoryAccessDenied()))),
      );
    }
    if (branch.id == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('مدفوعات الموظف')),
        body: const Center(child: Padding(padding: EdgeInsets.all(24),
          child: Text('ادخل فرع محدد أولاً عشان تسجل راتب أو دين للموظف',
            textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Cairo')))),
      );
    }
    if (_branchId != branch.id) {
      _branchId = branch.id;
      _method = null;
      _bankName = null;
      _currency = null;
      _originalCurrency = null;
      _accountType = null;
      _fx.clear();
    }
    final accountsAsync = _branchId == null
        ? const AsyncData<List<PersonalBankAccount>>([])
        : ref.watch(employeePaymentAccountsProvider(_branchId!));
    final summary = _isSalary
        ? ref
              .watch(employeeSalarySummaryProvider(widget.employeeId))
              .valueOrNull
        : ref.watch(employeeDebtSummaryProvider(widget.employeeId)).valueOrNull;
    final enabled =
        ref.watch(bizEnabledCurrenciesProvider).valueOrNull ?? <String>{};
    final baseCurrency = _isSalary
        ? (local ? _currency : (summary?['base_currency'])?.toString())
        : (widget.debt?['currency']?.toString() ??
              _originalCurrency ??
              _currency);
    final engine = local ? null : ref.watch(currencyEngineProvider);
    final rate = baseCurrency == _currency
        ? 1.0
        : local
        ? null
        : (_fx.text.trim().isNotEmpty
              ? parseEmployeeNumber(_fx.text)
              : (_currency != null && baseCurrency != null
                    ? engine?.getRate(_currency!, baseCurrency)
                    : null));
    final entered = parseEmployeeNumber(_amount.text) ?? 0;
    final equivalent = rate == null ? null : entered * rate;
    double? remaining = _isSalary
        ? double.tryParse('${summary?['remaining_salary']}')
        : null;
    if (!_isSalary && widget.debt != null) {
      remaining = double.tryParse(
        '${widget.debt!['outstanding_amount'] ?? widget.debt!['amount']}',
      );
    } else if (!_isSalary && summary != null) {
      remaining = 0;
      for (final row
          in (summary['debts'] as List? ?? const []).whereType<Map>()) {
        if (row['currency'] == baseCurrency &&
            row['direction'] == widget.direction) {
          remaining =
              remaining! +
              (double.tryParse('${row['amount']}') ?? 0) *
                  (row['kind'] == 'settlement' ? -1 : 1);
        }
      }
    }
    final title = _isSalary
        ? 'صرف راتب'
        : widget.kind == 'settlement'
        ? (_onEmployee ? 'تحصيل من الموظف' : 'سداد للموظف')
        : (_onEmployee ? 'دين على الموظف' : 'دين للموظف');
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        title: Text(
          title,
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body: accountsAsync.when(
        loading: () => const SizedBox.shrink(), // no loading screen
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.cloud_off_rounded,
                  size: 40,
                  color: AppColors.danger,
                ),
                const SizedBox(height: 12),
                const Text(
                  'تعذر تحميل الحسابات',
                  style: TextStyle(fontFamily: 'Cairo'),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () {
                    if (_branchId != null)
                      ref.invalidate(
                        employeePaymentAccountsProvider(_branchId!),
                      );
                  },
                  child: const Text('إعادة المحاولة'),
                ),
              ],
            ),
          ),
        ),
        data: (accounts) => ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (!_isSalary) Container(
              margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AppColors.primary.withAlpha(10), borderRadius: BorderRadius.circular(14)),
              child: Text(widget.kind == 'charge'
                ? (_onEmployee ? 'سيُخصم المبلغ من الحساب ويُسجّل ديناً على الموظف.'
                               : 'تسجيل دين للموظف فقط. لن يتغير رصيد الحساب إلا عند تسديده.')
                : (_onEmployee ? 'سيُضاف التحصيل إلى حسابك وينخفض الدين على الموظف.'
                               : 'سيُخصم السداد من حسابك وينخفض الدين الذي للموظف.'),
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 12))),
            if (widget.debt != null)
              Container(
                margin: const EdgeInsets.only(bottom: 14),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(10),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'فاتورة الدين: ${widget.debt!['invoice_no'] ?? widget.debt!['id']}',
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    _valueLine(
                      'قيمة الدين الأصلية',
                      num.tryParse('${widget.debt!['amount']}') ?? 0,
                      baseCurrency ?? '',
                    ),
                    _valueLine(
                      'المتبقي في هذه الفاتورة',
                      remaining ?? 0,
                      baseCurrency ?? '',
                    ),
                  ],
                ),
              ),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: AppColors.primary.withAlpha(16),
                    child: const Icon(
                      Icons.person_rounded,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.employeeName,
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          _isSalary
                              ? 'اختر من وين يطلع الراتب'
                              : 'اختر الحساب اللي بتسجل منه الدين',
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
            ),
            const SizedBox(height: 16),
              ListTile(
                key: const ValueKey('employee-payment-branch'),
                tileColor: AppColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: AppColors.border),
                ),
                leading: const Icon(
                  Icons.storefront_rounded,
                  color: AppColors.primary,
                ),
                title: Text(
                  branch.name ?? branch.id!,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: const Text('يُسجّل على حساب هذا الفرع فقط'),
              ),
            if (_branchId != null)
              Row(
                children: [
                  Expanded(
                    child: _sourceChip(
                      'الكاش',
                      'cash',
                      AppColors.success,
                      Icons.payments_rounded,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _sourceChip(
                      'البنوك',
                      'bank',
                      AppColors.primary,
                      Icons.account_balance_rounded,
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 14),
            if (_method == 'bank') ...[
              _selector(
                icon: Icons.account_balance_outlined,
                text: _bankName ?? 'اختر البنك',
                onTap: () => _pickBank(accounts),
              ),
              if (_bankName != null) ...[
                const SizedBox(height: 10),
                _selector(
                  icon: Icons.public_rounded,
                  text: _currency == null
                      ? 'اختر العملة'
                      : currencyLabel(_currency!, locale: 'ar'),
                  onTap: () => _pickBankCurrency(accounts),
                ),
              ],
            ] else if (_method == 'cash') ...[
              _selector(
                icon: Icons.payments_outlined,
                text: _currency == null
                    ? 'اختر عملة الكاش'
                    : currencyLabel(_currency!, locale: 'ar'),
                onTap: () => _pickCash(accounts),
              ),
            ] else
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(8),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'اختار أول: كاش أو بنك، وبعدها نكمل.',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            const SizedBox(height: 20),
            TextField(
              enabled: _currency != null && _branchId != null,
              controller: _amount,
              onChanged: (_) => setState(() {}),
              textDirection: TextDirection.ltr,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
              decoration: InputDecoration(
                labelText: 'المبلغ',
                labelStyle: const TextStyle(fontFamily: 'Cairo'),
                suffixText: _currency == null ? '' : currencySymbol(_currency!),
                suffixStyle: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            if (!_isSalary && widget.debt == null && _currency != null) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('original-currency-$_currency'),
                initialValue: _originalCurrency ?? _currency,
                decoration: const InputDecoration(
                  labelText: 'عملة الدين الأصلية',
                ),
                items: [
                  for (final code in <String>{
                    ...enabled,
                    _currency!,
                    for (final row
                        in (summary?['debts'] as List? ?? const [])
                            .whereType<Map>())
                      '${row['currency']}',
                  })
                    DropdownMenuItem(
                      value: code,
                      child: Text(currencyLabel(code, locale: 'ar')),
                    ),
                ],
                onChanged: (value) => setState(() {
                  _originalCurrency = value;
                  _fx.clear();
                }),
              ),
            ],
            if (_currency != null &&
                baseCurrency != null &&
                _currency != baseCurrency) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('employee-payment-fx'),
                controller: _fx,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textDirection: TextDirection.ltr,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'سعر الصرف (اختياري)',
                  hintText: rate?.toString(),
                  helper: Text(
                    '1 $_currency = ${rate == null ? "؟" : fmtNum(rate)} $baseCurrency',
                    textDirection: TextDirection.ltr,
                  ),
                ),
              ),
            ],
            if (equivalent != null && baseCurrency != null) ...[
              _valueLine(
                'المعادل بعملة الدين أو الراتب',
                equivalent,
                baseCurrency,
              ),
              if (remaining != null &&
                  (_isSalary || widget.kind == 'settlement'))
                _valueLine(
                  'المتبقي المتوقع',
                  remaining - equivalent,
                  baseCurrency,
                ),
              if (!_isSalary &&
                  widget.kind == 'settlement' &&
                  remaining != null &&
                  equivalent > remaining)
                const Text(
                  'المبلغ يتجاوز المتبقي في الفاتورة',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppColors.danger,
                  ),
                ),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: _notes,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: _isSalary
                    ? 'ملاحظات (اختياري)'
                    : 'السبب / ملاحظات (اختياري)',
                labelStyle: const TextStyle(fontFamily: 'Cairo'),
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _isSalary
                    ? AppColors.success
                    : (_onEmployee ? AppColors.danger : AppColors.success),
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              onPressed:
                  _saving ||
                      _branchId == null ||
                      _currency == null ||
                      baseCurrency == null ||
                      rate == null ||
                      !rate.isFinite ||
                      rate <= 0 ||
                      (!_isSalary &&
                          widget.kind == 'settlement' &&
                          remaining != null &&
                          equivalent != null &&
                          equivalent > remaining)
                  ? null
                  : () => _submit(accounts, baseCurrency, rate),
               icon: _saving && !local
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      _isSalary
                          ? Icons.payments_rounded
                          : Icons.handshake_rounded,
                    ),
              label: Text(
                 _saving && !local ? 'نحفظ العملية…' : title,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sourceChip(String label, String value, Color color, IconData icon) {
    final active = _method == value;
    return InkWell(
      onTap: () => setState(() {
        _method = value;
        _bankName = null;
        _currency = null;
        _accountType = null;
      }),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: active ? color.withAlpha(22) : AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: active ? color : AppColors.border),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: active ? color : AppColors.textSecondary,
              size: 24,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: active ? color : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _selector({
    required IconData icon,
    required String text,
    required VoidCallback onTap,
  }) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Row(
        children: [
          Icon(icon, size: 19, color: AppColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontWeight: FontWeight.w600,
                color: text.startsWith('اختر')
                    ? AppColors.textSecondary
                    : AppColors.textPrimary,
              ),
            ),
          ),
          TwoToneIcon(
            data: TwoToneIcons.arrowDown,
            size: 18,
            outlineColor: AppColors.textSecondary,
          ),
        ],
      ),
    ),
  );

  Future<void> _pickBank(List<PersonalBankAccount> accounts) async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 10, 20, 8),
              child: Text(
                'اختر البنك',
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const Divider(height: 1),
            for (final b in _bankNames(accounts))
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppColors.primary.withAlpha(16),
                  child: const Icon(
                    Icons.account_balance_rounded,
                    color: AppColors.primary,
                    size: 20,
                  ),
                ),
                title: Text(
                  b,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Text(
                  '${_bankRows(accounts, b).length} عملة متاحة',
                  style: const TextStyle(fontFamily: 'Cairo', fontSize: 10),
                ),
                onTap: () => Navigator.pop(ctx, b),
              ),
          ],
        ),
      ),
    );
    if (chosen != null && mounted)
      setState(() {
        _bankName = chosen;
        _currency = null;
        _accountType = null;
      });
  }

  Future<void> _pickBankCurrency(List<PersonalBankAccount> accounts) async {
    final rows = _bankRows(accounts, _bankName!);
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
              child: Text(
                'عملات $_bankName',
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const Divider(height: 1),
            for (final a in rows)
              ListTile(
                leading: Text(
                  currencyFlagEmoji(a.currency),
                  style: const TextStyle(fontSize: 22),
                ),
                title: Text(
                  currencyLabel(a.currency),
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: _balanceSubtitle(a, showAccountType: true),
                onTap: () =>
                    Navigator.pop(ctx, '${a.currency}||${a.accountType}'),
              ),
          ],
        ),
      ),
    );
    if (chosen != null && mounted) {
      final parts = chosen.split('||');
      setState(() {
        _currency = parts[0];
        _accountType = parts.length > 1 ? parts[1] : null;
      });
    }
  }

  Future<void> _pickCash(List<PersonalBankAccount> accounts) async {
    final cash = _cash(accounts);
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 10, 20, 8),
              child: Text(
                'عملات الكاش',
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const Divider(height: 1),
            for (final a in cash)
              ListTile(
                leading: Text(
                  currencyFlagEmoji(a.currency),
                  style: const TextStyle(fontSize: 22),
                ),
                title: Text(
                  currencyLabel(a.currency),
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: _balanceSubtitle(a),
                onTap: () => Navigator.pop(ctx, a.currency),
              ),
          ],
        ),
      ),
    );
    if (chosen != null && mounted) setState(() => _currency = chosen);
  }

  Widget _balanceSubtitle(
    PersonalBankAccount account, {
    bool showAccountType = false,
  }) {
    if (!ref.read(employeeCanProvider('banks.balances')))
      return const SizedBox.shrink();
    final arabic = Localizations.localeOf(context).languageCode == 'ar';
    final type = switch (account.accountType.trim().toLowerCase()) {
      'checking' || 'current' => arabic ? 'حساب جاري' : 'Checking',
      'savings' || 'savings_account' => arabic ? 'حساب توفير' : 'Savings',
      'cash' => arabic ? 'حساب نقدي' : 'Cash',
      'basic' => arabic ? 'حساب أساسي' : 'Basic account',
      _ => arabic ? 'حساب بنكي' : 'Bank account',
    };
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: arabic ? 'الرصيد الحالي ' : 'Current balance '),
          TextSpan(
            text: fmtNum(account.balance),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const TextSpan(text: ' '),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              width: 42,
              height: 20,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(18),
                borderRadius: BorderRadius.circular(5),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  currencySymbol(account.currency),
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ),
          ),
          if (showAccountType)
            TextSpan(text: ' ($type)', style: const TextStyle(fontSize: 9)),
        ],
      ),
      softWrap: true,
      style: TextStyle(
        fontFamily: 'Cairo',
        fontSize: 11,
        color: AppColors.textSecondary,
      ),
    );
  }

  Widget _valueLine(String label, num amount, String currency) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontFamily: 'Cairo', fontSize: 12),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '${fmtNum(amount)} $currency',
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.end,
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    ),
  );

  Future<void> _submit(
    List<PersonalBankAccount> accounts,
    String baseCurrency,
    double rate,
  ) async {
    if (!_sameSource(ref.read(businessLocalLedgerScopeProvider))) return;
    if (_branchId == null || _branchId != _branch.id) {
      showFyonaSnack(context, 'ادخل فرع محدد أولاً', success: false);
      return;
    }
    final amount = parseEmployeeNumber(_amount.text) ?? 0;
    if (amount <= 0) {
      showFyonaSnack(context, 'اكتب المبلغ أول', success: false);
      return;
    }
    if (_method == null) {
      showFyonaSnack(context, 'اختار كاش أو بنك', success: false);
      return;
    }
    if (_method == 'bank' && _bankName == null) {
      showFyonaSnack(context, 'اختر البنك', success: false);
      return;
    }
    if (_currency == null) {
      showFyonaSnack(context, 'اختر العملة', success: false);
      return;
    }
    final accountId = _accountId(accounts);
    if (accountId == null) {
      showFyonaSnack(context, 'الحساب غير متاح', success: false);
      return;
    }
    setState(() => _saving = true);
    try {
      if (_isSalary) {
        final payment = await ref
            .read(employeeApiProvider)
            .paySalary(widget.employeeId, {
              'amount': amount,
              'idempotency_key': _idempotencyKey,
              'currency': _currency,
              'exchange_rate': rate.toStringAsFixed(12),
              'bank_account_id': accountId,
              'notes': _notes.text.trim(),
              'branch_id': _branchId,
            });
        ref.invalidate(employeesProvider);
        ref.invalidate(businessAccountsProvider);
        ref.invalidate(myEmployeeFinanceProvider);
        if (!mounted) return;
        Navigator.pop(context, {
          ...payment,
          'paid_at': payment['paid_at'] ?? DateTime.now().toIso8601String(),
        });
      } else {
        await ref.read(employeeApiProvider).addDebt(widget.employeeId, {
          'direction': widget.direction,
          'idempotency_key': _idempotencyKey,
          'kind': widget.kind,
          if (widget.debt != null) 'debt_id': widget.debt!['id'],
          'amount': amount,
          'currency': baseCurrency,
          'payment_currency': _currency,
          'exchange_rate': rate.toStringAsFixed(12),
          'bank_account_id': accountId,
          'notes': _notes.text.trim(),
          'branch_id': _branchId,
        });
        ref.invalidate(myEmployeeFinanceProvider);
        ref.invalidate(businessAccountsProvider);
        if (mounted) {
          showFyonaSnack(context, 'سجلنا الدين', success: true);
          Navigator.pop(context, true);
        }
      }
    } catch (e) {
      if (mounted)
        showFyonaSnack(context, EmployeeApi.message(e), success: false);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
