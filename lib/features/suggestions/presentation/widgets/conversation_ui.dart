import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/utils/date_formatter.dart';

/// Circular avatar showing the user's first character, styled like the rest
/// of the FYONA suggestions UI.
class ConversationAvatar extends StatelessWidget {
  final String name;
  final double size;
  final bool isAdmin;

  const ConversationAvatar({
    super.key,
    required this.name,
    this.size = 40,
    this.isAdmin = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isAdmin ? AppColors.primary : AppColors.info;
    final ch = name.trim().isNotEmpty ? name.trim().characters.first : AppLocalizations.of(context).translate('suggestionsText2');
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          ch,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w700,
            fontSize: size * 0.42,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// Compact relative Arabic time, e.g. "الآن" / "قبل 5 د" / "قبل 3 س" / "قبل 2 ي".
String timeAgo(String? raw) {
  final ts = DateTime.tryParse(raw ?? '');
  if (ts == null) return '';
  final diff = DateTime.now().difference(ts.toLocal());
  if (diff.inSeconds < 60) return AppLocalizations.t('justNow');
  if (diff.inMinutes < 60) return AppLocalizations.t('suggestionsBeforeD', {'inMinutes': diff.inMinutes});
  if (diff.inHours < 24) return AppLocalizations.t('suggestionsBeforeS', {'inHours': diff.inHours});
  if (diff.inDays < 7) return AppLocalizations.t('suggestionsBeforeJ', {'inDays': diff.inDays});
  return '${ts.year}/${ts.month}/${ts.day}';
}

/// Short clock time for message bubbles, e.g. "2:30 م".
String clockTime(String? raw) {
  final ts = DateTime.tryParse(raw ?? '');
  if (ts == null) return '';
  final local = ts.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final ampm = local.hour < 12 ? AppLocalizations.t('suggestionsP') : AppLocalizations.t('suggestionsM');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute $ampm';
}

/// Humanized label for a suggestion status.
(String, Color) statusLabel(String status) {
  return switch (status) {
    'rejected' => (AppLocalizations.t('adminUnacceptable'), AppColors.danger),
    'completed' =>
      (AppLocalizations.t('suggestionsStatusCompleted'), AppColors.success),
    'in_progress' =>
      (AppLocalizations.t('suggestionsStatusInProgress'), AppColors.info),
    'proposed' => (AppLocalizations.t('suggestionsStatusProposed'), AppColors.warning),
    _ => (AppLocalizations.t('suggestionsStatusPending'), AppColors.warning),
  };
}

/// Short explanation shown in the status legend dialog.
String statusDescription(String status) {
  return switch (status) {
    'rejected' => AppLocalizations.t('suggestionsStatusRejectedDesc'),
    'completed' => AppLocalizations.t('suggestionsStatusCompletedDesc'),
    'in_progress' => AppLocalizations.t('suggestionsStatusInProgressDesc'),
    'proposed' => AppLocalizations.t('suggestionsStatusProposedDesc'),
    _ => AppLocalizations.t('suggestionsStatusPendingDesc'),
  };
}

/// The five statuses a suggestion can be in, in display order.
const List<String> suggestionStatuses = [
  'pending',
  'proposed',
  'in_progress',
  'completed',
  'rejected',
];

/// Horizontal "اليوم / أمس / dd MMM yyyy" separator between chat days.
class ConversationDateSeparator extends StatelessWidget {
  final DateTime date;
  const ConversationDateSeparator({super.key, required this.date});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final diff = now.difference(date).inDays;
    String label;
    if (diff == 0) {
      label = AppLocalizations.of(context).translate('today');
    } else if (diff == 1) {
      label = AppLocalizations.of(context).translate('yesterday');
    } else {
      label = localizedShortDate(context, date);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
           Expanded(child: Divider(color: AppColors.divider, height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(label,
                style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    color: AppColors.textDisabled)),
          ),
           Expanded(child: Divider(color: AppColors.divider, height: 1)),
        ],
      ),
    );
  }
}

/// Full-screen pinch-zoom viewer for a suggestion image.
void showSuggestionImageFullScreen(BuildContext context, Uint8List bytes) {
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black87,
      pageBuilder: (_, _, _) => _FullScreenImage(bytes: bytes),
    ),
  );
}

class _FullScreenImage extends StatelessWidget {
  final Uint8List bytes;
  const _FullScreenImage({required this.bytes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close, color: Colors.white),
        ),
      ),
      body: InteractiveViewer(
        maxScale: 5,
        child: Center(
          child: Image.memory(bytes, fit: BoxFit.contain),
        ),
      ),
    );
  }
}
