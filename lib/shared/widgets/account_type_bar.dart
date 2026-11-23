import 'package:flutter/material.dart';
import '../../core/localization/app_localizations.dart';

/// Account-type visual language (ONE source of truth for every picker):
///   savings (توفير) → GREEN bar  (unchanged, as it already looked)
///   checking (جاري) → BLUE bar
/// The bar is a slim rounded vertical strip placed at the START of the row,
/// right before the currency/account label.
const Color kCheckingBar = Color(0xFF1E6FD9);
const Color kSavingsBar = Color(0xFF1B7A43);

bool isSavingsType(String? type) =>
    (type ?? '').toLowerCase() == 'savings';

Color accountTypeBarColor(String? type) =>
    isSavingsType(type) ? kSavingsBar : kCheckingBar;

/// Localized «جاري» / «توفير».
String accountTypeLabel(AppLocalizations l10n, String? type) =>
    l10n.translate(isSavingsType(type)
        ? 'accountTypeSavings'
        : 'accountTypeChecking');

/// A slim colored strip marking the account type (blue = checking,
/// green = savings). Purely visual — never changes layout metrics.
class AccountTypeBar extends StatelessWidget {
  final String? type;
  final double height;
  final double width;
  const AccountTypeBar(
      {super.key, required this.type, this.height = 34, this.width = 4});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: accountTypeBarColor(type),
          borderRadius: BorderRadius.circular(width / 2),
        ),
      ),
    );
  }
}

/// Official, theme-aware account-type badge. Savings is green and checking is
/// blue in both light and dark themes, with a tinted background and border so
/// the label never sits as raw saturated text on white/black.
class AccountTypeBadge extends StatelessWidget {
  final String? type;
  final bool dense;
  const AccountTypeBadge({super.key, required this.type, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final savings = isSavingsType(type);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = savings
        ? (dark ? const Color(0xFF9BE7B8) : const Color(0xFF15643A))
        : (dark ? const Color(0xFF9CCBFF) : const Color(0xFF12539B));
    final bg = savings
        ? (dark ? const Color(0xFF143525) : const Color(0xFFE9F7EF))
        : (dark ? const Color(0xFF132D4D) : const Color(0xFFEAF2FF));
    final border = savings
        ? (dark ? const Color(0xFF2E6B49) : const Color(0xFFB9E3CB))
        : (dark ? const Color(0xFF2F5E96) : const Color(0xFFB9D7FA));
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: dense ? 6 : 7, vertical: dense ? 2 : 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: border, width: 0.8),
      ),
      child: Text(
        accountTypeLabel(l10n, type),
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: dense ? 9 : 9.5,
          height: 1.25,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.1,
          color: fg,
        ),
      ),
    );
  }
}
