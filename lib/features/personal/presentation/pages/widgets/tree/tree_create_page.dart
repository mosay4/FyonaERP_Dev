import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../../../core/services/currency/enabled_currencies_service.dart';
import '../../../../../../shared/providers/current_user_provider.dart';
import '../../../../../../core/localization/app_localizations.dart';
import '../../../../../../core/theme/app_colors.dart';
import '../../../../../../shared/widgets/currency_selector.dart';
import '../../../providers/financial_tree_provider.dart';
import 'app_tree_theme.dart';
import 'tree_canvas_page.dart';
import 'tree_shared_widgets.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Full-page professional tree creation flow (replaces the old modal wizard).
///
/// Three guided steps presented as polished sections with a fixed bottom
/// action bar: 1) Basic info, 2) Tree type, 3) Start empty or use a template.
class TreeCreatePage extends ConsumerStatefulWidget {
  const TreeCreatePage({super.key});

  @override
  ConsumerState<TreeCreatePage> createState() => _TreeCreatePageState();
}

class _TreeCreatePageState extends ConsumerState<TreeCreatePage> {
  int _step = 0;
  final _nameCtrl = TextEditingController();
  final _clientCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  String _currency = 'USD';
  bool _currencyTouched = false;
  String _treeType = 'personal';
  bool _useTemplate = false;
  bool _saving = false;

  String _tr(String key) => AppLocalizations.of(context).translate(key);

  @override
  void initState() {
    super.initState();
    _resolveCurrencyDefault();
  }

  /// Resolves USD-if-enabled-else-enabled without ever overriding an
  /// explicit user pick.
  Future<void> _resolveCurrencyDefault() async {
    try {
      final code =
          await resolveDefaultCurrency(ref.read(currentUserIdProvider));
      if (!mounted || _currencyTouched) return;
      setState(() => _currency = code);
    } catch (_) {}
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _clientCtrl.dispose();
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  bool get _canProceed => _step > 0 || _nameCtrl.text.trim().isNotEmpty;

  void _next() {
    if (_step < 2) {
      setState(() => _step++);
    } else {
      _create();
    }
  }

  void _back() {
    if (_step > 0) setState(() => _step--);
  }

  Future<void> _create() async {
    if (_nameCtrl.text.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      final amount = double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;
      final notifier = ref.read(financialTreeProvider.notifier);
      if (_useTemplate) {
        await notifier.createDemoTree();
      } else {
        await notifier.createTree(
          name: _nameCtrl.text.trim(),
          clientName: _clientCtrl.text.trim(),
          baseAmount: amount,
          currency: _currency,
          notes: _notesCtrl.text.trim(),
        );
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      final navigator = Navigator.of(context);
      navigator.pop();
      messenger.showSnackBar(SnackBar(
        content: Text(_tr('treeCreated')),
        backgroundColor: AppColors.success,
      ));
      navigator.push(MaterialPageRoute(builder: (_) => const TreeCanvasPage()));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(_tr('createTree'), style: TreeTheme.headingMd),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                    TreeTheme.space16, TreeTheme.space12, TreeTheme.space16, TreeTheme.space24),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: _buildStep(),
                ),
              ),
            ),
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final stepTitles = [_tr('treeStep1Title'), _tr('treeStep2Title'), _tr('treeStep3Title')];
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(TreeTheme.space16, 4, TreeTheme.space16, 0),
      padding: const EdgeInsets.all(TreeTheme.space20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: AppColors.gradientPrimary, begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(TreeTheme.radiusXl),
        boxShadow: [BoxShadow(color: AppColors.primary.withAlpha(60), blurRadius: 18, offset: const Offset(0, 8))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46, height: 46,
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(22),
                  borderRadius: BorderRadius.circular(TreeTheme.radiusMd),
                ),
                child: const Icon(Icons.account_tree, color: Colors.white, size: 24),
              ),
              const SizedBox(width: TreeTheme.space12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_tr('createTree'), style: TreeTheme.headingLg.copyWith(color: Colors.white)),
                    const SizedBox(height: 2),
                    Text(_tr('createTreeSubtitle'),
                        style: TreeTheme.bodySm.copyWith(color: Colors.white.withAlpha(210))),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: TreeTheme.space20),
          TreeStepIndicator(currentStep: _step, totalSteps: 3),
          const SizedBox(height: TreeTheme.space8),
          Row(
            children: List.generate(stepTitles.length, (i) {
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Text(
                    stepTitles[i],
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 10,
                      fontWeight: i <= _step ? FontWeight.w700 : FontWeight.w500,
                      color: i <= _step ? Colors.white : Colors.white.withAlpha(140),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 0: return _buildInfoStep();
      case 1: return _buildTypeStep();
      case 2: return _buildStartStep();
      default: return const SizedBox.shrink();
    }
  }

  Widget _stepCard({required Widget child}) {
    return Container(
      key: ValueKey(_step),
      padding: const EdgeInsets.all(TreeTheme.space20),
      decoration: TreeTheme.cardDecoration,
      child: child,
    );
  }

  Widget _buildInfoStep() {
    return _stepCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_tr('treeStep1Title'), style: TreeTheme.headingSm),
          const SizedBox(height: TreeTheme.space4),
          Text(_tr('treeStep1Subtitle'), style: TreeTheme.bodySm),
          const SizedBox(height: TreeTheme.space20),
          TreeTextField(
            controller: _nameCtrl,
            hint: _tr('treeName'),
            label: _tr('treeName'),
          ),
          const SizedBox(height: TreeTheme.space16),
          TreeTextField(
            controller: _clientCtrl,
            hint: _tr('treeClientName'),
            label: _tr('treeClientName'),
          ),
          const SizedBox(height: TreeTheme.space16),
          LayoutBuilder(builder: (context, constraints) {
            final narrow = constraints.maxWidth < 320;
            final amountField = TreeTextField(
              controller: _amountCtrl,
              hint: '0',
              label: _tr('baseAmount'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              isAmount: true,
            );
            final currencyField = CurrencySelector(
              label: _tr('treeCurrency'),
              value: _currency,
              showCode: false,
              onChanged: (v) =>
                  setState(() => {_currency = v, _currencyTouched = true}),
            );
            if (narrow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [amountField, const SizedBox(height: TreeTheme.space16), currencyField],
              );
            }
            return Row(
              children: [
                Expanded(child: amountField),
                const SizedBox(width: TreeTheme.space16),
                Expanded(child: currencyField),
              ],
            );
          }),
          const SizedBox(height: TreeTheme.space16),
          TreeTextField(
            controller: _notesCtrl,
            hint: _tr('treeNotes'),
            label: _tr('treeNotes'),
            maxLines: 3,
          ),
        ],
      ),
    );
  }

  Widget _buildTypeStep() {
    const types = [
      ('personal', 'treeTypePersonal', 'treeTypePersonalDesc', Icons.account_balance_wallet),
      ('budget', 'treeTypeBudget', 'treeTypeBudgetDesc', Icons.pie_chart_outline),
      ('assets', 'treeTypeAssets', 'treeTypeAssetsDesc', Icons.business_center),
      ('income_expense', 'treeTypeIncomeExpense', 'treeTypeIncomeExpenseDesc', Icons.compare_arrows),
      ('custom', 'treeTypeCustom', 'treeTypeCustomDesc', Icons.tune),
    ];
    return _stepCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_tr('treeStep2Title'), style: TreeTheme.headingSm),
          const SizedBox(height: TreeTheme.space4),
          Text(_tr('treeStep2Subtitle'), style: TreeTheme.bodySm),
          const SizedBox(height: TreeTheme.space20),
          LayoutBuilder(builder: (context, constraints) {
            final twoCols = constraints.maxWidth >= 340;
            return Wrap(
              spacing: TreeTheme.space12,
              runSpacing: TreeTheme.space12,
              children: types.map((t) {
                final selected = _treeType == t.$1;
                final width = twoCols
                    ? (constraints.maxWidth - TreeTheme.space12) / 2
                    : constraints.maxWidth;
                return _selectableCard(
                  width: width,
                  icon: t.$4,
                  title: _tr(t.$2),
                  subtitle: _tr(t.$3),
                  selected: selected,
                  onTap: () => setState(() => _treeType = t.$1),
                );
              }).toList(),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildStartStep() {
    return _stepCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_tr('treeStep3Title'), style: TreeTheme.headingSm),
          const SizedBox(height: TreeTheme.space4),
          Text(_tr('treeStep3Subtitle'), style: TreeTheme.bodySm),
          const SizedBox(height: TreeTheme.space20),
          _selectableCard(
            width: double.infinity,
            icon: Icons.add_circle_outline,
            title: _tr('startEmpty'),
            subtitle: _tr('startEmptyDesc'),
            selected: !_useTemplate,
            onTap: () => setState(() => _useTemplate = false),
          ),
          const SizedBox(height: TreeTheme.space12),
          _selectableCard(
            width: double.infinity,
            icon: Icons.auto_awesome,
            title: _tr('useTemplate'),
            subtitle: _tr('useTemplateDesc'),
            selected: _useTemplate,
            onTap: () => setState(() => _useTemplate = true),
          ),
        ],
      ),
    );
  }

  Widget _selectableCard({
    required double width,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(TreeTheme.radiusLg),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: width,
        padding: const EdgeInsets.all(TreeTheme.space16),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withAlpha(15) : AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(TreeTheme.radiusLg),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: selected ? AppColors.primary.withAlpha(25) : AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(TreeTheme.radiusMd),
              ),
              child: Icon(icon, color: selected ? AppColors.primary : AppColors.textSecondary, size: 22),
            ),
            const SizedBox(width: TreeTheme.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TreeTheme.bodyLg),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TreeTheme.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle, color: AppColors.primary, size: 22)
            else
              const Icon(Icons.radio_button_unchecked, color: AppColors.textDisabled, size: 22),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(TreeTheme.space16, TreeTheme.space12, TreeTheme.space16, TreeTheme.space12),
      decoration:  BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border, width: 1)),
      ),
      child: Row(
        children: [
          if (_step > 0)
            Expanded(
              child: OutlinedButton(
                onPressed: _saving ? null : _back,
                style: OutlinedButton.styleFrom(
                  side:  BorderSide(color: AppColors.border),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(TreeTheme.radiusMd)),
                  minimumSize: const Size(0, 48),
                ),
                child: Text(_tr('back'), style: TreeTheme.bodyMd),
              ),
            ),
          if (_step > 0) const SizedBox(width: TreeTheme.space12),
          Expanded(
            flex: 2,
            child: TreePrimaryButton(
              label: _step == 2 ? _tr('createTree') : _tr('next'),
              onPressed: _canProceed && !_saving ? _next : () {},
              loading: _saving,
              icon: _step == 2 ? Icons.check : Icons.arrow_forward,
            ),
          ),
        ],
      ),
    );
  }
}