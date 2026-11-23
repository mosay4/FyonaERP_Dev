class AppConstants {
  AppConstants._();

  static const String appName = 'FYONA ERP';
  static const String appVersion = '1.0.0';
  static const String appDescription = 'FYONA Business Suite';

  // ── Shared Preferences Keys ──
  static const String prefToken = 'auth_token';
  static const String prefRefreshToken = 'refresh_token';
  static const String prefUserData = 'user_data';
  static const String prefThemeMode = 'theme_mode';
  static const String prefLocale = 'locale';
  static const String prefOnboardingComplete = 'onboarding_complete';

  // ── Date Formats ──
  static const String dateFormat = 'yyyy-MM-dd';
  static const String dateTimeFormat = 'yyyy-MM-dd HH:mm:ss';
  static const String timeFormat = 'HH:mm:ss';
  static const String displayDateFormat = 'yyyy/MM/dd';
  static const String displayDateTimeFormat = 'yyyy/MM/dd HH:mm';

  // ── Currency ──
  static const String defaultCurrency = 'SAR';
  static const String currencySymbol = 'ريال';

  // ── Invoice Statuses ──
  static const List<String> invoiceStatuses = [
    'draft',
    'confirmed',
    'paid',
    'cancelled',
    'overdue',
    'refunded',
  ];

  // ── Payment Methods ──
  static const List<String> paymentMethods = [
    'cash',
    'bank_transfer',
    'check',
    'credit',
  ];

  // ── Expense Categories ──
  static const List<String> expenseCategories = [
    'rent',
    'utilities',
    'salaries',
    'marketing',
    'transport',
    'maintenance',
    'purchases',
    'other',
  ];
}
