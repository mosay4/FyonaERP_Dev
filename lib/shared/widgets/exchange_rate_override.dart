import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/currency_formatter.dart';

/// The rate an operation must use: a positive manual rate wins over the
/// automatic (saved/live) one.
double? effectiveExchangeRate(double? autoRate, double? manualRate) =>
    (manualRate != null && manualRate.isFinite && manualRate > 0)
        ? manualRate
        : autoRate;

/// Holds a manual rate for ONE currency pair: switching the pair (another
/// account/currency) silently falls back to the automatic rate.
class ManualRateOverride {
  String? _pair;
  double? _rate;

  static String _key(String from, String to) =>
      '${from.trim().toUpperCase()}>${to.trim().toUpperCase()}';

  double? rateFor(String from, String to) =>
      _pair == _key(from, to) ? _rate : null;

  void set(String from, String to, double? rate) {
    if (rate == null || !rate.isFinite || rate <= 0) {
      _pair = null;
      _rate = null;
    } else {
      _pair = _key(from, to);
      _rate = rate;
    }
  }

  void clear() => set('', '', null);
}

/// Compact «سعر الصرف: 1 دولار = 535 ريال يمني قديم ✎» line. The rate is
/// always [fromCurrency]→[toCurrency] (1 from = rate to); it is SHOWN (and
/// edited) in the direction that reads ≥ 1 so YER-style rates stay legible.
/// Tapping the pencil opens a small sheet to type a manual rate (> 0) or go
/// back to the automatic one; [onManualRateChanged] receives the new manual
/// rate (from→to) or null for «use the automatic rate».
/// When [amount] is given, the converted amount preview is shown below.
class ExchangeRateOverrideLine extends StatelessWidget {
  const ExchangeRateOverrideLine({
    super.key,
    required this.fromCurrency,
    required this.toCurrency,
    required this.autoRate,
    required this.manualRate,
    required this.onManualRateChanged,
    this.amount,
  });

  final String fromCurrency;
  final String toCurrency;
  final double? autoRate;
  final double? manualRate;
  final ValueChanged<double?> onManualRateChanged;
  final double? amount;

  static const editKey = Key('fx-rate-edit');
  static const fieldKey = Key('fx-rate-field');
  static const saveKey = Key('fx-rate-save');
  static const autoKey = Key('fx-rate-auto');
  static const convertedKey = Key('fx-rate-converted');

  bool get _isManual =>
      manualRate != null && manualRate!.isFinite && manualRate! > 0;

  double? get _rate => effectiveExchangeRate(_validAuto, manualRate);

  double? get _validAuto =>
      (autoRate != null && autoRate!.isFinite && autoRate! > 0)
          ? autoRate
          : null;

  /// Display direction follows the automatic rate when known (stable while
  /// editing), else the manual one.
  bool get _inverted {
    final basis = _validAuto ?? (_isManual ? manualRate : null);
    return basis != null && basis < 1;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final rate = _rate;
    final String rateText;
    if (rate == null) {
      rateText = l10n.translate('fxRateNone');
    } else if (_inverted) {
      rateText = formatCurrencyRateLine(toCurrency, 1 / rate, fromCurrency);
    } else {
      rateText = formatCurrencyRateLine(fromCurrency, rate, toCurrency);
    }
    final converted =
        (amount != null && rate != null) ? amount! * rate : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              '${l10n.translate('exchangeRate')}: ',
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            ),
            Expanded(
              child: Text(
                rateText,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: rate == null ? AppColors.warning : AppColors.primary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_isManual) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(20),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  l10n.translate('fxRateManualBadge'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
            InkWell(
              key: editKey,
              borderRadius: BorderRadius.circular(14),
              onTap: () => _edit(context),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.edit_outlined,
                  size: 16,
                  color: AppColors.primary,
                  semanticLabel: l10n.translate('saleEditRate'),
                ),
              ),
            ),
          ],
        ),
        if (converted != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${fmtNum(amount)} ${currencyLabel(fromCurrency)} → '
              '${fmtNum(converted)} ${currencyLabel(toCurrency)}',
              key: convertedKey,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.success,
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _edit(BuildContext context) async {
    final inverted = _inverted;
    final shownFrom = inverted ? toCurrency : fromCurrency;
    final shownTo = inverted ? fromCurrency : toCurrency;
    final current = _rate;
    final initial =
        current == null ? '' : fmtRate(inverted ? 1 / current : current);
    final result = await showModalBottomSheet<_RateEdit>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _RateSheet(
        from: shownFrom,
        to: shownTo,
        initial: initial.replaceAll(',', ''),
        canUseAuto: _validAuto != null,
      ),
    );
    if (result == null) return;
    final typed = result.rate;
    if (typed == null) {
      onManualRateChanged(null);
    } else {
      onManualRateChanged(inverted ? 1 / typed : typed);
    }
  }
}

class _RateEdit {
  const _RateEdit(this.rate);
  final double? rate; // null → back to the automatic rate
}

class _RateSheet extends StatefulWidget {
  const _RateSheet({
    required this.from,
    required this.to,
    required this.initial,
    required this.canUseAuto,
  });

  final String from;
  final String to;
  final String initial;
  final bool canUseAuto;

  @override
  State<_RateSheet> createState() => _RateSheetState();
}

class _RateSheetState extends State<_RateSheet> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    final l10n = AppLocalizations.of(context);
    final v = parseFormattedAmount(_ctrl.text.replaceAll('٫', '.'));
    if (v == null || !v.isFinite || v <= 0) {
      setState(() => _error = l10n.translate('fxRateInvalid'));
      return;
    }
    Navigator.pop(context, _RateEdit(v));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.fromLTRB(20, 12, 20, 16 + mq.padding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              l10n.translate('saleEditRate'),
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.translate('fxRateEditHint', params: {
                'from': currencyLabel(widget.from),
                'to': currencyLabel(widget.to),
              }),
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: ExchangeRateOverrideLine.fieldKey,
              controller: _ctrl,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,٠-٩٫]')),
              ],
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _save(),
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 14,
                color: AppColors.textPrimary,
              ),
              decoration: InputDecoration(
                prefixText: '1 ${currencyLabel(widget.from)} = ',
                suffixText: currencyLabel(widget.to),
                errorText: _error,
                filled: true,
                fillColor: AppColors.surfaceVariant,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.border, width: 0.5),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.border, width: 0.5),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.primary, width: 1),
                ),
              ),
            ),
            const SizedBox(height: 14),
            FilledButton(
              key: ExchangeRateOverrideLine.saveKey,
              onPressed: _save,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                l10n.translate('save'),
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
            if (widget.canUseAuto)
              TextButton(
                key: ExchangeRateOverrideLine.autoKey,
                onPressed: () => Navigator.pop(context, const _RateEdit(null)),
                child: Text(
                  l10n.translate('fxRateUseAuto'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
