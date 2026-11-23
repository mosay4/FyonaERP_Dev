import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/theme/app_radius.dart';
import '../../../../../shared/widgets/app_icon.dart';
import '../../../../../shared/widgets/two_tone_icon.dart';
import '../../../../../shared/widgets/two_tone_icons.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';

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
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final l10n = AppLocalizations.of(context);
    return Container(
      height: 68 + bottomPad,
      padding: EdgeInsets.only(bottom: bottomPad),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: List.generate(_items.length, (i) {
          final item = _items[i];
          final isActive = i == currentIndex;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                HapticFeedback.lightImpact();
                onTap(i);
              },
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          if (isActive)
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 250),
                              curve: Curves.easeOutBack,
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.primary.withAlpha(22),
                              ),
                            ),
                          AppIcon(
                            twoToneIcon: item.icon,
                            style: AppIconStyle.badge,
                            size: 36,
                            iconSize: 18,
                            backgroundColor: isActive
                                ? AppColors.primary.withAlpha(28)
                                : Colors.transparent,
                            borderColor: isActive
                                ? AppColors.primary.withAlpha(55)
                                : Colors.transparent,
                            accentColor: isActive
                                ? AppColors.primary
                                : AppColors.textSecondary,
                            color: isActive
                                ? AppColors.primary
                                : AppColors.textSecondary,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 200),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 10),
                          fontWeight:
                              isActive ? FontWeight.w700 : FontWeight.w500,
                          color: isActive
                              ? AppColors.primary
                              : AppColors.textSecondary,
                        ),
                        child: Text(l10n.translate(item.labelKey)),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                        margin: const EdgeInsets.only(top: 2),
                        width: isActive ? 20 : 0,
                        height: 2,
                        decoration: BoxDecoration(
                          color: isActive ? AppColors.primary : Colors.transparent,
                          borderRadius: AppRadius.fullBorder,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _NavItem {
  final TwoToneIconData icon;
  final String labelKey;
  const _NavItem({required this.icon, required this.labelKey});
}
