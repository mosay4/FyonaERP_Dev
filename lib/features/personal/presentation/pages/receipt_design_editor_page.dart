import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../shared/widgets/receipt/receipt_data.dart';
import '../../../../shared/widgets/receipt/receipt_card.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import '../providers/receipt_design_provider.dart';
import '../providers/receipt_design_models.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class ReceiptDesignEditorPage extends ConsumerStatefulWidget {
  final PersonalReceiptSection section;
  const ReceiptDesignEditorPage({super.key, required this.section});

  @override
  ConsumerState<ReceiptDesignEditorPage> createState() => _ReceiptDesignEditorPageState();
}

class _ReceiptDesignEditorPageState extends ConsumerState<ReceiptDesignEditorPage> {
  late ReceiptDesignPreset _preset;
  bool _hasChanged = false;

  @override
  void initState() {
    super.initState();
    final presets = ref.read(personalReceiptDesignProvider);
    _preset = presets[widget.section.id] ?? ReceiptDesignPreset.defaults(widget.section.id);
  }

  void _update(ReceiptDesignPreset p) {
    setState(() { _preset = p; _hasChanged = true; });
  }

  Future<void> _pickLogo() async {
    final result = await FilePicker.pickFiles(type: FileType.image);
    if (result != null && result.files.single.path != null) {
      final bytes = await File(result.files.single.path!).readAsBytes();
      _update(_preset.copyWith(logoBytes: bytes));
    }
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    await ref.read(personalReceiptDesignProvider.notifier).savePreset(_preset);
    setState(() => _hasChanged = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.translate('receiptDesignSaved'), style: TextStyle(fontFamily: 'Cairo')), backgroundColor: AppColors.success),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new,
              color: AppColors.textPrimary, size: 20),
          // Back to the customization hub (this editor is pushed on top).
          onPressed: () => context.pop(),
        ),
        title: Text(l10n.translate(widget.section.nameKey),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 16),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(l10n.translate('save'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.font(context),
                    fontWeight: FontWeight.w800,
                    color: _hasChanged
                        ? AppColors.primary
                        : AppColors.textDisabled)),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.all(R.spacing(context, 12)),
        children: [
          _buildPreview(context),
          SizedBox(height: R.spacing(context, 16)),
          _buildLogoSection(context),
          SizedBox(height: R.spacing(context, 12)),
          _buildColorsSection(context),
          SizedBox(height: R.spacing(context, 12)),
          _buildTextSection(context),
          SizedBox(height: R.spacing(context, 12)),
          _buildVisibilitySection(context),
          SizedBox(height: R.spacing(context, 12)),
          _buildFontSection(context),
          SizedBox(height: R.spacing(context, 16)),
          // Save applies ONLY this section's customization (never the
          // other sections, never the unified default of another section).
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _hasChanged ? _save : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                disabledBackgroundColor: AppColors.surfaceVariant,
                disabledForegroundColor: AppColors.textDisabled,
                padding: EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              icon: Icon(Icons.save_rounded, size: 20),
              label: Text(l10n.translate('save'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 15,
                      fontWeight: FontWeight.w800)),
            ),
          ),
          SizedBox(height: R.spacing(context, 32)),
        ],
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final sampleData = ReceiptData(
            title: l10n.translate(widget.section.nameKey),
      amount: 12500.00,
      currencySymbol: 'SAR',
      dateTime: '2026/07/23 11:30',
      referenceNumber: 'REF-123456',
      senderName: widget.section == PersonalReceiptSection.debt ? l10n.translate('sampleDebtorName') : null,
      senderAccount: widget.section == PersonalReceiptSection.debt ? l10n.translate('sampleDebtDue') : null,
      receiverName: l10n.translate('sampleCreditorName'),
      receiverAccount: l10n.translate('sampleSavingsGoal'),
      details: [
        ReceiptDetail(label: l10n.translate('sampleStatementLabel'), value: l10n.translate('sampleStatementValue')),
        ReceiptDetail(label: l10n.translate('sampleCommissionLabel'), value: l10n.translate('sampleCommissionValue')),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.mdBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(R.spacing(context, 10)),
            child: Row(
              children: [
                Icon(Icons.visibility, size: 16, color: AppColors.primary),
                SizedBox(width: R.gap(context)),
                Text(l10n.translate('livePreview'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
              ],
            ),
          ),
          Container(
            constraints: BoxConstraints(maxHeight: R.height(context) * 0.45),
            child: Center(
              child: SingleChildScrollView(
                child: ReceiptCard(data: sampleData, preset: _preset),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogoSection(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _section(l10n.translate('logo'), Icons.image, [
      _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _switch(l10n.translate('showLogo'), _preset.showBrandLogo, (v) => _update(_preset.copyWith(showBrandLogo: v))),
            SizedBox(height: R.spacing(context, 8)),
            if (_preset.logoBytes != null)
              Padding(
                padding: EdgeInsets.only(bottom: R.spacing(context, 8)),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(_preset.logoBytes!, height: 60),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: _outlinedButton(l10n.translate('addImage'), _pickLogo),
                ),
                if (_preset.logoBytes != null) ...[
                  SizedBox(width: R.spacing(context, 8)),
                  _outlinedButton(l10n.delete, () => _update(_preset.copyWith(logoBytes: null, clearLogo: true)), danger: true),
                ],
              ],
            ),
          ],
        ),
      ),
    ]);
  }

  Widget _buildColorsSection(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _section(l10n.translate('colors'), Icons.palette, [
      _card(
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _colorChip(l10n.translate('colorPrimary'), _preset.primaryColor, (c) => _update(_preset.copyWith(primaryColor: c))),
            _colorChip(l10n.translate('colorCardBackground'), _preset.backgroundColor, (c) => _update(_preset.copyWith(backgroundColor: c))),
            _colorChip(l10n.translate('colorSectionsBackground'), _preset.cardBackground, (c) => _update(_preset.copyWith(cardBackground: c))),
            _colorChip(l10n.translate('colorText'), _preset.textColor, (c) => _update(_preset.copyWith(textColor: c))),
            _colorChip(l10n.translate('colorAmount'), _preset.amountColor, (c) => _update(_preset.copyWith(amountColor: c))),
            _colorChip(l10n.translate('colorAccentBar'), _preset.accentBarColor, (c) => _update(_preset.copyWith(accentBarColor: c))),
            _colorChip(l10n.translate('colorSecondaryText'), _preset.secondaryTextColor, (c) => _update(_preset.copyWith(secondaryTextColor: c))),
            _colorChip(l10n.translate('colorDividers'), _preset.dividerColor, (c) => _update(_preset.copyWith(dividerColor: c))),
            _colorChip(l10n.translate('colorSuccess'), _preset.successColor, (c) => _update(_preset.copyWith(successColor: c))),
            _colorChip(l10n.translate('colorDanger'), _preset.dangerColor, (c) => _update(_preset.copyWith(dangerColor: c))),
          ],
        ),
      ),
    ]);
  }

  Widget _buildTextSection(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _section(l10n.translate('texts'), Icons.text_fields, [
      _card(
        Column(
          children: [
            _textField(l10n.translate('brandName'), _preset.brandName, (v) => _update(_preset.copyWith(brandName: v))),
            SizedBox(height: R.spacing(context, 8)),
            _textField(l10n.translate('receiptTitle'), _preset.headerTitle, (v) => _update(_preset.copyWith(headerTitle: v))),
            SizedBox(height: R.spacing(context, 8)),
            _textField(l10n.translate('footerText'), _preset.footerText, (v) => _update(_preset.copyWith(footerText: v))),
          ],
        ),
      ),
    ]);
  }

  Widget _buildVisibilitySection(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _section(l10n.translate('showHide'), Icons.visibility, [
      _card(
        Column(
          children: [
            _switch(l10n.translate('accentBar'), _preset.showAccentBar, (v) => _update(_preset.copyWith(showAccentBar: v))),
            _switch(l10n.translate('sender'), _preset.showSender, (v) => _update(_preset.copyWith(showSender: v))),
            _switch(l10n.translate('receiver'), _preset.showReceiver, (v) => _update(_preset.copyWith(showReceiver: v))),
            _switch(l10n.translate('referenceNumber'), _preset.showReference, (v) => _update(_preset.copyWith(showReference: v))),
            _switch(l10n.translate('details'), _preset.showDetails, (v) => _update(_preset.copyWith(showDetails: v))),
            _switch(l10n.translate('footer'), _preset.showFooter, (v) => _update(_preset.copyWith(showFooter: v))),
          ],
        ),
      ),
    ]);
  }

  Widget _buildFontSection(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _section(l10n.translate('font'), Icons.format_size, [
      _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.translate('fontSize'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), color: AppColors.textSecondary)),
            Row(
              children: [
                Text(l10n.translate('small'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'caption'), color: AppColors.textSecondary)),
                Expanded(
                  child: Slider(
                    value: _preset.fontSizeScale,
                    min: 0.7,
                    max: 1.5,
                    divisions: 8,
                    activeColor: AppColors.primary,
                    inactiveColor: AppColors.border,
                    label: _preset.fontSizeScale.toStringAsFixed(1),
                    onChanged: (v) => _update(_preset.copyWith(fontSizeScale: v)),
                  ),
                ),
                Text(l10n.translate('large'), style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context, 'caption'), color: AppColors.textSecondary)),
              ],
            ),
            Center(
              child: Text(_preset.fontSizeScale.toStringAsFixed(1) + 'x',
                style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), color: AppColors.primary, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    ]);
  }

  Widget _section(String title, IconData icon, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: AppColors.primary),
            SizedBox(width: R.gap(context)),
            Text(title, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          ],
        ),
        SizedBox(height: R.spacing(context, 8)),
        ...children,
      ],
    );
  }

  Widget _card(Widget child) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(R.spacing(context, 12)),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.mdBorder,
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }

  Widget _colorChip(String label, Color color, ValueChanged<Color> onChanged) {
    return GestureDetector(
      onTap: () async {
        final picked = await showDialog<Color>(
          context: context,
          builder: (ctx) => _ColorPickerDialog(initial: color, label: label),
        );
        if (picked != null) onChanged(picked);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
              boxShadow: [
                BoxShadow(color: color.withAlpha(80), blurRadius: 6, offset: const Offset(0, 2)),
              ],
            ),
          ),
          SizedBox(height: 3),
          Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 8, color: AppColors.textSecondary)),
        ],
      ),
    );
  }

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: R.font(context), color: AppColors.textPrimary)),
          Switch(value: value, activeThumbColor: AppColors.primary, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _textField(String label, String value, ValueChanged<String> onChanged) {
    return FyonaTextField(
      controller: TextEditingController(text: value)..selection = TextSelection.collapsed(offset: value.length),
      style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary, fontSize: R.font(context)),
      decoration: InputDecoration(
        labelText: label,
        labelStyle:  TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary),
        filled: true,
        fillColor: AppColors.surfaceVariant,
        border: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide:  BorderSide(color: AppColors.border)),
        focusedBorder: OutlineInputBorder(borderRadius: AppRadius.inputBorder, borderSide: const BorderSide(color: AppColors.primary)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      onChanged: onChanged,
    );
  }

  Widget _outlinedButton(String text, VoidCallback onPressed, {bool danger = false}) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: danger ? AppColors.danger : AppColors.textPrimary,
          side: BorderSide(color: danger ? AppColors.danger : AppColors.border),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.buttonBorder),
        ),
        onPressed: onPressed,
        child: Text(text),
      ),
    );
  }
}

class _ColorPickerDialog extends StatelessWidget {
  final Color initial;
  final String label;
  const _ColorPickerDialog({required this.initial, required this.label});

  static const _presetColors = [
    Color(0xFFA01530), Color(0xFFB82040), Color(0xFF1A1A1A),
    Color(0xFF2E7D32), Color(0xFFE65100), Color(0xFFC62828),
    Color(0xFF4A148C), Color(0xFF004D40), Color(0xFF1565C0),
    Color(0xFF5A5A5A), Color(0xFFE0E0E0), Color(0xFFFFFFFF),
    Color(0xFFF5F5F5), Color(0xFFFAFAFA), Color(0xFFEEEEEE),
    Color(0xFF888888), Color(0xFF4CAF50), Color(0xFFE84057),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(label, style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary)),
      content: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _presetColors.map((c) => GestureDetector(
          onTap: () => Navigator.of(context).pop(c),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: c == initial ? AppColors.primary : AppColors.border, width: c == initial ? 2.5 : 1),
            ),
          ),
        )).toList(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel, style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
        ),
      ],
    );
  }
}
