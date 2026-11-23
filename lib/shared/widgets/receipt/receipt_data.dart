class ReceiptData {
  final String title;
  final double amount;
  final String currencySymbol;
  final String dateTime;
  final String? referenceNumber;
  final String? senderName;
  final String? senderAccount;
  final String? receiverName;
  final String? receiverAccount;
  final List<ReceiptDetail> details;

  const ReceiptData({
    required this.title,
    required this.amount,
    required this.currencySymbol,
    required this.dateTime,
    this.referenceNumber,
    this.senderName,
    this.senderAccount,
    this.receiverName,
    this.receiverAccount,
    this.details = const [],
  });
}

class ReceiptDetail {
  final String label;
  final String value;

  const ReceiptDetail({required this.label, required this.value});
}
