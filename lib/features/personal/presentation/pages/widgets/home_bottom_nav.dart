import 'package:flutter/material.dart';
import '../../../../../core/localization/app_localizations.dart';
import '../../../../../shared/widgets/liquid_glass_nav_bar.dart';
import '../../../../../shared/widgets/app_icon.dart';
import '../../../../../shared/widgets/two_tone_icon.dart';
import '../../../../../shared/widgets/two_tone_icons.dart';

class HomeBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  HomeBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  static final _items = [
    _NavItem(icon: TwoToneIcons.home, labelKey: 'home'),
    _NavItem(icon: TwoToneIcons.bank, labelKey: 'personalBanks'),
    _NavItem(icon: TwoToneIcons.debt, labelKey: 'navDebts'),
    _NavItem(icon: TwoToneIcons.savingsGoal, labelKey: 'navSavingsGoals'),
    _NavItem(icon: TwoToneIcons.budget, labelKey: 'navBudget'),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return LiquidGlassNavBar(
      currentIndex: currentIndex,
      onTap: onTap,
      items: [
        for (final item in _items)
          LiquidGlassNavItem(
            label: l10n.translate(item.labelKey),
            icon: (active, color) => AppIcon(
              twoToneIcon: item.icon,
              style: AppIconStyle.badge,
              size: 26,
              iconSize: 19,
              backgroundColor: Colors.transparent,
              borderColor: Colors.transparent,
              accentColor: color,
              color: color,
            ),
          ),
      ],
    );
  }
}

class _NavItem {
  final TwoToneIconData icon;
  final String labelKey;
  const _NavItem({required this.icon, required this.labelKey});
}
