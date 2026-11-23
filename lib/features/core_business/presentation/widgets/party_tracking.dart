import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:country_picker/country_picker.dart';
import 'package:dio/dio.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../../../shared/widgets/secure_image.dart';
import '../../../personal/data/merchant_api.dart';
import '../../../branches/data/branch_epoch.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../data/local_directory/directory_party.dart';
import '../../data/local_directory/directory_pilot.dart';
import '../../data/local_directory/directory_scope.dart';
import '../providers/business_party_sharing_provider.dart';
import 'business_online_gate.dart';

Future<bool> showPartyTrackingDialog(
  BuildContext context,
  WidgetRef ref, {
  required String partyKind,
  required String partyId,
  DirectoryPartyReference? localParty,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final epoch = container.read(branchEpochProvider);
  final branch = BranchScope.branchId;
  final org = BranchScope.organizationId;
  bool sameSelection() =>
      context.mounted &&
      container.read(branchEpochProvider) == epoch &&
      BranchScope.organizationId == org &&
      BranchScope.branchId == branch;
  if (!await ensureBusinessOnline(context) || !context.mounted) return false;
  if (!sameSelection()) return false;
  final l10n = AppLocalizations.of(context);
  final localSharing = localParty == null
      ? null
      : container.read(localBusinessPartySharingProvider);
  if (localParty != null && localSharing == null) {
    showFyonaSnack(
      context,
      l10n.translate('bizPartySharingUnavailable'),
      success: false,
    );
    return false;
  }
  final legacy = localParty == null
      ? container.read(merchantApiProvider)
      : null;
  final contactPermission = '${partyKind}s.edit';
  bool current() =>
      sameSelection() &&
      !BranchScope.readOnly &&
      container.read(employeeCanProvider(contactPermission)) &&
      (localParty == null
          ? container.read(directoryPilotAccessProvider) == null
          : localSharing!.allows(localParty, 'edit'));
  Map<String, dynamic> contact(String phone, String code, String? country) => {
    if (phone.isNotEmpty) 'phone': phone,
    if (code.isNotEmpty) 'code': code,
    if (country != null) 'country': country,
  };
  if (!current()) return false;
  final invited = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _TrackingDialog(
      current: current,
      local: localParty != null,
      partyKind: partyKind,
      lookup: (phone, code, country) => localParty == null
          ? legacy!.lookup(phone: phone, code: code, country: country)
          : localSharing!.lookup(localParty, contact(phone, code, country)),
      invite: (phone, code, country) async {
        if (localParty == null) {
          await legacy!.invite(
            partyKind: partyKind,
            partyId: partyId,
            phone: phone,
            code: code,
            country: country,
          );
        } else {
          await localSharing!.invite(localParty, contact(phone, code, country));
        }
      },
      l10n: l10n,
    ),
  );
  if (invited == true && current()) {
    showFyonaSnack(context, l10n.translate('merchantDone'), success: true);
  }
  return invited == true;
}

String _digits(String value) {
  const ar = '٠١٢٣٤٥٦٧٨٩', fa = '۰۱۲۳۴۵۶۷۸۹';
  for (var i = 0; i < 10; i++) {
    value = value.replaceAll(ar[i], '$i').replaceAll(fa[i], '$i');
  }
  return value.trim();
}

class _TrackingDialog extends ConsumerStatefulWidget {
  const _TrackingDialog({
    required this.current,
    required this.local,
    required this.partyKind,
    required this.lookup,
    required this.invite,
    required this.l10n,
  });
  final bool Function() current;
  final bool local;
  final String partyKind;
  final Future<Map<String, dynamic>> Function(String, String, String?) lookup;
  final Future<void> Function(String, String, String?) invite;
  final AppLocalizations l10n;
  @override
  ConsumerState<_TrackingDialog> createState() => _TrackingDialogState();
}

class _TrackingDialogState extends ConsumerState<_TrackingDialog> {
  final _ctrl = TextEditingController();

  final _countries = CountryService()
      .getAll()
      .where((c) => c.phoneCode.isNotEmpty)
      .toList();
  late Country _country = _countries.firstWhere((c) => c.countryCode == 'YE');
  bool _phoneMode = false, _busy = false;
  String? _error;
  Map<String, dynamic>? _found;
  String _query = '';
  bool get _ar => widget.l10n.locale.languageCode == 'ar';
  String t(String ar, String en) => _ar ? ar : en;
  String name(Country c) =>
      CountryLocalizations(
        Locale(_ar ? 'ar' : 'en'),
      ).countryName(countryCode: c.countryCode) ??
      c.name;
  @override
  void dispose() {
    _ctrl.dispose();

    super.dispose();
  }

  void _changeMode(bool phone) => setState(() {
    _phoneMode = phone;
    _ctrl.clear();
    _found = null;
    _error = null;
  });

  String _failure(Object error) {
    if (error is DirectoryAccessDenied)
      return widget.l10n.translate('unauthorized');
    if (widget.local &&
        error is DioException &&
        error.response?.statusCode == 404) {
      return widget.l10n.translate('bizPartySharingUnavailable');
    }
    if (error is DioException && error.response?.data is Map) {
      final data = error.response!.data as Map;
      final message = data['detail'] ?? data['message'];
      if (message is String) return message;
      if (message is Map && message['message'] is String) {
        return message['message'];
      }
    }
    return t(
      'تعذر البحث الآن، تأكد من الاتصال وحاول ثانية',
      'Could not search. Check your connection and retry.',
    );
  }

  Future<void> _search() async {
    if (_busy || !widget.current()) return;
    final value = _digits(_ctrl.text);
    if (!RegExp(_phoneMode ? r'^\d{4,15}$' : r'^\d{6}$').hasMatch(value)) {
      setState(
        () => _error = t(
          _phoneMode
              ? 'اكتب رقم الهاتف بدون رمز الدولة'
              : 'الرقم المميز لازم يكون ستة أرقام فقط',
          _phoneMode
              ? 'Enter the national phone number without the calling code.'
              : 'Enter exactly six digits.',
        ),
      );
      return;
    }
    FocusScope.of(context).unfocus();

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await ensureBusinessOnline(context) || !mounted || !widget.current())
        return;
      final found = await widget.lookup(
        _phoneMode ? value : '',
        _phoneMode ? '' : value,
        _phoneMode ? _country.countryCode : null,
      );
      if (!mounted || !widget.current()) return;
      setState(() {
        _found = found['found'] == true ? found : null;
        _query = value;
        if (_found == null) {
          _error = t(
            _phoneMode
                ? 'ما لقينا حساب بهذا الرقم تأكد من الرقم والدولة.'
                : 'لم نعثر على حساب بهذا الرقم المميز، تأكد من صحة الرقم.',
            _phoneMode
                ? 'No account found. Check the number and country.'
                : 'No account found with this public code. Check the code.',
          );
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = _failure(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    if (_busy || _found == null || !widget.current()) return;

    setState(() => _busy = true);
    try {
      if (!await ensureBusinessOnline(context) || !mounted || !widget.current())
        return;
      await widget.invite(
        _phoneMode ? _query : '',
        _phoneMode ? '' : _query,
        _phoneMode ? _country.countryCode : null,
      );
      if (mounted && widget.current()) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _failure(e);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseCountry() async {
    final query = TextEditingController();
    final selected = await showDialog<Country>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          final search = _digits(query.text).toLowerCase();
          final rows = _countries
              .where(
                (c) => '${name(c)} ${c.name} ${c.countryCode} +${c.phoneCode}'
                    .toLowerCase()
                    .contains(search),
              )
              .toList();
          final height =
              (MediaQuery.sizeOf(ctx).height -
                      MediaQuery.viewInsetsOf(ctx).bottom -
                      190)
                  .clamp(180.0, 500.0);
          return Dialog(
            backgroundColor: AppColors.surface,
            insetPadding: const EdgeInsets.all(24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            child: SizedBox(
              width: 420,
              height: height,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            t('اختيار الدولة', 'Choose country'),
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    TextField(
                      key: const ValueKey('tracking-country-search'),
                      controller: query,
                      onChanged: (_) => update(() {}),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search_rounded),
                        hintText: t(
                          'ابحث باسم الدولة أو رمزها',
                          'Search country or calling code',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: rows.length,
                        itemBuilder: (_, i) {
                          final c = rows[i];
                          return ListTile(
                            leading: Text(
                              c.flagEmoji,
                              style: const TextStyle(fontSize: 25),
                            ),
                            title: Text(
                              name(c),
                              style: const TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 13,
                              ),
                            ),
                            trailing: Text(
                              '+${c.phoneCode}',
                              textDirection: TextDirection.ltr,
                            ),
                            onTap: () => Navigator.pop(ctx, c),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    query.dispose();
    if (selected != null && mounted) {
      setState(() {
        _country = selected;
        _found = null;
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 430,
          maxHeight: math.max(
            220,
            MediaQuery.sizeOf(context).height -
                MediaQuery.viewInsetsOf(context).bottom -
                64,
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha(18),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.person_add_alt_1_rounded,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.l10n.translate(
                        widget.partyKind == 'supplier'
                            ? 'trackAddSupplier'
                            : 'trackAddCustomer',
                      ),
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 18),

              if (_found == null) ...[
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                      value: false,
                      label: Text(
                        t('الرقم المميز', 'Public code'),
                        key: const ValueKey('tracking-mode-code'),
                      ),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text(
                        t('رقم الهاتف', 'Phone'),
                        key: const ValueKey('tracking-mode-phone'),
                      ),
                    ),
                  ],
                  selected: {_phoneMode},
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    textStyle: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 11,
                    ),
                  ),
                  onSelectionChanged: _busy
                      ? null
                      : (v) => _changeMode(v.first),
                ),
                const SizedBox(height: 14),
                if (_phoneMode)
                  LayoutBuilder(
                    builder: (context, constraints) => Row(
                      textDirection: TextDirection.ltr,
                      children: [
                        SizedBox(
                          width: 112,
                          child: OutlinedButton(
                            onPressed: _busy ? null : _chooseCountry,
                            key: const ValueKey('tracking-country'),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                            ),
                            child: FittedBox(
                              child: Row(
                                textDirection: TextDirection.ltr,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _country.flagEmoji,
                                    style: const TextStyle(fontSize: 22),
                                  ),
                                  const SizedBox(width: 4),
                                  Text('+${_country.phoneCode}'),
                                  const Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    size: 16,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: math.max(0, constraints.maxWidth - 120),
                          child: _input(),
                        ),
                      ],
                    ),
                  )
                else
                  _input(),
                const SizedBox(height: 8),
                Text(
                  t(
                    _phoneMode
                        ? 'اختار الدولة واكتب الرقم بدون رمزها.'
                        : 'ستة أرقام موجودة في الملف الشخصي للحساب.',
                    _phoneMode
                        ? 'Choose the country, then enter the national number.'
                        : 'The six-digit code from the account profile.',
                  ),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 10,
                    color: AppColors.textSecondary,
                  ),
                ),
              ] else ...[
                if (_found!['avatar'] != null)
                  Center(
                    child: ClipOval(
                      child: SecureImage(
                        url: '${_found!['avatar']}',
                        width: 64,
                        height: 64,
                      ),
                    ),
                  ),
                Text(
                  '${_found!['name'] ?? ''}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _phoneMode ? '+${_country.phoneCode} $_query' : _query,
                  textDirection: TextDirection.ltr,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  t(
                    'هذا هو الحساب اللي تقصده؟',
                    'Is this the account you mean?',
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: 'Cairo'),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 12,
                      color: AppColors.danger,
                    ),
                  ),
                ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: _busy
                    ? null
                    : _found == null
                    ? _search
                    : _confirm,
                style: FilledButton.styleFrom(
                  backgroundColor: _found == null
                      ? AppColors.primary
                      : AppColors.success,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        t(
                          _found == null ? 'بحث' : 'نعم، أرسل الدعوة',
                          _found == null ? 'Search' : 'Yes, send invitation',
                        ),
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontWeight: FontWeight.w800,
                        ),
                      ),
              ),
              if (_found != null)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _found = null;
                          _error = null;
                        }),
                  child: Text(t('لا، أبحث مرة ثانية', 'No, search again')),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _input() => TextField(
    key: ValueKey(_phoneMode ? 'tracking-phone-input' : 'tracking-code-input'),
    controller: _ctrl,
    enabled: !_busy,
    keyboardType: TextInputType.number,
    textDirection: TextDirection.ltr,
    textInputAction: TextInputAction.search,
    maxLength: _phoneMode ? 15 : 6,
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9٠-٩۰-۹]'))],
    onSubmitted: (_) => _search(),
    decoration: InputDecoration(
      counterText: _phoneMode ? '' : null,
      labelText: t(
        _phoneMode ? 'رقم الهاتف' : 'الرقم المميز',
        _phoneMode ? 'Phone number' : 'Public code',
      ),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(13)),
    ),
    style: const TextStyle(fontFamily: 'Cairo', fontSize: 14),
  );
}
