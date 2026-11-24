import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../../../shared/widgets/currency_selector.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/account_type_bar.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/bank_gradients.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../../../shared/widgets/app_icon_badge.dart';
import '../../../../shared/widgets/receipt/receipt.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import '../../data/models/personal_models.dart';
import '../../domain/services/personal_finance_service.dart';
import '../../di/personal_providers.dart';
import '../providers/personal_providers.dart';
import '../providers/receipt_design_provider.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/features/auth/domain/services/biometric_service.dart';
import 'package:fyona_flutter/features/auth/presentation/providers/auth_provider.dart';
import 'package:fyona_flutter/features/auth/presentation/providers/biometric_provider.dart';
import 'package:fyona_flutter/features/auth/presentation/widgets/app_pin_sheet.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

const _accountTypes = {
  'checking': 'accountTypeChecking',
  'savings': 'accountTypeSavings',
};

/// Whether the "delete bank completely" action is offered for [bankName].
/// Cash can never be deleted as a whole in ANY locale spelling — users may
/// only remove individual cash currencies (always keeping at least one).
bool canDeleteBankCompletely(String bankName) => !isCashAccount(bankName);

class PersonalBanksPage extends ConsumerStatefulWidget {
  final bool openTransfer;
  const PersonalBanksPage({super.key, this.openTransfer = false});
  @override
  ConsumerState<PersonalBanksPage> createState() => _PersonalBanksPageState();
}

class _PersonalBanksPageState extends ConsumerState<PersonalBanksPage> {
  bool _showForm = false;
  bool _showTransfer = false;
  bool _savingBank = false;
  bool _transferring = false;
  final Set<int> _expandedBanks = {};
  String? _editingId;
  String? _editingNotes;
  // Hero total display currency defaults to USD always (user-changeable,
  // persisted separately).
  String _heroCurrency = 'USD';
  final ScrollController _scrollCtrl = ScrollController();
  final GlobalKey _formKey = GlobalKey();
  final GlobalKey _transferKey = GlobalKey();

  final _nameCtrl = TextEditingController();

  /// Only «add a currency to this bank» fixes the bank name; a new bank's
  /// name stays editable however often the user leaves and returns.
  bool _bankNameFixed = false;
  final _balanceCtrl = TextEditingController();
  String _selectedCurrency = '';
  String _selectedType = 'checking';

  final _transferFromCtrl = TextEditingController();
  final _transferToCtrl = TextEditingController();
  String? _transferFromId;
  String? _transferToId;
  double _transferAmount = 0;

  static const _heroCurrencyKey = 'banks_hero_currency';

  @override
  void initState() {
    super.initState();
    if (widget.openTransfer) {
      _showTransfer = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_heroCurrencyKey);
      if (saved != null && mounted) setState(() => _heroCurrency = saved);
      ref.read(personalFinanceProvider.notifier).load();
      if (widget.openTransfer && mounted) {
        setState(() {
          _showTransfer = true;
          _showForm = false;
          _expandedBanks.clear();
        });
        _scrollToForm();
      }
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _balanceCtrl.dispose();
    _transferFromCtrl.dispose();
    _transferToCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToForm() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _formKey.currentContext ?? _transferKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, duration: Duration(milliseconds: 300), curve: Curves.easeOutCubic, alignment: 0.1);
      }
    });
  }

  void _resetForm() {
    _nameCtrl.clear();
    _bankNameFixed = false;
    _balanceCtrl.clear();
    // No preselected currency: the field shows the "choose currency" hint
    // until the user picks one (edit mode fills the current value).
    _selectedCurrency = '';
    _selectedType = 'checking';
    _editingId = null;
    _editingNotes = null;
    _showForm = false;
  }

  void _addCurrencyToBank(String bankName) {
    _resetForm();
    _nameCtrl.text = bankName;
    _bankNameFixed = true;
    _editingId = null;
    setState(() {
      _showForm = true;
      _showTransfer = false;
      _expandedBanks.add(bankName.hashCode);
    });
    _scrollToForm();
  }

  Future<void> _saveBank() async {
    if (_savingBank) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    if (_selectedCurrency.isEmpty) {
      showSnackbar(context, message: AppLocalizations.of(context).translate('selectCurrency'), color: AppColors.warning);
      return;
    }
    setState(() => _savingBank = true);
    var balance = double.tryParse(_balanceCtrl.text.replaceAll(',', '')) ?? 0;
    final type = (name == 'كاش' || name == 'Cash') ? 'cash' : _selectedType;
    // Re-adding a previously removed cash currency restores its stashed
    // balance unless the user typed an explicit one.
    if (_editingId == null && isCashAccount(name) && balance == 0) {
      try {
        final stashed = await ref
            .read(personalFinanceServiceProvider)
            .takeStashedCashBalance(_selectedCurrency);
        if (stashed != null && stashed > 0) balance = stashed;
      } catch (_) {}
    }
    final notifier = ref.read(personalFinanceProvider.notifier);

    // Validate: cannot create duplicate currency+type in same bank.
    // YER/YER_NEW share one bucket and 'cash' counts as 'checking', so the
    // same money can only repeat with a genuinely different account type.
    if (_editingId == null) {
      final existing = ref.read(personalFinanceProvider).bankAccounts;
      final duplicate = existing.any((a) =>
          a.bankName == name &&
          PersonalFinanceService.cashBucket(a.currency) ==
              PersonalFinanceService.cashBucket(_selectedCurrency) &&
          PersonalFinanceService.cashTypeKey(a.accountType) ==
              PersonalFinanceService.cashTypeKey(type));
      if (duplicate) {
        final l10n = AppLocalizations.of(context);
        final typeLabel = l10n.translate(_accountTypes[type] ?? 'accountTypeChecking');
        showSnackbar(context, message: l10n.translate('duplicateAccountError', params: {'currency': _selectedCurrency, 'type': typeLabel}), color: AppColors.warning);
        return;
      }
    }

    try {
      if (_editingId != null) {
        await notifier.updateBankAccount(_editingId!, bankName: name, currency: _selectedCurrency, balance: balance, notes: _editingId != null ? _editingNotes : null, accountType: type);
      } else {
        await notifier.addBankAccount(bankName: name, currency: _selectedCurrency, openingBalance: balance, notes: null, accountType: type);
      }
      setState(() => _resetForm());
      _savingBank = false;
    } catch (e) {
      _savingBank = false;
      if (mounted) {
        showSnackbar(context, message: e.toString(), color: AppColors.danger);
      }
    }
  }

  void _editBank(PersonalBankAccount a) {
    _nameCtrl.text = a.bankName;
    _balanceCtrl.text = a.balance.toStringAsFixed(0);
    _editingNotes = a.notes;
    _selectedCurrency = a.currency;
    // Cash accounts always get type 'cash' in _saveBank, but the dropdown
    // only has checking/savings � use 'checking' to avoid DropdownButton error
    _selectedType = (a.bankName == '���' || a.bankName == 'Cash') ? 'checking' : a.accountType;
    _editingId = a.id;
    setState(() => _showForm = true);
    _scrollToForm();
  }

  Future<void> _deleteBank(String id, String name) async {
    // Cash currencies are removed through the dedicated flow (vault snapshot
    // + transactions), while cash itself can never be fully deleted.
    final accounts = ref.read(personalFinanceProvider).bankAccounts;
    PersonalBankAccount? target;
    for (final a in accounts) {
      if (a.id == id) {
        target = a;
        break;
      }
    }
    if (target != null && isCashAccount(target.bankName)) {
      await _deleteCashCurrency(target);
      return;
    }
    final l10n = AppLocalizations.of(context);
    final confirm = await showConfirmDialog(context, title: l10n.translate('deleteAccountTitle'), message: l10n.translate('confirmDeleteAccount', params: {'name': name}), confirmText: l10n.translate('delete'), danger: true);
    if (confirm != true || !mounted) return;
    final verified = await verifySensitiveAction(context, ref);
    if (!verified) return;
    await ref.read(personalFinanceProvider.notifier).deleteBankAccount(id);
    if (mounted) setState(() {});
  }

  /// Deletes one cash currency (account + its transactions, stashed for
  /// restore). The last remaining cash account is protected: cash itself
  /// can never be deleted.
  Future<void> _deleteCashCurrency(PersonalBankAccount target) async {
    final l10n = AppLocalizations.of(context);
    final cashCount = ref
        .read(personalFinanceProvider)
        .bankAccounts
        .where((a) => isCashAccount(a.bankName))
        .length;
    if (cashCount <= 1) {
      showSnackbar(
        context,
        message: l10n.translate('cannotDeleteLastCash'),
        color: AppColors.warning,
      );
      return;
    }
    final confirm = await showConfirmDialog(
      context,
      title: l10n.translate('deleteAccountTitle'),
      message: l10n.translate('confirmDeleteAccount',
          params: {'name': '${target.bankName} (${target.currency})'}),
      confirmText: l10n.translate('delete'),
      danger: true,
    );
    if (confirm != true || !mounted) return;
    final verified = await verifySensitiveAction(context, ref);
    if (!verified) return;
    await ref
        .read(personalFinanceServiceProvider)
        .removeCashCurrency(target.currency);
    if (mounted) setState(() {});
  }

  Future<void> _deleteBankCompletely(String bankName) async {
    final l10n = AppLocalizations.of(context);
    // Backstop: cash can never be deleted as a whole in any locale
    // spelling, no matter which path reaches here. Individual cash
    // currencies are removed only via _deleteCashCurrency (which always
    // keeps at least one).
    if (isCashAccount(bankName)) {
      if (mounted) {
        showSnackbar(
          context,
          message: l10n.translate('cannotDeleteLastCash'),
          color: AppColors.warning,
        );
      }
      return;
    }
    // Capture notifiers before any async gap to avoid _dependents.isEmpty
    final financeNotifier = ref.read(personalFinanceProvider.notifier);
    final financeState = ref.read(personalFinanceProvider);
    // 1) Show warning dialog first
    final confirm = await showConfirmDialog(context, title: l10n.translate('deleteBankCompletely'), message: l10n.translate('confirmDeleteBank', params: {'name': bankName}), confirmText: l10n.translate('delete'), danger: true);
    if (confirm != true || !mounted) return;

    // 2) Identity gate: device biometric when enabled, else the app PIN.
    final verified = await verifySensitiveAction(
      context,
      ref,
      reason: l10n.translate('authenticateToDeleteBank'),
    );
    if (!verified) return;

    // 3) Delete all accounts for this bank
    if (!mounted) return;
    final accounts = financeState.bankAccounts.where((a) => a.bankName == bankName).toList();
    // Re-read to get latest in case state changed, but use captured notifier
    final currentAccounts = ref.read(personalFinanceProvider).bankAccounts.where((a) => a.bankName == bankName).toList();
    final toDelete = currentAccounts.isNotEmpty ? currentAccounts : accounts;
    await financeNotifier.deleteBankAccountsBatch(toDelete.map((a) => a.id).toList());
  }

  void _exportBankReceipt(PersonalBankAccount acc) {
    final l10n = AppLocalizations.of(context);
    final preset = ref.read(personalReceiptDesignProvider.notifier).getPreset('bank');
    final typeLabels = {'checking': 'accountTypeChecking', 'savings': 'accountTypeSavings', 'credit': 'accountTypeCredit', 'wallet': 'accountTypeWallet'};
    ReceiptModal.show(context, ReceiptData(
      title: l10n.translate('bankStatementCertificate'),
      amount: acc.balance,
      currencySymbol: currencySymbol(acc.currency),
      dateTime: DateFormat('yyyy/MM/dd HH:mm').format(DateTime.now()),
      senderName: acc.bankName,
      senderAccount: l10n.translate(typeLabels[acc.accountType] ?? 'accountTypeChecking'),
      details: [
        ReceiptDetail(label: l10n.translate('accountTypeLabel'), value: l10n.translate(typeLabels[acc.accountType] ?? 'accountTypeChecking')),
        ReceiptDetail(label: l10n.translate('currencyLabel'), value: acc.currency),
        if (acc.notes != null && acc.notes!.isNotEmpty) ReceiptDetail(label: l10n.translate('notesLabel'), value: acc.notes!),
      ],
    ), preset: preset);
  }

  Future<void> _doTransfer() async {
    if (_transferring) return;
    final l10n = AppLocalizations.of(context);
    if (_transferFromId == null || _transferToId == null) return;
    if (_transferAmount <= 0) {
      showSnackbar(context, message: l10n.translate('transferInvalidAmount'));
      return;
    }
    if (_transferFromId == _transferToId) {
      showSnackbar(context, message: l10n.translate('transferSameAccount'));
      return;
    }
    setState(() => _transferring = true);
    final accounts = ref.read(personalFinanceProvider).bankAccounts;
    final fromAcc = accounts.firstWhere((a) => a.id == _transferFromId);
    final toAcc = accounts.firstWhere((a) => a.id == _transferToId);
    if (fromAcc.balance < _transferAmount) {
      setState(() => _transferring = false);
      showSnackbar(context, message: l10n.translate('transferInsufficientBalance', params: {'balance': fmtNum(fromAcc.balance), 'currency': fromAcc.currency}), color: AppColors.danger);
      return;
    }
    double rate = 1.0;
    if (fromAcc.currency != toAcc.currency) {
      final engine = ref.read(currencyEngineProvider);
      final foundRate = engine.getRate(fromAcc.currency, toAcc.currency);
      if (foundRate == null || foundRate <= 0) {
        showSnackbar(context, message: l10n.translate('noExchangeRate', params: {'from': fromAcc.currency, 'to': toAcc.currency}));
        return;
      }
      rate = foundRate;
    }
    final ok = await ref.read(personalFinanceProvider.notifier).transferBetweenAccounts(
      fromId: _transferFromId!, toId: _transferToId!, amount: _transferAmount,
      fromCurrency: fromAcc.currency, toCurrency: toAcc.currency, rate: rate,
    );
    if (ok && mounted) {
      showSnackbar(context, message: l10n.translate('transferSuccess'));
      setState(() {
        _showTransfer = false;
        _transferFromId = null;
        _transferToId = null;
        _transferAmount = 0;
      });
    }
    _transferring = false;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(personalFinanceProvider);
    final accounts = state.bankAccounts;
    final grouped = _groupedByBank(accounts);
    final l10n = AppLocalizations.of(context);

    return state.isLoading
          ? Center(child: DotsLoader())
          : FyonaRefresh(
              color: AppColors.primary,
              backgroundColor: AppColors.surface,
              onRefresh: () async => await ref.read(personalFinanceProvider.notifier).load(),
              child: SingleChildScrollView(
              controller: _scrollCtrl,
              physics: AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(20, 16, 20, 100),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _HeroCard(totalBalance: state.walletTotalBalance, walletCurrency: state.walletCurrency, bankCount: grouped.length, accountCount: accounts.length, selectedCurrency: _heroCurrency, onCurrencyChanged: (v) {
                  setState(() => _heroCurrency = v);
                  SharedPreferences.getInstance().then((p) => p.setString(_heroCurrencyKey, v));
                }),
                SizedBox(height: 16),
                _buildActions(),
                if (_showForm) ...[SizedBox(height: 16), _buildForm()],
                if (_showTransfer) ...[SizedBox(height: 16), _buildTransferForm(accounts)],
                if (accounts.isNotEmpty) ...[
                  SizedBox(height: 20),
                  _SectionLabel(title: l10n.translate('bankAccountsTitle'), icon: TwoToneIcons.bank, trailing: '${grouped.length}'),
                  SizedBox(height: 12),
                  ...grouped.entries.map((e) {
                    final convertedTotal = ref.read(personalFinanceProvider.notifier).convertAccountsToWallet(e.value);
                    final engine = ref.read(currencyEngineProvider);
                    final displayTotal = _heroCurrency == state.walletCurrency
                        ? convertedTotal
                        : engine.convert(convertedTotal, state.walletCurrency, _heroCurrency);
                    return _BankGroupCard(
                      bankName: e.key, accounts: e.value, convertedTotal: displayTotal, primaryCurrency: _heroCurrency,
                      expanded: _expandedBanks.contains(e.key.hashCode),
                      onToggle: () => setState(() {
                        if (_expandedBanks.contains(e.key.hashCode)) _expandedBanks.remove(e.key.hashCode);
                        else {
                          _expandedBanks.add(e.key.hashCode);
                          _showForm = false;
                          _showTransfer = false;
                        }
                      }),
                      onEdit: _editBank,
                      onDelete: _deleteBank,
                      onExport: (a) => _exportBankReceipt(a),
                      onAddCurrency: () => _addCurrencyToBank(e.key),
                      onDeleteBank: () => _deleteBankCompletely(e.key),
                    );
                  }),
                ] else ...[
                  SizedBox(height: 48),
                  Center(child: Column(children: [
                    AppIconBadge(icon: TwoToneIcons.bank.outline, size: 72, iconSize: 32, backgroundColor: AppColors.surface, borderColor: AppColors.border, accentColor: AppColors.textPlaceholder),
                    SizedBox(height: 16),
                    Text(l10n.translate('noBankAccounts'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
                    SizedBox(height: 6),
                    Text(l10n.translate('addNewBankToStart'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textDisabled)),
                  ])),
                ],
              ]),
              ),
            );
  }

  Widget _buildActions() {
    final l10n = AppLocalizations.of(context);
    return Column(children: [
      Row(children: [
        Expanded(child: ElevatedButton.icon(
          onPressed: () {
            setState(() {
              _showTransfer = false;
              _showForm = !_showForm;
              if (_showForm) {
                _expandedBanks.clear();
                _editingId = null; _nameCtrl.clear(); _bankNameFixed = false; _balanceCtrl.clear(); _selectedCurrency = ''; _selectedType = 'checking';
              }
            });
            if (_showForm) _scrollToForm();
          },
          icon: TwoToneIcon(data: _showForm ? TwoToneIcons.delete : TwoToneIcons.plus, size: 18, outlineColor: Colors.white),
          label: Text(_showForm ? l10n.translate('close') : l10n.translate('addBank'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: Colors.white)),
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, padding: EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        )),
        SizedBox(width: 10),
        Expanded(child: ElevatedButton.icon(
          onPressed: () {
            setState(() {
              _showForm = false;
              _showTransfer = !_showTransfer;
              if (_showTransfer) _expandedBanks.clear();
            });
            if (_showTransfer) _scrollToForm();
          },
          icon: TwoToneIcon(data: TwoToneIcons.transfer, size: 18, outlineColor: Colors.white),
          label: Text(_showTransfer ? l10n.translate('close') : l10n.translate('muzarfa'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: Colors.white)),
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.primaryDark, padding: EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        )),
      ]),
    ]);
  }

  Widget _buildForm() {
    final l10n = AppLocalizations.of(context);
    return Container(
      key: _formKey,
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.border, width: 0.5)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AppIconBadge(icon: TwoToneIcons.bank.outline, size: 40, iconSize: 20, backgroundColor: AppColors.primary.withAlpha(20), borderColor: AppColors.primary.withAlpha(40)),
          SizedBox(width: 12),
          Text(_editingId != null ? l10n.translate('editAccount') : (_nameCtrl.text.isNotEmpty ? l10n.translate('addCurrencyFor', params: {'bank': _nameCtrl.text}) : l10n.translate('addNewAccount')), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        ]),
        SizedBox(height: 20),
        _InputField(controller: _nameCtrl, label: l10n.translate('bankNameLabel'), prefixIcon: TwoToneIcons.bank, readOnly: _editingId == null && _bankNameFixed),
        SizedBox(height: 12),
        _InputField(controller: _balanceCtrl, label: _editingId == null ? l10n.translate('openingBalance') : l10n.translate('balanceLabel'), keyboardType: TextInputType.number, prefixIcon: TwoToneIcons.money, isAmount: true),
        SizedBox(height: 12),
        CurrencySelector(label: l10n.translate('currencyLabel'), value: _selectedCurrency, showCode: false, hint: l10n.translate('selectCurrency'), onChanged: (v) => setState(() => _selectedCurrency = v)),
        SizedBox(height: 12),
        Container(
          height: 52,
          padding: EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border, width: 0.5)),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _selectedType, isExpanded: true,
              dropdownColor: AppColors.surface,
              hint: Text(l10n.translate('accountTypeLabel'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textDisabled)),
              style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textPrimary),
              items: _accountTypes.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(l10n.translate(e.value)))).toList(),
              onChanged: (v) => setState(() => _selectedType = v ?? 'checking'),
            ),
          ),
        ),
        SizedBox(height: 20),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(
            onPressed: () => setState(() => _resetForm()),
            child: Text(l10n.translate('cancel'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textDisabled)),
          ),
          SizedBox(width: 8),
          Flexible(
            child: ElevatedButton(
              onPressed: _saveBank,
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), elevation: 0),
              child: Text(_editingId != null ? l10n.translate('update') : l10n.translate('add'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: Colors.white)),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _buildTransferForm(List<PersonalBankAccount> accounts) {
    final l10n = AppLocalizations.of(context);
    return Container(
      key: _transferKey,
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.primaryDark.withAlpha(60), width: 1)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AppIconBadge(icon: TwoToneIcons.transfer.outline, size: 40, iconSize: 20, backgroundColor: AppColors.primaryDark.withAlpha(20), borderColor: AppColors.primaryDark.withAlpha(40)),
          SizedBox(width: 12),
          Text(l10n.translate('transferBetweenAccounts'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        ]),
        SizedBox(height: 16),
        _buildAccountDropdown(l10n.translate('fromAccount'), accounts, _transferFromId, (v) {
          setState(() => _transferFromId = v);
          _calculateConvertedAmount(accounts);
        }),
        SizedBox(height: 12),
        Center(child: TwoToneIcon(data: TwoToneIcons.arrowDown, size: 24, outlineColor: AppColors.primary)),
        SizedBox(height: 12),
        _buildAccountDropdown(l10n.translate('toAccount'), accounts, _transferToId, (v) {
          setState(() => _transferToId = v);
          _calculateConvertedAmount(accounts);
        }),
        SizedBox(height: 12),
        _InputField(
          label: l10n.translate('amountLabel'), keyboardType: TextInputType.number,
          prefixIcon: TwoToneIcons.money,
          onChanged: (v) {
            _transferAmount = double.tryParse(v) ?? 0;
            _calculateConvertedAmount(accounts);
          },
        ),
        if (_transferFromId != null && _transferToId != null && _transferAmount > 0) ...[
          SizedBox(height: 12),
          _buildConversionPreview(accounts),
        ],
        SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _doTransfer,
            icon: TwoToneIcon(data: TwoToneIcons.transfer, size: 18, outlineColor: Colors.white),
            label: Text(l10n.translate('transfer'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: Colors.white)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              padding: EdgeInsets.symmetric(vertical: 14, horizontal: 24),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
      ]),
    );
  }

  double? _convertedAmount;
  double? _currentRate;

  void _calculateConvertedAmount(List<PersonalBankAccount> accounts) {
    if (_transferFromId == null || _transferToId == null || _transferAmount <= 0) {
      setState(() { _convertedAmount = null; _currentRate = null; });
      return;
    }
    final fromAcc = accounts.firstWhere((a) => a.id == _transferFromId);
    final toAcc = accounts.firstWhere((a) => a.id == _transferToId);
    if (fromAcc.currency == toAcc.currency) {
      setState(() { _convertedAmount = _transferAmount; _currentRate = 1.0; });
      return;
    }
    final engine = ref.read(currencyEngineProvider);
    final rate = engine.getRate(fromAcc.currency, toAcc.currency);
    if (rate != null && rate > 0) {
      final r = rate;
      setState(() { _convertedAmount = _transferAmount * r; _currentRate = r; });
    } else {
      setState(() { _convertedAmount = null; _currentRate = null; });
    }
  }

  Widget _buildConversionPreview(List<PersonalBankAccount> accounts) {
    final fromAcc = accounts.firstWhere((a) => a.id == _transferFromId);
    final toAcc = accounts.firstWhere((a) => a.id == _transferToId);
    final l10n = AppLocalizations.of(context);
    final sym1 = currencySymbol(fromAcc.currency);
    final sym2 = currencySymbol(toAcc.currency);
    if (_currentRate != null && _convertedAmount != null) {
      return Container(
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.primary.withAlpha(10), borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.primary.withAlpha(30))),
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(l10n.translate('exchangeRate'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.textSecondary)),
            Text('1 ${fromAcc.currency} = ${fmtNum(_currentRate!)} ${toAcc.currency}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), fontWeight: FontWeight.w700, color: AppColors.primary)),
          ]),
          SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('${fmtNum(_transferAmount)} $sym1', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            Icon(Icons.arrow_forward, size: 16, color: AppColors.primary),
            Text('${fmtNum(_convertedAmount!)} $sym2', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w700, color: AppColors.success)),
          ]),
        ]),
      );
    }
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.warning.withAlpha(15), borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.warning.withAlpha(30))),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.warning),
        SizedBox(width: 8),
        Expanded(child: Text(l10n.translate('noExchangeRate', params: {'from': fromAcc.currency, 'to': toAcc.currency}), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: AppColors.warning))),
      ]),
    );
  }

  Widget _buildAccountDropdown(String label, List<PersonalBankAccount> accounts, String? value, ValueChanged<String?> onChanged) {
    final l10n = AppLocalizations.of(context);
    // Include cash alongside banks so transfer from/to cash works
    final bankAccs = List<PersonalBankAccount>.from(accounts);
    PersonalBankAccount? selected;
    if (value != null) {
      for (final a in bankAccs) {
        if (a.id == value) { selected = a; break; }
      }
    }
    return GestureDetector(
      onTap: () async {
        final grouped = _groupedByBank(bankAccs);
        final result = await showModalBottomSheet<String>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (ctx) => _TransferAccountPickerSheet(
            l10n: l10n,
            grouped: grouped,
            allAccounts: bankAccs,
          ),
        );
        if (result != null) {
          onChanged(result);
        }
      },
      child: Container(
        height: 52,
        padding: EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border, width: 0.5)),
        child: Row(children: [
          Expanded(
            child: selected != null
                ? Text('${selected.bankName} - ${selected.currency} (${fmtNum(selected.balance)})', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textPrimary))
                : Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textDisabled)),
          ),
          Icon(Icons.chevron_left_rounded, color: AppColors.textDisabled, size: 20),
        ]),
      ),
    );
  }

  Map<String, List<PersonalBankAccount>> _groupedByBank(List<PersonalBankAccount> accounts) {
    final map = <String, List<PersonalBankAccount>>{};
    for (final a in accounts) {
      map.putIfAbsent(a.bankName, () => []).add(a);
    }
    return map;
  }
}

// ????????????????????????????????????????????????????????????
//  TRANSFER ACCOUNT PICKER � two-step: banks first, then currencies
// ????????????????????????????????????????????????????????????
class _TransferAccountPickerSheet extends StatefulWidget {
  final AppLocalizations l10n;
  final Map<String, List<PersonalBankAccount>> grouped;
  final List<PersonalBankAccount> allAccounts;

  const _TransferAccountPickerSheet({
    required this.l10n,
    required this.grouped,
    required this.allAccounts,
  });

  @override
  State<_TransferAccountPickerSheet> createState() => _TransferAccountPickerSheetState();
}

class _TransferAccountPickerSheetState extends State<_TransferAccountPickerSheet> {
  String? _selectedBank;

  List<PersonalBankAccount> _currenciesFor(String bankName) =>
      widget.allAccounts.where((a) => a.bankName == bankName).toList();

  String _currencyCountLabel(int count) {
    // Via ARB pipeline (same as sheet title which renders fine) — N عملات only.
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
                    onTap: () => setState(() => _selectedBank = null),
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
                          onTap: () => Navigator.pop(ctx, a.id),
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
                            if (accs.length == 1) {
                              Navigator.pop(ctx, accs.first.id);
                            } else {
                              setState(() => _selectedBank = bankName);
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
  }
}

// ????????????????????????????????????????????????????????????
//  HERO CARD
// ????????????????????????????????????????????????????????????
class _HeroCard extends StatelessWidget {
  final double totalBalance;
  final String walletCurrency;
  final int bankCount;
  final int accountCount;
  final String selectedCurrency;
  final ValueChanged<String> onCurrencyChanged;
  const _HeroCard({required this.totalBalance, required this.walletCurrency, required this.bankCount, required this.accountCount, required this.selectedCurrency, required this.onCurrencyChanged});

  double _getDisplayAmount(BuildContext context) {
    if (selectedCurrency == walletCurrency) return totalBalance;
    final engine = ProviderScope.containerOf(context).read(currencyEngineProvider);
    final converted = engine.convert(totalBalance, walletCurrency, selectedCurrency);
    return converted != 0 ? converted : totalBalance;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final displayAmount = _getDisplayAmount(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment(-1.0, -1.0), end: Alignment(1.5, 1.5), colors: [Color(0xFFC01838), AppColors.primary, Color(0xFF7A1020)]),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: AppColors.primary.withAlpha(100), blurRadius: 32, offset: Offset(0, 12)), BoxShadow(color: AppColors.primaryDark.withAlpha(60), blurRadius: 48, offset: Offset(0, 24))],
      ),
      child: Stack(children: [
        Positioned(top: -30, right: -20, child: Container(width: 100, height: 100, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withAlpha(15)))),
        Positioned(bottom: -40, left: -10, child: Container(width: 120, height: 120, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withAlpha(10)))),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AppIconBadge(icon: TwoToneIcons.bank.outline, size: 44, iconSize: 22, backgroundColor: Colors.white.withAlpha(20), borderColor: Colors.white.withAlpha(30)),
            SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l10n.translate('totalBalances'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), fontWeight: FontWeight.w500, color: Colors.white.withAlpha(170))),
              SizedBox(height: 2),
              Text(l10n.translate('banksCountLine', params: {'banks': '$bankCount', 'accounts': '$accountCount'}), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: Colors.white.withAlpha(120))),
            ])),
            GestureDetector(
              onTap: () => _showCurrencyPicker(context),
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.white.withAlpha(25), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white.withAlpha(40))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(currencySymbol(selectedCurrency), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), fontWeight: FontWeight.w700, color: Colors.white)),
                  SizedBox(width: 2),
                  Icon(Icons.expand_more, size: 14, color: Colors.white.withAlpha(180)),
                ]),
              ),
            ),
          ]),
          SizedBox(height: 24),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  fmtNum(displayAmount),
                  style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 34), fontWeight: FontWeight.w700, color: Colors.white),
                ),
                SizedBox(width: 6),
                Text(
                  currencySymbol(selectedCurrency),
                  style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 18), fontWeight: FontWeight.w500, color: Colors.white.withAlpha(180)),
                ),
              ],
            ),
          ),
        ]),
      ]),
    );
  }

  void _showCurrencyPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(AppLocalizations.of(context).translate('currencyLabel'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          SizedBox(height: 12),
          CurrencySelector(
            label: '',
            value: selectedCurrency,
            showCode: false,
            onChanged: (v) { onCurrencyChanged(v); Navigator.pop(ctx); },
          ),
        ]),
      ),
    );
  }
}

// ????????????????????????????????????????????????????????????
//  SECTION LABEL
// ????????????????????????????????????????????????????????????
class _SectionLabel extends StatelessWidget {
  final String title;
  final TwoToneIconData? icon;
  final String? trailing;
  const _SectionLabel({required this.title, this.icon, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      if (icon != null) ...[
        AppIconBadge(icon: icon!.outline, size: 32, iconSize: 16, backgroundColor: AppColors.primary.withAlpha(20), borderColor: AppColors.primary.withAlpha(40)),
        SizedBox(width: 10),
      ],
      Text(title, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
      if (trailing != null) ...[
        Spacer(),
        Container(padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(6)), child: Text(trailing!, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), fontWeight: FontWeight.w600, color: AppColors.textDisabled))),
      ],
    ]);
  }
}

// ????????????????????????????????????????????????????????????
//  BANK GROUP CARD
// ????????????????????????????????????????????????????????????
class _BankGroupCard extends StatelessWidget {
  final String bankName;
  final List<PersonalBankAccount> accounts;
  final double convertedTotal;
  final String primaryCurrency;
  final bool expanded;
  final VoidCallback onToggle;
  final Function(PersonalBankAccount) onEdit;
  final Function(String, String) onDelete;
  final Function(PersonalBankAccount) onExport;
  final VoidCallback? onAddCurrency;
  final VoidCallback? onDeleteBank;

  const _BankGroupCard({required this.bankName, required this.accounts, required this.convertedTotal, required this.primaryCurrency, required this.expanded, required this.onToggle, required this.onEdit, required this.onDelete, required this.onExport, this.onAddCurrency, this.onDeleteBank});

  @override
  Widget build(BuildContext context) {
    final g = bankGradients[bankGradientIndex(bankName)];
    final l10n = AppLocalizations.of(context);

    return Container(
      margin: EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.black.withAlpha(30), blurRadius: 20, offset: Offset(0, 8))]),
      child: Column(children: [
        GestureDetector(
          onTap: () => context.pushNamed('personalBankDetail', pathParameters: {'bankName': bankName}),
          child: AnimatedContainer(
            duration: Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment(1, -0.5), end: Alignment(-1, 0.5), colors: g),
              borderRadius: expanded ? BorderRadius.vertical(top: Radius.circular(16)) : BorderRadius.circular(16),
            ),
            child: Row(children: [
              AppIconBadge(icon: TwoToneIcons.bank.outline, size: 42, iconSize: 20, backgroundColor: Colors.white.withAlpha(20), borderColor: Colors.white.withAlpha(30)),
              SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(isCashAccount(bankName) ? cashDisplayName() : bankName, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), fontWeight: FontWeight.w700, color: Colors.white)),
                SizedBox(height: 2),
                Text(l10n.translate('bankCurrenciesCount', params: {'count': '${accounts.length}'}), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 11), color: Colors.white.withAlpha(150))),
              ])),
              GestureDetector(
                onTap: onToggle,
                child: AnimatedRotation(duration: Duration(milliseconds: 300), turns: expanded ? 0.5 : 0, child: Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(color: Colors.white.withAlpha(20), borderRadius: BorderRadius.circular(8)),
                  child: TwoToneIcon(data: TwoToneIcons.arrowDown, size: 14, outlineColor: Colors.white.withAlpha(200)),
                )),
              ),
              SizedBox(width: 8),
              Icon(Icons.arrow_forward_ios, size: 14, color: Colors.white.withAlpha(120)),
            ]),
          ),
        ),
        AnimatedCrossFade(
          firstChild: SizedBox.shrink(),
          secondChild: Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(18, 16, 18, 16),
            decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.vertical(bottom: Radius.circular(16))),
            child: Column(children: [
              ...accounts.map((a) => _AccountRow(account: a, onEdit: () => onEdit(a), onDelete: () => onDelete(a.id, a.bankName), onExport: () => onExport(a))),
              SizedBox(height: 8),
              if (onAddCurrency != null)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: onAddCurrency,
                    icon: TwoToneIcon(data: TwoToneIcons.plus, size: 16, outlineColor: Colors.white),
                    label: Text(l10n.translate('addCurrency'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w700, color: Colors.white)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                if (onDeleteBank != null && canDeleteBankCompletely(bankName)) ...[
                SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: onDeleteBank,
                    icon: Icon(Icons.delete_forever, size: 16, color: AppColors.danger),
                    label: Text(l10n.translate('deleteBankCompletely'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w700, color: AppColors.danger)),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      side: BorderSide(color: AppColors.danger.withAlpha(60)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ]),
          ),
          crossFadeState: expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: Duration(milliseconds: 300),
        ),
      ]),
    );
  }
}

// ????????????????????????????????????????????????????????????
//  ACCOUNT ROW
// ????????????????????????????????????????????????????????????
class _AccountRow extends StatelessWidget {
  final PersonalBankAccount account;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onExport;
  const _AccountRow({required this.account, required this.onEdit, required this.onDelete, required this.onExport});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        Container(width: 34, height: 34, alignment: Alignment.center, decoration: BoxDecoration(color: AppColors.primary.withAlpha(20), borderRadius: BorderRadius.circular(8)),
          // The currency's country flag (neutral icon when it has none).
          child: currencyFlagEmoji(account.currency).isNotEmpty
              ? Text(currencyFlagEmoji(account.currency), style: const TextStyle(fontSize: 19))
              : TwoToneIcon(data: TwoToneIcons.transfer, size: 16, outlineColor: AppColors.primary)),
        SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(account.currency, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            SizedBox(width: 6),
            AccountTypeBadge(type: account.accountType, dense: true),
          ]),
          if (account.notes != null && account.notes!.isNotEmpty)
            Text(account.notes!, style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10), color: AppColors.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
        Text('${fmtNum(account.balance)}', style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        SizedBox(width: 4),
        InkWell(onTap: onExport, borderRadius: BorderRadius.circular(6), child: Padding(padding: EdgeInsets.all(6), child: Icon(Icons.receipt_long, size: 18, color: AppColors.primary))),
        InkWell(onTap: onEdit, borderRadius: BorderRadius.circular(6), child: Padding(padding: EdgeInsets.all(6), child: TwoToneIcon(data: TwoToneIcons.edit, size: 16, outlineColor: AppColors.primary))),
        InkWell(onTap: onDelete, borderRadius: BorderRadius.circular(6), child: Padding(padding: EdgeInsets.all(6), child: TwoToneIcon(data: TwoToneIcons.delete, size: 16, outlineColor: AppColors.danger))),
      ]),
    );
  }
}

// ????????????????????????????????????????????????????????????
//  REUSABLE INPUT
// ????????????????????????????????????????????????????????????
class _InputField extends StatelessWidget {
  final TextEditingController? controller;
  final String label;
  final TwoToneIconData? prefixIcon;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final bool readOnly;
  final bool isAmount;
  const _InputField({this.controller, required this.label, this.prefixIcon, this.keyboardType, this.onChanged, this.readOnly = false, this.isAmount = false});

  @override
  Widget build(BuildContext context) {
    return FyonaTextField(
      controller: controller, keyboardType: keyboardType, onChanged: onChanged, readOnly: readOnly,
      inputFormatters: isAmount ? [AmountInputFormatter()] : null,
      textAlign: TextAlign.right,
      style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14), color: readOnly ? AppColors.textDisabled : AppColors.textPrimary),
      decoration: InputDecoration(
        hintText: label, hintStyle: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 13), color: AppColors.textPlaceholder),
        prefixIcon: prefixIcon != null ? Padding(padding: EdgeInsets.only(left: 10), child: AppIconBadge(icon: prefixIcon!.outline, size: 32, iconSize: 16, backgroundColor: AppColors.surfaceVariant, borderColor: AppColors.border)) : null,
        prefixIconConstraints: BoxConstraints(minWidth: 44, maxWidth: 44, minHeight: 32),
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        filled: true, fillColor: AppColors.surfaceVariant,
        border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.border, width: 0.5), borderRadius: BorderRadius.circular(10)),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: AppColors.primary, width: 1), borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
