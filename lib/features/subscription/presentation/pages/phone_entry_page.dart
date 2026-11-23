import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/utils/country_names.dart';
import 'package:fyona_flutter/core/utils/country_phone_data.dart';
import 'package:fyona_flutter/core/utils/phone_format.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/responsive/breakpoints.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../personal/di/personal_providers.dart';
import '../../../business_banks/presentation/providers/business_banks_providers.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/currency/enabled_currencies_service.dart';
import '../../../../core/services/currency/business_currency_scope.dart'
    show ensureBizCountryDefaults, loadBizEnabledCurrencies;
import '../../../../shared/providers/current_user_provider.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Display names come from the shared [countryName] helper so the picker
/// follows the app language (Arabic / English). Numbering examples come
/// from [kPhoneCountries] (per-country leading digits).
const _countries = kPhoneCountries;

typedef _Country = PhoneCountry;

String _flagOf(String iso) {
  final base = 0x1F1E6;
  return String.fromCharCode(base + iso.codeUnitAt(0) - 65) +
      String.fromCharCode(base + iso.codeUnitAt(1) - 65);
}

class PhoneEntryPage extends ConsumerStatefulWidget {
  final bool isMandatory;
  const PhoneEntryPage({super.key, this.isMandatory = false});

  @override
  ConsumerState<PhoneEntryPage> createState() => _PhoneEntryPageState();
}

class _PhoneEntryPageState extends ConsumerState<PhoneEntryPage> {
  final _phoneController = TextEditingController();
  String _iso = 'YE';
  String? _error;
  bool _loading = false;

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  _Country get _selected =>
      _countries.firstWhere((c) => c.iso == _iso, orElse: () => _countries.first);

  Future<void> _pickCountry() async {
    final picked = await showModalBottomSheet<_Country>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _CountryPickerSheet(initial: _iso),
    );
    if (picked != null && mounted) setState(() => _iso = picked.iso);
  }

  Future<void> _onSave() async {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty) {
      setState(() => _error = AppLocalizations.of(context).translate('subPhoneRequired'));
      return;
    }
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 7) {
      setState(() => _error = AppLocalizations.of(context).translate('subPhoneIncomplete'));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final error = await ref
          .read(authProvider.notifier)
          .updatePhone(phone: phone, country: _iso);
      if (error != null) {
        if (mounted) {
          setState(() {
            _error = error;
            _loading = false;
          });
        }
        return;
      }
      if (!mounted) return;
      // Adopt this country's default currencies for fresh accounts (never
      // overrides a customization the user already saved), then ensure a
      // cash account exists for each of them. BOTH scopes are seeded so
      // Personal and Business start from the country's set independently.
      try {
        final uid = ref.read(currentUserIdProvider).trim();
        await ensureCountryDefaults(_iso, uid);
        await ensureBizCountryDefaults(_iso, uid);
        // Only the user's enabled set may materialize as cash: re-saving
        // the phone must never resurrect a currency the user removed.
        final enabled = await loadEnabledCurrencies(uid);
        await ref
            .read(personalFinanceServiceProvider)
            .ensureCashAccounts(defaultCurrenciesForCountry(_iso),
                enabled: enabled);
        final bizEnabled = await loadBizEnabledCurrencies(uid);
        await ref.read(bizCashServiceProvider).ensureCashAccounts(
            defaultCurrenciesForCountry(_iso),
            enabled: bizEnabled);
      } catch (_) {}
      if (!mounted) return;
      showSnackbar(context,
          message: AppLocalizations.of(context).translate('subPhoneSaved'), color: AppColors.success);
      if (widget.isMandatory) {
        // Mandatory first-run flow: phone done → straight into the
        // subscription activation section (never the dashboard).
        if (mounted) context.go(RouteNames.subscription);
      } else {
        context.pop(true);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = AppLocalizations.of(context).translate('subPhoneSaveFailed');
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isPhone = Breakpoints.isPhone(width);
    final _user = ref.watch(authProvider).user;
    final currentPhone = (_user?.phone ?? '').isNotEmpty
        ? maskIntlPhone(_user!.phone!)
        : _user?.phoneMasked;
    final isEditing = !widget.isMandatory;

    return PopScope(
      canPop: !widget.isMandatory,
      child: Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          AppLocalizations.of(context).translate(
              isEditing ? 'subPhoneEditTitle' : 'subPhoneAddTitle'),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 18),
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: !widget.isMandatory,
        leading: widget.isMandatory
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                color: AppColors.textPrimary,
                onPressed: () => context.pop(false),
              ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: isPhone ? 24 : 40,
              vertical: 24,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Icon ──
                  Container(
                    width: 80,
                    height: 80,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          AppColors.primary.withAlpha(25),
                          AppColors.primary.withAlpha(10),
                        ],
                      ),
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.primary.withAlpha(40)),
                    ),
                    child: const Icon(Icons.phone_android, size: 36, color: AppColors.primary),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    AppLocalizations.of(context).translate(
                        isEditing ? 'subPhoneEditSubtitle' : 'subPhoneSubtitle'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: isPhone ? 18 : 22,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppLocalizations.of(context).translate('subPhonePrivacy'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      color: AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xxl),

                  // ── Full phone error banner (never truncated) ──
                  if (_error != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.danger.withAlpha(18),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.danger.withAlpha(70), width: 1),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.error_outline_rounded, size: 20, color: AppColors.danger),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _error!,
                              softWrap: true,
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: R.fontSize(context, 13),
                                fontWeight: FontWeight.w700,
                                color: AppColors.danger,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // ── Phone input row ──
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Country code selector
                        _buildCountryCodeButton(),
                        const SizedBox(width: 10),
                        // Phone number field
                        Expanded(child: _buildPhoneField()),
                      ],
                    ),
                  ),

                  if (currentPhone != null && currentPhone.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.lg),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceVariant.withAlpha(120),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.info_outline, size: 14, color: AppColors.textSecondary),
                          const SizedBox(width: 6),
                          Text(
                            AppLocalizations.of(context).translate('subPhoneCurrent', params: {'phone': currentPhone}),
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 12),
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: AppSpacing.xl),
                  SizedBox(
                    width: double.infinity,
                    height: isPhone ? 50 : 54,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: AppColors.primary.withAlpha(100),
                        elevation: 0,
                        shadowColor: AppColors.primary.withAlpha(80),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.buttonRadius),
                        ),
                      ),
                      onPressed: (_loading || _phoneController.text.trim().isEmpty)
                          ? null
                          : _onSave,
                      child: _loading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                            )
                          : FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                AppLocalizations.of(context).translate(
                                    isEditing
                                        ? 'subPhoneSaveNew'
                                        : 'subPhoneSave'),
                                maxLines: 1,
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: R.fontSize(context, 16),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildCountryCodeButton() {
    return GestureDetector(
      onTap: _pickCountry,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 52,
        constraints: const BoxConstraints(minWidth: 120),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.inputRadius),
          border: Border.all(
            color: _error != null ? AppColors.danger : AppColors.border,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_flagOf(_selected.iso), style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 8),
            Text(
              _selected.cc,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 15),
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  Widget _buildPhoneField() {
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.inputRadius),
        border: Border.all(
          color: _error != null ? AppColors.danger : AppColors.border,
          width: 1,
        ),
      ),
      child: FyonaTextField(
        controller: _phoneController,
        keyboardType: TextInputType.phone,
        textInputAction: TextInputAction.done,
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: R.fontSize(context, 15),
          fontWeight: FontWeight.w500,
          color: AppColors.textPrimary,
        ),
        textAlign: TextAlign.left,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
          LengthLimitingTextInputFormatter(15),
        ],
        onChanged: (_) {
          setState(() {
            if (_error != null) _error = null;
          });
        },
        decoration: InputDecoration(
          hintText: _selected.example,
          hintStyle: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 14),
            color: AppColors.textPlaceholder,
          ),
          prefixIcon: Icon(Icons.phone_outlined, size: 18, color: AppColors.textSecondary),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════
//  COUNTRY PICKER SHEET — Full-screen with search + 2-col grid
// ════════════════════════════════════════════════════════════
class _CountryPickerSheet extends StatefulWidget {
  final String initial;
  const _CountryPickerSheet({required this.initial});

  @override
  State<_CountryPickerSheet> createState() => _CountryPickerSheetState();
}

class _CountryPickerSheetState extends State<_CountryPickerSheet> {
  final _searchCtrl = TextEditingController();
  late List<_Country> _filtered;
  String? _selectedIso;

  bool _isAr() => Localizations.localeOf(context).languageCode == 'ar';

  String _countryLabel(_Country c) => countryName(c.iso, isAr: _isAr());

  // Group countries by first letter of the localized name
  Map<String, List<_Country>> get _grouped {
    final map = <String, List<_Country>>{};
    for (final c in _filtered) {
      final key = _countryLabel(c).characters.first;
      map.putIfAbsent(key, () => []).add(c);
    }
    return map;
  }

  @override
  void initState() {
    super.initState();
    _filtered = _countries;
    _selectedIso = widget.initial;
    _searchCtrl.addListener(_applyFilter);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _applyFilter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? _countries
          : _countries
              .where((c) =>
                  _countryLabel(c).contains(q) ||
                  _countryLabel(c).toLowerCase().contains(q) ||
                  c.cc.contains(q) ||
                  c.iso.toLowerCase().contains(q))
              .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: AppColors.primary.withAlpha(40), width: 0.5)),
      ),
      child: Column(
        children: [
          // ── Handle ──
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // ── Title ──
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(20),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.public_rounded, size: 20, color: AppColors.primary),
                ),
                const SizedBox(width: 12),
                Text(
                  AppLocalizations.of(context).translate('subPhonePickCountry'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 17),
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                Text(
                  AppLocalizations.of(context).translate('subPhoneCountryCount', params: {'count': _filtered.length}),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12),
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),

          // ── Search ──
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: FyonaTextField(
              controller: _searchCtrl,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 14),
                color: AppColors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: AppLocalizations.of(context).translate('subPhoneSearchCountry'),
                hintStyle: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13),
                  color: AppColors.textPlaceholder,
                ),
                prefixIcon: Icon(Icons.search_rounded, size: 20, color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.surfaceVariant,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderSide: BorderSide.none,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),

           Divider(height: 1, color: AppColors.border),

          // ── Country list (grouped) ──
          Expanded(
            child: _filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.search_off_rounded, size: 40, color: AppColors.textDisabled),
                        const SizedBox(height: 8),
                        Text(
                          AppLocalizations.of(context).translate('subPhoneNoResults'),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 14),
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  )
                : _searchCtrl.text.trim().isNotEmpty
                    ? _buildFlatList()
                    : _buildGroupedList(),
          ),

          SizedBox(height: bottomPad),
        ],
      ),
    );
  }

  Widget _buildFlatList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _filtered.length,
      itemBuilder: (_, i) => _buildCountryTile(_filtered[i]),
    );
  }

  Widget _buildGroupedList() {
    final groups = _grouped;
    final keys = groups.keys.toList()..sort();
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: keys.length,
      itemBuilder: (_, sectionIdx) {
        final key = keys[sectionIdx];
        final items = groups[key]!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Section header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                key,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13),
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ),
            ...items.map((c) => _buildCountryTile(c)),
          ],
        );
      },
    );
  }

  Widget _buildCountryTile(_Country c) {
    final selected = c.iso == _selectedIso;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          Navigator.pop(context, c);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          color: selected ? AppColors.primary.withAlpha(15) : null,
          child: Row(
            children: [
              // Flag
              Text(_flagOf(c.iso), style: const TextStyle(fontSize: 24)),
              const SizedBox(width: 14),
              // Country name
              Expanded(
                child: Text(
                  _countryLabel(c),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? AppColors.primary : AppColors.textPrimary,
                  ),
                ),
              ),
              // Country code
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.primary.withAlpha(20)
                      : AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  c.cc,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: FontWeight.w600,
                    color: selected ? AppColors.primary : AppColors.textSecondary,
                  ),
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 10),
                Icon(Icons.check_circle_rounded, size: 18, color: AppColors.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
