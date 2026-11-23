import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:gal/gal.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/utils/subscription_identity.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../di/subscription_providers.dart';
import '../providers/subscription_providers.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';

/// Professional, plan-colored subscription invoice.
///
/// Data is resolved exactly like the profile's "ملخص الاشتراك" (single source
/// of truth = live `/subscription/status` + stored invoices + route params):
///   1. Route-provided params (set right after approval / payment — race-free).
///   2. Live subscription status snapshot (`subscriptionStatusProvider`).
///   3. Newest stored invoice (`subscriptionInvoicesProvider`).
///   4. Cached user model (offline fallback — the card NEVER disappears).
///
/// Arrives via the approval auto-transfer, the bell notifications tap, or
/// immediately after a card payment. Rendering is guaranteed: while the
/// sources load a skeleton frame is shown; only a total absence of data after
/// bounded retries produces an explicit error + retry — never a blank card.
class SubscriptionInvoiceScreen extends ConsumerStatefulWidget {
  final String? planName;
  final double? amount;
  final String? currency;
  final String? method;
  final String? invoiceNo;
  final String? period;
  final String? start;
  final String? end;
  final String? bank;
  final String? card;
  const SubscriptionInvoiceScreen({
    super.key,
    this.planName,
    this.amount,
    this.currency,
    this.method,
    this.invoiceNo,
    this.period,
    this.start,
    this.end,
    this.bank,
    this.card,
  });

  @override
  ConsumerState<SubscriptionInvoiceScreen> createState() => _SubscriptionInvoiceScreenState();
}

class _SubscriptionInvoiceScreenState extends ConsumerState<SubscriptionInvoiceScreen> {
  Timer? _retryTimer;
  int _retriesLeft = 2;
  bool _activating = false;
  final GlobalKey _invoiceKey = GlobalKey();

  Future<void> _bindAutoRenewForPaidCard() async {
    try {
      final data = ref.read(subscriptionStatusProvider).valueOrNull ?? {};
      final method = (widget.method ?? data['payment_method'] ?? '')
          .toString()
          .toLowerCase();
      final isCard = method.contains('card') ||
          method.contains('stripe') ||
          method.contains('international');
      final inv = (widget.invoiceNo ?? data['invoice_number']?.toString() ?? '')
          .trim();
      if (!isCard || inv.isEmpty) return;
      final service = ref.read(subscriptionServiceProvider);
      final res = await service
          .activateAutoRenewFromInvoice(invoiceNo: inv)
          .timeout(const Duration(seconds: 20));
      final needsAction = res['requires_action'] == true;
      final secret = res['client_secret']?.toString() ?? '';
      if (needsAction && secret.isNotEmpty) {
        try {
          await Stripe.instance
              .confirmPayment(paymentIntentClientSecret: secret);
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _goDashboard() async {
    if (_activating) return;
    setState(() => _activating = true);
    await _bindAutoRenewForPaidCard();
    if (!mounted) return;
    // Server entitlements decide the landing section (business-first when
    // business is active), never the old login-time mode.
    ref.invalidate(subscriptionStatusProvider);
    ref.invalidate(subscriptionPlansProvider);
    context.go('/account-entry');
  }

  @override
  void initState() {
    super.initState();
    // Fresh data on every open: status snapshot + stored invoices, so the
    // card can never render an older state after approval/renewal.
    Future.microtask(() {
      if (!mounted) return;
      try {
        ref.invalidate(subscriptionStatusProvider);
      } catch (_) {}
      try {
        ref.invalidate(subscriptionInvoicesProvider);
      } catch (_) {}
      _scheduleRetry();
    });
  }

  /// Bounded safety net: if the very first snapshot raced with activation,
  /// refetch at most twice, then stop forever (no infinite loading flicker).
  void _scheduleRetry() {
    if (!mounted || _retriesLeft <= 0) return;
    _retriesLeft--;
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      if (_hasAnyInvoiceData()) return; // data arrived — stop retrying
      try {
        ref.invalidate(subscriptionStatusProvider);
        ref.invalidate(subscriptionInvoicesProvider);
      } catch (_) {}
      _scheduleRetry();
    });
  }

  /// True when any concrete invoice data is already available from any source
  /// (route params, stored invoices, or live status).
  bool _hasAnyInvoiceData() {
    if ((widget.invoiceNo ?? '').isNotEmpty || widget.amount != null) return true;
    try {
      final stored = ref.read(subscriptionInvoicesProvider).valueOrNull;
      if (stored != null && stored.isNotEmpty) {
        final first = stored.first;
        if ((first['invoice_number']?.toString() ?? '').isNotEmpty ||
            (first['amount'] as num?) != null) return true;
      }
      final data = ref.read(subscriptionStatusProvider).valueOrNull ?? {};
      if ((data['invoice_number']?.toString() ?? '').isNotEmpty) return true;
      if ((data['plan_price'] as num?) != null) return true;
      if ((data['amount'] as num?) != null) return true;
    } catch (_) {}
    return false;
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  Future<Uint8List?> _captureInvoice() async {
    try {
      final boundary = _invoiceKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveInvoice() async {
    final bytes = await _captureInvoice();
    if (bytes == null || !mounted) return;
    try {
      await Gal.putImageBytes(bytes, album: 'FYONA');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).translate('invoiceSaved')), backgroundColor: AppColors.success),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).translate('invoiceSaveFailed')), backgroundColor: AppColors.danger),
        );
      }
    }
  }

  Future<void> _shareInvoice() async {
    final bytes = await _captureInvoice();
    if (bytes == null || !mounted) return;
    final xFile = XFile.fromData(bytes, name: 'fyona_invoice.png', mimeType: 'image/png');
    await Share.shareXFiles([xFile], text: 'FYONA Invoice');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final statusAsync = ref.watch(subscriptionStatusProvider);
    final invoicesAsync = ref.watch(subscriptionInvoicesProvider);
    final user = ref.watch(authProvider).user;

    final data = statusAsync.valueOrNull ?? {};
    final stored = invoicesAsync.valueOrNull;
    // §13: when opened from a notification deep-link (invoice_no param),
    // resolve THAT invoice — never a stale .first entry.
    Map<String, dynamic>? storedLatest;
    if (stored != null && stored.isNotEmpty) {
      final targetNo = (widget.invoiceNo ?? '').trim();
      if (targetNo.isNotEmpty) {
        for (final inv in stored) {
          final n = (inv['invoice_number']?.toString() ?? '').trim();
          if (n == targetNo) {
            storedLatest = inv;
            break;
          }
        }
      }
      storedLatest ??= stored.first;
    }

    // ── Data resolution (same source as the profile subscription summary) ──
    final end = widget.end ??
        data['end_date']?.toString() ??
        storedLatest?['subscription_end_date']?.toString() ??
        storedLatest?['end_date']?.toString() ??
        (user?.status == 'trial' ? user?.trialEndDate : user?.subscriptionEndDate);
    final start = widget.start ??
        data['start_date']?.toString() ??
        storedLatest?['subscription_start_date']?.toString() ??
        storedLatest?['start_date']?.toString() ??
        user?.subscriptionStartDate;
    final rawPlan = widget.planName ??
        data['plan_name']?.toString() ??
        data['plan']?.toString() ??
        storedLatest?['plan_name']?.toString() ??
        user?.subscriptionPlan;
    final plan = _normalizePlanKey(rawPlan);
    final rawAmt = widget.amount ??
        (data['plan_price'] as num?)?.toDouble() ??
        (data['amount'] as num?)?.toDouble() ??
        (storedLatest?['amount'] as num?)?.toDouble();
    final amt = rawAmt;
    final cur = (widget.currency ??
        data['currency']?.toString() ??
        data['plan_currency']?.toString() ??
        storedLatest?['currency']?.toString() ??
        'SAR').toString().toUpperCase();
    final payMethodRaw = widget.method ??
        data['payment_method']?.toString() ??
        storedLatest?['payment_method']?.toString();
    final payMethod = _methodLabel(payMethodRaw);
    final bankName = widget.bank ??
        data['bank_name']?.toString() ??
        storedLatest?['bank_name']?.toString();
    final cardBrand = widget.card ??
        data['card_brand']?.toString() ??
        storedLatest?['card_brand']?.toString();
    final periodRaw = widget.period ??
        data['period']?.toString() ??
        storedLatest?['period']?.toString();
    final period = periodRaw == 'monthly'
        ? l10n.translate('plansMonthly')
        : l10n.translate('plansYearly');
    final invoiceNo = widget.invoiceNo ??
        data['invoice_number']?.toString() ??
        data['invoice_no']?.toString() ??
        storedLatest?['invoice_number']?.toString();
    final orgName = storedLatest?['organization_name']?.toString() ??
        data['organization_name']?.toString();
    final userEmail = storedLatest?['user_email']?.toString() ?? user?.email;

    final identity = subscriptionIdentityColor(plan);

    // A real invoice exists when we have a concrete invoice number, an amount,
    // or at least a plan — enough to render the professional card.
    final hasData = (invoiceNo != null && invoiceNo.isNotEmpty) ||
        amt != null ||
        plan.isNotEmpty;

    final stillLoading = statusAsync.isLoading ||
        (invoicesAsync.isLoading && storedLatest == null);

    debugPrint(
      '[INVOICE] hasData=$hasData invoiceNo=$invoiceNo amt=$amt plan=$plan '
      'cur=$cur method=$payMethod period=$periodRaw '
      'loading=$stillLoading hasValue=${statusAsync.hasValue} '
      'invoicesLen=${(stored?.length ?? 0)} '
      'statusError=${statusAsync.hasError} routeParams(plan/amount)='
      '${widget.planName}/${widget.amount}',
    );

    if (!hasData) {
      // Loading frame — the card area is never blank.
      if (stillLoading) {
        return _buildLoadingFrame(context, l10n.translate('subInvoiceLoading'));
      }
      return _buildNoDataState(context);
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(l10n.translate('subInvoiceTitle'),
            style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
        centerTitle: true,
      ),
      // The whole page is scrollable; bottom insets (gesture nav bar,
      // display cutout) are added via SafeArea so the bottom action never
      // hides. Layout/padding/proportions are byte-identical to before.
      body: SafeArea(
        minimum: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewPadding.bottom + 10,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RepaintBoundary(
                key: _invoiceKey,
                child: _InvoicePaper(
                identity: identity,
                plan: plan,
                invoiceNo: invoiceNo,
                billToName: user?.fullName ?? '',
                billToEmail: userEmail ?? '',
                billToOrg: orgName ?? '',
                planLabel: _planLabel(rawPlan),
                period: period,
                start: start != null ? _formatDate(start) : null,
                end: end != null ? _formatDate(end) : null,
                amt: amt,
                cur: cur,
                payMethod: payMethod,
                bank: bankName,
                card: cardBrand,
                thanks: l10n.translate('subInvoiceThanks'),
                l10n: l10n,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _saveInvoice,
                      icon: Icon(Icons.download_rounded, size: 20, color: identity),
                      label: Text(l10n.translate('invoiceDownload'), style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w700, color: identity)),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: identity, width: 1.5),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _shareInvoice,
                      icon: const Icon(Icons.share_rounded, size: 20, color: Colors.white),
                      label: Text(l10n.translate('invoiceShare'), style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: identity,
                        foregroundColor: identity == AppColors.gold ? const Color(0xFF3A2E00) : Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: _activating ? null : _goDashboard,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: identity,
                    foregroundColor: identity == AppColors.gold
                        ? const Color(0xFF3A2E00)
                        : Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: _activating
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: identity == AppColors.gold
                                ? const Color(0xFF3A2E00)
                                : Colors.white,
                          ),
                        )
                      : const Icon(Icons.rocket_launch_rounded),
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(l10n.translate('subInvoiceStartNow'),
                        style: TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.w900)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── states ────────────────────────────────────────────────────────────

  Widget _buildLoadingFrame(BuildContext context, String label) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(l10n.translate('subInvoiceTitle'),
            style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
        centerTitle: true,
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppColors.primary),
            const SizedBox(height: 16),
            Text(label,
                style: TextStyle(fontFamily: 'Cairo', fontSize: 14, color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }

  Widget _buildNoDataState(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(l10n.translate('subInvoiceTitle'),
            style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
        centerTitle: true,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: AppColors.danger),
              const SizedBox(height: 12),
              Text(l10n.translate('coreServerError'),
                  style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () {
                  ref.invalidate(subscriptionStatusProvider);
                  ref.invalidate(subscriptionInvoicesProvider);
                },
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
                child: Text(l10n.translate('retry')),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => context.go(RouteNames.subscription),
                child: Text(l10n.translate('subInvoiceBrowsePlans'),
                    style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── helpers ───────────────────────────────────────────────────────────

  String _formatDate(String? d) {
    if (d == null || d.isEmpty) return '';
    final t = d.trim();
    // Server dates arrive as 'YYYY-MM-DD...' — convert to DD/MM/YYYY.
    if (t.length >= 10 && t[4] == '-' && t[7] == '-') {
      return '${t.substring(8, 10)}/${t.substring(5, 7)}/${t.substring(0, 4)}';
    }
    return t;
  }

  String _normalizePlanKey(String? p) {
    final k = subscriptionIdentityKey(p);
    if (k.isNotEmpty) return k;
    final lower = (p ?? '').trim().toLowerCase();
    if (lower.contains('free') || lower == 'مجاني') return 'free';
    if (lower.contains('personal') || lower == 'شخصي' || lower.contains('باقة شخصية')) return 'personal';
    if (lower.contains('business') && lower.contains('شخصي')) return 'premium';
    if (lower.contains('business') || lower == 'أعمال' || lower.contains('باقة أعمال')) return 'business';
    return p ?? '';
  }

  String _planLabel(String? p) {
    final k = subscriptionIdentityKey(p);
    if (k == subIdentityFree) return 'مجاني';
    if (k == subIdentityPersonal) return 'شخصي';
    if (k == subIdentityBusiness) return 'أعمال';
    if (k == subIdentityPremium) return 'أعمال + شخصي';
    switch ((p ?? '').trim().toLowerCase()) {
      case 'personal': case 'personal_plan': return 'شخصي';
      case 'business': case 'business_plan': return 'أعمال';
      case 'premium': case 'premium_plan': return 'أعمال + شخصي';
      case 'trial': return 'تجريبي';
      case 'free': return 'مجاني';
      default: return (p != null && p.isNotEmpty) ? p : '—';
    }
  }

  String _methodLabel(String? m) {
    switch (m) {
      case 'card':
      case 'stripe':
      case 'international':
        return 'دفع إلكتروني (بطاقة)';
      default:
        return 'تحويل بنكي';
    }
  }
}

/// The printable "paper" of the invoice: header band, bill-to block, detail
/// rows, total + paid seal and the footer line — all tinted with the plan's
/// identity color.
class _InvoicePaper extends StatelessWidget {
  final Color identity;
  final String plan;
  final String? invoiceNo;
  final String billToName;
  final String billToEmail;
  final String billToOrg;
  final String planLabel;
  final String period;
  final String? start;
  final String? end;
  final double? amt;
  final String cur;
  final String payMethod;
  final String? bank;
  final String? card;
  final String thanks;
  final AppLocalizations l10n;

  const _InvoicePaper({
    required this.identity,
    required this.plan,
    required this.invoiceNo,
    required this.billToName,
    required this.billToEmail,
    required this.billToOrg,
    required this.planLabel,
    required this.period,
    required this.start,
    required this.end,
    required this.amt,
    required this.cur,
    required this.payMethod,
    required this.bank,
    required this.card,
    required this.thanks,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    final amountText = amt != null ? _fmt(amt!) : '—';
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: identity.withAlpha(120), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(28),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header band (plan identity) ──
          Container(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: switch (identity) {
                  AppColors.gold => [Color(0xFF8E6B23), AppColors.gold, Color(0xFF8E6B23)],
                  AppColors.danger => [identity, Color(0xFF7B1A1A)],
                  AppColors.success => [identity, Color(0xFF1B5E20)],
                  _ => [Color(0xFF0D3D8A), identity],
                },
              ),
              borderRadius: BorderRadius.vertical(top: Radius.circular(19)),
            ),
            child: Row(
              children: [
                Container(
                  width: 52, height: 52,
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(30),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Center(child: Icon(Icons.receipt_long_rounded,
                      size: 28,
                      color: identity == AppColors.gold ? const Color(0xFF3A2E00) : Colors.white)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('FYONA ERP',
                          style: TextStyle(fontFamily: 'Cairo', color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900)),
                      Text(l10n.translate('subInvoiceReceipt'),
                          style: TextStyle(fontFamily: 'Cairo', color: Colors.white.withAlpha(210), fontSize: 12, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                if ((invoiceNo ?? '').isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(26),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(invoiceNo ?? '',
                        style: TextStyle(fontFamily: 'Cairo', color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Paid seal + status ──
                Row(
                  children: [
                    Expanded(
                      child: Text(l10n.translate('subInvoicePaid'),
                          style: TextStyle(fontFamily: 'Cairo', color: AppColors.success, fontSize: 13, fontWeight: FontWeight.w800)),
                    ),
                    Transform.rotate(
                      angle: -0.19,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppColors.success.withAlpha(14),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.success.withAlpha(180), width: 1.5),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle_rounded, size: 14, color: AppColors.success),
                            const SizedBox(width: 4),
                            Text(l10n.translate('subInvoiceStatusActive'),
                                style: TextStyle(fontFamily: 'Cairo', color: AppColors.success, fontSize: 12, fontWeight: FontWeight.w800)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                // ── Bill to ──
                _blockTitle(l10n.translate('subInvoiceBillTo')),
                if (billToName.isNotEmpty) _billRow(Icons.person_outline, billToName),
                if (billToEmail.isNotEmpty) _billRow(Icons.email_outlined, billToEmail),
                if (billToOrg.isNotEmpty) _billRow(Icons.workspace_premium_outlined, billToOrg),
                const SizedBox(height: 14),
                Divider(height: 2, color: AppColors.border),
                const SizedBox(height: 14),
                // ── Details ──
                _rowWithChip(
                  l10n.translate('subInvoicePlan'),
                  planLabel,
                  Container(
                    width: 10, height: 10,
                    decoration: BoxDecoration(color: identity, borderRadius: BorderRadius.circular(3)),
                  ),
                ),
                _row(l10n.translate('subInvoicePeriod'), period),
                if (start != null) _row(l10n.translate('subInvoiceStart'), start!),
                if (end != null) _row(l10n.translate('subInvoiceEnd'), end!),
                _row(l10n.translate('subInvoicePaymentMethod'), payMethod),
                if ((bank ?? '').isNotEmpty) _row(l10n.translate('subInvoiceBank'), bank!),
                if ((card ?? '').isNotEmpty) _row(l10n.translate('subInvoiceCardBrand'), (card ?? '').toUpperCase()),
                Divider(height: 2, color: AppColors.border),
                const SizedBox(height: 14),
                // ── Total ──
                Row(
                  children: [
                    Expanded(
                      child: Text(l10n.translate('subInvoiceTotal'),
                          style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w800)),
                    ),
                    Text('$amountText $cur',
                        style: TextStyle(fontFamily: 'Cairo', color: identity, fontSize: 22, fontWeight: FontWeight.w900)),
                  ],
                ),
                const SizedBox(height: 14),
                // ── Footer ──
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: identity.withAlpha(10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: identity.withAlpha(40)),
                  ),
                  child: Text(
                    thanks,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontFamily: 'Cairo', color: identity, fontSize: 12, height: 1.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _blockTitle(String t) {
    return Text(t,
        style: TextStyle(fontFamily: 'Cairo', color: AppColors.textDisabled, fontSize: 11, fontWeight: FontWeight.w600));
  }

  Widget _billRow(IconData icon, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppColors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(value,
                style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _row(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(k,
              style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary, fontSize: 13))),
          Flexible(child: Text(v, textAlign: TextAlign.end,
              style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w700))),
        ],
      ),
    );
  }

  Widget _rowWithChip(String k, String v, Widget chip) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(k,
              style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary, fontSize: 13))),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              chip,
              const SizedBox(width: 6),
              Flexible(child: Text(v, textAlign: TextAlign.end,
                  style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w700))),
            ],
          ),
        ],
      ),
    );
  }

  String _fmt(double v) => fmtNum(v);
}
