class CompanySettings {
  final String companyName;
  final String? legalName;
  final String? logo;
  final String? crNumber;
  final String? taxNumber;
  final String? address;
  final String? phone;
  final String? email;
  final String defaultCurrency;
  final double taxRate;
  final String invoicePrefix;
  final String invoicePrimaryColor;
  final String invoiceAccentColor;
  final String invoiceFontColor;
  final String invoiceFooter;
  final String invoiceTemplate;

  const CompanySettings({
    this.companyName = 'مؤسستي',
    this.legalName,
    this.logo,
    this.crNumber,
    this.taxNumber,
    this.address,
    this.phone,
    this.email,
    this.defaultCurrency = 'SAR',
    this.taxRate = 15.0,
    this.invoicePrefix = 'INV-',
    this.invoicePrimaryColor = '#6B0F1A',
    this.invoiceAccentColor = '#C8A03C',
    this.invoiceFontColor = '#323232',
    this.invoiceFooter = 'شكراً لتعاملكم معنا',
    this.invoiceTemplate = 'standard',
  });

  factory CompanySettings.fromJson(Map<String, dynamic> json) => CompanySettings(
    companyName: json['company_name'] as String? ?? 'مؤسستي',
    legalName: json['legal_name'] as String?,
    logo: json['logo'] as String?,
    crNumber: json['cr_number'] as String?,
    taxNumber: json['tax_number'] as String?,
    address: json['address'] as String?,
    phone: json['phone'] as String?,
    email: json['email'] as String?,
    defaultCurrency: json['default_currency'] as String? ?? 'SAR',
    taxRate: (json['tax_rate'] as num?)?.toDouble() ?? 15.0,
    invoicePrefix: json['invoice_prefix'] as String? ?? 'INV-',
    invoicePrimaryColor: json['invoice_primary_color'] as String? ?? '#6B0F1A',
    invoiceAccentColor: json['invoice_accent_color'] as String? ?? '#C8A03C',
    invoiceFontColor: json['invoice_font_color'] as String? ?? '#323232',
    invoiceFooter: json['invoice_footer'] as String? ?? 'شكراً لتعاملكم معنا',
    invoiceTemplate: json['invoice_template'] as String? ?? 'standard',
  );

  Map<String, dynamic> toJson() => {
    'company_name': companyName, if (legalName != null) 'legal_name': legalName,
    if (logo != null) 'logo': logo,
    if (crNumber != null) 'cr_number': crNumber, if (taxNumber != null) 'tax_number': taxNumber,
    if (address != null) 'address': address, if (phone != null) 'phone': phone,
    if (email != null) 'email': email, 'default_currency': defaultCurrency,
    'tax_rate': taxRate, 'invoice_prefix': invoicePrefix,
    'invoice_primary_color': invoicePrimaryColor, 'invoice_accent_color': invoiceAccentColor,
    'invoice_font_color': invoiceFontColor, 'invoice_footer': invoiceFooter,
    'invoice_template': invoiceTemplate,
  };

  CompanySettings copyWith({
    String? companyName, String? legalName, String? logo, String? crNumber, String? taxNumber,
    String? address, String? phone, String? email, String? defaultCurrency,
    double? taxRate, String? invoicePrefix, String? invoicePrimaryColor,
    String? invoiceAccentColor, String? invoiceFontColor, String? invoiceFooter,
    String? invoiceTemplate,
  }) => CompanySettings(
    companyName: companyName ?? this.companyName, legalName: legalName ?? this.legalName,
    logo: logo ?? this.logo,
    crNumber: crNumber ?? this.crNumber, taxNumber: taxNumber ?? this.taxNumber,
    address: address ?? this.address, phone: phone ?? this.phone,
    email: email ?? this.email, defaultCurrency: defaultCurrency ?? this.defaultCurrency,
    taxRate: taxRate ?? this.taxRate, invoicePrefix: invoicePrefix ?? this.invoicePrefix,
    invoicePrimaryColor: invoicePrimaryColor ?? this.invoicePrimaryColor,
    invoiceAccentColor: invoiceAccentColor ?? this.invoiceAccentColor,
    invoiceFontColor: invoiceFontColor ?? this.invoiceFontColor,
    invoiceFooter: invoiceFooter ?? this.invoiceFooter,
    invoiceTemplate: invoiceTemplate ?? this.invoiceTemplate,
  );
}

class TaxSetting {
  final String name;
  final String nameAr;
  final double rate;
  final String? description;
  final bool isDefault;
  final bool isActive;

  const TaxSetting({required this.name, required this.nameAr, this.rate = 15.0, this.description, this.isDefault = false, this.isActive = true});

  factory TaxSetting.fromJson(Map<String, dynamic> json) => TaxSetting(
    name: json['name'] as String? ?? '', nameAr: json['name_ar'] as String? ?? '',
    rate: (json['rate'] as num?)?.toDouble() ?? 0,
    description: json['description'] as String?,
    isDefault: json['is_default'] as bool? ?? false,
    isActive: json['is_active'] as bool? ?? true,
  );

  Map<String, dynamic> toJson() => {
    'name': name, 'name_ar': nameAr, 'rate': rate, if (description != null) 'description': description,
    'is_default': isDefault, 'is_active': isActive,
  };

  TaxSetting copyWith({
    String? name, String? nameAr, double? rate, String? description, bool? isDefault, bool? isActive,
  }) => TaxSetting(
    name: name ?? this.name, nameAr: nameAr ?? this.nameAr, rate: rate ?? this.rate,
    description: description ?? this.description,
    isDefault: isDefault ?? this.isDefault, isActive: isActive ?? this.isActive,
  );
}

class CurrencySetting {
  final String currency;
  final String? name;
  final String? symbol;
  final double rate;

  const CurrencySetting({required this.currency, this.name, this.symbol, this.rate = 1.0});
  factory CurrencySetting.fromJson(Map<String, dynamic> json) => CurrencySetting(
    currency: json['currency'] as String? ?? '',
    name: json['name'] as String?,
    symbol: json['symbol'] as String?,
    rate: (json['rate'] as num?)?.toDouble() ?? 1.0,
  );

  Map<String, dynamic> toJson() => {
    'currency': currency, if (name != null) 'name': name, if (symbol != null) 'symbol': symbol, 'rate': rate,
  };

  CurrencySetting copyWith({String? currency, String? name, String? symbol, double? rate}) => CurrencySetting(
    currency: currency ?? this.currency, name: name ?? this.name,
    symbol: symbol ?? this.symbol, rate: rate ?? this.rate,
  );
}
