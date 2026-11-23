import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/utils/constants.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';

class BusinessType {
  final String id;
  final String name;
  final String description;
  final IconData icon;

  const BusinessType({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
  });
}

class OnboardingData {
  String? businessTypeId;
  String companyName;
  String legalName;
  String commercialRegNo;
  String taxNo;
  String mobile;
  String address;
  String accountingMethod;
  String currency;
  double taxRate;
  String invoicePrefix;

  OnboardingData({
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
  });
}

class OnboardingService {
  List<BusinessType> getBusinessTypes() {
    return [
      BusinessType(
        id: 'retail',
        name: AppLocalizations.t('onboardingCommerce'),
        description: AppLocalizations.t('onboardingRetailAndWholesaleStores'),
        icon: Icons.shopping_cart,
      ),
      BusinessType(
        id: 'services',
        name: AppLocalizations.t('onboardingServices'),
        description: AppLocalizations.t('onboardingServiceAndConsultingCompanies'),
        icon: Icons.person,
      ),
      BusinessType(
        id: 'contracting',
        name: AppLocalizations.t('onboardingContracting'),
        description: AppLocalizations.t('onboardingContractingAndConstructionComp'),
        icon: Icons.settings,
      ),
      BusinessType(
        id: 'manufacturing',
        name: AppLocalizations.t('onboardingIndustry'),
        description: AppLocalizations.t('onboardingFactoriesAndIndustrialFaciliti'),
        icon: Icons.settings,
      ),
      BusinessType(
        id: 'healthcare',
        name: AppLocalizations.t('goalIconHealth'),
        description: AppLocalizations.t('onboardingHospitalsAndMedicalCenters'),
        icon: Icons.settings,
      ),
      BusinessType(
        id: 'education',
        name: AppLocalizations.t('goalIconEducation'),
        description: AppLocalizations.t('onboardingSchoolsUniversitiesAndInstitut'),
        icon: Icons.settings,
      ),
      BusinessType(
        id: 'technology',
        name: AppLocalizations.t('onboardingTechnique'),
        description: AppLocalizations.t('onboardingTechnologyAndSoftwareCompanies'),
        icon: Icons.settings,
      ),
      BusinessType(
        id: 'hospitality',
        name: AppLocalizations.t('onboardingHospitality'),
        description: AppLocalizations.t('onboardingHotelsRestaurantsAndHospitalit'),
        icon: Icons.settings,
      ),
    ];
  }

  Future<void> completeOnboarding(OnboardingData data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('business_type_id', data.businessTypeId ?? '');
    await prefs.setString('company_name', data.companyName);
    await prefs.setString('legal_name', data.legalName);
    await prefs.setString('commercial_reg_no', data.commercialRegNo);
    await prefs.setString('tax_no', data.taxNo);
    await prefs.setString('mobile', data.mobile);
    await prefs.setString('address', data.address);
    await prefs.setString('accounting_method', data.accountingMethod);
    await prefs.setString('currency', data.currency);
    await prefs.setDouble('tax_rate', data.taxRate);
    await prefs.setString('invoice_prefix', data.invoicePrefix);
    await prefs.setBool(AppConstants.prefOnboardingComplete, true);
  }

  Future<bool> isOnboardingComplete() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(AppConstants.prefOnboardingComplete) ?? false;
  }
}
