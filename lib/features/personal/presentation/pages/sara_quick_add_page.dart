import 'package:flutter/material.dart';

import '../widgets/add_transaction_sheet.dart';
import 'personal_transactions_page.dart';

/// Deep-link target of Sara's "log today's transactions" notification
/// (`/personal/quick-add?type=expense|income`): shows the transactions
/// history and opens the standard add-transaction sheet on top of it once,
/// right after the first frame. Closing the sheet leaves the user on the
/// history page.
class SaraQuickAddPage extends StatefulWidget {
  final String type;

  /// Test seam: what to render under the sheet.
  final Widget? background;

  /// Test seam: how the sheet is opened.
  final void Function(BuildContext context, String type)? openSheet;

  const SaraQuickAddPage({
    super.key,
    this.type = 'expense',
    this.background,
    this.openSheet,
  });

  static String normalizeType(String? raw) =>
      raw == 'income' ? 'income' : 'expense';

  @override
  State<SaraQuickAddPage> createState() => _SaraQuickAddPageState();
}

class _SaraQuickAddPageState extends State<SaraQuickAddPage> {
  bool _opened = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _opened) return;
      _opened = true;
      final type = SaraQuickAddPage.normalizeType(widget.type);
      final open = widget.openSheet ??
          (ctx, t) => showAddTransactionSheet(ctx, initialType: t);
      open(context, type);
    });
  }

  @override
  Widget build(BuildContext context) {
    return widget.background ?? const PersonalTransactionsPage();
  }
}
