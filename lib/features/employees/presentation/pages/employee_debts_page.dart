import 'package:flutter/material.dart';
import '../../../branches/data/branch_scope.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/receipt/receipt_data.dart';
import '../../../../shared/widgets/receipt/receipt_modal.dart';
import '../../data/employee_api.dart';
import '../../data/employee_branch_context.dart';
import '../../data/employee_device_finance.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../providers/employee_providers.dart';
import '../providers/employee_device_finance_provider.dart';
import 'employee_payment_page.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

class EmployeeDebtsPage extends ConsumerStatefulWidget {
  const EmployeeDebtsPage({
    super.key,
    required this.employeeId,
    required this.employeeName,
    this.organizationName,
    this.branchId,
    this.branchName,
    this.readOnly = false,
  });
  final String employeeId;
  final String employeeName;
  final String? organizationName;
  final String? branchId;
  final String? branchName;
  final bool readOnly;
  @override
  ConsumerState<EmployeeDebtsPage> createState() => _EmployeeDebtsPageState();
}

class _EmployeeDebtsPageState extends ConsumerState<EmployeeDebtsPage> {
  List<Map<String, dynamic>> _debts = [];
  bool _loading = true;
  bool _settle = false;
  String _direction = 'employee_owes';
  String _side = 'all';
  String _period = 'month';
  DateTime? _from, _to;
  String? _error;
  late final EmployeeReadSelection? _deviceScope;

  @override
  void initState() {
    super.initState();
    _deviceScope = widget.readOnly
        ? ref.read(employeeDeviceSelectionProvider)
        : null;
    if (_deviceScope == null) _load();
  }

  Future<void> _load() async {
    try {
      final data = widget.readOnly
          ? await ref.read(employeeFinanceForProvider(widget.employeeId).future)
          : await ref.read(employeeApiProvider).debts(widget.employeeId);
      if (!mounted) return;
      setState(() {
        _debts = [
          for (final row in (data['debts'] as List? ?? []).whereType<Map>())
            Map<String, dynamic>.from(row),
        ];
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = EmployeeApi.message(e);
        });
    }
  }

  List<Map<String, dynamic>> _filtered(List<Map<String, dynamic>> debts) {
    final now = DateTime.now();
    final from = _period == 'month'
        ? DateTime(now.year, now.month)
        : _period == 'year'
        ? DateTime(now.year)
        : _period == 'range'
        ? _from
        : null;
    final end = _period == 'range' ? _to?.add(const Duration(days: 1)) : null;
    return debts.where((row) {
      if (widget.readOnly) {
        if (_side != 'all' &&
            row['direction'] !=
                (_side == 'for' ? 'employer_owes' : 'employee_owes'))
          return false;
      } else {
        if (row['direction'] != _direction) return false;
        if (_settle &&
            (row['kind'] != 'charge' ||
                (num.tryParse(
                          '${row['outstanding_amount'] ?? row['amount']}',
                        ) ??
                        0) <=
                    0))
          return false;
      }
      if (!widget.readOnly && _settle) return true;
      final date = DateTime.tryParse('${row['created_at'] ?? ''}')?.toLocal();
      return date == null ||
          ((from == null || !date.isBefore(from)) &&
              (end == null || date.isBefore(end)));
    }).toList();
  }

  Future<void> _payment([Map<String, dynamic>? debt]) async {
    final branch = EmployeeBranchContext.payment(
      branchId: widget.branchId,
      branchName: widget.branchName,
    );
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EmployeePaymentPage(
          mode: 'debt',
          employeeId: widget.employeeId,
          employeeName: widget.employeeName,
          organizationName: widget.organizationName,
          branchId: branch.id,
          branchName: branch.name,
          direction: _direction,
          kind: debt == null ? 'charge' : 'settlement',
          debt: debt,
        ),
      ),
    );
    if (done == true) await _load();
  }

  Future<void> _range() async {
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (selected != null)
      setState(() {
        _period = 'range';
        _from = selected.start;
        _to = selected.end;
      });
  }

  void _receipt(Map d) {
    final settled = d['kind'] == 'settlement';
    final snapshotName = '${d['employee_name'] ?? widget.employeeName}';
    final organization =
        '${d['organization_name'] ?? widget.organizationName ?? ''}';
    ReceiptModal.show(
      context,
      ReceiptData(
        title: settled ? 'فاتورة سداد دين' : 'فاتورة دين',
        amount:
            num.tryParse('${d['payment_amount'] ?? d['amount']}')?.toDouble() ??
            0,
        currencySymbol: '${d['payment_currency'] ?? d['currency'] ?? 'SAR'}',
        dateTime: '${d['created_at'] ?? ''}'
            .replaceFirst('T', ' ')
            .split('.')
            .first,
        referenceNumber: '${d['invoice_no'] ?? d['id']}',
        senderName: organization,
        receiverName: snapshotName,
        details: [
          if (d['cash_effect'] == 'none')
            const ReceiptDetail(
              label: 'حركة الرصيد',
              value: 'تسجيل دين فقط — لم يتم إيداع أو سحب مبلغ',
            ),
          ReceiptDetail(
            label: 'نوع الدين',
            value: d['direction'] == 'employer_owes'
                ? 'دين للموظف'
                : 'دين على الموظف',
          ),
          if (d['original_debt_invoice'] != null)
            ReceiptDetail(
              label: 'فاتورة الدين الأصلية',
              value: '${d['original_debt_invoice']}',
            ),
          if (d['payment_currency'] != d['currency'] &&
              d['converted_amount'] != null) ...[
            ReceiptDetail(
              label: 'سعر الصرف',
              value:
                  '1 ${d['payment_currency']} = ${d['exchange_rate']} ${d['currency']}',
            ),
            ReceiptDetail(
              label: 'المعادل بعملة الدين',
              value: '${d['converted_amount']} ${d['currency']}',
            ),
          ],
          if (d['remaining_amount'] != null)
            ReceiptDetail(
              label: 'المتبقي في الدين',
              value: '${d['remaining_amount']} ${d['currency']}',
            ),
          if ('${d['branch_name'] ?? ''}'.isNotEmpty)
            ReceiptDetail(label: 'الفرع', value: '${d['branch_name']}'),
          if ('${d['bank_name'] ?? ''}'.isNotEmpty)
            ReceiptDetail(label: 'الحساب', value: '${d['bank_name']}'),
          if ('${d['notes'] ?? ''}'.isNotEmpty)
            ReceiptDetail(label: 'ملاحظات', value: '${d['notes']}'),
        ],
      ),
      protect: _deviceScope == null
          ? null
          : (receipt) => protectEmployeeReceipt(
              _deviceScope,
              '${d['id']}',
              'debts',
              receipt,
            ),
    );
  }

  Widget _periodChip(String label, String key) => ChoiceChip(
    label: Text(
      label,
      style: const TextStyle(fontFamily: 'Cairo', fontSize: 11),
    ),
    selected: _period == key,
    onSelected: (_) => setState(() => _period = key),
  );

  @override
  Widget build(BuildContext context) {
    final local = _deviceScope;
    final copy =
        local != null && local == ref.watch(employeeDeviceSelectionProvider)
        ? ref.watch(employeeFinanceForProvider(widget.employeeId))
        : null;
    final rows = local == null
        ? _debts
        : [
            for (final row
                in (copy?.asData?.value['debts'] as List? ?? const [])
                    .whereType<Map>())
              Map<String, dynamic>.from(row),
          ];
    final filtered = _filtered(rows);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          widget.readOnly ? 'ديوني' : 'ديون ${widget.employeeName}',
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
          : FyonaRefresh(
              onRefresh: local == null
                  ? _load
                  : () async {
                      ref.invalidate(employeeDeviceCopyProvider);
                    },
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (!widget.readOnly && !BranchScope.readOnly) ...[
                    SegmentedButton<bool>(
                      showSelectedIcon: false,
                      style: SegmentedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 12,
                        ),
                        textStyle: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 11,
                          height: 1.5,
                        ),
                      ),
                      segments: const [
                        ButtonSegment(
                          value: false,
                          label: Text(
                            'إنشاء دين',
                            softWrap: true,
                            textAlign: TextAlign.center,
                          ),
                        ),
                        ButtonSegment(
                          value: true,
                          label: Text(
                            'تسديد/تحصيل دين',
                            softWrap: true,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                      selected: {_settle},
                      onSelectionChanged: (values) => setState(() {
                        _settle = values.first;
                        if (_settle) _period = 'all';
                      }),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: _directionButton(
                            'employee_owes',
                            _settle ? 'تحصيل دين على الموظف' : 'دين على الموظف',
                            _settle
                                ? '(تستلم من الموظف المبلغ)'
                                : '(تعطي الموظف مبلغ)',
                            AppColors.danger,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _directionButton(
                            'employer_owes',
                            _settle ? 'تسديد دين للموظف' : 'دين للموظف',
                            _settle
                                ? '(تدفع للموظف المبلغ)'
                                : '(تاخذ من الموظف مبلغ)',
                            AppColors.success,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (!_settle)
                      FilledButton.icon(
                        onPressed: () => _payment(),
                        style: FilledButton.styleFrom(
                          backgroundColor: _direction == 'employee_owes'
                              ? AppColors.danger
                              : AppColors.success,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text(
                          'إنشاء دين جديد',
                          style: TextStyle(fontFamily: 'Cairo'),
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withAlpha(10),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Text(
                          'اختر فاتورة الدين التي تريد تحصيلها أو تسديدها. تقدر تدفع جزءاً منها وبعملة مختلفة.',
                          style: TextStyle(fontFamily: 'Cairo', fontSize: 12),
                        ),
                      ),
                  ] else
                    Wrap(
                      spacing: 8,
                      children: [
                        _sideChip('الكل', 'all', AppColors.primary),
                        _sideChip('دين لك', 'for', AppColors.success),
                        _sideChip('دين عليك', 'on', AppColors.danger),
                      ],
                    ),
                  const SizedBox(height: 14),
                  if (widget.readOnly || !_settle)
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _periodChip('هذا الشهر', 'month'),
                        _periodChip('هذه السنة', 'year'),
                        ActionChip(
                          label: Text(
                            _period == 'range' && _from != null
                                ? '${DateFormat('dd/MM').format(_from!)} - ${DateFormat('dd/MM').format(_to!)}'
                                : 'بين تاريخين',
                          ),
                          onPressed: _range,
                        ),
                        _periodChip('كل الديون', 'all'),
                      ],
                    ),
                  const SizedBox(height: 12),
                  if (_error != null)
                    Text(
                      _error!,
                      style: const TextStyle(color: AppColors.danger),
                    ),
                  if (filtered.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                        !widget.readOnly && _settle
                            ? 'لا توجد فواتير دين متبقية لهذا الاتجاه'
                            : 'ما في ديون في هذه الفترة',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontFamily: 'Cairo'),
                      ),
                    ),
                  for (final row in filtered) _record(row),
                ],
              ),
            ),
    );
  }

  Widget _directionButton(
    String value,
    String label,
    String explanation,
    Color color,
  ) => OutlinedButton(
    style: OutlinedButton.styleFrom(
      foregroundColor: color,
      backgroundColor: _direction == value
          ? color.withAlpha(14)
          : AppColors.surface,
      side: BorderSide(color: _direction == value ? color : AppColors.border),
      minimumSize: const Size(0, 84),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
    ),
    onPressed: () => setState(() => _direction = value),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 11,
            fontWeight: FontWeight.w800,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          explanation,
          textAlign: TextAlign.center,
          softWrap: true,
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 10,
            height: 1.6,
          ),
        ),
      ],
    ),
  );
  Widget _sideChip(String label, String value, Color color) => ChoiceChip(
    label: Text(label),
    selected: _side == value,
    selectedColor: color.withAlpha(24),
    onSelected: (_) => setState(() => _side = value),
  );
  Widget _record(Map<String, dynamic> row) {
    final forEmployee = row['direction'] == 'employer_owes';
    final color = forEmployee ? AppColors.success : AppColors.danger;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        contentPadding: const EdgeInsets.all(12),
        leading: CircleAvatar(
          backgroundColor: color.withAlpha(20),
          child: Icon(
            forEmployee ? Icons.call_received_rounded : Icons.call_made_rounded,
            color: color,
          ),
        ),
        title: Text(
          '${fmtNum(num.tryParse('${row['amount']}') ?? 0)} ${currencySymbol('${row['currency']}')}',
          textDirection: TextDirection.ltr,
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w800,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${row['invoice_no'] ?? row['id']} • ${'${row['created_at']}'.split('T').first}',
              style: const TextStyle(fontSize: 10),
            ),
            Text(
              widget.readOnly
                  ? (forEmployee ? 'دين لك' : 'دين عليك')
                  : (row['kind'] == 'settlement' ? 'عملية سداد' : 'فاتورة دين'),
              style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: color),
            ),
            if (row['kind'] == 'charge' && row['outstanding_amount'] != null)
              Text(
                'المتبقي: ${fmtNum(num.tryParse('${row['outstanding_amount']}') ?? 0)} ${currencySymbol('${row['currency']}')}',
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 11),
              ),
          ],
        ),
        trailing: const Icon(Icons.chevron_left_rounded),
        onTap: () =>
            !widget.readOnly && _settle ? _payment(row) : _receipt(row),
      ),
    );
  }
}
