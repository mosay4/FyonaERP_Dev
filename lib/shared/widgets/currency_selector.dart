import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import '../../shared/providers/current_user_provider.dart';
import 'two_tone_icon.dart';
import 'two_tone_icons.dart';
import '../../core/services/currency/enabled_currencies_service.dart'
    show loadEnabledCurrencies, defaultEnabledCurrencies;
import '../../core/services/currency/business_currency_scope.dart'
    show loadBizEnabledCurrencies;
import '../../core/utils/currency_formatter.dart'
    show currencyName, currencyShort, currencyFlagEmoji, currencyLabel;
import '../../core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

const Map<String, String> popularCurrencies = {
  'USD': 'دولار أمريكي',
  'EUR': 'يورو',
  'SAR': 'ريال سعودي',
  'AED': 'درهم إماراتي',
  'KWD': 'دينار كويتي',
  'QAR': 'ريال قطري',
  'BHD': 'دينار بحريني',
  'OMR': 'ريال عماني',
  'EGP': 'جنيه مصري',
  'YER': 'ريال يمني جديد',
  'YER_OLD': 'ريال يمني قديم',
  'GBP': 'جنيه إسترليني',
  'TRY': 'ليرة تركية',
};

const Map<String, String> worldCurrencies = {
  'USD': 'دولار أمريكي',
  'EUR': 'يورو',
  'SAR': 'ريال سعودي',
  'AED': 'درهم إماراتي',
  'KWD': 'دينار كويتي',
  'QAR': 'ريال قطري',
  'BHD': 'دينار بحريني',
  'OMR': 'ريال عماني',
  'EGP': 'جنيه مصري',
  'YER': 'ريال يمني جديد',
  'YER_OLD': 'ريال يمني قديم',
  'GBP': 'جنيه إسترليني',
  'TRY': 'ليرة تركية',
  'AFN': 'أفغاني',
  'ALL': 'ليك ألباني',
  'DZD': 'دينار جزائري',
  'AUD': 'دولار أسترالي',
  'CAD': 'دولار كندي',
  'CNY': 'يوان صيني',
  'JPY': 'ين ياباني',
  'INR': 'روبية هندية',
  'KRW': 'وون كوري',
  'RUB': 'روبل روسي',
  'CHF': 'فرنك سويسري',
  'SEK': 'كرونا سويدية',
  'NOK': 'كرونا نرويجية',
  'DKK': 'كرونا دنماركية',
  'PLN': 'زلوتي بولندي',
  'CZK': 'كرونا تشيكية',
  'HUF': 'فورنت مجري',
  'RON': 'ليو روماني',
  'BGN': 'ليف بلغاري',
  'ZAR': 'راند جنوب أفريقي',
  'NGN': 'نيرة نيجيرية',
  'MAD': 'درهم مغربي',
  'TND': 'دينار تونسي',
  'LYD': 'دينار ليبي',
  'SDG': 'جنيه سوداني',
  'IQD': 'دينار عراقي',
  'JOD': 'دينار أردني',
  'LBP': 'ليرة لبنانية',
  'SYP': 'ليرة سورية',
  'SYP_NEW': 'ليرة سورية جديدة',
  'SYP_OLD': 'ليرة سورية قديمة',
  'ILS': 'شيكل إسرائيلي',
  'IRR': 'ريال إيراني',
  'PKR': 'روبية باكستانية',
  'BDT': 'تاكا بنغلاديشي',
  'MYR': 'رينغيت ماليزي',
  'IDR': 'روبية إندونيسية',
  'PHP': 'بيزو فلبيني',
  'THB': 'بات تايلاندي',
  'VND': 'دونغ فيتنامي',
  'SGD': 'دولار سنغافوري',
  'HKD': 'دولار هونغ كونغ',
  'TWD': 'دولار تايواني',
  'MXN': 'بيزو مكسيكي',
  'BRL': 'ريال برازيلي',
  'ARS': 'بيزو أرجنتيني',
  'CLP': 'بيزو تشيلي',
  'COP': 'بيزو كولومبي',
  'PEN': 'سول بيروفي',
  'VES': 'بوليفار فنزويلي',
  'UAH': 'هريفنا أوكرانية',
  'KZT': 'تنغي كازاخستاني',
  'UZS': 'سوم أوزبكي',
  'AZN': 'مانات أذربيجاني',
  'GEL': 'لاري جورجي',
  'AMD': 'درام أرميني',
  'RSD': 'دينار صربي',
  'HRK': 'كونا كرواتية',
  'ISK': 'كرونا آيسلندية',
  'XOF': 'فرنك غرب أفريقي',
  'XAF': 'فرنك وسط أفريقي',
  'MUR': 'روبية موريشيوس',
  'ETB': 'بير إثيوبي',
  'KES': 'شلن كيني',
  'TZS': 'شلن تنزاني',
  'UGX': 'شلن أوغندي',
  'GHS': 'سيدي غاني',
};

class CurrencySelector extends ConsumerStatefulWidget {
  final String? label;
  final String value;
  final bool showCode;
  final ValueChanged<String>? onChanged;

  /// When true the dropdown lists every world currency (with search) instead
  /// of only the user's enabled set. Selection still reports via [onChanged].
  final bool showAll;

  /// Placeholder shown in the closed field when [value] is empty (nothing
  /// chosen yet). When null, an empty value renders blank.
  final String? hint;

  /// Currency scope: 'personal' (default, unchanged behavior) or 'business'.
  /// Business screens pass 'business' so the Business enabled-set applies
  /// while Personal keeps its own set untouched.
  final String scope;
  final Set<String>? enabledBusinessCurrencies;

  const CurrencySelector({
    super.key,
    this.label,
    this.value = 'USD',
    this.showCode = true,
    this.onChanged,
    this.showAll = false,
    this.hint,
    this.scope = 'personal',
    this.enabledBusinessCurrencies,
  });

  @override
  ConsumerState<CurrencySelector> createState() => _CurrencySelectorState();
}

class _CurrencySelectorState extends ConsumerState<CurrencySelector> {
  bool _isOpen = false;
  final _searchCtrl = TextEditingController();
  List<MapEntry<String, String>> _filtered = [];
  late String _code;
  Set<String> _enabled = defaultEnabledCurrencies.toSet();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _code = widget.value;
    _loadEnabled();
  }

  Future<void> _loadEnabled() async {
    final business = widget.scope == 'business';
    final override = business ? widget.enabledBusinessCurrencies : null;
    final Set<String> enabled;
    if (override != null) {
      enabled = override;
    } else {
      final uid = ref.read(currentUserIdProvider);
      enabled = business
          ? await loadBizEnabledCurrencies(uid)
          : await loadEnabledCurrencies(uid);
    }
    if (!mounted || (business && !identical(override, widget.enabledBusinessCurrencies))) return;
    setState(() {
      _enabled = enabled;
      _loaded = true;
      _applyFilter(_searchCtrl.text);
    });
  }

  @override
  void didUpdateWidget(CurrencySelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    final enabled = widget.enabledBusinessCurrencies;
    if (widget.scope == 'business' && enabled != null &&
        !identical(enabled, oldWidget.enabledBusinessCurrencies)) {
      _enabled = enabled;
      _loaded = true;
      _applyFilter(_searchCtrl.text);
    } else if (widget.scope == 'business' && enabled == null &&
        oldWidget.enabledBusinessCurrencies != null) {
      _loadEnabled();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  static const Set<String> _yerAliases = {'YER', 'YER_NEW'};

  /// Whether [code] (a key of [worldCurrencies]) is effectively enabled.
  /// "YER" and "YER_NEW" are the same currency — enabled if either is on.
  bool _isEnabledKey(String key) {
    if (_enabled.contains(key)) return true;
    if (_yerAliases.contains(key)) {
      return _enabled.any(_yerAliases.contains);
    }
    return false;
  }

  List<MapEntry<String, String>> _enabledEntries() {
    if (widget.showAll) return worldCurrencies.entries.toList();
    return worldCurrencies.entries.where((e) => _isEnabledKey(e.key)).toList();
  }

  String _display(String c) {
    final name = currencyName(c);
    if (name == c) return c;
    return widget.showCode ? '$c - $name' : name;
  }

  /// The compact badge on the left of every row: the ISO code itself
  /// (YER_OLD, YER_NEW, SAR, USD, …) so it is identical everywhere.
  String _symbol(String c) => currencyShort(c);

  /// Row text that never repeats what the badge already says.
  String _rowLabel(String c) {
    final label = _display(c);
    if (label == c) return '';
    if (label.startsWith('$c - ')) return label.substring(c.length + 3);
    return label;
  }

  void _applyFilter(String q) {
    if (!_loaded) {
      _filtered = _enabledEntries();
      return;
    }
    if (q.isEmpty) {
      _filtered = _enabledEntries();
    } else {
      _filtered = _enabledEntries()
          .where((e) =>
              e.key.toLowerCase().contains(q.toLowerCase()) ||
              e.value.contains(q) ||
              currencyName(e.key).toLowerCase().contains(q.toLowerCase()))
          .toList();
    }
  }

  void _filter(String q) {
    setState(() => _applyFilter(q));
  }

  @override
  Widget build(BuildContext context) {
    final effectiveLabel = widget.label ?? AppLocalizations.of(context).translate('currencyLabel');
    final hasValue = _code.isNotEmpty;
    if (!_isOpen) {
      return FyonaTextField(
        controller: TextEditingController(text: hasValue ? _display(_code) : ''),
        readOnly: true,
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: R.fontSize(context, 14),
          fontWeight: FontWeight.w500,
          color: AppColors.textPrimary,
        ),
        decoration: InputDecoration(
          labelText: effectiveLabel,
          hintText: hasValue ? null : widget.hint,
          hintStyle: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 14),
            fontWeight: FontWeight.w500,
            color: AppColors.textPlaceholder,
          ),
          labelStyle: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 13),
            fontWeight: FontWeight.w500,
            color: AppColors.textSecondary,
          ),
          filled: true,
          fillColor: AppColors.surfaceVariant,
          contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          suffixIconConstraints: const BoxConstraints(minWidth: 52, minHeight: 48),
          suffixIcon: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _isOpen = true),
            child: Container(
              margin: const EdgeInsetsDirectional.only(end: 8),
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(22),
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.primary.withAlpha(70), width: 1),
              ),
              child: TwoToneIcon(data: TwoToneIcons.arrowDown, size: 28, outlineColor: AppColors.primary),
            ),
          ),
          border: OutlineInputBorder(
            borderRadius: AppRadius.mdBorder,
            borderSide: BorderSide(color: AppColors.border, width: 0.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: AppRadius.mdBorder,
            borderSide: BorderSide(color: AppColors.border, width: 0.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: AppRadius.mdBorder,
            borderSide: BorderSide(
              color: AppColors.primary,
              width: 1.5,
            ),
          ),
        ),
        onTap: () => setState(() => _isOpen = true),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FyonaTextField(
          controller: _searchCtrl,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 14),
            fontWeight: FontWeight.w500,
            color: AppColors.textPrimary,
          ),
          decoration: InputDecoration(
            hintText: AppLocalizations.t('currencySearchHint'),
            hintStyle: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 13),
              fontWeight: FontWeight.w500,
              color: AppColors.textDisabled,
            ),
            prefixIcon: Padding(
              padding: EdgeInsets.only(right: 10),
              child: TwoToneIcon(data: TwoToneIcons.search, outlineColor: AppColors.primary, size: 20),
            ),
            suffixIconConstraints: const BoxConstraints(minWidth: 52, minHeight: 48),
            suffixIcon: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _isOpen = false),
              child: Container(
                margin: const EdgeInsetsDirectional.only(end: 8),
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(22),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.primary.withAlpha(70), width: 1),
                ),
                child: TwoToneIcon(data: TwoToneIcons.arrowUp, size: 28, outlineColor: AppColors.primary),
              ),
            ),
            filled: true,
            fillColor: AppColors.surfaceVariant,
            contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: AppRadius.mdBorder,
              borderSide: BorderSide(color: AppColors.border, width: 0.5),
            ),
          ),
          onChanged: _filter,
        ),
        SizedBox(height: 8),
        Builder(builder: (ctx) {
          final rows = (_filtered.length / 2).ceil();
          final h = (rows * 52.0 + 12).clamp(80.0, 280.0);
          return SizedBox(
            height: h,
            child: GridView.count(
              crossAxisCount: 2,
              childAspectRatio: 3.5,
              children: _filtered
                .map(
                  (e) => GestureDetector(
                    onTap: () {
                      setState(() {
                        _code = e.key;
                        _isOpen = false;
                      });
                      widget.onChanged?.call(e.key);
                    },
                    child: Container(
                      margin: EdgeInsets.all(2),
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: _code == e.key
                            ? Color(0xFF1E1E1E)
                            : AppColors.surfaceVariant,
                        borderRadius: AppRadius.smBorder,
                        border: Border.all(
                          color: _code == e.key
                              ? AppColors.primary
                              : AppColors.primaryDark,
                          width: _code == e.key ? 1.0 : 0.5,
                        ),
                      ),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.primary.withAlpha(20),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                    color: AppColors.primary.withAlpha(70),
                                    width: 0.5),
                              ),
                              child: Text(
                                currencyFlagEmoji(e.key).isEmpty
                                    ? _symbol(e.key)
                                    : currencyFlagEmoji(e.key),
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: R.fontSize(context, 13),
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                _rowLabel(e.key),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: R.fontSize(context, 11),
                                  fontWeight: FontWeight.w500,
                                  color: _code == e.key
                                      ? AppColors.primary
                                      : AppColors.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
            ),
          );
        }),
      ],
    );
  }
}
