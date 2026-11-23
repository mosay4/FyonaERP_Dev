import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/invoice_design_models.dart';
import '../providers/invoice_design_provider.dart';
import '../widgets/invoice_preview_card.dart';
import '../widgets/signature_pad_dialog.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

/// Business invoice-design editor — same smooth pattern as the Personal
/// receipt-design editor (live preview + logo + colours + texts + visibility
/// + font), extended with an electronic signature/stamp upload and manual
/// drag positioning on the live preview. Business-only; Personal untouched.
class InvoiceDesignEditorPage extends ConsumerStatefulWidget {
  final String templateId; // 'paper' | 'thermal'
  const InvoiceDesignEditorPage({super.key, required this.templateId});
  @override
  ConsumerState<InvoiceDesignEditorPage> createState() =>
      _InvoiceDesignEditorPageState();
}

class _InvoiceDesignEditorPageState
    extends ConsumerState<InvoiceDesignEditorPage> {
  late InvoiceDesignPreset _preset;
  bool _hasChanged = false;
  final _scrollCtrl = ScrollController();
  bool _attachedHint = false;

  @override
  void dispose() {
    invoiceDesignSaveAndExitCallback = null;
    ref.read(invoiceDesignDirtyProvider.notifier).state = false;
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _preset = ref
        .read(invoiceDesignProvider.notifier)
        .getPreset(widget.templateId);
    ref.read(invoiceDesignDirtyProvider.notifier).state = false;
    invoiceDesignSaveAndExitCallback = () async {
      await ref.read(invoiceDesignProvider.notifier).savePreset(_preset);
      _hasChanged = false;
      ref.read(invoiceDesignDirtyProvider.notifier).state = false;
    };
    // English locale → use the English default footer when untouched.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final lang = Localizations.localeOf(context).languageCode;
      if (lang == 'en' && _preset.footerText == 'نظام فيونا المحاسبي') {
        setState(() => _preset =
            _preset.copyWith(footerText: 'Fyona Accounting System'));
      }
    });
  }

  void _update(InvoiceDesignPreset p) {
    setState(() {
      _preset = p;
      _hasChanged = true;
    });
    ref.read(invoiceDesignDirtyProvider.notifier).state = true;
  }

  /// After attaching a signature/stamp: scroll up to the LIVE preview and show
  /// a hint that the merchant can move / resize it inside its frame.
  void _afterAttach() {
    setState(() => _attachedHint = true);
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(0,
          duration: const Duration(milliseconds: 450), curve: Curves.easeOut);
    }
    Future.delayed(const Duration(seconds: 7), () {
      if (mounted) setState(() => _attachedHint = false);
    });
  }

  Future<void> _pickImage(
      void Function(Uint8List?) apply) async {
    final result = await FilePicker.pickFiles(type: FileType.image);
    if (result != null && result.files.single.path != null) {
      final bytes = await File(result.files.single.path!).readAsBytes();
      apply(bytes);
    }
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    await ref.read(invoiceDesignProvider.notifier).savePreset(_preset);
    if (!mounted) return;
    setState(() => _hasChanged = false);
    ref.read(invoiceDesignDirtyProvider.notifier).state = false;
    final messenger = ScaffoldMessenger.of(context);
    // Return to the customization hub, then confirm success (green).
    context.pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(l10n.translate('invDesignSaved'),
            style: const TextStyle(fontFamily: 'Cairo')),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.success,
      ));
  }

  Future<void> _confirmExit() async {
    final l10n = AppLocalizations.of(context);
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.translate('invUnsavedTitle'),
            style: const TextStyle(
                fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
        content: Text(l10n.translate('invUnsavedBody'),
            style: const TextStyle(fontFamily: 'Cairo', height: 1.4)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: Text(l10n.translate('cancel'),
                style: const TextStyle(fontFamily: 'Cairo')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: Text(l10n.translate('invExitWithoutSave'),
                style: const TextStyle(fontFamily: 'Cairo')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: Text(l10n.translate('invSaveAndExit'),
                style: const TextStyle(fontFamily: 'Cairo')),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'save') {
      await _save();
    } else if (action == 'discard') {
      ref.read(invoiceDesignDirtyProvider.notifier).state = false;
      if (mounted) context.pop();
    }
  }

  Future<void> _pickColor(String label, Color current,
      InvoiceDesignPreset Function(int) apply) async {
    final c = await showDialog<Color>(
      context: context,
      builder: (_) => _ColorPickerDialog(initial: current, label: label),
    );
    if (c != null) _update(apply(c.toARGB32()));
  }

  Map<String, dynamic> _sample() {
    final isReturn = widget.templateId.startsWith('return_');
    if (isReturn) {
      return {
        'invoice_number': 'RET-2026-0001',
        'invoice_type': widget.templateId.contains('sale')
            ? 'sale_return'
            : 'purchase_return',
        'customer_name': 'أحمد محمد سالم',
        'supplier_name': 'مؤسسة التوريدات',
        'invoice_date': DateTime.now().toIso8601String(),
        'currency': 'SAR',
        'branch_name': 'الفرع الرئيسي',
        'total': 250.0,
        'notes': 'منتج تالف',
        'original_invoice': 'INV-2026-0001',
        'items': [
          {'description': 'ساعة فيونا', 'quantity': 2, 'unit_price': 120, 'discount': 0, 'total': 240},
        ],
      };
    }
    return {
      'invoice_number': 'INV-2026-0001',
      'invoice_date': DateTime.now().toIso8601String(),
      'customer_name': 'أحمد محمد سالم',
      'supplier_name': 'مؤسسة التوريدات',
      'currency': 'SAR',
      'branch_name': 'الفرع الرئيسي',
      'subtotal': 390.0,
      'discount_amount': 10.0,
      'tax_amount': 57.0,
      'total': 437.0,
      'paid_amount': 500.0,
      'balance': 63.0,
      'notes': '',
      'items': [
        {'description': 'ساعة فيونا', 'quantity': 2, 'unit_price': 120, 'discount': 0, 'total': 240},
        {'description': 'منتج تبييض الأسنان', 'quantity': 1, 'unit_price': 85, 'discount': 10, 'total': 75},
        {'description': 'منتج تجميلي فاخر', 'quantity': 3, 'unit_price': 25, 'discount': 0, 'total': 75},
      ],
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isReturn = widget.templateId.startsWith('return_');
    final isThermal = widget.templateId.contains('thermal');
    final isNarrow = widget.templateId.endsWith('thermal58');
    final titleKey = widget.templateId == 'thermal58'
        ? 'invDesignThermal58Title'
        : widget.templateId == 'thermal'
            ? 'invDesignThermalTitle'
            : widget.templateId == 'paper'
                ? 'invDesignPaperTitle'
                : isNarrow
                    ? 'invDesignReturnThermal58Title'
                    : isThermal
                        ? 'invDesignReturnThermalTitle'
                        : 'invDesignReturnPaperTitle';
    return PopScope(
      canPop: !_hasChanged,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _confirmExit();
      },
      child: Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          color: AppColors.textPrimary,
          // The back arrow must honor the unsaved-changes guard too
          // (Navigator.pop bypasses PopScope, so guard explicitly).
          onPressed: () {
            if (_hasChanged) {
              _confirmExit();
            } else {
              context.pop();
            }
          },
        ),
        title: Text(l10n.translate(titleKey),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 17),
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary)),
        actions: [
          IconButton(
            icon: const Icon(Icons.check_rounded),
            color: AppColors.primary,
            onPressed: _save,
          ),
        ],
      ),
      body: ListView(controller: _scrollCtrl, padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        _section(l10n.translate('livePreview')),
        _card(
          child: Container(
            color: AppColors.surfaceVariant.withAlpha(60),
            padding: const EdgeInsets.all(8),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: isNarrow ? 220 : (isThermal ? 300 : 620),
                child: InvoicePreviewCard(
                  invoice: _sample(),
                  design: _preset,
                  isPurchase: false,
                  interactive: true,
                  onSignatureChange: (x, y, w) =>
                      _update(_preset.copyWith(sigX: x, sigY: y, sigW: w)),
                  onStampChange: (x, y, w) =>
                      _update(_preset.copyWith(stampX: x, stampY: y, stampW: w)),
                ),
              ),
            ),
          ),
        ),
        if (!isThermal && (_preset.showSignature || _preset.showStamp))
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _attachedHint
                  ? AppColors.primary.withAlpha(18)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: _attachedHint
                  ? Border.all(color: AppColors.primary.withAlpha(90))
                  : null,
            ),
            child: Row(children: [
              if (_attachedHint) ...[
                Icon(Icons.open_with_rounded,
                    size: 16, color: AppColors.primary),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(l10n.translate('invDesignDragHint'),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        fontWeight:
                            _attachedHint ? FontWeight.w700 : FontWeight.w500,
                        color: _attachedHint
                            ? AppColors.primary
                            : AppColors.textSecondary)),
              ),
            ]),
          ),

        _section(l10n.translate('logo')),
        _card(child: Column(children: [
          _imgRow(
            label: '${l10n.translate('logo')} (${l10n.translate('optional')})',
            bytes: _preset.logoBytes,
            onPick: () => _pickImage(
                (b) => _update(_preset.copyWith(logoBytes: b))),
            onClear: () => _update(_preset.copyWith(clearLogo: true)),
          ),
          if (!isThermal) ...[
            const Divider(height: 20),
            _imgRow(
              label:
                  '${l10n.translate('invDesignStamp')} (${l10n.translate('optional')})',
              bytes: _preset.stampBytes,
              onPick: () async {
                await _pickImage(
                    (b) => _update(_preset.copyWith(stampBytes: b)));
                if (_preset.stampBytes != null) _afterAttach();
              },
              onClear: () => _update(_preset.copyWith(clearStamp: true)),
            ),
            const Divider(height: 20),
            _sigRow(l10n),
          ],
        ])),

        _section(l10n.translate('colors')),
        _card(child: Column(children: [
          _colorChip(l10n.translate('colorPrimary'),
              Color(_preset.primaryColor),
              () => _pickColor(l10n.translate('colorPrimary'),
                  Color(_preset.primaryColor),
                  (v) => _preset.copyWith(primaryColor: v))),
          _colorChip(l10n.translate('colorSectionsBackground'),
              Color(_preset.panelColor),
              () => _pickColor(l10n.translate('colorSectionsBackground'),
                  Color(_preset.panelColor),
                  (v) => _preset.copyWith(panelColor: v))),
          _colorChip(l10n.translate('colorText'), Color(_preset.textColor),
              () => _pickColor(l10n.translate('colorText'),
                  Color(_preset.textColor),
                  (v) => _preset.copyWith(textColor: v))),
          _colorChip(l10n.translate('colorSecondaryText'),
              Color(_preset.secondaryTextColor),
              () => _pickColor(l10n.translate('colorSecondaryText'),
                  Color(_preset.secondaryTextColor),
                  (v) => _preset.copyWith(secondaryTextColor: v))),
        ])),

        _section(l10n.translate('texts')),
        _card(child: Column(children: [
          _textField(l10n.translate('brandName'), _preset.brandName,
              (v) => _update(_preset.copyWith(brandName: v))),
          _textField(l10n.translate('invDesignCompanyName'),
              _preset.companyName,
              (v) => _update(_preset.copyWith(companyName: v))),
          _textField(l10n.translate('invDesignCompanyAddress'),
              _preset.companyAddress,
              (v) => _update(_preset.copyWith(companyAddress: v))),
          _textField(l10n.translate('invDesignCompanyPhone'),
              _preset.companyPhone,
              (v) => _update(_preset.copyWith(companyPhone: v))),
          if (!isReturn) ...[
            _textField(l10n.translate('invDesignTitleSale'), _preset.titleSale,
                (v) => _update(_preset.copyWith(titleSale: v))),
            _textField(l10n.translate('invDesignTitlePurchase'),
                _preset.titlePurchase,
                (v) => _update(_preset.copyWith(titlePurchase: v))),
          ],
          if (isReturn) ...[
            _textField(l10n.translate('invDesignReturnCustomerTitle'),
                _preset.titleReturnCustomer,
                (v) => _update(_preset.copyWith(titleReturnCustomer: v))),
            _textField(l10n.translate('invDesignReturnSupplierTitle'),
                _preset.titleReturnSupplier,
                (v) => _update(_preset.copyWith(titleReturnSupplier: v))),
          ],
          _textField(l10n.translate('footerText'), _preset.footerText,
              (v) => _update(_preset.copyWith(footerText: v))),
          _textField(l10n.translate('invDesignNotes'), _preset.notesText,
              (v) => _update(_preset.copyWith(notesText: v))),
        ])),

        _section(l10n.translate('showHide')),
        _card(child: Column(children: [
          _switch(l10n.translate('logo'), _preset.showLogo,
              (v) => _update(_preset.copyWith(showLogo: v))),
          _switch(l10n.translate('invDesignQr'), _preset.showQR,
              (v) => _update(_preset.copyWith(showQR: v))),
          if (!isThermal) ...[
            _switch(l10n.translate('invDesignSignature'), _preset.showSignature,
                (v) => _update(_preset.copyWith(showSignature: v))),
            _switch(l10n.translate('invDesignStamp'), _preset.showStamp,
                (v) => _update(_preset.copyWith(showStamp: v))),
          ],
          _switch(l10n.translate('invDesignCompanyInfo'),
              _preset.showCompanyInfo,
              (v) => _update(_preset.copyWith(showCompanyInfo: v))),
          _switch(l10n.translate('invDesignCustomer'), _preset.showCustomer,
              (v) => _update(_preset.copyWith(showCustomer: v))),
          _switch(l10n.translate('invDesignNotes'), _preset.showNotes,
              (v) => _update(_preset.copyWith(showNotes: v))),
          _switch(l10n.translate('footer'), _preset.showFooter,
              (v) => _update(_preset.copyWith(showFooter: v))),
          _switch(l10n.translate('invDesignProductImages'),
              _preset.showProductImages,
              (v) => _update(_preset.copyWith(showProductImages: v))),
        ])),

        _section(l10n.translate('fontSize')),
        _card(child: Slider(
          value: _preset.fontSizeScale,
          min: 0.7,
          max: 1.5,
          divisions: 8,
          activeColor: AppColors.primary,
          label: '${(_preset.fontSizeScale * 100).round()}%',
          onChanged: (v) => _update(_preset.copyWith(fontSizeScale: v)),
        )),

        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton.icon(
            onPressed: _save,
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            icon: const Icon(Icons.save_outlined),
            label: Text(l10n.translate('save'),
                style: const TextStyle(
                    fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
          ),
        ),
        if (_hasChanged)
          const SizedBox(height: 4),
      ]),
      ),
    );
  }

  // ── helpers ────────────────────────────────────────────────────────

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 16, 2, 8),
        child: Text(t,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 14),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary)),
      );

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(12)),
        child: child,
      );

  Widget _imgRow({
    required String label,
    required Uint8List? bytes,
    required VoidCallback onPick,
    required VoidCallback onClear,
  }) =>
      Row(children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
              color: AppColors.surfaceVariant.withAlpha(80),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border)),
          child: bytes != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(bytes, fit: BoxFit.contain))
              : Icon(Icons.image_outlined, color: AppColors.textSecondary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(label,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13),
                  color: AppColors.textPrimary)),
        ),
        if (bytes != null)
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            color: AppColors.danger,
            onPressed: onClear,
          ),
        TextButton.icon(
          onPressed: onPick,
          icon: const Icon(Icons.upload_outlined, size: 18),
          label: Text(bytes != null ? l10nChange() : l10nAdd(),
              style: const TextStyle(fontFamily: 'Cairo')),
        ),
      ]);

  String l10nChange() => AppLocalizations.of(context).translate('change');
  String l10nAdd() => AppLocalizations.of(context).translate('addLabel');

  Widget _sigRow(AppLocalizations l10n) {
    final bytes = _preset.signatureBytes;
    return Row(children: [
      Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
            color: AppColors.surfaceVariant.withAlpha(80),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border)),
        child: bytes != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(bytes, fit: BoxFit.contain))
            : Icon(Icons.draw_outlined, color: AppColors.textSecondary),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
            '${l10n.translate('invDesignSignature')} (${l10n.translate('optional')})',
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 13),
                color: AppColors.textPrimary)),
      ),
      if (bytes != null)
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 20),
          color: AppColors.danger,
          onPressed: () => _update(_preset.copyWith(clearSignature: true)),
        ),
      TextButton.icon(
        onPressed: _signatureOptions,
        icon: const Icon(Icons.add, size: 18),
        label: Text(l10nAdd(),
            style: const TextStyle(fontFamily: 'Cairo')),
      ),
    ]);
  }

  Future<void> _signatureOptions() async {
    final l10n = AppLocalizations.of(context);
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(top: 10),
              decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 8),
          ListTile(
            leading: Icon(Icons.upload_outlined, color: AppColors.primary),
            title: Text(l10n.translate('sigUpload'),
                style: const TextStyle(fontFamily: 'Cairo')),
            onTap: () => Navigator.pop(ctx, 'upload'),
          ),
          ListTile(
            leading: Icon(Icons.draw_outlined, color: AppColors.primary),
            title: Text(l10n.translate('sigDirect'),
                style: const TextStyle(fontFamily: 'Cairo')),
            onTap: () => Navigator.pop(ctx, 'direct'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (picked == 'upload') {
      await _pickImage(
          (b) => _update(_preset.copyWith(signatureBytes: b)));
      if (_preset.signatureBytes != null) _afterAttach();
    } else if (picked == 'direct') {
      await _directSignature();
    }
  }

  Future<void> _directSignature() async {
    final bytes = await SignaturePadDialog.show(context);
    if (bytes != null) {
      _update(_preset.copyWith(signatureBytes: bytes));
      _afterAttach();
    }
  }

  Widget _colorChip(String label, Color color, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: GestureDetector(
          onTap: onTap,
          child: Row(children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.border)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      color: AppColors.textPrimary)),
            ),
            Icon(Icons.chevron_left_rounded, color: AppColors.textSecondary),
          ]),
        ),
      );

  Widget _textField(String label, String value, ValueChanged<String> onChanged) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: FyonaTextFormField(
          initialValue: value,
          textAlign: TextAlign.right,
          style: const TextStyle(fontFamily: 'Cairo'),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: const TextStyle(fontFamily: 'Cairo'),
            isDense: true,
            filled: true,
            fillColor: AppColors.surfaceVariant.withAlpha(60),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: AppColors.border)),
          ),
          onChanged: onChanged,
        ),
      );

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged) =>
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(label,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 13),
                color: AppColors.textPrimary)),
        value: value,
        activeThumbColor: AppColors.primary,
        onChanged: onChanged,
      );
}

class _ColorPickerDialog extends StatelessWidget {
  final Color initial;
  final String label;
  const _ColorPickerDialog({required this.initial, required this.label});

  static const _presetColors = [
    Color(0xFF8E102F), Color(0xFFA01530), Color(0xFFB82040), Color(0xFF1A1A1A),
    Color(0xFF2E7D32), Color(0xFFE65100), Color(0xFFC62828), Color(0xFF4A148C),
    Color(0xFF004D40), Color(0xFF1565C0), Color(0xFF5A5A5A), Color(0xFFE0E0E0),
    Color(0xFFFFFFFF), Color(0xFFF5F1F2), Color(0xFFFAFAFA), Color(0xFFEEEEEE),
    Color(0xFF888888), Color(0xFF4CAF50),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(label,
          style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary)),
      content: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _presetColors
            .map((c) => GestureDetector(
                  onTap: () => Navigator.of(context).pop(c),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: c == initial
                              ? AppColors.primary
                              : AppColors.border,
                          width: c == initial ? 2.5 : 1),
                    ),
                  ),
                ))
            .toList(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.translate('cancel'),
              style: TextStyle(
                  fontFamily: 'Cairo', color: AppColors.textSecondary)),
        ),
      ],
    );
  }
}
