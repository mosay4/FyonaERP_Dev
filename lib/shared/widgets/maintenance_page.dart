import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/localization/app_localizations.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/providers/platform_controls_provider.dart';
import '../../../features/auth/presentation/providers/auth_provider.dart';

class MaintenancePage extends ConsumerStatefulWidget {
  const MaintenancePage({super.key});

  @override
  ConsumerState<MaintenancePage> createState() => _MaintenancePageState();
}

class _MaintenancePageState extends ConsumerState<MaintenancePage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;
  Timer? _poll;

  static String _featureLabel(AppLocalizations l10n, String key) {
    final k = key.startsWith('/') ? key.substring(1) : key;
    return switch (k.split('/').last) {
      'debts' => l10n.translate('personalDebts'),
      'savings' => l10n.translate('personalSavingsGoals'),
      'banks' => l10n.translate('personalBanks'),
      'budget' => l10n.translate('personalBudget'),
      'transactions' => l10n.translate('personalTransactions'),
      'ai' => l10n.translate('personalSara'),
      'suggestions' => l10n.translate('personalSuggestions'),
      _ => k.split('/').last,
    };
  }

  bool _isSectionLevel(String? key) =>
      key == null || key == 'all' || key == 'personal' || key == 'business';

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      ref.read(platformControlsProvider.notifier).refresh().then((_) {
        if (mounted) _checkAndDismiss();
      });
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  String? _queryKey(BuildContext ctx) =>
      GoRouterState.of(ctx).uri.queryParameters['key'];

  void _checkAndDismiss() {
    if (!mounted) return;
    final ctrl = ref.read(platformControlsProvider).valueOrNull;
    if (ctrl == null) return;
    final key = _queryKey(context);

    if (_isSectionLevel(key)) {
      if (key == 'all' && !ctrl.isAppMaintenance) {
        _navigateBack();
        return;
      }
      if ((key == 'personal' || key == 'business') &&
          ctrl.maintenance[key] != true &&
          !ctrl.isAppMaintenance) {
        _navigateBack();
        return;
      }
      return;
    }

    if (!ctrl.isFeatureDisabled(key ?? '') &&
        !ctrl.isRouteUnderMaintenance(key ?? '')) {
      _navigateBack();
    }
  }

  void _navigateBack() {
    if (!mounted) return;
    final key = _queryKey(context);

    if (_isSectionLevel(key)) {
      context.go(RouteNames.login);
      return;
    }

    final user = ref.read(authProvider).user;
    final mode = user?.preferredUsageMode;
    context.go(mode == 'personal'
        ? RouteNames.personalDashboard
        : RouteNames.dashboard);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final key = _queryKey(context);
    final isSection = _isSectionLevel(key);
    final isLight = AppColors.isLightMode;

    final String title;
    final String body;

    if (key == 'all') {
      title = l10n.translate('maintenanceModalAppTitle');
      body = l10n.translate('maintenanceModalAppBody');
    } else if (isSection) {
      final sectionName = l10n.translate(key == 'personal'
          ? 'maintenanceSectionPersonal'
          : 'maintenanceSectionBusiness');
      title = l10n.translate('maintenanceModalTitle');
      body = l10n.translate('maintenanceModalSectionBody',
          params: {'section': sectionName});
    } else {
      final featureName = _featureLabel(l10n, key ?? '');
      title = l10n.translate('maintenanceModalFeatureTitle');
      body = l10n.translate('maintenanceModalFeatureBody',
          params: {'feature': featureName});
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxWidth: 420),
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: AppColors.danger.withAlpha(isLight ? 100 : 70),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.danger.withAlpha(isLight ? 30 : 20),
                    blurRadius: 40,
                    spreadRadius: 4,
                  ),
                  BoxShadow(
                    color: Colors.black.withAlpha(25),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ScaleTransition(
                    scale: _pulseAnimation,
                    child: Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            AppColors.danger.withAlpha(35),
                            AppColors.danger.withAlpha(10),
                          ],
                        ),
                        border: Border.all(
                          color: AppColors.danger.withAlpha(50),
                          width: 1.5,
                        ),
                      ),
                      child: const Icon(
                        Icons.build_rounded,
                        color: AppColors.danger,
                        size: 42,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      color: AppColors.textPrimary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    body,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 14,
                      color: AppColors.textSecondary,
                      height: 1.8,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceVariant,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.notifications_active_rounded,
                            size: 14, color: AppColors.textSecondary),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            l10n.translate('maintenanceNotifyNote'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 11.5,
                              color: AppColors.textSecondary.withAlpha(210),
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton.icon(
                      onPressed: _navigateBack,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.danger,
                        foregroundColor: Colors.white,
                        elevation: 2,
                        shadowColor: AppColors.danger.withAlpha(80),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      icon: const Icon(Icons.arrow_back_rounded, size: 19),
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          l10n.translate('maintenanceModalBackToHome'),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
