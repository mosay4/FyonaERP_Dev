import 'package:flutter/material.dart';

import '../../../core_business/presentation/widgets/business_number_field.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../../../../shared/widgets/currency_selector.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/bank_gradients.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/amount_input_formatter.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../../../shared/widgets/app_icon_badge.dart';
import '../../../../shared/widgets/receipt/receipt.dart';
import '../../data/business_bank_models.dart';
import '../../../branches/data/branch_api.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../../shared/widgets/account_type_bar.dart';
import '../../../dashboard/presentation/providers/business_dashboard_providers.dart';
import '../../../sales/presentation/providers/sale_providers.dart';
import '../../../returns/presentation/providers/returns_providers.dart';
import '../providers/business_banks_providers.dart';
import '../../../personal/presentation/providers/receipt_design_provider.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import '../../../../shared/providers/current_user_provider.dart';
import 'package:fyona_flutter/features/auth/presentation/widgets/app_pin_sheet.dart';
import '../../../../core/services/currency/business_currency_scope.dart'
    show bizEnabledCurrenciesProvider, loadBizEnabledCurrencies, saveBizEnabledCurrencies;
import '../../../core_business/data/local_directory/directory_database.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../../core_business/data/local_ledger/business_money.dart';
import '../../../core_business/presentation/widgets/business_operation_error.dart';
import '../../../purchases/presentation/providers/purchase_providers.dart' show purchaseAccountsProvider;

/// Whether the "delete bank completely" action is offered for [bankName].
/// Cash can never be deleted as a whole in ANY locale spelling — users may
/// only remove individual cash currencies (always keeping at least one).
bool bizCanDeleteBankCompletely(String bankName) => !isBizCashAccount(bankName);

class BusinessBanksPage extends ConsumerStatefulWidget {
  final bool openTransfer;
  const BusinessBanksPage({super.key, this.openTransfer = false});
  @override
  ConsumerState<BusinessBanksPage> createState() => _BusinessBanksPageState();
}

class _BusinessBanksPageState extends ConsumerState<BusinessBanksPage> {
  bool _showForm = false;
  bool _showTransfer = false;
  bool _savingBank = false;
  bool _transferring = false;
  bool _confirmingAccountAction = false;
  final Set<int> _expandedBanks = {};
  String? _editingId;
  BusinessBankAccount? _editingAccount;
  String? _openingBalanceField;
  String? _bankCommand;
  String? _transferCommand;
  // Hero total display currency defaults to USD always (user-changeable,
  // persisted separately from the personal hero currency).
  String _heroCurrency = 'USD';
  final ScrollController _scrollCtrl = ScrollController();
  final GlobalKey _formKey = GlobalKey();
  final GlobalKey _transferKey = GlobalKey();

  final _nameCtrl = TextEditingController();
  final _balanceCtrl = TextEditingController();
  String _selectedCurrency = '';
  String _selectedType = 'checking';

  final _transferAmountCtrl = TextEditingController();
  String? _transferFromId;
  String? _transferToId;
  BusinessBanksNotifier? _formSource;
  double get _transferAmount => parseFormattedAmount(_transferAmountCtrl.text) ?? 0;

  static const _heroCurrencyKey = 'biz_banks_hero_currency';

  @override
  void initState() {
    super.initState();
    if (widget.openTransfer) {
      _showTransfer = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final source = ref.read(businessBanksProvider.notifier);
      if (_showTransfer) _formSource = source;
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_heroCurrencyKey);
      if (!mounted || !source.isCurrent) return;
      if (saved != null) setState(() => _heroCurrency = saved);
      // Business cash rows for every enabled Business currency (fresh
      // currencies only — never resurrects a removed one).
      try {
        if (source.isLocal &&
            !BranchScope.readOnly &&
            ref.read(employeeWorkspaceCompanyProvider) == null &&
            ref.read(employeeCanProvider('banks.add_delete'))) {
          // Device ledger: the branch's own cash, created here on the phone.
          final enabled = await loadBizEnabledCurrencies(ref.read(currentUserIdProvider).trim());
          if (!mounted || !source.isCurrent) return;
          await source.ensureLocalCash(enabled);
        } else if (!source.isLocal &&
            !BranchScope.readOnly &&
            ref.read(employeeWorkspaceCompanyProvider) == null &&
            ref.read(employeeCanProvider('banks.add_delete'))) {
          final uid = ref.read(currentUserIdProvider).trim();
          final enabled = await loadBizEnabledCurrencies(uid);
          if (!mounted || !source.isCurrent) return;
          await ref
              .read(bizCashServiceProvider)
              .ensureCashAccounts(
                enabled.toList(),
                enabled: enabled,
                userId: uid,
              );
        }
      } catch (_) {}
      if (!mounted || !source.isCurrent) return;
      await source.load();
      if (widget.openTransfer && mounted && source.isCurrent) {
        _scrollToForm();
      }
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _balanceCtrl.dispose();
    _transferAmountCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// Refetch every cached account list after ANY bank change.
  void _invalidateAccountCaches() {
    // Local readers observe the ledger revision emitted after the commit.
    if (ref.read(businessBanksProvider.notifier).isLocal) return;
    ref.invalidate(businessAccountsProvider);
    ref.invalidate(saleAccountsProvider);
    ref.invalidate(purchaseAccountsProvider);
    ref.invalidate(returnAccountsProvider);
    ref.read(businessBanksProvider.notifier).load();
  }

  void _scrollToForm() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _formKey.currentContext ?? _transferKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          alignment: 0.1,
        );
      }
    });
  }

  void _resetForm() {
    _nameCtrl.clear();
    _balanceCtrl.clear();
    // No preselected currency: the field shows the "choose currency" hint
    // until the user picks one (edit mode fills the current value).
    _selectedCurrency = '';
    _selectedType = 'checking';
    _editingId = null;
    _editingAccount = null;
    _openingBalanceField = null;
    _bankCommand = null;
    _showForm = false;
  }

  void _addCurrencyToBank(String bankName) {
    _resetForm();
    _nameCtrl.text = bankName;
    _editingId = null;
    _formSource = ref.read(businessBanksProvider.notifier);
    setState(() {
      _showForm = true;
      _showTransfer = false;
      _expandedBanks.add(bankName.hashCode);
    });
    _scrollToForm();
  }

  Future<void> _saveBank() async {
    if (_savingBank) return;
    final notifier = ref.read(businessBanksProvider.notifier);
    if (!_canSubmit(notifier, 'banks.add_delete')) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    if (_selectedCurrency.isEmpty) {
      showSnackbar(
        context,
        message: AppLocalizations.of(context).translate('selectCurrency'),
        color: AppColors.warning,
      );
      return;
    }
    setState(() => _savingBank = true);
    final decimal = _balanceCtrl.text.replaceAll(',', '').trim();
    var balance = double.tryParse(decimal) ?? 0;
    final edit = _editingAccount;
    final changedBalance = _balanceCtrl.text != _openingBalanceField;
    // The selected type is honoured for cash too, so a cash currency can exist
    // as both جاري and توفير (each shown independently) — same as banks.
    final type = _selectedType;

    if (_editingId == null) {
      final existing = ref.read(businessBanksProvider).accounts;
      final duplicate = existing.any(
        (a) =>
            a.bankName == name &&
            a.currency.toUpperCase() == _selectedCurrency.toUpperCase() &&
            a.accountType == type,
      );
      if (duplicate) {
        final l10n = AppLocalizations.of(context);
        final typeLabel = l10n.translate(
          type == 'savings' ? 'accountTypeSavings' : 'accountTypeChecking',
        );
        showSnackbar(
          context,
          message: l10n.translate(
            'duplicateAccountError',
            params: {'currency': _selectedCurrency, 'type': typeLabel},
          ),
          color: AppColors.warning,
        );
        setState(() => _savingBank = false);
        return;
      }
      // Re-adding a previously removed cash currency restores its stashed
      // balance unless the user typed an explicit one.
      if (!notifier.isLocal && isBizCashAccount(name) && balance == 0) {
        try {
          final uid = ref.read(currentUserIdProvider).trim();
          final stashed = await ref
              .read(bizCashServiceProvider)
              .takeStashedCashBalance(_selectedCurrency, userId: uid);
          if (stashed != null && stashed > 0) balance = stashed;
        } catch (_) {}
      }
    }

    try {
      if (!mounted || !_canSubmit(notifier, 'banks.add_delete')) return;
      final command = _bankCommand ??= const Uuid().v4();
      if (_editingId != null) {
        await notifier.updateAccount(
          _editingId!,
          bankName: name,
          currency: _selectedCurrency,
          accountType: notifier.isLocal && edit?.accountType == 'cash' && type == 'checking'
              ? null : type,
          balance: !notifier.isLocal || changedBalance ? balance : null,
          decimalBalance: notifier.isLocal && changedBalance
              ? (decimal.isEmpty ? '0' : decimal)
              : null,
          originalBalance: edit?.balance,
          commandId: command,
        );
      } else {
        await notifier.addAccount(
          bankName: name,
          accountName: name,
          accountNumber: '',
          currency: _selectedCurrency,
          accountType: type,
          balance: balance,
          decimalBalance: notifier.isLocal ? (decimal.isEmpty ? '0' : decimal) : null,
          commandId: command,
        );
      }
      if (!mounted || !notifier.isCurrent) return;
      // The whole app reads accounts through CACHED providers (income/expense
      // sheet, invoice payment pickers, dashboard). Without this invalidation
      // a freshly added bank was invisible there → "no bank accounts". This
      // was the ROOT CAUSE of that report.
      _invalidateAccountCaches();

      setState(_resetForm);
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        final message = e is BusinessLedgerError &&
                e.problem == BusinessLedgerProblem.duplicateBankAccount
            ? l10n.translate('duplicateAccountError', params: {
                'currency': _selectedCurrency,
                'type': l10n.translate(type == 'savings'
                    ? 'accountTypeSavings' : 'accountTypeChecking'),
              })
            : _bankError(e, l10n, local: notifier.isLocal);
        showSnackbar(context, message: message, color: AppColors.danger);
      }
    } finally {
      if (mounted) setState(() => _savingBank = false);
    }
  }

  bool _canSubmit(BusinessBanksNotifier source, String permission) =>
      source.isCurrent && identical(_formSource, source) &&
      !BranchScope.readOnly && ref.read(employeeCanProvider(permission));

  String _bankError(Object error, AppLocalizations l10n, {required bool local}) {
    if (error is BusinessLedgerError) {
      return l10n.translate(switch (error.problem) {
        BusinessLedgerProblem.cannotDeleteLastCash => 'cannotDeleteLastCash',
        BusinessLedgerProblem.insufficientBalance => 'insufficientBalance',
        BusinessLedgerProblem.invalidAmount => 'transferInvalidAmount',
        BusinessLedgerProblem.invalidAccount => 'accountNotFound',
        _ => 'txOperationFailed',
      });
    }
    if (error is FormatException) return l10n.translate('transferInvalidAmount');
    if (error is DirectoryAccessDenied) return l10n.translate('unauthorized');
    if (local) return l10n.translate('txOperationFailed');
    return businessOperationError(l10n, error, fallback: 'txOperationFailed');
  }

  void _editBank(BusinessBankAccount a) {
    _formSource = ref.read(businessBanksProvider.notifier);
    _nameCtrl.text = a.bankName;
    _balanceCtrl.text = ref.read(businessBankBalanceReadProvider) ? fmtNum(a.balance) : '';
    _openingBalanceField = _balanceCtrl.text;
    _editingAccount = a;
    _bankCommand = null;
    _selectedCurrency = a.currency;
    _selectedType = a.accountType == 'savings' ? 'savings' : 'checking';
    _editingId = a.id;
    setState(() => _showForm = true);
    _scrollToForm();
  }

  Future<void> _deleteBank(String id, String name) async {
    if (_confirmingAccountAction) return;
    // Cash currencies are removed through the dedicated flow (vault snapshot),
    // while cash itself can never be fully deleted.
    final accounts = ref.read(businessBanksProvider).accounts;
    BusinessBankAccount? target;
    for (final a in accounts) {
      if (a.id == id) {
        target = a;
        break;
      }
    }
    if (target != null && isBizCashAccount(target.bankName)) {
      await _deleteCashCurrency(target);
      return;
    }
    await _confirmDelete(name: name, save: (source) => source.deleteAccount(id));
  }

  /// Deletes one cash currency (vaulting its balance for restore).
  /// The last remaining cash account is protected: cash itself can never
  /// be deleted.
  Future<void> _deleteCashCurrency(BusinessBankAccount target) async {
    if (_confirmingAccountAction) return;
    final l10n = AppLocalizations.of(context);
    final cashCount = ref
        .read(businessBanksProvider)
        .accounts
        .where((a) => isBizCashAccount(a.bankName))
        .length;
    if (cashCount <= 1) {
      showSnackbar(
        context,
        message: l10n.translate('cannotDeleteLastCash'),
        color: AppColors.warning,
      );
      return;
    }
    await _confirmDelete(
      name: '${target.bankName} (${target.currency})',
      save: (source) async {
        await source.deleteCashCurrency(target);
        if (source.isLocal || !mounted || !source.isCurrent) return;
        // Only the connected path uses the old branch preference and vault.
        try {
          final uid = ref.read(currentUserIdProvider).trim();
          final enabled = await loadBizEnabledCurrencies(uid);
          if (!mounted || !source.isCurrent) return;
          if (enabled.remove(target.currency.toUpperCase())) {
            await saveBizEnabledCurrencies(enabled, uid);
            if (mounted && source.isCurrent) {
              await ref.read(branchApiProvider).saveCurrencies(enabled.toList());
            }
          }
        } catch (_) {}
      },
    );
  }

  Future<void> _deleteBankCompletely(String bankName, String groupKey) async {
    final l10n = AppLocalizations.of(context);
    // Backstop: cash can never be deleted as a whole in any locale
    // spelling, no matter which path reaches here. Individual cash
    // currencies are removed only via _deleteCashCurrency (which always
    // keeps at least one).
    if (isBizCashAccount(bankName)) {
      if (mounted) {
        showSnackbar(
          context,
          message: l10n.translate('cannotDeleteLastCash'),
          color: AppColors.warning,
        );
      }
      return;
    }
    await _confirmDelete(
      name: bankName,
      wholeBank: true,
      save: (source) => source.deleteBankCompletely(bankName, groupKey: groupKey),
    );
  }

  Future<void> _confirmDelete({
    required String name,
    bool wholeBank = false,
    required Future<void> Function(BusinessBanksNotifier) save,
  }) async {
    if (_confirmingAccountAction || BranchScope.readOnly ||
        !ref.read(employeeCanProvider('banks.add_delete'))) return;
    _confirmingAccountAction = true;
    final source = ref.read(businessBanksProvider.notifier);
    final l10n = AppLocalizations.of(context);
    try {
      final confirm = await showConfirmDialog(
        context,
        title: l10n.translate(wholeBank ? 'deleteBankCompletely' : 'deleteAccountTitle'),
        message: l10n.translate(
          wholeBank ? 'confirmDeleteBank' : 'confirmDeleteAccount',
          params: {'name': name},
        ),
        confirmText: l10n.translate('delete'),
        danger: true,
      );
      if (confirm != true || !mounted || !source.isCurrent) return;
      final verified = await verifySensitiveAction(
        context, ref,
        reason: wholeBank ? l10n.translate('authenticateToDeleteBank') : null,
      );
      if (!verified || !mounted || !source.isCurrent || BranchScope.readOnly ||
          !ref.read(employeeCanProvider('banks.add_delete'))) return;
      await save(source);
      if (mounted && source.isCurrent) _invalidateAccountCaches();
    } catch (e) {
      if (mounted) {
        showSnackbar(
          context,
          message: _bankError(e, l10n, local: source.isLocal),
          color: AppColors.danger,
        );
      }
    } finally {
      _confirmingAccountAction = false;
    }
  }

  void _exportBankReceipt(BusinessBankAccount acc) {
    if (!ref.read(businessBankBalanceReadProvider) ||
        !ref.read(employeeCanProvider('reports.view')) ||
        !ref.read(employeeCanProvider('reports.export'))) return;
    final l10n = AppLocalizations.of(context);
    final preset = ref
        .read(personalReceiptDesignProvider.notifier)
        .getPreset('bank');
    ReceiptModal.show(
      context,
      ReceiptData(
        title: l10n.translate('bankStatementCertificate'),
        amount: acc.balance,
        currencySymbol: currencySymbol(acc.currency),
        dateTime: DateFormat('yyyy/MM/dd HH:mm').format(DateTime.now()),
        senderName: acc.bankName,
        senderAccount: acc.accountName.isEmpty
            ? acc.accountNumber
            : acc.accountName,
        details: [
          ReceiptDetail(
            label: l10n.translate('accountNameLabel'),
            value: acc.accountName.isEmpty ? acc.bankName : acc.accountName,
          ),
          ReceiptDetail(
            label: l10n.translate('currencyLabel'),
            value: acc.currency,
          ),
        ],
      ),
      preset: preset,
    );
  }

  Future<void> _doTransfer(BusinessRate? quote) async {
    if (_transferring) return;
    final source = ref.read(businessBanksProvider.notifier);
    if (!_canSubmit(source, 'banks.transfer')) return;
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
    try {
      final accounts = ref.read(businessBanksProvider).accounts;
      final fromAcc = accounts.firstWhere((a) => a.id == _transferFromId);
      final toAcc = accounts.firstWhere((a) => a.id == _transferToId);
      if (ref.read(businessBankBalanceReadProvider) && fromAcc.balance < _transferAmount) {
        if (mounted) {
          setState(() => _transferring = false);
          showSnackbar(
            context,
            message: l10n.translate(
              'transferInsufficientBalance',
              params: {
                'balance': fmtNum(fromAcc.balance),
                'currency': fromAcc.currency,
              },
            ),
            color: AppColors.danger,
          );
        }
        return;
      }
      double? toAmount;
      double? rate;
      if (fromAcc.currency != toAcc.currency) {
        final foundRate = source.isLocal
            ? double.tryParse(quote?.decimal ?? '')
            : source.rate(fromAcc.currency, toAcc.currency);
        if (foundRate == null || foundRate <= 0) {
          if (mounted) {
            setState(() => _transferring = false);
            showSnackbar(
              context,
              message: l10n.translate(
                'noExchangeRate',
                params: {'from': fromAcc.currency, 'to': toAcc.currency},
              ),
            );
          }
          return;
        }
        rate = foundRate;
        toAmount = _transferAmount * rate;
      }
      final saved = await source.transfer(
        fromId: fromAcc.id,
        toId: toAcc.id,
        amount: _transferAmount,
        toAmount: toAmount,
        rate: rate,
        decimalAmount: _transferAmountCtrl.text.replaceAll(',', ''),
        quote: quote,
        commandId: _transferCommand ??= const Uuid().v4(),
      );
      if (!saved || !mounted || !source.isCurrent) return;
      _invalidateAccountCaches();
      if (mounted) {
        showSnackbar(context, message: l10n.translate('transferSuccess'));
        setState(() {
          _showTransfer = false;
          _transferFromId = null;
          _transferToId = null;
          _transferAmountCtrl.clear();
          _transferCommand = null;
        });
      }
    } catch (e) {
      if (mounted) {
        showSnackbar(
          context,
          message: _bankError(e, l10n, local: source.isLocal),
          color: AppColors.danger,
        );
      }
    } finally {
      if (mounted) setState(() => _transferring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(businessBanksProvider);
    final source = ref.watch(businessBanksProvider.notifier);
    ref.listen(businessBanksProvider.notifier, (previous, next) {
      if (previous == next) return;
      setState(() {
        _resetForm();
        _formSource = null;
        _showTransfer = false;
        _transferFromId = _transferToId = null;
        _transferAmountCtrl.clear();
        _transferCommand = null;
        _expandedBanks.clear();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && next.isCurrent) next.load();
      });
    });
    ref.listen(businessBankBalanceReadProvider, (_, allowed) {
      if (!allowed && _editingId != null) {
        _balanceCtrl.clear();
        _openingBalanceField = '';
      }
    });
    final accounts = state.accounts;
    final grouped = _groupedByBank(accounts);
    final l10n = AppLocalizations.of(context);

    return state.isLoading
        ? const Center(child: DotsLoader())
        : RefreshIndicator(
            color: AppColors.primary,
            backgroundColor: AppColors.surface,
            onRefresh: () async =>
                await ref.read(businessBanksProvider.notifier).load(),
            child: SingleChildScrollView(
              controller: _scrollCtrl,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(20, 16, 20, 100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (source.isLocal && state.error != null)
                    TextButton.icon(
                      onPressed: source.load,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(l10n.translate('txOperationFailed')),
                    ),

                  if (ref.watch(businessBankBalanceReadProvider)) _HeroCard(
                     displayAmount: _heroTotal(source, state),
                    bankCount: grouped.length,
                    accountCount: accounts.length,
                     selectedCurrency: _heroCurrency,
                     enabledBusinessCurrencies: source.isLocal
                         ? (ref.watch(bizEnabledCurrenciesProvider).valueOrNull ?? const {})
                         : null,
                    onCurrencyChanged: (v) {
                      setState(() => _heroCurrency = v);
                      SharedPreferences.getInstance().then(
                        (p) => p.setString(_heroCurrencyKey, v),
                      );
                    },
                  ),
                  SizedBox(height: 16),
                  if (!BranchScope.readOnly) _buildActions(),
                  if (_showForm && ref.watch(employeeCanProvider('banks.add_delete'))) ...[SizedBox(height: 16), _buildForm()],
                  if (_showTransfer && ref.watch(employeeCanProvider('banks.transfer'))) ...[
                    SizedBox(height: 16),
                    _buildTransferForm(accounts),
                  ],
                  if (accounts.isNotEmpty) ...[
                    SizedBox(height: 20),
                    _SectionLabel(
                      title: l10n.translate('bankAccountsTitle'),
                      icon: TwoToneIcons.bank,
                      trailing: '${grouped.length}',
                    ),
                    SizedBox(height: 12),
                    ...grouped.entries.map((e) {
                      final convertedTotal = ref
                          .read(businessBanksProvider.notifier)
                          .convertAccountsToWallet(e.value);
                      final displayTotal = source.isLocal
                          ? source.totalIn(e.value, _heroCurrency)
                          : _heroCurrency == state.walletCurrency
                          ? convertedTotal
                          : source.convert(
                              convertedTotal,
                              state.walletCurrency,
                              _heroCurrency,
                            );
                      return _BankGroupCard(
                        bankName: e.value.first.bankName,
                        groupKey: e.key,
                        accounts: e.value,
                        convertedTotal: displayTotal,
                        primaryCurrency: _heroCurrency,
                        expanded: _expandedBanks.contains(e.key.hashCode),
                        onToggle: () => setState(() {
                          if (_expandedBanks.contains(e.key.hashCode)) {
                            _expandedBanks.remove(e.key.hashCode);
                          } else {
                            _expandedBanks.add(e.key.hashCode);
                            _showForm = false;
                            _showTransfer = false;
                          }
                        }),
                        onEdit: _editBank,
                        onDelete: _deleteBank,
                        onExport: (a) => _exportBankReceipt(a),
                        onAddCurrency: ref.watch(employeeCanProvider('banks.add_delete'))
                            ? () => _addCurrencyToBank(e.value.first.bankName) : null,
                        onDeleteBank: ref.watch(employeeCanProvider('banks.add_delete'))
                             ? () => _deleteBankCompletely(e.value.first.bankName, e.key) : null,
                      );
                    }),
                  ] else ...[
                    SizedBox(height: 48),
                    Center(
                      child: Column(
                        children: [
                          AppIconBadge(
                            icon: TwoToneIcons.bank.outline,
                            size: 72,
                            iconSize: 32,
                            backgroundColor: AppColors.surface,
                            borderColor: AppColors.border,
                            accentColor: AppColors.textPlaceholder,
                          ),
                          SizedBox(height: 16),
                          Text(
                            l10n.translate('noBankAccounts'),
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 15),
                              fontWeight: FontWeight.w700,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            l10n.translate('addNewBankToStart'),
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 12),
                              color: AppColors.textDisabled,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
  }

  Widget _buildActions() {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        Row(
          children: [
            if (ref.watch(employeeCanProvider('banks.add_delete')))
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _showTransfer = false;
                      _showForm = !_showForm;
                       if (_showForm) {
                         _formSource = ref.read(businessBanksProvider.notifier);
                        _expandedBanks.clear();
                         _editingId = null;
                         _editingAccount = null;
                         _openingBalanceField = null;
                         _bankCommand = null;
                        _nameCtrl.clear();
                        _balanceCtrl.clear();
                        _selectedCurrency = '';
                        _selectedType = 'checking';
                      }
                    });
                    if (_showForm) _scrollToForm();
                  },
                  icon: TwoToneIcon(
                    data: _showForm ? TwoToneIcons.delete : TwoToneIcons.plus,
                    size: 18,
                    outlineColor: Colors.white,
                  ),
                  label: Text(
                    _showForm
                        ? l10n.translate('close')
                        : l10n.translate('addBank'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            if (ref.watch(employeeCanProvider('banks.add_delete')) &&
                ref.watch(employeeCanProvider('banks.transfer')))
              SizedBox(width: 10),
            if (ref.watch(employeeCanProvider('banks.transfer')))
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _showForm = false;
                      _showTransfer = !_showTransfer;
                      if (_showTransfer) {
                        _formSource = ref.read(businessBanksProvider.notifier);
                        _expandedBanks.clear();
                      }
                    });
                    if (_showTransfer) _scrollToForm();
                  },
                  icon: TwoToneIcon(
                    data: TwoToneIcons.transfer,
                    size: 18,
                    outlineColor: Colors.white,
                  ),
                  label: Text(
                    _showTransfer
                        ? l10n.translate('close')
                        : l10n.translate('muzarfa'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryDark,
                    padding: EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (BranchScope.allMode) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _linkBanks,
              icon: const Icon(Icons.link_rounded, size: 18),
              label: Text(
                l10n.translate('bankLinkAction'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 12),
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: const BorderSide(color: AppColors.primary),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  double _heroTotal(BusinessBanksNotifier source, BusinessBanksState state) {
    if (source.isLocal) return source.totalIn(state.accounts, _heroCurrency);
    if (_heroCurrency == state.walletCurrency) return state.walletTotal;
    final amount = source.convert(state.walletTotal, state.walletCurrency, _heroCurrency);
    return amount != 0 ? amount : state.walletTotal;
  }

  Future<void> _linkBanks() async {
    if (!BranchScope.allMode) return;
    final l10n = AppLocalizations.of(context);
    final accounts = ref.read(businessBanksProvider).accounts;
    final selected = <String>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(
            l10n.translate('bankLinkTitle'),
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.translate('bankLinkBody'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 10.5,
                    height: 1.4,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: accounts
                        .map(
                          (a) => CheckboxListTile(
                            value: selected.contains(a.id),
                            activeColor: AppColors.primary,
                            dense: true,
                            title: Text(
                              a.bankName,
                              style: const TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 12,
                              ),
                            ),
                            subtitle: Text(
                              '${a.accountName} · ${a.accountNumber} · ${a.currency}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 10,
                              ),
                            ),
                            onChanged: (v) => setLocal(() {
                              if (v == true) {
                                selected.add(a.id);
                              } else {
                                selected.remove(a.id);
                              }
                            }),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(
                l10n.translate('cancel'),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              onPressed: () {
                if (selected.length < 2) {
                  showSnackbar(
                    ctx,
                    message: l10n.translate('bankLinkNeedTwo'),
                    color: AppColors.danger,
                  );
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: Text(
                l10n.translate('bankLinkConfirm'),
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
    if (ok != true || !mounted || !BranchScope.allMode) return;
    try {
      await ref.read(businessBanksApiProvider).linkAccounts(selected.toList());
      await ref.read(businessBanksProvider.notifier).load();
      if (mounted) {
        showSnackbar(
          context,
          message: l10n.translate('bankLinkDone'),
          color: AppColors.success,
        );
      }
    } catch (e) {
      if (mounted) {
        showSnackbar(context, message: '$e', color: AppColors.danger);
      }
    }
  }

  Widget _buildForm() {
    final l10n = AppLocalizations.of(context);
    final local = ref.watch(businessBanksProvider.notifier).isLocal;
    return Container(
      key: _formKey,
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIconBadge(
                icon: TwoToneIcons.bank.outline,
                size: 40,
                iconSize: 20,
                backgroundColor: AppColors.primary.withAlpha(20),
                borderColor: AppColors.primary.withAlpha(40),
              ),
              SizedBox(width: 12),
              Text(
                _editingId != null
                    ? l10n.translate('editAccount')
                    : (_nameCtrl.text.isNotEmpty
                          ? l10n.translate(
                              'addCurrencyFor',
                              params: {'bank': _nameCtrl.text},
                            )
                          : l10n.translate('addNewAccount')),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 15),
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          SizedBox(height: 20),
          _InputField(
            controller: _nameCtrl,
            label: l10n.translate('bankNameLabel'),
            prefixIcon: TwoToneIcons.bank,
            readOnly: _editingId == null && _nameCtrl.text.isNotEmpty,
          ),
          SizedBox(height: 12),
          _InputField(
            controller: _balanceCtrl,
            label: _editingId == null
                ? l10n.translate('openingBalance')
                : l10n.translate('balanceLabel'),
            keyboardType: TextInputType.number,
            prefixIcon: TwoToneIcons.money,
            isAmount: true,
            readOnly: local && _editingId != null &&
                !ref.watch(businessBankBalanceReadProvider),
          ),
          SizedBox(height: 12),
          CurrencySelector(
            label: l10n.translate('currencyLabel'),
            value: _selectedCurrency,
            showCode: false,
            scope: 'business',
            enabledBusinessCurrencies: local
                ? (ref.watch(bizEnabledCurrenciesProvider).valueOrNull ?? const {})
                : null,
            hint: l10n.translate('selectCurrency'),
            onChanged: (v) => setState(() => _selectedCurrency = v),
          ),
          SizedBox(height: 12),
          Container(
            height: 52,
            padding: EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border, width: 0.5),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _selectedType,
                isExpanded: true,
                dropdownColor: AppColors.surface,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13),
                  color: AppColors.textPrimary,
                ),
                items: [
                  DropdownMenuItem(
                    value: 'checking',
                    child: Text(l10n.translate('accountTypeChecking')),
                  ),
                  DropdownMenuItem(
                    value: 'savings',
                    child: Text(l10n.translate('accountTypeSavings')),
                  ),
                ],
                onChanged: (v) =>
                    setState(() => _selectedType = v ?? 'checking'),
              ),
            ),
          ),
          SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() => _resetForm()),
                child: Text(
                  l10n.translate('cancel'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    color: AppColors.textDisabled,
                  ),
                ),
              ),
              SizedBox(width: 8),
              Flexible(
                child: ElevatedButton(
                  onPressed: _saveBank,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    elevation: 0,
                  ),
                  child: Text(
                    _editingId != null
                        ? l10n.translate('update')
                        : l10n.translate('add'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTransferForm(List<BusinessBankAccount> accounts) {
    final l10n = AppLocalizations.of(context);
    final source = ref.read(businessBanksProvider.notifier);
    final from = accounts.where((a) => a.id == _transferFromId).firstOrNull;
    final to = accounts.where((a) => a.id == _transferToId).firstOrNull;
    final quote = source.isLocal && from != null && to != null
        ? source.transferQuote(from.currency, to.currency)
        : null;
    return Container(
      key: _transferKey,
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.primaryDark.withAlpha(60),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIconBadge(
                icon: TwoToneIcons.transfer.outline,
                size: 40,
                iconSize: 20,
                backgroundColor: AppColors.primaryDark.withAlpha(20),
                borderColor: AppColors.primaryDark.withAlpha(40),
              ),
              SizedBox(width: 12),
              Text(
                l10n.translate('transferBetweenAccounts'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 15),
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
          _buildAccountDropdown(
            l10n.translate('fromAccount'),
            accounts,
            _transferFromId,
             (v) {
               setState(() => _transferFromId = v);
            },
          ),
          SizedBox(height: 12),
          Center(
            child: TwoToneIcon(
              data: TwoToneIcons.arrowDown,
              size: 24,
              outlineColor: AppColors.primary,
            ),
          ),
          SizedBox(height: 12),
          _buildAccountDropdown(
            l10n.translate('toAccount'),
            accounts,
            _transferToId,
             (v) {
               setState(() => _transferToId = v);
            },
          ),
          SizedBox(height: 12),
          _InputField(
            label: l10n.translate('amountLabel'),
            controller: _transferAmountCtrl,
            keyboardType: TextInputType.number,
            prefixIcon: TwoToneIcons.money,
            isAmount: true,
            onChanged: (_) => setState(() {}),
          ),
          if (from != null && to != null && _transferAmount > 0) ...[
            SizedBox(height: 12),
            _buildConversionPreview(from, to, source, quote),
          ],
          SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _doTransfer(quote),
              icon: TwoToneIcon(
                data: TwoToneIcons.transfer,
                size: 18,
                outlineColor: Colors.white,
              ),
              label: Text(
                l10n.translate('transfer'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 14),
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: EdgeInsets.symmetric(vertical: 14, horizontal: 24),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConversionPreview(
    BusinessBankAccount fromAcc,
    BusinessBankAccount toAcc,
    BusinessBanksNotifier source,
    BusinessRate? quote,
  ) {
    final l10n = AppLocalizations.of(context);
    final sym1 = currencySymbol(fromAcc.currency);
    final sym2 = currencySymbol(toAcc.currency);
    final rate = source.isLocal ? double.tryParse(quote?.decimal ?? '') :
        source.rate(fromAcc.currency, toAcc.currency);
    double? received;
    try {
      if (quote != null) {
        received = quote.convert(
          BusinessMoney.minor(_transferAmountCtrl.text.replaceAll(',', '')),
          halfEven: false,
        ) / 100;
      } else if (!source.isLocal && rate != null && rate > 0) {
        received = _transferAmount * rate;
      }
    } on FormatException {
      return const SizedBox.shrink(); // Submit still reports the existing amount validation.
    }
    if (rate != null && received != null) {
      return Container(
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.primary.withAlpha(10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.primary.withAlpha(30)),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  l10n.translate('exchangeRate'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 11),
                    color: AppColors.textSecondary,
                  ),
                ),
                Text(
                  '1 ${fromAcc.currency} = ${fmtRate(rate)} ${toAcc.currency}',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 11),
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
            SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${fmtNum(_transferAmount)} $sym1',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                Icon(Icons.arrow_forward, size: 16, color: AppColors.primary),
                Text(
                  '${fmtNum(received)} $sym2',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: FontWeight.w700,
                    color: AppColors.success,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withAlpha(15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.warning.withAlpha(30)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.warning),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.translate(
                'noExchangeRate',
                params: {'from': fromAcc.currency, 'to': toAcc.currency},
              ),
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 11),
                color: AppColors.warning,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountDropdown(
    String label,
    List<BusinessBankAccount> accounts,
    String? value,
    ValueChanged<String?> onChanged,
  ) {
    final l10n = AppLocalizations.of(context);
    // Include cash alongside banks so transfer from/to cash works
    final source = ref.read(businessBanksProvider.notifier);
    final bankAccs = source.isLocal
        ? accounts.where((a) => a.isActive).toList()
        : accounts;
    BusinessBankAccount? selected;
    if (value != null) {
      for (final a in bankAccs) {
        if (a.id == value) {
          selected = a;
          break;
        }
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
          ),
        );
        if (result != null && mounted && _canSubmit(source, 'banks.transfer')) {
          onChanged(result);
        }
      },
      child: Container(
        height: 52,
        padding: EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border, width: 0.5),
        ),
        child: Row(
          children: [
            Expanded(
              child: selected != null
                  ? Text(
                      '${selected.bankName} - ${selected.currency}${ref.watch(businessBankBalanceReadProvider) ? ' (${fmtNum(selected.balance)})' : ''}',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 13),
                        color: AppColors.textPrimary,
                      ),
                    )
                  : Text(
                      label,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        color: AppColors.textDisabled,
                      ),
                    ),
            ),
            Icon(
              Icons.chevron_left_rounded,
              color: AppColors.textDisabled,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  Map<String, List<BusinessBankAccount>> _groupedByBank(
    List<BusinessBankAccount> accounts,
  ) {
    final map = <String, List<BusinessBankAccount>>{};
    for (final a in accounts) {
      // Stable server identity / confirmed link — never the display name.
      map.putIfAbsent(a.groupKey, () => []).add(a);
    }
    return map;
  }
}

// ════════════════════════════════════════════════════════════
//  TRANSFER ACCOUNT PICKER — two-step: banks first, then currencies
// ════════════════════════════════════════════════════════════
class _TransferAccountPickerSheet extends ConsumerStatefulWidget {
  final AppLocalizations l10n;
  final Map<String, List<BusinessBankAccount>> grouped;

  const _TransferAccountPickerSheet({
    required this.l10n,
    required this.grouped,
  });

  @override
  ConsumerState<_TransferAccountPickerSheet> createState() =>
      _TransferAccountPickerSheetState();
}

class _TransferAccountPickerSheetState
    extends ConsumerState<_TransferAccountPickerSheet> {
  String? _selectedBank;

  String _currencyCountLabel(int count) {
    // Via ARB pipeline — N عملات only.
    try {
      final t = widget.l10n.translate(
        'personalCurrenciesCount',
        params: {'count': count},
      );
      if (t != 'personalCurrenciesCount') return t;
    } catch (_) {}
    return '$count';
  }

  @override
  Widget build(BuildContext context) {
    final banks = widget.grouped.keys.toList();
    final showCurrencies = _selectedBank != null;
    final currencies = showCurrencies
        ? widget.grouped[_selectedBank]!
        : <BusinessBankAccount>[];

    return Container(
      height:
          MediaQuery.of(context).size.height * (showCurrencies ? 0.55 : 0.6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(
            margin: EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                if (showCurrencies)
                  GestureDetector(
                    onTap: () => setState(() => _selectedBank = null),
                    child: Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: 18,
                      color: AppColors.primary,
                    ),
                  ),
                if (showCurrencies) SizedBox(width: 8),
                Expanded(
                  child: Text(
                    showCurrencies
                        ? widget.grouped[_selectedBank]!.first.bankName
                        : widget.l10n.translate('selectAccount'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1),
          Expanded(
            child: showCurrencies
                ? ListView.builder(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    itemCount: currencies.length,
                    itemBuilder: (ctx, i) {
                      final a = currencies[i];
                      return Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => Navigator.pop(ctx, a.id),
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceVariant,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
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
                                SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        currencyName(a.currency),
                                        style: TextStyle(
                                          fontFamily: 'Cairo',
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.textPrimary,
                                        ),
                                      ),
                                      SizedBox(height: 3),
                                      if (ref.watch(businessBankBalanceReadProvider)) Text(
                                        '${widget.l10n.translate('balance')}: ${fmtNum(a.balance)}',
                                        style: TextStyle(
                                          fontFamily: 'Cairo',
                                          fontSize: 12,
                                          color: AppColors.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_left_rounded,
                                  color: AppColors.textDisabled,
                                  size: 22,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  )
                : ListView.builder(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    itemCount: banks.length,
                    itemBuilder: (ctx, i) {
                      final bankName = banks[i];
                      final accs = widget.grouped[bankName]!;
                      final displayName = accs.first.bankName;
                      final currencyCount = accs
                          .map((a) => a.currency)
                          .toSet()
                          .length;
                      return Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
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
                            padding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceVariant,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: AppColors.primary,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.account_balance_rounded,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                                ),
                                SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        displayName,
                                        style: TextStyle(
                                          fontFamily: 'Cairo',
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.textPrimary,
                                        ),
                                      ),
                                      SizedBox(height: 3),
                                      Text(
                                        _currencyCountLabel(currencyCount),
                                        style: TextStyle(
                                          fontFamily: 'Cairo',
                                          fontWeight: FontWeight.w600,
                                          fontSize: 11,
                                          color: AppColors.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_left_rounded,
                                  color: AppColors.textDisabled,
                                  size: 22,
                                ),
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

// ════════════════════════════════════════════════════════════
//  HERO CARD
// ════════════════════════════════════════════════════════════
class _HeroCard extends StatelessWidget {
  final double displayAmount;
  final int bankCount;
  final int accountCount;
  final String selectedCurrency;
  final ValueChanged<String> onCurrencyChanged;
  final Set<String>? enabledBusinessCurrencies;
  const _HeroCard({
    required this.displayAmount,
    required this.bankCount,
    required this.accountCount,
    required this.selectedCurrency,
    required this.onCurrencyChanged,
    this.enabledBusinessCurrencies,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment(-1.0, -1.0),
          end: Alignment(1.5, 1.5),
          colors: [Color(0xFFC01838), AppColors.primary, Color(0xFF7A1020)],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withAlpha(100),
            blurRadius: 32,
            offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: AppColors.primaryDark.withAlpha(60),
            blurRadius: 48,
            offset: const Offset(0, 24),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            top: -30,
            right: -20,
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withAlpha(15),
              ),
            ),
          ),
          Positioned(
            bottom: -40,
            left: -10,
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withAlpha(10),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AppIconBadge(
                    icon: TwoToneIcons.bank.outline,
                    size: 44,
                    iconSize: 22,
                    backgroundColor: Colors.white.withAlpha(20),
                    borderColor: Colors.white.withAlpha(30),
                  ),
                  SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.translate('totalBalances'),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 13),
                            fontWeight: FontWeight.w500,
                            color: Colors.white.withAlpha(170),
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          l10n.translate(
                            'banksCountLine',
                            params: {
                              'banks': '$bankCount',
                              'accounts': '$accountCount',
                            },
                          ),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 11),
                            color: Colors.white.withAlpha(120),
                          ),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () => _showCurrencyPicker(context),
                    child: Container(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(25),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withAlpha(40)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            currencySymbol(selectedCurrency),
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 11),
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(width: 2),
                          Icon(
                            Icons.expand_more,
                            size: 14,
                            color: Colors.white.withAlpha(180),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
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
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 34),
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(width: 6),
                    Text(
                      currencySymbol(selectedCurrency),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 18),
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withAlpha(180),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showCurrencyPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppLocalizations.of(context).translate('currencyLabel'),
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 15),
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            SizedBox(height: 12),
            CurrencySelector(
              label: '',
              value: selectedCurrency,
              showCode: false,
              scope: 'business',
              enabledBusinessCurrencies: enabledBusinessCurrencies,
              onChanged: (v) {
                onCurrencyChanged(v);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  SECTION LABEL
// ════════════════════════════════════════════════════════════
class _SectionLabel extends StatelessWidget {
  final String title;
  final TwoToneIconData? icon;
  final String? trailing;
  const _SectionLabel({required this.title, this.icon, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (icon != null) ...[
          AppIconBadge(
            icon: icon!.outline,
            size: 32,
            iconSize: 16,
            backgroundColor: AppColors.primary.withAlpha(20),
            borderColor: AppColors.primary.withAlpha(40),
          ),
          SizedBox(width: 10),
        ],
        Text(
          title,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 15),
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        if (trailing != null) ...[
          const Spacer(),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              trailing!,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 11),
                fontWeight: FontWeight.w600,
                color: AppColors.textDisabled,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════
//  BANK GROUP CARD
// ════════════════════════════════════════════════════════════
class _BankGroupCard extends ConsumerWidget {
  final String bankName;
  final String groupKey;
  final List<BusinessBankAccount> accounts;
  final double convertedTotal;
  final String primaryCurrency;
  final bool expanded;
  final VoidCallback onToggle;
  final Function(BusinessBankAccount) onEdit;
  final Function(String, String) onDelete;
  final Function(BusinessBankAccount) onExport;
  final VoidCallback? onAddCurrency;
  final VoidCallback? onDeleteBank;

  const _BankGroupCard({
    required this.bankName,
    required this.groupKey,
    required this.accounts,
    required this.convertedTotal,
    required this.primaryCurrency,
    required this.expanded,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onExport,
    this.onAddCurrency,
    this.onDeleteBank,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = bankGradients[bankGradientIndex(bankName)];
    final l10n = AppLocalizations.of(context);

    return Container(
      margin: EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(30),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          GestureDetector(
            onTap: !ref.watch(employeeCanProvider('banks.details')) ? null : () => context.push(
              '/banks/detail?bankName=${Uri.encodeComponent(bankName)}'
              '&groupId=${Uri.encodeComponent(groupKey)}',
            ),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: const Alignment(1, -0.5),
                  end: const Alignment(-1, 0.5),
                  colors: g,
                ),
                borderRadius: expanded
                    ? BorderRadius.vertical(top: Radius.circular(16))
                    : BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  AppIconBadge(
                    icon: TwoToneIcons.bank.outline,
                    size: 42,
                    iconSize: 20,
                    backgroundColor: Colors.white.withAlpha(20),
                    borderColor: Colors.white.withAlpha(30),
                  ),
                  SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isBizCashAccount(bankName)
                              ? l10n.translate('cashAccount')
                              : bankName,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 14),
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          l10n.translate(
                            'bankCurrenciesCount',
                            params: {'count': '${accounts.length}'},
                          ),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 11),
                            color: Colors.white.withAlpha(150),
                          ),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: onToggle,
                    child: AnimatedRotation(
                      duration: const Duration(milliseconds: 300),
                      turns: expanded ? 0.5 : 0,
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(20),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: TwoToneIcon(
                          data: TwoToneIcons.arrowDown,
                          size: 14,
                          outlineColor: Colors.white.withAlpha(200),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: 8),
                  Icon(Icons.arrow_forward_ios, size: 14, color: Colors.white),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(18, 16, 18, 16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(16),
                ),
              ),
              child: Column(
                children: [
                  ...accounts.map(
                    (a) => _AccountRow(
                      account: a,
                      onEdit: () => onEdit(a),
                      onDelete: () => onDelete(a.id, a.bankName),
                      onExport: () => onExport(a),
                    ),
                  ),
                  SizedBox(height: 8),
                  if (onAddCurrency != null)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: onAddCurrency,
                        icon: TwoToneIcon(
                          data: TwoToneIcons.plus,
                          size: 16,
                          outlineColor: Colors.white,
                        ),
                        label: Text(
                          l10n.translate('addCurrency'),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 12),
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          padding: EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  if (onDeleteBank != null &&
                      bizCanDeleteBankCompletely(bankName)) ...[
                    SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: onDeleteBank,
                        icon: Icon(
                          Icons.delete_forever,
                          size: 16,
                          color: AppColors.danger,
                        ),
                        label: Text(
                          l10n.translate('deleteBankCompletely'),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 12),
                            fontWeight: FontWeight.w700,
                            color: AppColors.danger,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          side: BorderSide(
                            color: AppColors.danger.withAlpha(60),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            crossFadeState: expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 300),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  ACCOUNT ROW
// ════════════════════════════════════════════════════════════
class _AccountRow extends ConsumerWidget {
  final BusinessBankAccount account;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onExport;
  const _AccountRow({
    required this.account,
    required this.onEdit,
    required this.onDelete,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCash = isBizCashAccount(account.bankName);
    final type = account.accountType.isEmpty ? 'checking' : account.accountType;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(20),
              borderRadius: BorderRadius.circular(8),
            ),
            child: TwoToneIcon(
              data: TwoToneIcons.transfer,
              size: 16,
              outlineColor: AppColors.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      account.currency,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    // Cash rows show the currency code only — never a name suffix.
                    if (!isCash) ...[
                      const SizedBox(width: 6),
                      AccountTypeBadge(type: type, dense: true),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (ref.watch(businessBankBalanceReadProvider)) Text(
            fmtNum(account.balance),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 12),
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          SizedBox(width: 4),
          if (ref.watch(businessBankBalanceReadProvider) && ref.watch(employeeCanProvider('reports.view')) && ref.watch(employeeCanProvider('reports.export'))) InkWell(
            onTap: onExport,
            borderRadius: BorderRadius.circular(6),
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(
                Icons.receipt_long,
                size: 18,
                color: AppColors.primary,
              ),
            ),
          ),
          if (ref.watch(employeeCanProvider('banks.add_delete'))) InkWell(
            onTap: onEdit,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: EdgeInsets.all(6),
              child: TwoToneIcon(
                data: TwoToneIcons.edit,
                size: 16,
                outlineColor: AppColors.primary,
              ),
            ),
          ),
          if (ref.watch(employeeCanProvider('banks.add_delete'))) InkWell(
            onTap: onDelete,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: EdgeInsets.all(6),
              child: TwoToneIcon(
                data: TwoToneIcons.delete,
                size: 16,
                outlineColor: AppColors.danger,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  REUSABLE INPUT
// ════════════════════════════════════════════════════════════
class _InputField extends StatelessWidget {
  final TextEditingController? controller;
  final String label;
  final TwoToneIconData? prefixIcon;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final bool readOnly;
  final bool isAmount;
  const _InputField({
    this.controller,
    required this.label,
    this.prefixIcon,
    this.keyboardType,
    this.onChanged,
    this.readOnly = false,
    this.isAmount = false,
  });

  @override
  Widget build(BuildContext context) {
    return BusinessNumberField(
      controller: controller,
      keyboardType: keyboardType,
      onChanged: onChanged,
      readOnly: readOnly,
      inputFormatters: isAmount ? [AmountInputFormatter()] : null,
      textAlign: TextAlign.right,
      style: TextStyle(
        fontFamily: 'Cairo',
        fontSize: R.fontSize(context, 14),
        color: readOnly ? AppColors.textDisabled : AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: label,
        hintStyle: TextStyle(
          fontFamily: 'Cairo',
          fontSize: R.fontSize(context, 13),
          color: AppColors.textPlaceholder,
        ),
        prefixIcon: prefixIcon != null
            ? Padding(
                padding: EdgeInsets.only(left: 10),
                child: AppIconBadge(
                  icon: prefixIcon!.outline,
                  size: 32,
                  iconSize: 16,
                  backgroundColor: AppColors.surfaceVariant,
                  borderColor: AppColors.border,
                ),
              )
            : null,
        prefixIconConstraints: const BoxConstraints(
          minWidth: 44,
          maxWidth: 44,
          minHeight: 32,
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        filled: true,
        fillColor: AppColors.surfaceVariant,
        border: OutlineInputBorder(
          borderSide: BorderSide.none,
          borderRadius: BorderRadius.circular(10),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: AppColors.border, width: 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: AppColors.primary, width: 1),
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }
}
