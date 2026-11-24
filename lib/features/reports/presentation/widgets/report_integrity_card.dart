import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/services/currency/currency_engine.dart';
import '../../../core_business/data/local_directory/directory_scope.dart';
import '../../data/reports_api.dart';

Widget refreshReport({
  required bool local,
  required Future<void> Function() onRefresh,
  required Widget child,
}) => local
    ? RefreshIndicator.noSpinner(onRefresh: onRefresh, child: child)
    : RefreshIndicator(
        color: AppColors.primary,
        onRefresh: onRefresh,
        child: child,
      );

class ReportIntegrityCard extends StatelessWidget {
  const ReportIntegrityCard({
    super.key,
    required this.error,
    required this.onRetry,
  });
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ar = l10n.locale.languageCode == 'ar';
    final localMissing = error is ReportNotAvailableLocally;
    final containsLocal = BusinessReportsApi.includesDeviceLedger(error);
    final denied =
        error is DirectoryAccessDenied || error is ReportScopeChanged;
    final missing = BusinessReportsApi.missingRates(error);
    final pending = BusinessReportsApi.ratesPending(error);
    if (pending) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.currency_exchange_rounded,
              size: 36,
              color: AppColors.primary,
            ),
            const SizedBox(height: 14),
            Text(
              ar ? 'جارٍ تجهيز أسعار العملات' : 'Preparing exchange rates',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 16,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              ar
                  ? 'سيكتمل التقرير تلقائياً بعد مزامنة الأسعار. جميع العمليات والقيم الأصلية محفوظة.'
                  : 'Your report will be ready after rate synchronization. All original records are preserved.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                height: 1.6,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            OutlinedButton(
              onPressed: () async {
                final engine = ProviderScope.containerOf(
                  context,
                  listen: false,
                ).read(currencyEngineProvider);
                await engine.refreshIfStale(maxAge: Duration.zero);
                if (context.mounted) onRetry();
              },
              child: Text(
                ar ? 'تحديث' : 'Refresh',
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
            ),
          ],
        ),
      );
    }
    return Card(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.fact_check_outlined,
              color: AppColors.primary,
              size: 34,
            ),
            const SizedBox(height: 12),
            Text(
              denied
                  ? (ar ? 'غير مصرح بعرض التقرير' : 'Report access denied')
                  : missing.isEmpty
                  ? (ar ? 'تعذّر تجهيز التقرير' : 'Report unavailable')
                  : (ar
                        ? 'الإجمالي غير قابل للاعتماد بعد'
                        : 'Total is not yet verifiable'),
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              denied
                  ? (ar
                        ? 'تحقّق من الفرع والصلاحيات المحددة لهذا التقرير.'
                        : 'Check the selected branch and report permissions.')
                  : containsLocal
                  ? l10n.translate('repSelectDeviceBranch')
                  : localMissing
                  ? (ar
                        ? 'هذا التقرير لم يُنقل إلى دفتر الجهاز لهذا الفرع بعد. لن نعرض أرقام الدفتر القديم على أنها أرقام الفرع.'
                        : 'This report is not available from the device ledger yet. Older server figures are not shown for this branch.')
                  : missing.isEmpty
                  ? (ar
                        ? 'تحقق من الاتصال ثم أعد المحاولة.'
                        : 'Check the connection and retry.')
                  : (ar
                        ? 'القيم الأصلية محفوظة. يلزم سعر صرف موثّق لتواريخ العمليات أدناه. لن نعرض إجمالياً ناقصاً أو نستخدم سعر اليوم لعملية تاريخية. اطلب من الإدارة توثيق السعر التاريخي المعتمد ثم أعد المحاولة.'
                        : 'Original amounts are preserved. Documented rates are required for the dates below. No partial total or present-day rate will replace historical valuation. Ask administration to document the approved historical rate, then retry.'),
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                height: 1.65,
                color: AppColors.textSecondary,
              ),
            ),
            for (final row in missing.take(8))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${fmtNum(row['original_amount'])} ${currencyLabel('${row['currency']}')} • '
                  '${'${row['at']}'.split('T').first} → ${currencyLabel('${row['target']}')}',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(
                ar ? 'إعادة المحاولة' : 'Retry',
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ReportValuationNote extends StatelessWidget {
  const ReportValuationNote({super.key, required this.data});
  final Map? data;
  @override
  Widget build(BuildContext context) {
    final asRecorded = data?['local_valuation'] == 'as_recorded';
    if (!asRecorded &&
        (data?['fx_valuation'] as Map?)?['basis'] != 'latest_approved') {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final keys = asRecorded
        ? localReportNoticeKeys(data!)
        : ['repFxBasisLatest'];
    if (keys.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text(
        keys.map(l10n.translate).join('\n'),
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 10.5,
          height: 1.5,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

// The owner's rule: reports show their numbers, never warning lines. Why
// profit shows «—» is explained only by tapping it.
List<String> localReportNoticeKeys(Map data) => const [];

// ignore: unused_element
List<String> _legacyNoticeKeys(Map data) => [
  if (data['uncosted_stock'] != null && data['uncosted_stock'] != 0)
    'repLocalUncostedStock',
  // Why profit shows «—» is explained by tapping it (owner's choice).
  if (data['legacy_flow_unclassified'] == true) 'repLocalLegacyFlow',
  if (data['legacy_settlements_unlinked'] == true) 'repLocalLegacySettlements',
  if (data['pending_shared_cash'] == true) 'repLocalPendingCash',
];
