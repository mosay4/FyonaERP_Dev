import 'package:flutter/material.dart';
import '../../../core_business/presentation/widgets/business_number_field.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../invoices/data/invoice_design_models.dart';
import '../../../invoices/presentation/providers/invoice_design_provider.dart';
import '../../../invoices/presentation/widgets/invoice_preview_card.dart';
import '../../domain/printer_models.dart';
import '../providers/printing_providers.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

enum _Phase { idle, scanning, preparing, sending, success, failure }

/// FYONA professional print page for Business invoices.
///
/// Finds printers (Bluetooth / WiFi-LAN / system), lets the merchant choose the
/// paper (58/80/A4), copies and a preferred printer, shows a real preview and a
/// lightweight 3D paper-ejection animation, and prints directly through
/// ESC/POS for thermal or the Android system service for A4.
class InvoicePrintPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> invoice;
  final bool isPurchase;
  final bool isReturn;
  final Map<String, InvoiceDesignPreset>? localPresets;
  const InvoicePrintPage(
      {super.key,
      required this.invoice,
       required this.isPurchase,
       this.localPresets,
      this.isReturn = false});
  @override
  ConsumerState<InvoicePrintPage> createState() => _InvoicePrintPageState();
}

class _InvoicePrintPageState extends ConsumerState<InvoicePrintPage>
    with TickerProviderStateMixin {
  late final AnimationController _paperCtrl;
  late final AnimationController _scanCtrl;

  List<PrinterDevice> _devices = [];
  PrinterDevice? _selected;
  PrintPaper _paper = PrintPaper.thermal80;
  int _copies = 1;
  bool _autoCut = true;
  bool _loadingPrefs = true;
  _Phase _phase = _Phase.idle;
  String _message = '';
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    _paperCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400));
    _scanCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600));
    _init();
  }

  @override
  void dispose() {
    _paperCtrl.dispose();
    _scanCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final prefs = await ref.read(printServiceProvider).loadPrefs();
    if (!mounted) return;
    setState(() {
      _paper = prefs.paper;
      _copies = prefs.copies;
      _autoCut = prefs.autoCut;
      _selected = prefs.printer;
      _loadingPrefs = false;
    });
    _discover();
  }

  Future<void> _discover() async {
    setState(() {
      _phase = _Phase.scanning;
      _message = '';
    });
    _scanCtrl.repeat();
    // Runtime Bluetooth permissions (Android 12+); ignore if denied.
    try {
      await [Permission.bluetoothConnect, Permission.bluetoothScan].request();
    } catch (_) {}
    final service = ref.read(printServiceProvider);
    final results = <PrinterDevice>[];
    try {
      results.addAll(await service.discoverBluetooth());
    } catch (_) {}
    try {
      results.addAll(await service.discoverNetwork());
    } catch (_) {}
    if (!mounted) return;
    _scanCtrl.stop();
    _scanCtrl.reset();
    setState(() {
      _devices = results;
      // keep a previously-saved printer visible even if not found now
      if (_selected != null && !_devices.any((d) => d.id == _selected!.id)) {
        _devices = [..._devices, _selected!];
      }
      _phase = _Phase.idle;
    });
  }

  void _select(PrinterDevice d) {
    setState(() => _selected = d);
    _persist();
  }

  void _persist() {
    ref.read(printServiceProvider).savePrefs(PrintPrefs(
        printer: _selected,
        paper: _paper,
        copies: _copies,
        autoCut: _autoCut));
  }

  String _templateId() =>
      '${widget.isReturn ? 'return_' : ''}${_paper.templateId}';

  Future<void> _addManualNetwork() async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.translate('printAddNetwork'),
            style: const TextStyle(fontFamily: 'Cairo')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          FyonaTextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontFamily: 'Cairo'),
            decoration: InputDecoration(
                labelText: l10n.translate('printIpAddress'),
                labelStyle: const TextStyle(fontFamily: 'Cairo')),
          ),
          const SizedBox(height: 8),
          FyonaTextField(
            controller: nameCtrl,
            style: const TextStyle(fontFamily: 'Cairo'),
            decoration: InputDecoration(
                labelText: l10n.translate('printPrinterName'),
                labelStyle: const TextStyle(fontFamily: 'Cairo')),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.translate('cancel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.translate('addLabel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
    if (ok != true) return;
    final ip = ctrl.text.trim();
    if (ip.isEmpty) return;
    final device = ref
        .read(printServiceProvider)
        .manualNetwork(ip, name: nameCtrl.text.trim());
    setState(() {
      _devices = [..._devices, device];
      _selected = device;
    });
    _persist();
  }

  Future<void> _runPrint({required bool test}) async {
    final l10n = AppLocalizations.of(context);
    // Single-flight guard: never fire an unintended duplicate job.
    if (_printing) return;
    if (_selected == null) {
      setState(() {
        _phase = _Phase.failure;
        _message = l10n.translate('printPickFirst');
      });
      return;
    }
    _printing = true;
    setState(() {
      _phase = _Phase.preparing;
      _message = l10n.translate('printPreparing');
    });
    _paperCtrl.forward(from: 0);
    await Future.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    setState(() {
      _phase = _Phase.sending;
      _message = l10n.translate('printSending');
    });

    final service = ref.read(printServiceProvider);
    final tplId = _templateId();
    final design = widget.localPresets == null
        ? ref.read(invoiceDesignProvider.notifier).getPreset(tplId)
        : widget.localPresets![tplId] ?? InvoiceDesignPreset.defaults(tplId);
    _persist();

    PrintOutcome outcome;
    final useDirect = _paper.isThermal && _selected!.kind != PrinterKind.system;
    if (useDirect) {
      outcome = test
          ? await service.testPrint(
              printer: _selected!, templateId: tplId, design: design)
          : await service.printThermal(
              invoice: widget.invoice,
              design: design,
              isPurchase: widget.isPurchase,
              printer: _selected!,
              templateId: tplId,
              copies: _copies,
              autoCut: _autoCut,
            );
    } else {
      outcome = await service.printSystem(
        invoice: widget.invoice,
        design: design,
        isPurchase: widget.isPurchase,
        templateId: _paper == PrintPaper.a4 ? tplId : tplId,
      );
    }
    if (!mounted) return;
    setState(() {
      if (outcome.ok) {
        _phase = _Phase.success;
        _message = outcome.sentOnly
            ? l10n.translate('printSent')
            : outcome.message;
      } else {
        _phase = _Phase.failure;
        _message = outcome.message;
      }
    });
    // reset the ejection animation smoothly
    await Future.delayed(const Duration(milliseconds: 900));
    if (mounted) _paperCtrl.reverse();
    _printing = false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          color: AppColors.textPrimary,
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  color: AppColors.primary, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(l10n.translate('printCenter'),
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 16),
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary)),
        ]),
      ),
      body: _loadingPrefs
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                _scene(dark),
                const SizedBox(height: 12),
                _statusCard(l10n),
                const SizedBox(height: 14),
                _paperSection(l10n),
                const SizedBox(height: 12),
                _copiesSection(l10n),
                const SizedBox(height: 12),
                _printersSection(l10n),
                const SizedBox(height: 12),
                _previewSection(l10n),
                const SizedBox(height: 80),
              ],
            ),
      bottomNavigationBar: _loadingPrefs ? null : _bottomBar(l10n),
    );
  }

  // ── 3D-ish animated printer + paper ejection ───────────────────────

  Widget _scene(bool dark) {
    return Center(
      child: SizedBox(
        height: 170,
        child: AnimatedBuilder(
          animation: Listenable.merge([_paperCtrl, _scanCtrl]),
          builder: (context, _) {
            final p = Curves.easeInOut.transform(_paperCtrl.value);
            final scanning = _phase == _Phase.scanning;
            final glow = scanning ? 0.25 + 0.25 * _scanCtrl.value : 0.0;
            return Stack(alignment: Alignment.center, children: [
              // soft burgundy glow
              Container(
                width: 150 + 40 * glow,
                height: 150 + 40 * glow,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    AppColors.primary.withAlpha((90 * (0.4 + glow)).round()),
                    AppColors.primary.withAlpha(0),
                  ]),
                ),
              ),
              // ejected paper (slides up out of the printer)
              Positioned(
                top: 26 - 42 * p,
                child: Opacity(
                  opacity: 0.15 + 0.85 * p,
                  child: Transform(
                    alignment: Alignment.bottomCenter,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.0012)
                      ..rotateX(0.5 * (1 - p)),
                    child: Container(
                      width: 96,
                      height: 120,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppColors.primary, width: 1.2),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withAlpha(60),
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(height: 6, color: AppColors.primary),
                            const SizedBox(height: 6),
                            for (var i = 0; i < 6; i++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 5),
                                child: Container(
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: (dark
                                            ? Colors.white
                                            : Colors.black)
                                        .withAlpha(i == 0 ? 90 : 45),
                                    borderRadius: BorderRadius.circular(2),
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
              // printer body
              Positioned(
                bottom: 8,
                child: Container(
                  width: 150,
                  height: 84,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        AppColors.surface,
                        AppColors.surfaceVariant.withAlpha(220),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppColors.primary.withAlpha(90)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(dark ? 90 : 40),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Stack(alignment: Alignment.topCenter, children: [
                    // paper slot
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      width: 110,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(dark ? 160 : 60),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                                scanning
                                    ? Icons.wifi_tethering
                                    : Icons.print_rounded,
                                size: 20,
                                color: AppColors.primary),
                            const SizedBox(width: 8),
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: scanning
                                    ? AppColors.warning
                                    : (_phase == _Phase.success
                                        ? AppColors.success
                                        : (_phase == _Phase.failure
                                            ? AppColors.danger
                                            : AppColors.textDisabled)),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }

  Widget _statusCard(AppLocalizations l10n) {
    final color = switch (_phase) {
      _Phase.success => AppColors.success,
      _Phase.failure => AppColors.danger,
      _Phase.scanning || _Phase.preparing || _Phase.sending => AppColors.primary,
      _Phase.idle => AppColors.textSecondary,
    };
    final icon = switch (_phase) {
      _Phase.success => Icons.check_circle_rounded,
      _Phase.failure => Icons.error_rounded,
      _Phase.scanning => Icons.wifi_tethering,
      _Phase.preparing || _Phase.sending => Icons.hourglass_top_rounded,
      _Phase.idle => Icons.info_outline_rounded,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withAlpha(18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _message.isEmpty
                ? l10n.translate('printReady')
                : _message,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 12.5),
                fontWeight: FontWeight.w700,
                color: color),
          ),
        ),
      ]),
    );
  }

  Widget _paperSection(AppLocalizations l10n) {
    return _card(
      title: l10n.translate('printPaperSize'),
      child: Row(children: [
        for (final p in PrintPaper.values) ...[
          Expanded(
            child: GestureDetector(
              onTap: () {
                setState(() => _paper = p);
                _persist();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _paper == p ? AppColors.primary : AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: _paper == p
                          ? AppColors.primary
                          : AppColors.border),
                ),
                child: Column(children: [
                  Icon(p.icon,
                      size: 18,
                      color:
                          _paper == p ? Colors.white : AppColors.textSecondary),
                  const SizedBox(height: 4),
                  Text(l10n.translate(p.labelKey),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 11),
                          fontWeight: FontWeight.w700,
                          color:
                              _paper == p ? Colors.white : AppColors.textSecondary)),
                ]),
              ),
            ),
          ),
          if (p != PrintPaper.a4) const SizedBox(width: 8),
        ],
      ]),
    );
  }

  Widget _copiesSection(AppLocalizations l10n) {
    return _card(
      title: l10n.translate('printCopies'),
      child: Row(children: [
        _stepBtn(Icons.remove, _copies > 1 ? () => setState(() {
              _copies--;
              _persist();
            }) : null),
        GestureDetector(
          onTap: _editCopies,
          child: Container(
            width: 64,
            height: 38,
            alignment: Alignment.center,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(14),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.primary.withAlpha(70)),
            ),
            child: Text('$_copies',
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 16),
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary)),
          ),
        ),
        _stepBtn(Icons.add, _copies < 999 ? () => setState(() {
              _copies++;
              _persist();
            }) : null),
        const Spacer(),
        if (_paper.isThermal)
          Row(children: [
            Text(l10n.translate('printAutoCut'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 12),
                    color: AppColors.textSecondary)),
            Switch(
                value: _autoCut,
                activeThumbColor: AppColors.primary,
                onChanged: (v) => setState(() {
                      _autoCut = v;
                      _persist();
                    })),
          ]),
      ]),
    );
  }

  Future<void> _editCopies() async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController(text: '$_copies');
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.translate('printCopies'),
            style: const TextStyle(fontFamily: 'Cairo')),
        content: BusinessNumberField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 20),
          decoration: InputDecoration(
            hintText: '1',
            helperText: l10n.translate('printCopiesHint'),
            helperStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 11),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.translate('cancel'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              onPressed: () => Navigator.pop(
                  ctx, int.tryParse(ctrl.text.trim())),
              child: Text(l10n.translate('save'),
                  style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
    if (result == null) return;
    // Enforce printer bounds (1..999).
    final v = result.clamp(1, 999);
    setState(() => _copies = v);
    _persist();
  }

  Widget _stepBtn(IconData icon, VoidCallback? onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: onTap == null
                ? AppColors.surface
                : AppColors.primary.withAlpha(24),
            border: Border.all(
                color: onTap == null
                    ? AppColors.border
                    : AppColors.primary.withAlpha(90)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon,
              size: 18,
              color:
                  onTap == null ? AppColors.textDisabled : AppColors.primary),
        ),
      );

  Widget _printersSection(AppLocalizations l10n) {
    return _card(
      title: l10n.translate('printPrinters'),
      trailing: Row(children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_link, size: 18),
          color: AppColors.primary,
          tooltip: l10n.translate('printAddNetwork'),
          onPressed: _addManualNetwork,
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: AnimatedRotation(
            turns: _phase == _Phase.scanning ? _scanCtrl.value : 0,
            duration: const Duration(milliseconds: 300),
            child: const Icon(Icons.refresh, size: 18),
          ),
          color: AppColors.primary,
          tooltip: l10n.translate('printScan'),
          onPressed: _phase == _Phase.scanning ? null : _discover,
        ),
      ]),
      child: _devices.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(children: [
                if (_phase == _Phase.scanning)
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                      _phase == _Phase.scanning
                          ? l10n.translate('printScanning')
                          : l10n.translate('printNoPrinters'),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 12),
                          color: AppColors.textSecondary)),
                ),
              ]),
            )
          : Column(children: [
              for (final d in _devices) _deviceTile(d, l10n),
            ]),
    );
  }

  Widget _deviceTile(PrinterDevice d, AppLocalizations l10n) {
    final active = _selected?.id == d.id;
    return GestureDetector(
      onTap: () => _select(d),
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: active ? AppColors.primary.withAlpha(16) : AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: active ? AppColors.primary : AppColors.border),
        ),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(20),
                borderRadius: BorderRadius.circular(10)),
            child: Icon(d.kind.icon, size: 18, color: AppColors.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 13),
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                  Text(l10n.translate(d.kind.labelKey),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 10.5),
                          color: AppColors.textSecondary)),
                ]),
          ),
          if (active)
            Icon(Icons.check_circle_rounded,
                color: AppColors.primary, size: 20),
        ]),
      ),
    );
  }

  Widget _previewSection(AppLocalizations l10n) {
    final design = (widget.localPresets == null
        ? ref.watch(invoiceDesignProvider)[_templateId()]
        : widget.localPresets![_templateId()]) ??
        InvoiceDesignPreset.defaults(_templateId());
    final isThermal = _paper.isThermal;
    return _card(
      title: l10n.translate('printPreview'),
      child: Container(
        height: 220,
        decoration: BoxDecoration(
            color: AppColors.surfaceVariant.withAlpha(60),
            borderRadius: BorderRadius.circular(10)),
        clipBehavior: Clip.antiAlias,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: isThermal ? (_paper == PrintPaper.thermal58 ? 220 : 300) : 620,
            child: InvoicePreviewCard(
              invoice: widget.invoice,
              design: design,
              isPurchase: widget.isPurchase,
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(
      {required String title, required Widget child, Widget? trailing}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(title,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary)),
          ),
          if (trailing != null) trailing,
        ]),
        const SizedBox(height: 8),
        child,
      ]),
    );
  }

  Widget _bottomBar(AppLocalizations l10n) {
    final busy = _phase == _Phase.preparing || _phase == _Phase.sending;
    return Container(
      padding: EdgeInsets.fromLTRB(
          16, 12, 16, 12 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border))),
      child: Row(children: [
        Expanded(
          flex: 2,
          child: SizedBox(
            height: 52,
            child: OutlinedButton.icon(
              onPressed: busy || _selected == null
                  ? null
                  : () => _runPrint(test: true),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: BorderSide(color: AppColors.primary.withAlpha(120)),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.science_outlined, size: 15),
              label: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(l10n.translate('printTest'),
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 3,
          child: SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: busy ? null : () => _runPrint(test: false),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.print_rounded, size: 20),
              label: Text(l10n.translate('printNow'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 15),
                      fontWeight: FontWeight.w800)),
            ),
          ),
        ),
      ]),
    );
  }
}
