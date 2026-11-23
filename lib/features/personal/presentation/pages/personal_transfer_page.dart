import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/receipt/receipt.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../data/models/personal_models.dart';
import '../providers/personal_providers.dart';
import '../providers/receipt_design_provider.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class PersonalTransferPage extends ConsumerStatefulWidget {
  const PersonalTransferPage({super.key});
  @override
  ConsumerState<PersonalTransferPage> createState() => _PersonalTransferPageState();
}

class _PersonalTransferPageState extends ConsumerState<PersonalTransferPage> {
  final _amountController = TextEditingController();
  final _descController = TextEditingController();
  String _statusText = '';
  Color _statusColor = Colors.transparent;
  bool _isLoading = false;
  PersonalBankAccount? _fromAccount;
  PersonalBankAccount? _toAccount;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(personalFinanceProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _amountController.dispose();
    _descController.dispose();
    super.dispose();
  }

  // Include cash alongside banks — user must be able to transfer from/to cash
  List<PersonalBankAccount> _allAccountsWithCash(List<PersonalBankAccount> all) =>
      List<PersonalBankAccount>.from(all);

  Map<String, List<PersonalBankAccount>> _groupByBank(List<PersonalBankAccount> accs) {
    final map = <String, List<PersonalBankAccount>>{};
    for (final a in accs) {
      (map[a.bankName] ??= []).add(a);
    }
    return map;
  }

  Future<void> _pickAccount({required bool isFrom}) async {
    final l10n = AppLocalizations.of(context);
    // Reload first so cash + all banks are fresh (stale state hid cash)
    try {
      await ref.read(personalFinanceProvider.notifier).load();
    } catch (_) {}
    if (!mounted) return;
    final accounts = ref.read(personalFinanceProvider).bankAccounts;
    final bankAccs = _allAccountsWithCash(accounts);
    final grouped = _groupByBank(bankAccs);
    if (grouped.isEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.translate('noBankAccounts'), style: const TextStyle(fontFamily: 'Cairo'))),
      );
      return;
    }

    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _AccountPickerSheet(
        l10n: l10n,
        grouped: grouped,
        allAccounts: bankAccs,
      ),
    );

    if (result != null && mounted) {
      final selected = bankAccs.where((a) => a.id == result).firstOrNull;
      setState(() {
        if (isFrom) {
          _fromAccount = selected;
        } else {
          _toAccount = selected;
        }
      });
    }
  }

  Widget _buildAccountField({
    required String label,
    required PersonalBankAccount? account,
    required bool isFrom,
  }) {
    final l10n = AppLocalizations.of(context);
    return GestureDetector(
      onTap: () => _pickAccount(isFrom: isFrom),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: account != null ? AppColors.primary.withOpacity(0.4) : AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                isFrom ? Icons.account_balance_wallet_outlined : Icons.savings_outlined,
                color: AppColors.primary, size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
                  const SizedBox(height: 2),
                  account != null
                      ? Text(
                          '${account.bankName} — ${account.currency}',
                          style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                        )
                      : Text(
                          l10n.translate('selectAccount'),
                          style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textDisabled),
                        ),
                ],
              ),
            ),
            if (account != null)
              Text(
                fmtNum(account.balance),
                style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.primary),
              ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_left_rounded, color: AppColors.textDisabled, size: 20),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(personalFinanceProvider);

    return state.isLoading
        ? const Center(child: DotsLoader())
        : ListView(
            padding: R.padding(context),
            children: [
              SizedBox(height: R.spacing(context, AppSpacing.lg)),
              Container(
                padding: EdgeInsets.all(R.spacing(context, 16)),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(R.radiusValue(context, 12)),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  children: [
                    _buildAccountField(
                      label: l10n.translate('fromAccountLabel'),
                      account: _fromAccount,
                      isFrom: true,
                    ),
                    SizedBox(height: R.spacing(context, AppSpacing.sm)),
                    TwoToneIcon(data: TwoToneIcons.arrowLeft, size: 32, outlineColor: AppColors.info),
                    SizedBox(height: R.spacing(context, AppSpacing.sm)),
                    _buildAccountField(
                      label: l10n.translate('toAccountLabel'),
                      account: _toAccount,
                      isFrom: false,
                    ),
                  ],
                ),
              ),
              SizedBox(height: R.spacing(context, AppSpacing.md)),
              FyonaTextField(
                controller: _amountController,
                keyboardType: TextInputType.number,
                inputFormatters: [AmountInputFormatter()],
                textAlign: TextAlign.right,
                decoration: InputDecoration(
                  labelText: l10n.translate('amount'),
                  filled: true, fillColor: AppColors.surfaceVariant,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(R.radiusValue(context, 8)),
                    borderSide: BorderSide(color: AppColors.border),
                  ),
                ),
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), color: AppColors.textPrimary),
              ),
              SizedBox(height: R.spacing(context, AppSpacing.sm)),
              FyonaTextField(
                controller: _descController,
                textAlign: TextAlign.right,
                decoration: InputDecoration(
                  labelText: l10n.translate('description'),
                  filled: true, fillColor: AppColors.surfaceVariant,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(R.radiusValue(context, 8)),
                    borderSide: BorderSide(color: AppColors.border),
                  ),
                ),
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), color: AppColors.textPrimary),
              ),
              SizedBox(height: R.spacing(context, AppSpacing.lg)),
              SizedBox(
                width: double.infinity,
                height: R.buttonHeight(context),
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _doTransfer,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isLoading ? AppColors.success : AppColors.info,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(R.radiusValue(context, 8)),
                    ),
                  ),
                  child: Text(
                    _isLoading ? l10n.translate('completed') : l10n.translate('transfer'),
                    style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              if (_statusText.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: R.spacing(context, AppSpacing.sm)),
                  child: Text(_statusText, textAlign: TextAlign.center, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), color: _statusColor)),
                ),
            ],
          );
  }

  void _exportTransferReceipt({
    required String fromName,
    required String fromCurrency,
    required String toName,
    required String toCurrency,
    required double sentAmount,
    required double receivedAmount,
    required double? rate,
    String? description,
  }) {
    final l10n = AppLocalizations.of(context);
    final preset = ref.read(personalReceiptDesignProvider.notifier).getPreset('transfer');
    final fromDisplay = '$fromName ($fromCurrency)';
    final toDisplay = '$toName ($toCurrency)';
    ReceiptModal.show(context, ReceiptData(
      title: l10n.translate('transfer'),
      amount: sentAmount,
      currencySymbol: currencySymbol(fromCurrency),
      dateTime: DateFormat('yyyy/MM/dd HH:mm').format(DateTime.now()),
      senderName: fromDisplay,
      receiverName: toDisplay,
      details: [
        ReceiptDetail(
            label: l10n.translate('transferFrom'),
            value: fromDisplay),
        ReceiptDetail(
            label: l10n.translate('transferSentAmount'),
            value: '${fmtNum(sentAmount)} $fromCurrency'),
        ReceiptDetail(
            label: l10n.translate('transferTo'),
            value: toDisplay),
        ReceiptDetail(
            label: l10n.translate('transferReceivedAmount'),
            value: '${fmtNum(receivedAmount)} $toCurrency'),
        if (fromCurrency.toUpperCase() != toCurrency.toUpperCase() &&
            rate != null &&
            rate > 0)
          ReceiptDetail(
              label: l10n.translate('transferRate'),
              value: '1 $fromCurrency = ${fmtNum(rate)} $toCurrency'),
        if (description != null && description.isNotEmpty) ReceiptDetail(label: l10n.translate('description'), value: description),
        ReceiptDetail(label: l10n.translate('statusDetail'), value: l10n.translate('transferSuccess')),
      ],
    ), preset: preset);
  }

  Future<void> _doTransfer() async {
    final l10n = AppLocalizations.of(context);
    final fromId = _fromAccount?.id;
    final toId = _toAccount?.id;
    final amount = double.tryParse(_amountController.text.replaceAll(',', '')) ?? 0;

    if (fromId == null || toId == null) {
      setState(() { _statusText = l10n.translate('selectAccount'); _statusColor = AppColors.warning; });
      return;
    }
    if (fromId == toId) {
      setState(() { _statusText = l10n.translate('transferSameAccount'); _statusColor = AppColors.warning; });
      return;
    }
    if (amount <= 0) {
      setState(() { _statusText = l10n.translate('transferInvalidAmount'); _statusColor = AppColors.danger; });
      return;
    }

    setState(() { _isLoading = true; _statusText = '${l10n.translate('loading')}...'; _statusColor = AppColors.info; });

    final now = DateTime.now();
    final notifier = ref.read(personalFinanceProvider.notifier);
    String handleError() => l10n.translate('errorOccurred');
    try {
      final outMsg = await notifier.addTransaction(
        type: 'transfer_out',
        amount: amount,
        category: l10n.translate('transfer'),
        description: _descController.text.isNotEmpty ? _descController.text : l10n.translate('transfer'),
        date: now,
        accountId: fromId,
      );
      if (outMsg != null) {
        if (mounted) {
          setState(() { _isLoading = false; _statusText = outMsg.trim().isEmpty ? handleError() : outMsg; _statusColor = AppColors.danger; });
        }
        return;
      }
      final inMsg = await notifier.addTransaction(
        type: 'transfer_in',
        amount: amount,
        category: l10n.translate('transfer'),
        description: _descController.text.isNotEmpty ? _descController.text : l10n.translate('transfer'),
        date: now,
        accountId: toId,
      );
      if (inMsg != null) {
        if (mounted) {
          setState(() { _isLoading = false; _statusText = inMsg.trim().isEmpty ? handleError() : inMsg; _statusColor = AppColors.danger; });
        }
        return;
      }
      if (mounted) {
        setState(() {
          _isLoading = false;
          _statusText = '${l10n.translate('transferSuccess')} ✓';
          _statusColor = AppColors.success;
        });
        // Receipt carries the full operation: both accounts with their
        // currencies, the sent amount, the received amount and the rate.
        // (Both legs execute with the same typed amount; the rate here is
        // informational for cross-currency pairs.)
        final fromCur = (_fromAccount?.currency ?? 'USD').toUpperCase();
        final toCur = (_toAccount?.currency ?? 'USD').toUpperCase();
        double? rate;
        if (fromCur != toCur) {
          try {
            final rates = ref.read(personalFinanceProvider).exchangeRates;
            for (final r in rates) {
              if (r.fromCurrency.toUpperCase() == fromCur &&
                  r.toCurrency.toUpperCase() == toCur) {
                rate = r.rate;
                break;
              }
            }
            if (rate == null) {
              for (final r in rates) {
                if (r.fromCurrency.toUpperCase() == toCur &&
                    r.toCurrency.toUpperCase() == fromCur &&
                    r.rate != 0) {
                  rate = 1.0 / r.rate;
                  break;
                }
              }
            }
          } catch (_) {}
        }
        final received =
            (rate != null && rate > 0) ? amount * rate : amount;
        _exportTransferReceipt(
          fromName: _fromAccount?.bankName ?? '---',
          fromCurrency: fromCur,
          toName: _toAccount?.bankName ?? '---',
          toCurrency: toCur,
          sentAmount: amount,
          receivedAmount: received,
          rate: rate,
          description: _descController.text,
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _statusText = l10n.translate('errorOccurred');
          _statusColor = AppColors.danger;
        });
      }
    }
  }
}

class _AccountPickerSheet extends StatefulWidget {
  final AppLocalizations l10n;
  final Map<String, List<PersonalBankAccount>> grouped;
  final List<PersonalBankAccount> allAccounts;

  const _AccountPickerSheet({
    required this.l10n,
    required this.grouped,
    required this.allAccounts,
  });

  @override
  State<_AccountPickerSheet> createState() => _AccountPickerSheetState();
}

class _AccountPickerSheetState extends State<_AccountPickerSheet> {
  String? _selectedBank;
  String? _selectedAccountId;

  List<PersonalBankAccount> _currenciesFor(String bankName) =>
      widget.allAccounts.where((a) => a.bankName == bankName).toList();

  String _currencyCountLabel(int count) {
    // Via ARB pipeline (same as the sheet title which renders fine),
    // avoids hardcoded-string font subsetting issues. Shows only N عملات.
    try {
      final t = widget.l10n.translate('personalCurrenciesCount', params: {'count': count});
      if (t != 'personalCurrenciesCount') return t;
    } catch (_) {}
    return '$count';
  }

  @override
  Widget build(BuildContext context) {
    final banks = widget.grouped.keys.toList();
    final showCurrencies = _selectedBank != null;
    final currencies = showCurrencies ? _currenciesFor(_selectedBank!) : <PersonalBankAccount>[];

    return StatefulBuilder(
      builder: (ctx, setModalState) {
        return Container(
          height: MediaQuery.of(context).size.height * (showCurrencies ? 0.55 : 0.6),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    if (showCurrencies)
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          setModalState(() {
                            _selectedBank = null;
                            _selectedAccountId = null;
                          });
                        },
                        child: Icon(Icons.arrow_forward_ios_rounded, size: 18, color: AppColors.primary),
                      ),
                    if (showCurrencies) const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        showCurrencies ? _selectedBank! : widget.l10n.translate('selectAccount'),
                        style: TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: showCurrencies
                    ? ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: currencies.length,
                        itemBuilder: (ctx, i) {
                          final a = currencies[i];
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () {
                                HapticFeedback.lightImpact();
                                setModalState(() => _selectedAccountId = a.id);
                                Navigator.pop(ctx, a.id);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                decoration: BoxDecoration(
                                  color: AppColors.surfaceVariant,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 44, height: 44,
                                      decoration: BoxDecoration(
                                        color: AppColors.primary,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Center(
                                        child: Text(
                                          currencyFlagEmoji(a.currency).isEmpty
                                              ? a.currency
                                              : currencyFlagEmoji(a.currency),
                                          style: const TextStyle(fontSize: 22),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(currencyName(a.currency),
                                            style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                                          const SizedBox(height: 3),
                                          Text('${widget.l10n.translate('balance')}: ${fmtNum(a.balance)}',
                                            style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: AppColors.textSecondary)),
                                        ],
                                      ),
                                    ),
                                    Icon(Icons.chevron_left_rounded, color: AppColors.textDisabled, size: 22),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: banks.length,
                        itemBuilder: (ctx, i) {
                          final bankName = banks[i];
                          final accs = widget.grouped[bankName]!;
                          final currencyCount = accs.map((a) => a.currency).toSet().length;
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () {
                                HapticFeedback.lightImpact();
                                if (accs.length == 1) {
                                  Navigator.pop(ctx, accs.first.id);
                                } else {
                                  setModalState(() => _selectedBank = bankName);
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                decoration: BoxDecoration(
                                  color: AppColors.surfaceVariant,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 44, height: 44,
                                      decoration: BoxDecoration(
                                        color: AppColors.primary,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Icon(Icons.account_balance_rounded, color: Colors.white, size: 22),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(bankName,
                                            style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                                          const SizedBox(height: 3),
                                          Text(_currencyCountLabel(currencyCount),
                                             style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600, fontSize: 11, color: AppColors.textSecondary)),
                                        ],
                                      ),
                                    ),
                                    Icon(Icons.chevron_left_rounded, color: AppColors.textDisabled, size: 22),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
