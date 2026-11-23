import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/router/route_names.dart';
import '../../../../shared/widgets/dots_loader.dart';
import '../providers/subscription_providers.dart';
import '../../di/subscription_providers.dart';

/// Shown right after the user submits a bank-transfer subscription request.
/// Explains that their request is under review, and AUTO-REFRESHES in the
/// background so the moment the admin approves, the user is taken directly to
/// their activated subscription invoice — no need to leave the app.
class SubscriptionPendingPage extends ConsumerStatefulWidget {
  const SubscriptionPendingPage({super.key});

  @override
  ConsumerState<SubscriptionPendingPage> createState() => _SubscriptionPendingPageState();
}

class _SubscriptionPendingPageState extends ConsumerState<SubscriptionPendingPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hCtrl;
  Timer? _poll;
  String? _rejectedReason;

  @override
  void initState() {
    super.initState();
    _hCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
      ..repeat();
    _startPolling();
    // Background upload of the receipt that was staged before navigation, so
    // the user reaches this waiting screen in the SAME second they tapped send.
    Future.microtask(_uploadReceipt);
  }

  /// Uploads the staged receipt in the background. On success the request is
  /// created and the status polling below picks up `pending`. On failure an
  /// inline retry is shown WITHOUT leaving this screen.
  Future<void> _uploadReceipt() async {
    final submission = ref.read(pendingReceiptProvider);
    if (submission == null) return;
    await ref.read(receiptUploadProvider.notifier).run(submission);
    if (!mounted) return;
    if (ref.read(receiptUploadProvider).succeeded) {
      ref.read(pendingReceiptProvider.notifier).clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).translate('subPaySubmittedOk')),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
      // The NEW request now exists server-side: wipe any stale rejection and
      // refresh the state immediately so the waiting screen shows instead of
      // the previous rejection view.
      try {
        ref.invalidate(subscriptionStatusProvider);
      } catch (_) {}
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) _checkStatus();
      });
    }
  }

  void _startPolling() {
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _checkStatus());
    // First check shortly after mount.
    Timer(const Duration(milliseconds: 1200), _checkStatus);
  }

  Future<void> _checkStatus() async {
    if (!mounted) return;
    try {
      final status = await ref.read(subscriptionServiceProvider).getStatus();
      if (!mounted) return;
      final st = (status['request_status'] ?? status['status'])?.toString();
      debugPrint('[PENDING] poll st=$st keys=${status.keys.toList()}');
      // Only a REAL paid activation leaves this screen: the status must be
      // active AND not a trial. A leftover trial must never bounce the user
      // to the invoice (that was the phantom-activation bug).
      if (st == 'active' && status['is_trial'] != true) {
        _poll?.cancel();
        ref.invalidate(subscriptionStatusProvider);
        ref.invalidate(subscriptionPlansProvider);
        final params = <String, String>{
          if ((status['plan_name']?.toString() ?? '').isNotEmpty)
            'plan': status['plan_name'].toString(),
          if ((status['plan_price']?.toString() ?? '').isNotEmpty)
            'amount': status['plan_price'].toString(),
          if ((status['currency']?.toString() ?? '').isNotEmpty)
            'currency': status['currency'].toString(),
          if ((status['payment_method']?.toString() ?? '').isNotEmpty)
            'method': status['payment_method'].toString(),
          if ((status['invoice_number']?.toString() ?? '').isNotEmpty)
            'invoice_no': status['invoice_number'].toString(),
          if ((status['period']?.toString() ?? '').isNotEmpty)
            'period': status['period'].toString(),
          if ((status['start_date']?.toString() ?? '').isNotEmpty)
            'start': status['start_date'].toString(),
          if ((status['end_date']?.toString() ?? '').isNotEmpty)
            'end': status['end_date'].toString(),
          if ((status['bank_name']?.toString() ?? '').isNotEmpty)
            'bank': status['bank_name'].toString(),
          if ((status['card_brand']?.toString() ?? '').isNotEmpty)
            'card': status['card_brand'].toString(),
        };
        final qs = params.entries
            .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
            .join('&');
        context.go('${RouteNames.subscriptionInvoice}${qs.isEmpty ? '' : '?$qs'}');
      } else if (st == 'pending' || st == 'none') {
        // A NEW request (or none) supersedes any earlier rejection: clear the
        // stale rejection view so a re-submission shows the waiting screen
        // instead of bouncing back to the old rejection.
        if (_rejectedReason != null) {
          setState(() => _rejectedReason = null);
        }
      } else if (st == 'rejected') {
        // Never show the OLD rejection while a NEW submission is still being
        // uploaded (its request row may not exist yet, so the status endpoint
        // still reflects the previous rejected request).
        final submission = ref.read(pendingReceiptProvider);
        final uploadDone = ref.read(receiptUploadProvider).succeeded;
        if (submission == null || uploadDone) {
          _poll?.cancel();
          ref.invalidate(subscriptionStatusProvider);
          setState(() => _rejectedReason = status['rejection_reason']?.toString() ?? '');
        }
      }
    } catch (_) {
      // transient network error — keep polling
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _hCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_rejectedReason != null) {
      return _RejectedView(
        reason: _rejectedReason!,
        onRetry: () {
          ref.invalidate(subscriptionStatusProvider);
          ref.invalidate(subscriptionPlansProvider);
          context.go(RouteNames.subscription);
        },
      );
    }
    return PopScope(
      // While the request is being reviewed the user is LOCKED on this screen:
      // the Android back button / gestures may not leave. Once the admin has
      // rejected (reason shown), leaving is permitted.
      canPop: _rejectedReason != null,
      child: Scaffold(
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
                // Animated hourglass
                AnimatedBuilder(
                  animation: _hCtrl,
                  builder: (_, __) => Transform.rotate(
                    angle: _hCtrl.value * 6.28318,
                    child: Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(colors: [AppColors.primary, AppColors.primaryDark]),
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: [
                          BoxShadow(color: AppColors.primary.withAlpha(80), blurRadius: 24, offset: const Offset(0, 8)),
                        ],
                      ),
                      child: const Icon(Icons.hourglass_bottom_rounded, size: 46, color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  l10n.translate('subPendingTitle'),
                  textAlign: TextAlign.center,
                  style:  TextStyle(fontFamily: 'Cairo', fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.textPrimary),
                ),
                const SizedBox(height: 14),
                Text(
                  'سيقوم فريقنا بمراجعة طلبك في أقرب وقت. عند الموافقة سيوصلك إشعار في التطبيق يحتوي على جميع تفاصيل اشتراكك.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'Cairo', fontSize: 14, color: AppColors.textSecondary, height: 1.9),
                ),
                const SizedBox(height: 22),
                const DotsLoader(size: 12),
                const SizedBox(height: 18),
                // Live upload state of the staged receipt (only shown while a
                // submission exists — plain deep links have nothing to send).
                if (ref.watch(pendingReceiptProvider) != null)
                  _UploadStatusCard(
                    state: ref.watch(receiptUploadProvider),
                    onRetry: _uploadReceipt,
                    onCancel: () {
                      ref.read(receiptUploadProvider.notifier).reset();
                      ref.read(pendingReceiptProvider.notifier).clear();
                      context.go(RouteNames.subscription);
                    },
                  ),
                const Spacer(),
                // No home/back button while PENDING: the user stays here until
                // the admin approves (→ invoice) or rejects (→ reason view).
                // The router also blocks leaving to plans during review.
                Text(
                  l10n.translate('subPendingStayHint'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: AppColors.textDisabled, height: 1.7),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Inline status of the background receipt upload: uploading → success →
/// error+retry. Never navigates anywhere by itself.
class _UploadStatusCard extends StatelessWidget {
  final ReceiptUploadState state;
  final VoidCallback onRetry;
  final VoidCallback onCancel;
  const _UploadStatusCard({required this.state, required this.onRetry, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: state.error != null
            ? AppColors.danger.withAlpha(10)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: state.error != null
              ? AppColors.danger.withAlpha(45)
              : AppColors.border,
        ),
      ),
      child: state.uploading
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.translate('subPendingUploading'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textSecondary),
                  ),
                ),
              ],
            )
          : state.error != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.cloud_off_rounded, size: 18, color: AppColors.danger),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.translate('subPendingUploadFailed', params: {'error': state.error!}),
                            textAlign: TextAlign.center,
                            style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.textSecondary, height: 1.6),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton.icon(
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: Text(l10n.translate('subPendingUploadRetry'), style: const TextStyle(fontFamily: 'Cairo')),
                        ),
                        TextButton(
                          onPressed: onCancel,
                          child: Text(l10n.translate('subPendingUploadCancel'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textDisabled)),
                        ),
                      ],
                    ),
                  ],
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check_circle_rounded, size: 18, color: AppColors.success),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.translate('subPaySubmittedOk'),
                        textAlign: TextAlign.center,
                        style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.success),
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _RejectedView extends StatelessWidget {
  final String reason;
  final VoidCallback onRetry;
  const _RejectedView({required this.reason, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
                style:  TextStyle(fontFamily: 'Cairo', fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.textPrimary),
              ),
              const SizedBox(height: 14),
              if (reason.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withAlpha(10),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.danger.withAlpha(40)),
                  ),
                  child: Text(
                    reason,
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
                  onPressed: onRetry,
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
