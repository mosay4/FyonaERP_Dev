import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/responsive/breakpoints.dart';
import '../providers/auth_provider.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/router/route_names.dart';

class ChooseUsagePage extends ConsumerStatefulWidget {
  const ChooseUsagePage({super.key});

  @override
  ConsumerState<ChooseUsagePage> createState() => _ChooseUsagePageState();
}

class _ChooseUsagePageState extends ConsumerState<ChooseUsagePage> {
  bool _loading = false;
  late final AppLocalizations l10n;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    l10n = AppLocalizations.of(context);
  }

  Future<void> _choose(String mode) async {
    if (_loading) return;
    if (mode == 'business') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.translate('businessComingSoon'), style: const TextStyle(fontFamily: 'Cairo')),
        ),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      await ref.read(authProvider.notifier).setUsageMode(mode);
      // ننتظر دورة كاملة عشان GoRouter يتحدث بالـ auth state الجديد
      await Future.delayed(const Duration(milliseconds: 100));
      if (mounted) {
        // Mandatory phone step right after choosing usage — same design as before
        final user = ref.read(authProvider).user;
        final needsPhone = user == null || !user.hasPhone;
        if (needsPhone) {
          context.go('${RouteNames.phoneEntry}?mandatory=true');
          return;
        }
        final routeName = mode == 'personal' ? 'personal' : 'dashboard';
        context.goNamed(routeName);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.translate('authUsageModeError'), style: TextStyle(fontFamily: 'Cairo'))),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isPhone = Breakpoints.isPhone(width);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.star,
                  size: 56,
                  color: AppColors.primary,
                ),
                SizedBox(height: 16),
                Text(
                  l10n.translate('chooseUsageTitle'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: isPhone ? 22 : 26,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                SizedBox(height: 8),
                 Text(
                  l10n.translate('chooseUsageSubtitle'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 32),
                _buildChoiceCard(
                  icon: Icons.business,
                  title: l10n.translate('businessCardTitle'),
                  desc: l10n.translate('businessCardDesc'),
                  mode: 'business',
                ),
                const SizedBox(height: 16),
                _buildChoiceCard(
                  icon: Icons.person,
                  title: l10n.translate('personalCardTitle'),
                  desc: l10n.translate('personalCardDesc'),
                  mode: 'personal',
                ),
                const SizedBox(height: 16),
                _buildChoiceCard(
                  icon: Icons.work_history_rounded,
                  title: l10n.translate('bothCardTitle'),
                  desc: l10n.translate('bothCardDesc'),
                  mode: 'both',
                ),
                SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChoiceCard({
    required IconData icon,
    required String title,
    required String desc,
    required String mode,
  }) {
    return GestureDetector(
      onTap: _loading ? null : () => _choose(mode),
      child: Container(
        constraints: BoxConstraints(maxWidth: 320),
        width: double.infinity,
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadius.cardBorder,
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: Colors.white, size: 28),
            ),
             SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 16),
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    desc,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 12),
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_back_ios_new,
              color: AppColors.textDisabled,
            ),
          ],
        ),
      ),
    );
  }
}

