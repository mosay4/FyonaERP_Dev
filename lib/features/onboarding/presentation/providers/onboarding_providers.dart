import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/services/onboarding_service.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';

final onboardingServiceProvider = Provider<OnboardingService>((ref) {
  return OnboardingService();
});

final businessTypesProvider = Provider<List<BusinessType>>((ref) {
  return ref.watch(onboardingServiceProvider).getBusinessTypes();
});

class OnboardingState {
  final int currentStep;
  final String? businessTypeId;
  final String companyName;
  final String legalName;
  final String commercialRegNo;
  final String taxNo;
  final String mobile;
  final String address;
  final String accountingMethod;
  final String currency;
  final double taxRate;
  final String invoicePrefix;
  final bool isSubmitting;
  final String? error;

  const OnboardingState({
    this.currentStep = 0,
    this.businessTypeId,
    this.companyName = '',
    this.legalName = '',
    this.commercialRegNo = '',
    this.taxNo = '',
    this.mobile = '',
    this.address = '',
    this.accountingMethod = 'simple',
    this.currency = 'SAR',
    this.taxRate = 15.0,
    this.invoicePrefix = 'INV-',
    this.isSubmitting = false,
    this.error,
  });

  OnboardingState copyWith({
    int? currentStep,
    String? businessTypeId,
    String? companyName,
    String? legalName,
    String? commercialRegNo,
    String? taxNo,
    String? mobile,
    String? address,
    String? accountingMethod,
    String? currency,
    double? taxRate,
    String? invoicePrefix,
    bool? isSubmitting,
    String? error,
    bool clearError = false,
  }) {
    return OnboardingState(
      currentStep: currentStep ?? this.currentStep,
      businessTypeId: businessTypeId ?? this.businessTypeId,
      companyName: companyName ?? this.companyName,
      legalName: legalName ?? this.legalName,
      commercialRegNo: commercialRegNo ?? this.commercialRegNo,
      taxNo: taxNo ?? this.taxNo,
      mobile: mobile ?? this.mobile,
      address: address ?? this.address,
      accountingMethod: accountingMethod ?? this.accountingMethod,
      currency: currency ?? this.currency,
      taxRate: taxRate ?? this.taxRate,
      invoicePrefix: invoicePrefix ?? this.invoicePrefix,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class OnboardingNotifier extends StateNotifier<OnboardingState> {
  final OnboardingService _service;

  OnboardingNotifier(this._service) : super(const OnboardingState());

  void setBusinessType(String id) {
    state = state.copyWith(businessTypeId: id);
  }

  void setCompanyName(String v) {
    state = state.copyWith(companyName: v);
  }

  void setLegalName(String v) {
    state = state.copyWith(legalName: v);
  }

  void setCommercialRegNo(String v) {
    state = state.copyWith(commercialRegNo: v);
  }

  void setTaxNo(String v) {
    state = state.copyWith(taxNo: v);
  }

  void setMobile(String v) {
    state = state.copyWith(mobile: v);
  }

  void setAddress(String v) {
    state = state.copyWith(address: v);
  }

  void setAccountingMethod(String v) {
    state = state.copyWith(accountingMethod: v);
  }

  void setCurrency(String v) {
    state = state.copyWith(currency: v);
  }

  void setTaxRate(double v) {
    state = state.copyWith(taxRate: v);
  }

  void setInvoicePrefix(String v) {
    state = state.copyWith(invoicePrefix: v);
  }

  bool validateStep() {
    final step = state.currentStep;
    switch (step) {
      case 0:
        if (state.businessTypeId == null) {
          state = state.copyWith(error: AppLocalizations.t('onboardingPleaseSelectTheType'), clearError: false);
          return false;
        }
        return true;
      case 1:
        if (state.companyName.trim().isEmpty) {
          state = state.copyWith(error: AppLocalizations.t('onboardingPleaseEnterTheCompany'), clearError: false);
          return false;
        }
        return true;
      case 2:
        return true;
      default:
        return true;
    }
  }

  void nextStep() {
    if (!validateStep()) return;
    if (state.currentStep < 3) {
      state = state.copyWith(currentStep: state.currentStep + 1, error: '');
    }
  }

  void prevStep() {
    if (state.currentStep > 0) {
      state = state.copyWith(currentStep: state.currentStep - 1, error: '');
    }
  }

  void clearError() {
    state = state.copyWith(clearError: true);
  }

  Future<void> complete() async {
    state = state.copyWith(isSubmitting: true, error: '');
    try {
      final data = OnboardingData(
        businessTypeId: state.businessTypeId,
        companyName: state.companyName,
        legalName: state.legalName,
        commercialRegNo: state.commercialRegNo,
        taxNo: state.taxNo,
        mobile: state.mobile,
        address: state.address,
        accountingMethod: state.accountingMethod,
        currency: state.currency,
        taxRate: state.taxRate,
        invoicePrefix: state.invoicePrefix,
      );
      await _service.completeOnboarding(data);
      state = state.copyWith(isSubmitting: false);
    } catch (e) {
      state = state.copyWith(
        isSubmitting: false,
        error: AppLocalizations.t('onboardingFailedToSaveSettings', {'e': e.toString()}),
      );
    }
  }
}

final onboardingStateProvider =
    StateNotifierProvider<OnboardingNotifier, OnboardingState>((ref) {
  return OnboardingNotifier(ref.watch(onboardingServiceProvider));
});
