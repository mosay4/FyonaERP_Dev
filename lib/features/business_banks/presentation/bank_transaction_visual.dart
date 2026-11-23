import 'package:flutter/material.dart';

import '../../../core/localization/app_localizations.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/two_tone_icon.dart';
import '../../../shared/widgets/two_tone_icons.dart';

class BankTransactionVisual {
  BankTransactionVisual(String type) : type = type.trim().toLowerCase();

  final String type;

  bool get isIn => const {
    'deposit',
    'transfer_in',
    'transfer_reversal_in',
    'reconciliation_increase',
    'opening_balance',
  }.contains(type);

  Color get color => isIn ? AppColors.success : AppColors.danger;

  TwoToneIconData get icon => switch (type) {
    'transfer_reversal_in' || 'transfer_reversal_out' => TwoToneIcons.refresh,
    'reconciliation_increase' => TwoToneIcons.reconIncrease,
    'reconciliation_decrease' => TwoToneIcons.reconDecrease,
    'transfer_in' || 'transfer_out' => TwoToneIcons.transfer,
    'deposit' => TwoToneIcons.arrowDown,
    'withdrawal' => TwoToneIcons.arrowUp,
    _ => TwoToneIcons.receipt,
  };

  String label(AppLocalizations l10n) => l10n.translate(switch (type) {
    'deposit' => 'deposit',
    'withdrawal' => 'withdrawal',
    'transfer_in' => 'incomingTransfer',
    'transfer_out' => 'outgoingTransfer',
    'transfer_reversal_in' => 'bankReversalIncoming',
    'transfer_reversal_out' => 'bankReversalOutgoing',
    'reconciliation_increase' => 'reconIncrease',
    'reconciliation_decrease' => 'reconDecrease',
    'opening_balance' => 'txKindOpening',
    _ => 'bankStatement',
  });
}
