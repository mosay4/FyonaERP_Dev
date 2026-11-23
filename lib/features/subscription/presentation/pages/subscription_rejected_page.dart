import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../providers/subscription_providers.dart';

/// Reached when the user taps a rejection notification (or after the pending
/// poll surfaces a `rejected` status). Shows the admin's reason and offers a
/// clear path back to the plans screen.
class SubscriptionRejectedPage extends ConsumerWidget {
  final String? reason;
  const SubscriptionRejectedPage({super.key, this.reason});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final data = ref.watch(subscriptionStatusProvider).valueOrNull;
    final effectiveReason = (reason != null && reason!.isNotEmpty)
        ? reason!
        : (data?['rejection_reason']?.toString() ?? '');
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            children: [
              const Spacer(),
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: AppColors.danger.withAlpha(24),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: const Icon(Icons.cancel_rounded, size: 52, color: AppColors.danger),
              ),
              const SizedBox(height: 28),
              Text(
                l10n.translate('subRejectedTitle'),
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'Cairo', fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 14),
              if (effectiveReason.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withAlpha(10),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.danger.withAlpha(40)),
                  ),
                  child: Text(
                    effectiveReason,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontFamily: 'Cairo', fontSize: 14, color: AppColors.textSecondary, height: 1.8),
                  ),
                )
              else
                Text(
                  l10n.translate('subRejectedGeneric'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'Cairo', fontSize: 14, color: AppColors.textSecondary, height: 1.8),
                ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () {
                    context.go(RouteNames.subscription);
                  },
                  child: Text(l10n.translate('subRejectedRetry'),
                      style: const TextStyle(fontFamily: 'Cairo', fontSize: 15, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}