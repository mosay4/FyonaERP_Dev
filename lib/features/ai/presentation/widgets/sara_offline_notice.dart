import 'package:flutter/material.dart';

import '../../../../core/localization/app_localizations.dart';

/// Personal Sara is ONLINE-ONLY (owner's decision): with no network the
/// chat never answers from device data and never runs the local agent
/// loop — it shows [SaraOfflineNotice] instead. Business Sara keeps its own
/// behaviour. Sara's smart notifications are a separate, fully on-device
/// engine (smart_insights) and are NOT affected by this policy.
class SaraOnlinePolicy {
  SaraOnlinePolicy._();

  /// True when the chat for [accountType] must not handle a message now.
  static bool chatBlocked({required String accountType, required bool online}) =>
      accountType == 'personal' && !online;

  /// Whether the AI service may fall back to a local (offline) answer.
  static bool allowsOfflineFallback(String accountType) =>
      accountType == 'business';
}

/// Calm, theme-aware "Sara needs the internet" card shown above the
/// composer of the Personal chat while offline. Settles immediately (a
/// single short fade/slide, no looping animation).
class SaraOfflineNotice extends StatelessWidget {
  const SaraOfflineNotice({super.key, this.onRetry});

  /// Optional "try again" (re-checks connectivity).
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final light = Theme.of(context).brightness == Brightness.light;
    final primary = Theme.of(context).colorScheme.primary;
    final text = light ? const Color(0xFF1B1E23) : const Color(0xFFF0F0F0);
    final sub = light ? const Color(0xFF6B7280) : const Color(0xFF9A9A9A);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      builder: (_, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, 8 * (1 - v)), child: child),
      ),
      child: Container(
        key: const Key('saraOfflineNotice'),
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(
          color: light ? Colors.white : const Color(0xFF1B1C21),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: primary.withValues(alpha: light ? .18 : .28)),
          boxShadow: [
            BoxShadow(
              color: primary.withValues(alpha: light ? .06 : .12),
              blurRadius: 18,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: primary.withValues(alpha: .10),
              ),
              child: Icon(Icons.wifi_off_rounded, size: 18, color: primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.translate('saraPersonalOfflineTitle'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.translate('saraPersonalOfflineBody'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 11.5,
                      height: 1.5,
                      color: sub,
                    ),
                  ),
                ],
              ),
            ),
            if (onRetry != null)
              TextButton(
                key: const Key('saraOfflineRetry'),
                onPressed: onRetry,
                child: Text(
                  l10n.translate('retry'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: primary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
