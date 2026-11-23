import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/phone_format.dart';
import '../../../../shared/widgets/secure_image.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../core_business/presentation/widgets/debt_widgets.dart';
import '../../../auth/presentation/widgets/app_pin_sheet.dart';
import '../../data/merchant_api.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// «حساباتي مع التجار» — the personal side: incoming invites + linked
/// merchants. Everything is real data from the backend; nothing is shared
/// before the user accepts.
class MerchantAccountsPage extends ConsumerStatefulWidget {
  const MerchantAccountsPage({super.key});
  @override
  ConsumerState<MerchantAccountsPage> createState() =>
      _MerchantAccountsPageState();
}

class _MerchantAccountsPageState extends ConsumerState<MerchantAccountsPage> {
  List<Map<String, dynamic>> _invites = [];
  List<Map<String, dynamic>> _merchants = [];
  List<Map<String, dynamic>> _filtered = [];
  final TextEditingController _search = TextEditingController();
  bool _loading = true;
  bool _selecting = false;
  String? _selectedLink;

  void _applySearch(String q) {
    final t = q.trim().toLowerCase();
    setState(() {
      _filtered = t.isEmpty
          ? _merchants
          : _merchants
              .where((m) =>
                  '${m['merchant_name'] ?? ''}'.toLowerCase().contains(t))
              .toList();
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final api = ref.read(merchantApiProvider);
      final invites = await api.myInvites();
      final merchants = await api.myMerchants();
      if (mounted) {
        setState(() {
          _invites = invites;
          _merchants = merchants;
          _loading = false;
        });
        _applySearch(_search.text);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _respond(Map inv, bool accept) async {
    final l10n = AppLocalizations.of(context);
    try {
      final api = ref.read(merchantApiProvider);
      if (accept) {
        await api.acceptInvite('${inv['link_id']}');
      } else {
        await api.rejectInvite('${inv['link_id']}');
      }
      if (mounted) {
        showFyonaSnack(context, l10n.translate('merchantDone'), success: true);
      }
      _load();
    } catch (_) {
      if (mounted) {
        showFyonaSnack(context, l10n.translate('merchantFailed'),
            success: false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        centerTitle: true,
        actions: [
          IconButton(
              tooltip: l10n.translate('merchantUnlinkTooltip'),
              icon: Icon(_selecting
                  ? Icons.close_rounded
                  : Icons.delete_outline_rounded),
              color: _selecting ? AppColors.danger : AppColors.textPrimary,
              onPressed: () => setState(() {
                    _selecting = !_selecting;
                    _selectedLink = null;
                  })),
          IconButton(
              icon: const Icon(Icons.notifications_outlined),
              onPressed: () => context.push('/personal/debt-notifications')),
        ],
        title: Text(
            _selecting
                ? l10n.translate('merchantUnlinkTooltip')
                : l10n.translate('merchantAccounts'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
      ),
      bottomNavigationBar: _selecting
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _selectedLink == null
                          ? AppColors.textDisabled
                          : AppColors.danger,
                      minimumSize: const Size(0, 54),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed:
                        _selectedLink == null ? null : _unlinkSelected,
                    icon: const Icon(Icons.delete_outline_rounded, size: 20),
                    label: Text(l10n.translate('merchantUnlinkBtn'),
                        maxLines: 1,
                        style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 14,
                            height: 1.4,
                            fontWeight: FontWeight.w800)),
                  ),
                ),
              ),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  FyonaTextField(
                    controller: _search,
                    onChanged: _applySearch,
                    decoration: InputDecoration(
                        hintText: l10n.translate('debtSearchMerchant'),
                        prefixIcon: const Icon(Icons.search_rounded),
                        isDense: true,
                        filled: true,
                        fillColor: AppColors.surface,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide:
                                BorderSide(color: AppColors.border))),
                  ),
                  if (_selecting)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(l10n.translate('merchantUnlinkSelect'),
                          style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 12,
                              color: Colors.grey)),
                    ),
                  const SizedBox(height: 14),
                  Row(children: [
                    Expanded(
                      child: Text(l10n.translate('merchantMyMerchants'),
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary)),
                    ),
                    const SizedBox(width: 8),
                    _requestsButton(l10n),
                  ]),
                  const SizedBox(height: 8),
                  if (_merchants.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: Text(l10n.translate('merchantNone'),
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 13,
                                color: AppColors.textSecondary)),
                      ),
                    )
                  else if (_filtered.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                          child: Text(l10n.translate('merchantNone'),
                              style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 13,
                                  color: AppColors.textSecondary))),
                    )
                  else
                    for (final m in _filtered) _merchantCard(l10n, m),
                ],
              ),
            ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
      );

  Widget _requestsButton(AppLocalizations l10n) {
    final n = _invites.length;
    return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showRequests(l10n),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: DebtStyle.red.withAlpha(12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: DebtStyle.red.withAlpha(50)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.mark_email_unread_outlined,
                size: 17, color: DebtStyle.red),
            const SizedBox(width: 6),
            Text(l10n.translate('merchantRequestsBtn'),
                style: DebtStyle.text(context,
                    size: 12.5, bold: true, color: DebtStyle.red)),
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                  color: n > 0 ? DebtStyle.red : Colors.grey.withAlpha(70),
                  borderRadius: BorderRadius.circular(10)),
              child: Text('$n',
                  style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: Colors.white)),
            ),
          ]),
        ),
    );
  }

  void _showRequests(AppLocalizations l10n) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: EdgeInsets.fromLTRB(
            16, 14, 16, 16 + MediaQuery.of(ctx).padding.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const DebtIcon(Icons.mark_email_unread_outlined, size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Text(l10n.translate('merchantRequestsBtn'),
                  style: DebtStyle.text(context, size: 16, bold: true)),
            ),
          ]),
          const SizedBox(height: 10),
          if (_invites.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Text(l10n.translate('merchantRequestsEmpty'),
                  style: DebtStyle.text(context, color: Colors.grey)),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _invites.length,
                itemBuilder: (_, i) => _requestCard(l10n, _invites[i], ctx),
              ),
            ),
        ]),
      ),
    );
  }

  String _merchantDisplay(Map inv) {
    var shop = '${inv['shop_name'] ?? ''}'.trim();
    // Never show the raw «X's Organization» / «Organization» label.
    shop = shop
        .replaceAll(RegExp(r"\s*'s\s+organization\s*$", caseSensitive: false), '')
        .trim();
    if (shop.toLowerCase() == 'organization') shop = '';
    final name = '${inv['merchant_name'] ?? ''}'.trim();
    return shop.isNotEmpty ? shop : (name.isNotEmpty ? name : 'تاجر');
  }


  Widget _requestCard(AppLocalizations l10n, Map inv, BuildContext sheetCtx) {
    final name = _merchantDisplay(inv);
    final number = formatIntlPhone('${inv['merchant_phone'] ?? ''}');
    final avatar = '${inv['merchant_avatar'] ?? ''}';
    final isSupplier = '${inv['kind']}' == 'supplier';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DebtStyle.surface(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DebtStyle.border(context)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          ClipOval(
            child: avatar.trim().isEmpty
                ? Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: DebtStyle.red.withAlpha(22),
                        shape: BoxShape.circle),
                    child: Text(
                        name.trim().isEmpty ? '?' : name.trim().characters.first,
                        style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontWeight: FontWeight.w800,
                            color: DebtStyle.red)),
                  )
                : SecureImage(
                    url: avatar.startsWith('uploads/') ? '/$avatar' : avatar,
                    width: 42,
                    height: 42,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 42,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: DebtStyle.red.withAlpha(22),
                          shape: BoxShape.circle),
                      child: Text(
                          name.trim().isEmpty
                              ? '?'
                              : name.trim().characters.first,
                          style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontWeight: FontWeight.w800,
                              color: DebtStyle.red)),
                    ),
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DebtStyle.text(context, size: 14, bold: true)),
                  if (number.trim().isNotEmpty)
                    Row(children: [
                      Flexible(
                        child: Text(
                            '${l10n.translate('merchantNumberLabel')}: ',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: DebtStyle.text(context,
                                size: 11.5, color: Colors.grey)),
                      ),
                      Directionality(
                        textDirection: TextDirection.ltr,
                        child: Text(number,
                            maxLines: 1,
                            style: DebtStyle.text(context,
                                size: 11.5, color: Colors.grey)),
                      ),
                    ]),
                  const SizedBox(height: 2),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                        color: DebtStyle.red.withAlpha(14),
                        borderRadius: BorderRadius.circular(7)),
                    child: Text(
                        l10n.translate(isSupplier
                            ? 'merchantClassifiedSupplier'
                            : 'merchantClassifiedCustomer'),
                        maxLines: 2,
                        style: DebtStyle.text(context,
                            size: 10, bold: true, color: DebtStyle.red)),
                  ),
                ]),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 38,
              child: FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1F9D55),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10))),
                onPressed: () {
                  Navigator.pop(sheetCtx);
                  _confirmLink(inv);
                },
                child: Text(l10n.translate('merchantApprove'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12,
                        fontWeight: FontWeight.w800)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 38,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    side: BorderSide(color: AppColors.danger.withAlpha(140)),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10))),
                onPressed: () {
                  Navigator.pop(sheetCtx);
                  _respond(inv, false);
                },
                child: Text(l10n.translate('merchantCancelBtn'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12,
                        fontWeight: FontWeight.w800)),
              ),
            ),
          ),
        ]),
      ]),
    );
  }

  Future<void> _confirmLink(Map inv) async {
    final l10n = AppLocalizations.of(context);
    final name = _merchantDisplay(inv);
    final number = formatIntlPhone('${inv['merchant_phone'] ?? ''}');
    final isSupplier = '${inv['kind']}' == 'supplier';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.translate('merchantConfirmLinkTitle'),
            style: const TextStyle(
                fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 15,
                      fontWeight: FontWeight.w800)),
              if (number.trim().isNotEmpty)
                Row(children: [
                  Flexible(
                    child: Text(
                        '${l10n.translate('merchantNumberLabel')}: ',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 12,
                            color: Colors.grey)),
                  ),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(number,
                        maxLines: 1,
                        style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 12,
                            color: Colors.grey)),
                  ),
                ]),
              Text(
                  l10n.translate(isSupplier
                      ? 'merchantClassifiedSupplier'
                      : 'merchantClassifiedCustomer'),
                  style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 11.5,
                      color: Colors.grey)),
              const SizedBox(height: 10),
              Text(
                  l10n.translate(
                      isSupplier
                          ? 'merchantLinkBodySupplier'
                          : 'merchantLinkBodyCustomer',
                      params: {'name': name}),
                  style: const TextStyle(
                      fontFamily: 'Cairo', fontSize: 12.5)),
            ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.translate('cancel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1F9D55)),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.translate('merchantConfirmBtn'),
                  style: const TextStyle(
                      fontFamily: 'Cairo', fontWeight: FontWeight.w800))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref
          .read(merchantApiProvider)
          .acceptInvite('${inv['link_id']}');
      await _load();
      if (mounted) {
        showFyonaSnack(context, l10n.translate('merchantLinkedOk'),
            success: true);
      }
    } catch (_) {
      if (mounted) {
        showFyonaSnack(context, l10n.translate('merchantFailed'),
            success: false);
      }
    }
  }

  Widget _merchantCard(AppLocalizations l10n, Map m) {
    final name = '${m['merchant_name'] ?? ''}';
    final linkId = '${m['link_id']}';
    final selected = _selectedLink == linkId;
    // Reference 4: merchant/shop name only — no phone, code, amounts.
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            if (!_selecting) {
              context.push(
                  '/personal/merchant-partner?link=$linkId&name=${Uri.encodeComponent(name)}');
              return;
            }
            setState(() => _selectedLink = selected ? null : linkId);
          },
          onLongPress: _selecting
              ? null
              : () => setState(() {
                    _selecting = true;
                    _selectedLink = linkId;
                  }),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
            decoration: BoxDecoration(
              color: DebtStyle.surface(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: selected ? DebtStyle.red : DebtStyle.border(context),
                  width: selected ? 2 : 1),
            ),
            child: Row(children: [
              const DebtIcon(Icons.storefront_outlined, size: 48),
              const SizedBox(width: 14),
              Expanded(
                  child: Text(name.isEmpty ? '—' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DebtStyle.text(context, size: 16, bold: true))),
              const SizedBox(width: 8),
              if (_selecting)
                Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: selected
                        ? DebtStyle.red
                        : DebtStyle.border(context))
              else
                const DebtArrow(),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _unlinkSelected() async {
    final linkId = _selectedLink;
    if (linkId == null) return;
    final l10n = AppLocalizations.of(context);
    Map<String, dynamic>? m;
    for (final row in _merchants) {
      if ('${row['link_id']}' == linkId) {
        m = row;
        break;
      }
    }
    final name = '${m?['merchant_name'] ?? ''}'.trim();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AppColors.danger.withAlpha(15), shape: BoxShape.circle),
            child: Icon(Icons.link_off_rounded, color: AppColors.danger),
          ),
          const SizedBox(width: 10),
          Expanded(
              child: Text(l10n.translate('merchantUnlinkTitle'),
                  style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 16,
                      fontWeight: FontWeight.w800))),
        ]),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (name.isNotEmpty)
                Text(name,
                    style: const TextStyle(
                        fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(l10n.translate('merchantUnlinkBody'),
                  style: const TextStyle(fontFamily: 'Cairo', fontSize: 12.5)),
            ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.translate('cancel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.translate('merchantUnlinkBtn'),
                  style: const TextStyle(
                      fontFamily: 'Cairo', fontWeight: FontWeight.w800))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final verified = await verifySensitiveAction(context, ref,
        reason: l10n.translate('merchantUnlinkBioReason'));
    if (!verified || !mounted) return;
    try {
      await ref.read(merchantApiProvider).unlinkMerchant(linkId);
      setState(() {
        _selecting = false;
        _selectedLink = null;
      });
      await _load();
      if (mounted) {
        showFyonaSnack(context, l10n.translate('merchantUnlinkDone'),
            success: true);
      }
    } catch (_) {
      if (mounted) {
        showFyonaSnack(context, l10n.translate('merchantFailed'),
            success: false);
      }
    }
  }
}

/// One merchant's own view: «ديوني» + «فواتيري» (two separate sections).
class MerchantPartnerPage extends ConsumerStatefulWidget {
  final String linkId;
  final String merchantName;
  const MerchantPartnerPage(
      {super.key, required this.linkId, required this.merchantName});
  @override
  ConsumerState<MerchantPartnerPage> createState() =>
      _MerchantPartnerPageState();
}

class _MerchantPartnerPageState extends ConsumerState<MerchantPartnerPage> {
  Map<String, dynamic> _debts = {};
  List<Map<String, dynamic>> _invoices = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final api = ref.read(merchantApiProvider);
      final debts = await api.partnerDebts(widget.linkId);
      final invoices = await api.partnerInvoices(widget.linkId);
      if (mounted) {
        setState(() {
          _debts = debts;
          _invoices = invoices;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map> get _debtRows =>
      (_debts['debts'] as List? ?? []).whereType<Map>().toList();

  Future<void> _requestPayment() async {
    final l10n = AppLocalizations.of(context);
    final row = _debtRows.isNotEmpty ? _debtRows.first : null;
    final ccy = '${row?['currency'] ?? 'SAR'}';
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.translate('merchantRecordPay'),
            style: TextStyle(fontFamily: 'Cairo')),
        content: FyonaTextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
              labelText: '${l10n.translate('merchantAmount')} ($ccy)',
              labelStyle: TextStyle(fontFamily: 'Cairo')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.translate('cancel'),
                  style: TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.translate('merchantSend'),
                  style: TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final amt = double.tryParse(ctrl.text.trim()) ?? 0;
    if (amt <= 0) return;
    try {
      await ref.read(merchantApiProvider).requestSettlement(
            linkId: widget.linkId,
            amount: amt,
            currency: ccy,
            idempotencyKey:
                'pay-${widget.linkId}-${DateTime.now().microsecondsSinceEpoch}',
          );
      if (mounted) {
        showFyonaSnack(context, l10n.translate('merchantSent'),
            success: true);
      }
    } catch (_) {
      if (mounted) {
        showFyonaSnack(context, l10n.translate('merchantFailed'),
            success: false);
      }
    }
    ctrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          centerTitle: true,
          title: Text(widget.merchantName,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary)),
          bottom: TabBar(
            labelStyle: TextStyle(
                fontFamily: 'Cairo', fontWeight: FontWeight.w800),
            tabs: [
              Tab(text: l10n.translate('merchantDebts')),
              Tab(text: l10n.translate('merchantInvoices')),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(children: [
                _debtsTab(l10n),
                _invoicesTab(l10n),
              ]),
      ),
    );
  }

  Widget _debtsTab(AppLocalizations l10n) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_debtRows.isEmpty)
          _empty(l10n.translate('merchantNone'))
        else
          for (final d in _debtRows)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(children: [
                Expanded(
                  child: Text('${d['currency']}',
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary)),
                ),
                Text(
                    '${l10n.translate('merchantYouOwe')} '
                    '${_fmt(d['debt'])}',
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: AppColors.warning)),
              ]),
            ),
      ],
    );
  }

  Widget _invoicesTab(AppLocalizations l10n) {
    if (_invoices.isEmpty) return _empty(l10n.translate('merchantNone'));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final i in _invoices)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text('${i['number'] ?? ''}',
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              color: AppColors.textPrimary)),
                    ),
                    Text('${i['date'] ?? ''}',
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 11,
                            color: AppColors.textSecondary)),
                  ]),
                  const SizedBox(height: 4),
                  Text(
                      '${l10n.translate('repTotalCol')}: ${_fmt(i['total'])} ${i['currency']}  '
                      '• ${l10n.translate('repRemaining')}: ${_fmt(i['remaining'])}',
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 12,
                          color: AppColors.textSecondary)),
                ]),
          ),
      ],
    );
  }

  Widget _empty(String t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 50),
        child: Center(
          child: Text(t,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 13,
                  color: AppColors.textSecondary)),
        ),
      );

  static String _fmt(dynamic v) {
    final d = (v is num) ? v.toDouble() : (num.tryParse('$v') ?? 0).toDouble();
    return d == d.roundToDouble()
        ? d.round().toString()
        : d.toStringAsFixed(2);
  }
}
