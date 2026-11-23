import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:fyona_flutter/shared/widgets/confirm_dialog.dart';
import 'package:fyona_flutter/features/subscription/di/subscription_providers.dart';
import 'package:fyona_flutter/features/subscription/presentation/pages/auto_renew_sheet.dart';
import 'package:fyona_flutter/features/subscription/presentation/widgets/stripe_error_messages.dart';

/// Auto-renewal management block for the subscription details sheet.
///
/// Read-only status + safe card display (brand/last4 only). Enabling always
/// goes through explicit consent + Stripe SetupIntent; disabling stops the
/// NEXT renewal only (the paid period stays usable until its end date).
/// UI truth for the renewal block, derived ONLY from backend state —
/// never from a local tap. `showSave` (no saved method), `showEnabled`
/// (on + off-session ready), `showFix` (on but not chargeable).
enum RenewalUiState { showSave, showEnabled, showFix }

RenewalUiState renewalUiState({
  required bool enabled,
  required bool hasSavedMethod,
  required bool offSessionReady,
}) {
  if (!hasSavedMethod) return RenewalUiState.showSave;
  if (enabled && offSessionReady) return RenewalUiState.showEnabled;
  if (enabled && !offSessionReady) return RenewalUiState.showFix;
  return RenewalUiState.showSave;
}

class AutoRenewSection extends ConsumerStatefulWidget {
  final String planName;
  final String period;
  final bool visible;

  const AutoRenewSection({
    super.key,
    required this.planName,
    this.period = 'yearly',
    this.visible = true,
  });

  @override
  ConsumerState<AutoRenewSection> createState() => _AutoRenewSectionState();
}

class _AutoRenewSectionState extends ConsumerState<AutoRenewSection> {
  Map<String, dynamic>? _status;
  bool _loading = true;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final st = await ref
          .read(subscriptionServiceProvider)
          .autoRenewStatus();
      if (!mounted) return;
      setState(() {
        _status = st;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _tr(String key, String fallback) =>
      AppLocalizations.of(context).translate(key) == key
          ? fallback
          : AppLocalizations.of(context).translate(key);

  Future<void> _enable() async {
    final done = await AutoRenewSheet.push(
      context,
      planName: widget.planName,
      period: widget.period,
    );
    if (done == true && mounted) {
      setState(() => _loading = true);
      await _load();
    }
  }

  Future<void> _disable() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: Text(_tr('autoRenewDisableTitle', 'إيقاف التجديد التلقائي'),
            style:
                const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
        content: Text(
            _tr('autoRenewDisableBody',
                'سيتوقف التجديد القادم فقط — يبقى اشتراكك فعالاً حتى نهاية المدة المدفوعة.'),
            style: const TextStyle(fontFamily: 'Cairo')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_tr('cancel', 'إلغاء'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_tr('autoRenewDisableConfirm', 'إيقاف التجديد'),
                  style: const TextStyle(
                      fontFamily: 'Cairo',
                      color: AppColors.danger,
                      fontWeight: FontWeight.bold))),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _working = true);
    try {
      await ref.read(subscriptionServiceProvider).disableAutoRenew();
      if (!mounted) return;
      showSnackbar(context,
          message: _tr('autoRenewDisabled', 'تم إيقاف التجديد القادم'),
          color: AppColors.success);
      setState(() => _loading = true);
      await _load();
    } catch (e) {
      if (!mounted) return;
      showSnackbar(context,
          message: e.toString(), color: AppColors.danger);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _completeFirstPayment() async {
    final secret = _status?['pending_client_secret']?.toString() ?? '';
    if (secret.isEmpty || !mounted) return;
    setState(() => _working = true);
    try {
      await Stripe.instance.confirmPayment(
        paymentIntentClientSecret: secret,
      );
      if (!mounted) return;
      setState(() => _loading = true);
      await _load();
      if (!mounted) return;
      final ok = _status?['enabled'] == true;
      showSnackbar(context,
          message: ok
              ? _tr('autoRenewEnabled', 'تم تفعيل التجديد التلقائي')
              : _tr('autoRenewActionIncomplete',
                  'لم تكتمل المصادقة بعد — أعد المحاولة لإتمام أول دفعة.'),
          color: ok ? AppColors.success : AppColors.warning);
    } catch (e) {
      if (!mounted) return;
      showSnackbar(context,
          message: _friendlyStripeError(e), color: AppColors.danger);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _friendlyStripeError(Object e) {
    if (e is StripeException) {
      final mapped = stripeDeclineMessage(
        declineCode: e.error.declineCode,
        stripeErrorCode: e.error.stripeErrorCode,
        arabic: AppLocalizations.currentLanguage != 'en',
      );
      if (mapped != null && mapped.isNotEmpty) return mapped;
      final message = e.error.localizedMessage ?? e.error.message ?? '';
      final net = stripeNetworkMessage(message,
          arabic: AppLocalizations.currentLanguage != 'en');
      if (net != null) return net;
      if (message.isNotEmpty) return message;
    }
    return _tr('subPayFailed', 'فشلت العملية');
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();
    final enabled = _status?['enabled'] == true;
    final card = _status?['card'] as Map?;
    // Backend truth with safe fallbacks when the live lookup failed:
    // a visible card implies a saved method; readiness defaults to true
    // so no spurious warning is shown offline.
    final hasSavedMethod =
        (_status?['has_saved_method'] as bool?) ?? (card != null);
    final offSessionReady =
        (_status?['off_session_ready'] as bool?) ?? true;
    final pendingAction = _status?['pending_action'] == true &&
        ((_status?['pending_client_secret']?.toString() ?? '').isNotEmpty);
    final uiState = renewalUiState(
      enabled: enabled,
      hasSavedMethod: hasSavedMethod,
      offSessionReady: offSessionReady,
    );
    final showFix = uiState == RenewalUiState.showFix;
    final cardLabel = card == null
        ? null
        : '${(card['brand']?.toString() ?? '').toUpperCase()} •••• ${card['last4'] ?? ''}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                  enabled
                      ? Icons.autorenew_rounded
                      : Icons.autorenew_outlined,
                  size: 18,
                  color: enabled ? AppColors.success : AppColors.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    '${_tr('autoRenewTitle', 'التجديد التلقائي')}: ${enabled ? _tr('autoRenewOn', 'مفعّل') : _tr('autoRenewOff', 'متوقف')}',
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 13),
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary)),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: (enabled ? AppColors.success : AppColors.textDisabled)
                      .withAlpha(20),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                    enabled
                        ? _tr('autoRenewOn', 'مفعّل')
                        : _tr('autoRenewOff', 'متوقف'),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        fontWeight: FontWeight.w700,
                        color: enabled
                            ? AppColors.success
                            : AppColors.textSecondary)),
              ),
            ],
          ),
          if (cardLabel != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.credit_card_rounded,
                    size: 15, color: AppColors.textSecondary),
                const SizedBox(width: 6),
                Text(cardLabel,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary)),
              ],
            ),
          ],
          const SizedBox(height: 12),
          if (showFix) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.warning.withAlpha(12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.warning.withAlpha(60)),
              ),
              child: Text(
                  _tr('autoRenewFixHint',
                      'التجديد مفعّل لكن وسيلة الدفع غير جاهزة للخصم التلقائي — أكمل الإعداد.'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 12),
                      color: AppColors.warning)),
            ),
            const SizedBox(height: 12),
          ],
          SizedBox(
            width: double.infinity,
            child: _loading || _working
                ? const Center(
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5)))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (pendingAction) ...[
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _completeFirstPayment,
                            icon: const Icon(Icons.verified_user_outlined,
                                size: 18),
                            label: Text(
                                _tr('autoRenewCompletePayment',
                                    'إكمال الدفعة الأولى'),
                                style: const TextStyle(
                                    fontFamily: 'Cairo',
                                    fontWeight: FontWeight.w800)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.warning,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  vertical: 12),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                              elevation: 0,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      if (!pendingAction)
                        OutlinedButton.icon(
                          // One primary action per state: enable when off,
                          // disable when fully on, never both.
                          onPressed: enabled && !showFix
                              ? _disable
                              : _enable,
                          icon: Icon(
                              (enabled && !showFix)
                                  ? Icons.stop_circle_outlined
                                  : Icons.play_circle_outline_rounded,
                              size: 18),
                          label: Text(
                              (enabled && !showFix)
                                  ? _tr('autoRenewDisable',
                                      'إيقاف التجديد التلقائي')
                                  : showFix
                                      ? _tr('autoRenewFix',
                                          'إكمال إعداد التجديد')
                                      : _tr('autoRenewEnable',
                                          'تفعيل التجديد التلقائي'),
                              style: const TextStyle(
                                  fontFamily: 'Cairo',
                                  fontWeight: FontWeight.w700)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: (enabled && !showFix)
                                ? AppColors.danger
                                : AppColors.success,
                            side: BorderSide(
                                color: (enabled && !showFix)
                                    ? AppColors.danger
                                    : AppColors.success,
                                width: 1.2),
                            padding:
                                const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      if (enabled && !showFix) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _working ? null : _enable,
                          icon: const Icon(
                              Icons.credit_card_rounded,
                              size: 18),
                          label: Text(
                              _tr('autoRenewChangeCard',
                                  'تغيير البطاقة'),
                              style: const TextStyle(
                                  fontFamily: 'Cairo',
                                  fontWeight: FontWeight.w700)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.textSecondary,
                            side: BorderSide(
                                color: AppColors.border, width: 1.2),
                            padding:
                                const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
