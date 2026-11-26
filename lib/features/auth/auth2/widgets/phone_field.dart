import 'package:country_picker/country_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_colors.dart';
import '../auth2_strings.dart';

/// Every country with a dialling code (offline data from country_picker).
final List<Country> kAllCountries = CountryService()
    .getAll()
    .where((c) => c.phoneCode.isNotEmpty && c.countryCode != 'WW')
    .toList(growable: false);

Country countryByCode(String? code) =>
    CountryService().findByCode(code) ??
    CountryService().findByCode('YE') ??
    kAllCountries.first;

/// Default country: the phone's region when known, else Yemen.
Country defaultCountry() {
  String? region;
  try {
    region = WidgetsBinding.instance.platformDispatcher.locale.countryCode;
  } catch (_) {}
  return countryByCode(region);
}

String countryDisplayName(Country c, String languageCode) {
  try {
    final local = CountryLocalizations(Locale(languageCode))
        .countryName(countryCode: c.countryCode);
    if (local != null && local.isNotEmpty) return local;
  } catch (_) {}
  return c.name;
}

/// Pure phone normalisation: national digits → E.164 (`+<cc><national>`).
/// Accepts Arabic-Indic digits, spaces, dashes, a trunk `0`, and a pasted
/// international number (`+967…` / `00967…`) which also switches country.
class PhoneNumberParser {
  static const _trunkZeroKept = {'IT', 'SM', 'VA'};

  static String digitsOnly(String raw) {
    final b = StringBuffer();
    for (final r in raw.runes) {
      if (r >= 0x30 && r <= 0x39) {
        b.writeCharCode(r);
      } else if (r >= 0x660 && r <= 0x669) {
        b.writeCharCode(0x30 + r - 0x660);
      } else if (r >= 0x6F0 && r <= 0x6F9) {
        b.writeCharCode(0x30 + r - 0x6F0);
      }
    }
    return b.toString();
  }

  /// When [raw] is an international number returns (country, national).
  static (Country, String)? splitInternational(String raw) {
    final t = raw.trim();
    String? digits;
    if (t.startsWith('+')) {
      digits = digitsOnly(t);
    } else if (digitsOnly(t).startsWith('00')) {
      digits = digitsOnly(t).substring(2);
    }
    // Only a complete number (pasted / fully typed) switches the country,
    // never the first digits of a code still being typed.
    if (digits == null || digits.length < 8) return null;
    Country? best;
    for (final c in kAllCountries) {
      final code = c.phoneCode;
      if (digits.startsWith(code) && (best == null || code.length > best.phoneCode.length)) {
        best = c;
      }
    }
    if (best == null) return null;
    return (best, digits.substring(best.phoneCode.length));
  }

  static String national(Country c, String raw) {
    var d = digitsOnly(raw);
    if (d.startsWith('0') && !_trunkZeroKept.contains(c.countryCode)) {
      d = d.replaceFirst(RegExp(r'^0+'), '');
    }
    return d;
  }

  static String e164(Country c, String raw) => '+${c.phoneCode}${national(c, raw)}';

  static bool isValid(Country c, String raw) {
    final n = national(c, raw);
    if (n.length < 6 || n.length > 13) return false;
    return c.phoneCode.length + n.length <= 15;
  }
}

class PhoneFieldController extends ChangeNotifier {
  PhoneFieldController({Country? country, String text = ''})
      : _country = country ?? defaultCountry(),
        text = TextEditingController(text: text) {
    this.text.addListener(_onText);
  }

  final TextEditingController text;
  Country _country;
  bool _adjusting = false;

  Country get country => _country;
  set country(Country c) {
    _country = c;
    notifyListeners();
  }

  void _onText() {
    if (_adjusting) return;
    final split = PhoneNumberParser.splitInternational(text.text);
    if (split != null) {
      _adjusting = true;
      _country = split.$1;
      text.value = TextEditingValue(
        text: split.$2,
        selection: TextSelection.collapsed(offset: split.$2.length),
      );
      _adjusting = false;
    }
    notifyListeners();
  }

  /// Fills the field from a stored E.164 number.
  void setE164(String e164) {
    final split = PhoneNumberParser.splitInternational(e164);
    if (split == null) return;
    _adjusting = true;
    _country = split.$1;
    text.text = split.$2;
    _adjusting = false;
    notifyListeners();
  }

  String get e164 => PhoneNumberParser.e164(_country, text.text);
  bool get isValid => PhoneNumberParser.isValid(_country, text.text);

  @override
  void dispose() {
    text.removeListener(_onText);
    text.dispose();
    super.dispose();
  }
}

/// Phone input: country button (flag + dial code) + national number.
class PhoneField extends StatelessWidget {
  const PhoneField({
    super.key,
    required this.controller,
    this.autofocus = false,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
  });

  final PhoneFieldController controller;
  final bool autofocus;
  final TextInputAction textInputAction;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller.country;
        return Directionality(
          // Numbers always read left-to-right, also in Arabic.
          textDirection: TextDirection.ltr,
          child: TextFormField(
            key: const Key('phone_input'),
            controller: controller.text,
            autofocus: autofocus,
            keyboardType: TextInputType.phone,
            textInputAction: textInputAction,
            autofillHints: const [AutofillHints.telephoneNumberNational],
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9+٠-٩۰-۹ \-]')),
              LengthLimitingTextInputFormatter(20),
            ],
            onFieldSubmitted: (_) => onSubmitted?.call(),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              letterSpacing: 0.5,
            ),
            validator: (_) =>
                controller.isValid ? null : a2(context, 'errPhone'),
            decoration: InputDecoration(
              hintText: c.example.isNotEmpty ? c.example : a2(context, 'phone'),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              prefixIcon: Padding(
                padding: const EdgeInsetsDirectional.only(start: 6, end: 4),
                child: TextButton(
                  key: const Key('country_button'),
                  onPressed: () async {
                    final picked = await showCountrySheet(context, selected: c);
                    if (picked != null) controller.country = picked;
                  },
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 40),
                    foregroundColor: AppColors.textPrimary,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(c.flagEmoji, style: const TextStyle(fontSize: 20)),
                      const SizedBox(width: 6),
                      Text(
                        '+${c.phoneCode}',
                        key: const Key('dial_code'),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Icon(Icons.arrow_drop_down,
                          size: 18, color: AppColors.textSecondary),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Searchable list of every country (localized name, flag, dial code).
Future<Country?> showCountrySheet(BuildContext context, {Country? selected}) {
  return showModalBottomSheet<Country>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _CountrySheet(selected: selected),
  );
}

class _CountrySheet extends StatefulWidget {
  const _CountrySheet({this.selected});
  final Country? selected;

  @override
  State<_CountrySheet> createState() => _CountrySheetState();
}

class _CountrySheetState extends State<_CountrySheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final lang = Localizations.maybeLocaleOf(context)?.languageCode == 'en' ? 'en' : 'ar';
    final q = _query.trim().toLowerCase();
    final qDigits = PhoneNumberParser.digitsOnly(q);
    final items = kAllCountries.where((c) {
      if (q.isEmpty) return true;
      if (qDigits.isNotEmpty && c.phoneCode.startsWith(qDigits)) return true;
      return countryDisplayName(c, lang).toLowerCase().contains(q) ||
          c.name.toLowerCase().contains(q) ||
          c.countryCode.toLowerCase() == q;
    }).toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Text(
                a2(context, 'countryTitle'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                key: const Key('country_search'),
                onChanged: (v) => setState(() => _query = v),
                style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: a2(context, 'countrySearch'),
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final c = items[i];
                  final sel = c.countryCode == widget.selected?.countryCode;
                  return ListTile(
                    key: Key('country_${c.countryCode}'),
                    dense: true,
                    leading: Text(c.flagEmoji, style: const TextStyle(fontSize: 22)),
                    title: Text(
                      countryDisplayName(c, lang),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 14,
                        fontWeight: sel ? FontWeight.w800 : FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    trailing: Text(
                      '+${c.phoneCode}',
                      textDirection: TextDirection.ltr,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: sel ? AppColors.primary : AppColors.textSecondary,
                      ),
                    ),
                    onTap: () => Navigator.of(context).pop(c),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
