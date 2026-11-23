import 'package:flutter/material.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/receipt/receipt_data.dart';
import '../../../../shared/widgets/receipt/receipt_modal.dart';

void showSalaryReceipt(
  BuildContext context,
  Map payment, {
  required String employeeName,
  String? organizationName,
  String? branchName,
  Widget Function(Widget receipt)? protect,
}) {
  final raw = '${payment['paid_at'] ?? ''}'
      .replaceFirst('T', ' ')
      .split('.')
      .first;
  final amount = num.tryParse('${payment['amount'] ?? 0}') ?? 0;
  final base = num.tryParse('${payment['base_salary'] ?? 0}') ?? 0;
  final remaining = num.tryParse('${payment['remaining_salary'] ?? 0}') ?? 0;
  ReceiptModal.show(
    context,
    ReceiptData(
      title: 'فاتورة راتب',
      amount: amount.toDouble(),
      currencySymbol: '${payment['currency'] ?? 'SAR'}',
      dateTime: raw.isEmpty ? '-' : raw,
      referenceNumber:
          '${payment['invoice_no'] ?? payment['operation_no'] ?? ''}',
      senderName: payment['organization_name'] as String? ?? organizationName,
      receiverName: payment['employee_name'] as String? ?? employeeName,
      details: [
        ReceiptDetail(
          label: 'الفرع',
          value: ('${payment['branch_name'] ?? branchName ?? ''}').isEmpty
              ? 'الفرع الرئيسي'
              : '${payment['branch_name'] ?? branchName}',
        ),
        if ('${payment['bank_name'] ?? ''}'.isNotEmpty)
          ReceiptDetail(label: 'طريقة الدفع', value: '${payment['bank_name']}'),
        if (payment['base_salary'] != null)
          ReceiptDetail(
            label: 'الراتب الأساسي',
            value:
                '${fmtNum(base)} ${currencySymbol('${payment['base_currency'] ?? payment['currency'] ?? 'SAR'}')}',
          ),
        if (payment['remaining_salary'] != null)
          ReceiptDetail(
            label: 'المتبقي من الراتب',
            value:
                '${fmtNum(remaining)} ${currencySymbol('${payment['base_currency'] ?? payment['currency'] ?? 'SAR'}')}',
          ),
        if (payment['converted_amount'] != null)
          ReceiptDetail(label: 'المعادل بعملة الراتب', value:
            '${fmtNum(num.tryParse('${payment['converted_amount']}') ?? 0)} ${payment['base_currency']}'),
        if (payment['exchange_rate'] != null)
          ReceiptDetail(label: 'سعر الصرف المستخدم', value: '${payment['exchange_rate']}'),
        if ('${payment['notes'] ?? ''}'.isNotEmpty)
          ReceiptDetail(label: 'ملاحظات', value: '${payment['notes']}'),
      ],
    ),
    protect: protect,
  );
}
