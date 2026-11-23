import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../shared/widgets/business_widgets.dart';
import '../../../email/data/models/email_models.dart';
import '../../../email/presentation/providers/email_providers.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../core/localization/app_localizations.dart';

class EmailLogsPage extends ConsumerStatefulWidget {
  const EmailLogsPage({super.key});
  @override
  ConsumerState<EmailLogsPage> createState() => _EmailLogsPageState();
}

class _EmailLogsPageState extends ConsumerState<EmailLogsPage> {
  @override
  Widget build(BuildContext context) {
    final logsAsync = ref.watch(emailLogListProvider);

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: Text(AppLocalizations.of(context).translate('emailMailLog')),
          actions: [
            IconButton(
              icon: TwoToneIcon(data: TwoToneIcons.refresh),
              onPressed: () => ref.invalidate(emailLogListProvider),
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: () async => ref.invalidate(emailLogListProvider),
          child: logsAsync.when(
            loading: () => const LoadingShimmer(),
            error: (e, _) => EmptyStateWidget(
              title: AppLocalizations.of(context).translate('errorOccurred'),
              subtitle: e.toString(),
              icon: Icons.error_outline,
            ),
            data: (logs) {
              if (logs.isEmpty) {
                return EmptyStateWidget(
                  title: AppLocalizations.of(context).translate('emailThereAreNoMail'),
                  subtitle: AppLocalizations.of(context).translate('emailNoMessagesHaveBeen'),
                  icon: Icons.email,
                );
              }
              return ListView(
                padding: EdgeInsets.all(R.spacing(context)),
                children: logs.map((log) => _buildLogCard(log)).toList(),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildLogCard(EmailLog log) {
    final statusColor = log.status == 'sent' ? AppColors.success
        : log.status == 'failed' ? AppColors.danger
        : AppColors.warning;
    final statusLabel = log.status == 'sent' ? AppLocalizations.of(context).translate('emailSent')
        : log.status == 'failed' ? AppLocalizations.of(context).translate('failed')
        : AppLocalizations.of(context).translate('emailBeingSent');
    final dateStr = log.sentAt != null ? DateFormat('yyyy/MM/dd HH:mm').format(log.sentAt!) : '';

    return Container(
      margin: EdgeInsets.only(bottom: R.spacing(context)),
      child: Material(
        color: AppColors.surface,
        borderRadius: AppRadius.mdBorder,
        child: Container(
          padding: EdgeInsets.all(R.spacing(context)),
          decoration: BoxDecoration(
            borderRadius: AppRadius.mdBorder,
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const TwoToneIcon(data: TwoToneIcons.warning, size: 12, outlineColor: AppColors.danger),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(log.to, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'body'), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withAlpha(25),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: statusColor.withAlpha(80)),
                  ),
                  child: Text(statusLabel, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'caption'), fontWeight: FontWeight.w600, color: statusColor)),
                ),
              ]),
              const SizedBox(height: 6),
              Text(log.subject, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'body_small'), color: AppColors.textSecondary)),
              const SizedBox(height: 4),
              Row(children: [
                TwoToneIcon(data: TwoToneIcons.clock, size: 12, outlineColor: AppColors.textDisabled),
                const SizedBox(width: 4),
                Text(dateStr, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'caption'), color: AppColors.textDisabled)),
                if (log.error != null) ...[
                  const Spacer(),
                  const TwoToneIcon(data: TwoToneIcons.warning, size: 12, outlineColor: AppColors.danger),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(log.error!, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'caption'), color: AppColors.danger), overflow: TextOverflow.ellipsis),
                  ),
                ],
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
