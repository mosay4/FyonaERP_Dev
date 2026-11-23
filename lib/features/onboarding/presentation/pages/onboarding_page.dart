import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../providers/onboarding_providers.dart';
import '../../domain/services/onboarding_service.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});
  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final _companyNameCtrl = TextEditingController();
  final _legalNameCtrl = TextEditingController();
  final _commercialRegCtrl = TextEditingController();
  final _taxNoCtrl = TextEditingController();
  final _mobileCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _taxRateCtrl = TextEditingController();
  final _invoicePrefixCtrl = TextEditingController();
  final _pageController = PageController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final s = ref.read(onboardingStateProvider);
      _companyNameCtrl.text = s.companyName;
      _legalNameCtrl.text = s.legalName;
      _commercialRegCtrl.text = s.commercialRegNo;
      _taxNoCtrl.text = s.taxNo;
      _mobileCtrl.text = s.mobile;
      _addressCtrl.text = s.address;
      _taxRateCtrl.text = s.taxRate.toStringAsFixed(1);
      _invoicePrefixCtrl.text = s.invoicePrefix;
    });
  }

  @override
  void dispose() {
    _companyNameCtrl.dispose();
    _legalNameCtrl.dispose();
    _commercialRegCtrl.dispose();
    _taxNoCtrl.dispose();
    _mobileCtrl.dispose();
    _addressCtrl.dispose();
    _taxRateCtrl.dispose();
    _invoicePrefixCtrl.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _goToStep(int step) {
    _pageController.animateToPage(
      step,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _onNext() {
    final notifier = ref.read(onboardingStateProvider.notifier);
    if (notifier.validateStep()) {
      notifier.nextStep();
      _goToStep(ref.read(onboardingStateProvider).currentStep);
    }
  }

  void _onBack() {
    ref.read(onboardingStateProvider.notifier).prevStep();
    _goToStep(ref.read(onboardingStateProvider).currentStep);
  }

  void _onComplete() async {
    final notifier = ref.read(onboardingStateProvider.notifier);
    await notifier.complete();
    if (mounted && ref.read(onboardingStateProvider).error == null) {
      context.go(RouteNames.dashboard);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onboardingStateProvider);
    final businessTypes = ref.watch(businessTypesProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildProgressBar(state.currentStep),
            if (state.error != null) _buildErrorBanner(state.error!),
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) {
                  ref.read(onboardingStateProvider.notifier).clearError();
                },
                children: [
                  _buildStep1(state, businessTypes),
                  _buildStep2(state),
                  _buildStep3(state),
                  _buildStep4(state),
                ],
              ),
            ),
            _buildBottomBar(state),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressBar(int step) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Column(
        children: [
          Row(
            children: List.generate(4, (i) {
              final isActive = i == step;
              final isDone = i < step;
              return Expanded(
                child: Container(
                  height: 4,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: isActive
                        ? AppColors.primary
                        : isDone
                            ? AppColors.success
                            : AppColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 8),
          Text(
            '${step + 1} / 4',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.font(context, 'caption'),
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String error) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: AppColors.danger.withAlpha(30),
      child: Row(
        children: [
          const TwoToneIcon(data: TwoToneIcons.warning, size: 16, outlineColor: AppColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.font(context, 'caption'),
                color: AppColors.danger,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => ref.read(onboardingStateProvider.notifier).clearError(),
            child: TwoToneIcon(data: TwoToneIcons.close, size: 16, outlineColor: AppColors.danger),
          ),
        ],
      ),
    );
  }

  // ── Step 1: Business Type ──

  Widget _buildStep1(OnboardingState state, List<BusinessType> types) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocalizations.of(context).translate('onboardingChooseTheTypeOf'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.font(context, 'title'),
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            AppLocalizations.of(context).translate('onboardingChooseYourFieldOf'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.font(context, 'body'),
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 20),
          ...types.map((t) => _buildBusinessTypeCard(state, t)),
        ],
      ),
    );
  }

  Widget _buildBusinessTypeCard(OnboardingState state, BusinessType type) {
    final selected = state.businessTypeId == type.id;
    return GestureDetector(
      onTap: () => ref.read(onboardingStateProvider.notifier).setBusinessType(type.id),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withAlpha(20) : AppColors.surface,
          borderRadius: AppRadius.mdBorder,
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: selected ? AppColors.primary : AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                type.icon,
                size: 24,
                color: selected ? Colors.white : AppColors.textSecondary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    type.name,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.font(context, 'body'),
                      fontWeight: FontWeight.w600,
                      color: selected ? AppColors.textPrimary : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    type.description,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.font(context, 'caption'),
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              TwoToneIcon(data: TwoToneIcons.check, size: 22, outlineColor: AppColors.primary),
          ],
        ),
      ),
    );
  }

  // ── Step 2: Company Data ──

  Widget _buildStep2(OnboardingState state) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocalizations.of(context).translate('onboardingCompanyData'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.font(context, 'title'),
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            AppLocalizations.of(context).translate('onboardingEnterBasicInformationFor'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.font(context, 'body'),
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 20),
          _buildTextField(
            controller: _companyNameCtrl,
            label: AppLocalizations.of(context).translate('onboardingCompanyName'),
            icon: Icons.business,
            onChanged: (v) => ref.read(onboardingStateProvider.notifier).setCompanyName(v),
          ),
          const SizedBox(height: 14),
          _buildTextField(
            controller: _legalNameCtrl,
            label: AppLocalizations.of(context).translate('onboardingLegalName'),
            icon: Icons.description,
            onChanged: (v) => ref.read(onboardingStateProvider.notifier).setLegalName(v),
          ),
          const SizedBox(height: 14),
          _buildTextField(
            controller: _commercialRegCtrl,
            label: AppLocalizations.of(context).translate('onboardingCommercialRegistrationNumber'),
            icon: Icons.person,
            onChanged: (v) => ref.read(onboardingStateProvider.notifier).setCommercialRegNo(v),
          ),
          const SizedBox(height: 14),
          _buildTextField(
            controller: _taxNoCtrl,
            label: AppLocalizations.of(context).translate('dataImportTaxNumber'),
            icon: Icons.receipt_long,
            onChanged: (v) => ref.read(onboardingStateProvider.notifier).setTaxNo(v),
          ),
          const SizedBox(height: 14),
          _buildTextField(
            controller: _mobileCtrl,
            label: AppLocalizations.of(context).translate('phone'),
            icon: Icons.contact_mail,
            keyboardType: TextInputType.phone,
            onChanged: (v) => ref.read(onboardingStateProvider.notifier).setMobile(v),
          ),
          const SizedBox(height: 14),
          _buildTextField(
            controller: _addressCtrl,
            label: AppLocalizations.of(context).translate('adminTheAddress'),
            icon: Icons.business,
            maxLines: 3,
            onChanged: (v) => ref.read(onboardingStateProvider.notifier).setAddress(v),
          ),
        ],
      ),
    );
  }

  // ── Step 3: Financial Settings ──

  Widget _buildStep3(OnboardingState state) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocalizations.of(context).translate('onboardingFinancialSettings'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.font(context, 'title'),
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            AppLocalizations.of(context).translate('onboardingSelectTheCurrencyTax'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.font(context, 'body'),
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 20),
          // Accounting method
          Text(
            AppLocalizations.of(context).translate('onboardingAccountingMethod'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.font(context, 'body'),
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'simple', label: Text(AppLocalizations.of(context).translate('onboardingSimplified'), style: TextStyle(fontFamily: 'Cairo'))),
                ButtonSegment(value: 'advanced', label: Text(AppLocalizations.of(context).translate('onboardingAdvanced'), style: TextStyle(fontFamily: 'Cairo'))),
              ],
              selected: {state.accountingMethod},
              onSelectionChanged: (v) => ref.read(onboardingStateProvider.notifier).setAccountingMethod(v.first),
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) return AppColors.primary;
                  return AppColors.surfaceVariant;
                }),
                foregroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) return Colors.white;
                  return AppColors.textSecondary;
                }),
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Currency
          Text(
            AppLocalizations.of(context).translate('currencyLabel'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.font(context, 'body'),
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          _buildCurrencyDropdown(state),
          const SizedBox(height: 20),
          // Tax rate
          Text(
            AppLocalizations.of(context).translate('onboardingDefaultTaxRate'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.font(context, 'body'),
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          _buildTextField(
            controller: _taxRateCtrl,
            label: '%',
            icon: Icons.attach_money,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (v) {
              final parsed = double.tryParse(v);
              if (parsed != null) {
                ref.read(onboardingStateProvider.notifier).setTaxRate(parsed);
              }
            },
          ),
          const SizedBox(height: 20),
          // Invoice prefix
          Text(
            AppLocalizations.of(context).translate('onboardingInvoicePrefix'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.font(context, 'body'),
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          _buildTextField(
            controller: _invoicePrefixCtrl,
            label: AppLocalizations.of(context).translate('onboardingExampleINV'),
            icon: Icons.shopping_cart,
            onChanged: (v) => ref.read(onboardingStateProvider.notifier).setInvoicePrefix(v),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrencyDropdown(OnboardingState state) {
    const currencies = ['SAR', 'USD', 'EUR', 'GBP', 'AED', 'EGP', 'JOD'];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.inputBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: state.currency,
          isExpanded: true,
          dropdownColor: AppColors.surfaceVariant,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.font(context, 'body'),
            color: AppColors.textPrimary,
          ),
          items: currencies.map((c) {
            return DropdownMenuItem(
              value: c,
              child: Text(c, style: const TextStyle(fontFamily: 'Cairo')),
            );
          }).toList(),
          onChanged: (v) {
            if (v != null) {
              ref.read(onboardingStateProvider.notifier).setCurrency(v);
            }
          },
        ),
      ),
    );
  }

  // ── Step 4: Confirmation ──

  Widget _buildStep4(OnboardingState state) {
    final businessTypes = ref.watch(businessTypesProvider);
    final selectedType = businessTypes.where((t) => t.id == state.businessTypeId).firstOrNull;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 20),
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: AppColors.success.withAlpha(25),
              borderRadius: BorderRadius.circular(30),
            ),
            child: TwoToneIcon(data: TwoToneIcons.sparkle, size: 56, outlineColor: AppColors.success),
          ),
          const SizedBox(height: 24),
          Text(
            AppLocalizations.of(context).translate('onboardingEverythingIsReady'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.font(context, 'title'),
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 20),
          _buildSummaryRow(AppLocalizations.of(context).translate('onboardingTypeOfActivity'), selectedType?.name ?? ''),
          if (state.companyName.isNotEmpty) _buildSummaryRow(AppLocalizations.of(context).translate('designStudioCompanyName'), state.companyName),
          _buildSummaryRow(AppLocalizations.of(context).translate('currencyLabel'), state.currency),
          _buildSummaryRow(AppLocalizations.of(context).translate('onboardingTax'), '${state.taxRate.toStringAsFixed(1)}%'),
          _buildSummaryRow(AppLocalizations.of(context).translate('onboardingAccountingMethod'), state.accountingMethod == 'simple' ? AppLocalizations.of(context).translate('onboardingSimplified') : AppLocalizations.of(context).translate('onboardingAdvanced')),
          if (state.invoicePrefix.isNotEmpty) _buildSummaryRow(AppLocalizations.of(context).translate('onboardingInvoicePrefix'), state.invoicePrefix),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: state.isSubmitting ? null : _onComplete,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                disabledBackgroundColor: AppColors.surfaceVariant,
                foregroundColor: Colors.white,
                disabledForegroundColor: AppColors.textDisabled,
                shape: RoundedRectangleBorder(borderRadius: AppRadius.mdBorder),
              ),
              child: state.isSubmitting
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                    )
                  : Text(
                      AppLocalizations.of(context).translate('onboardingStartNow'),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.font(context, 'body_large'),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(String label, String value) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.smBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.font(context, 'body_small'),
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.font(context, 'body'),
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Bottom Bar ──

  Widget _buildBottomBar(OnboardingState state) {
    final isLastStep = state.currentStep == 3;
    final isFirstStep = state.currentStep == 0;

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      decoration:  BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          if (!isFirstStep)
            Expanded(
              child: SizedBox(
                height: 48,
                child: OutlinedButton(
                  onPressed: _onBack,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side:  BorderSide(color: AppColors.border),
                    shape: RoundedRectangleBorder(borderRadius: AppRadius.mdBorder),
                  ),
                  child: Text(
                    AppLocalizations.of(context).translate('previous'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.font(context, 'body'),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          if (!isFirstStep) const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 48,
              child: ElevatedButton(
                onPressed: isLastStep ? _onComplete : _onNext,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  disabledBackgroundColor: AppColors.surfaceVariant,
                  foregroundColor: Colors.white,
                  disabledForegroundColor: AppColors.textDisabled,
                  shape: RoundedRectangleBorder(borderRadius: AppRadius.mdBorder),
                ),
                child: isLastStep
                    ? (state.isSubmitting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                          )
                        : Text(
                            AppLocalizations.of(context).translate('onboardingStartNow'),
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.font(context, 'body_large'),
                              fontWeight: FontWeight.bold,
                            ),
                          ))
                    : Text(
                        AppLocalizations.of(context).translate('next'),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.font(context, 'body'),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Reusable Widgets ──

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
    int maxLines = 1,
    required ValueChanged<String> onChanged,
  }) {
    return FyonaTextField(
      controller: controller,
      onChanged: onChanged,
      keyboardType: keyboardType,
      maxLines: maxLines,
      textDirection: TextDirection.rtl,
      style: TextStyle(
        fontFamily: 'Cairo',
        fontSize: R.font(context, 'body'),
        color: AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: label,
        hintStyle: TextStyle(
          fontFamily: 'Cairo',
          fontSize: R.font(context, 'caption'),
          color: AppColors.textDisabled,
        ),
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        prefixIcon: Padding(
          padding: const EdgeInsetsDirectional.only(start: 12, end: 8),
          child: Icon(icon, size: 20, color: AppColors.textSecondary),
        ),
        border: OutlineInputBorder(
          borderRadius: AppRadius.inputBorder,
          borderSide:  BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.inputBorder,
          borderSide:  BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.inputBorder,
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
      ),
    );
  }
}
