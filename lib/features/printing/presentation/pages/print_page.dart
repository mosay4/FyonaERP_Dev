import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../core_business/presentation/widgets/business_number_field.dart';
import '../../../invoices/data/invoice_design_models.dart';
import '../../../invoices/presentation/providers/invoice_design_provider.dart';
import '../../../invoices/presentation/widgets/invoice_preview_card.dart';
import '../../domain/printer_models.dart';
import '../providers/printing_providers.dart';
import '../widgets/printer_scene.dart';

/// FYONA Print Center for Business invoices.
///
/// Finds printers on every path the device has (Bluetooth, BLE, USB, Wi-Fi /
/// LAN, Windows printers), keeps a default printer per branch on this
/// device, and prints straight from FYONA — no system dialog, no other app —
/// with the protocol each printer needs (ESC/POS, IPP, raw, spooler).
/// «طباعة الآن» scrolls up to the printer, where the receipt comes out with
/// the REAL progress of the job; "printed" is shown only when the printer
/// confirms it.
class InvoicePrintPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> invoice;
  final bool isPurchase;
  final bool isReturn;
  final Map<String, InvoiceDesignPreset>? localPresets;
  const InvoicePrintPage({
    super.key,
    required this.invoice,
    required this.isPurchase,
    this.localPresets,
    this.isReturn = false,
  });
  @override
  ConsumerState<InvoicePrintPage> createState() => _InvoicePrintPageState();
}

class _InvoicePrintPageState extends ConsumerState<InvoicePrintPage> {
  final _scroll = ScrollController();
  StreamSubscription<PrinterDevice>? _scan;
  StreamSubscription<PrintProgress>? _job;

  List<PrinterDevice> _devices = [];
  PrinterDevice? _selected;
  PrintPaper _paper = PrintPaper.thermal80;
  int _copies = 1;
  bool _autoCut = true;
  bool _loadingPrefs = true;
  bool _scanning = false;

  SceneState _scene = SceneState.idle;
  double _progress = 0;
  String _message = '';
  Color? _messageColor;

  bool get _busy => _job != null;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _scan?.cancel();
    _job?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final service = ref.read(printServiceProvider);
    final prefs = await service.loadPrefs();
    final saved = await service.savedPrinters();
    if (!mounted) return;
    setState(() {
      _paper = prefs.paper;
      _copies = prefs.copies;
      _autoCut = prefs.autoCut;
      _selected = prefs.printer;
      _devices = [
        if (prefs.printer != null) prefs.printer!,
        for (final d in saved)
          if (d.id != prefs.printer?.id) d,
      ];
      _loadingPrefs = false;
    });
    _discover();
  }

  Future<void> _discover() async {
    if (_scanning) return;
    final service = ref.read(printServiceProvider);
    setState(() => _scanning = true);
    if (_scene == SceneState.idle) setState(() => _scene = SceneState.scanning);
    await service.ensurePermissions();
    if (!mounted) return;
    await _scan?.cancel();
    _scan = service.discover().listen((d) {
      if (!mounted || _devices.any((x) => x.id == d.id)) return;
      setState(() => _devices = [..._devices, d]);
    }, onDone: () {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        if (_scene == SceneState.scanning) _scene = SceneState.idle;
      });
    });
  }

  void _select(PrinterDevice d) {
    HapticFeedback.selectionClick();
    setState(() => _selected = d);
    _persist();
  }

  void _persist() {
    ref.read(printServiceProvider).savePrefs(PrintPrefs(
        printer: _selected, paper: _paper, copies: _copies, autoCut: _autoCut));
  }

  String _templateId() => '${widget.isReturn ? 'return_' : ''}${_paper.templateId}';

  InvoiceDesignPreset _design() {
    final id = _templateId();
    return widget.localPresets == null
        ? ref.read(invoiceDesignProvider.notifier).getPreset(id)
        : widget.localPresets![id] ?? InvoiceDesignPreset.defaults(id);
  }

  // ── Printing ──

  Future<void> _print({required bool test, bool force = false}) async {
    final l10n = AppLocalizations.of(context);
    if (_busy) return; // one tap = one job
    final printer = _selected;
    if (printer == null) {
      setState(() {
        _scene = SceneState.failed;
        _message = l10n.translate('printPickFirst');
        _messageColor = AppColors.danger;
      });
      return;
    }
    HapticFeedback.mediumImpact();
    _persist();
    // Up to the printer: the receipt comes out where the eye is.
    if (_scroll.hasClients && _scroll.offset > 0) {
      unawaited(_scroll.animateTo(0,
          duration: const Duration(milliseconds: 480), curve: Curves.easeInOutCubic));
    }
    setState(() {
      _scene = SceneState.connecting;
      _progress = .02;
      _message = l10n.translate('printPreparing');
      _messageColor = AppColors.primary;
    });
    final service = ref.read(printServiceProvider);
    final stream = test
        ? service.testPrint(
            printer: printer, paper: _paper, templateId: _templateId(), design: _design())
        : service.print(
            invoice: widget.invoice,
            design: _design(),
            isPurchase: widget.isPurchase,
            printer: printer,
            paper: _paper,
            templateId: _templateId(),
            copies: _copies,
            autoCut: _autoCut,
            force: force,
          );
    final done = Completer<void>();
    String? duplicate;
    _job = stream.listen((p) {
      if (!mounted) return;
      setState(() {
        switch (p.stage) {
          case PrintStage.preparing:
            _message = l10n.translate('printPreparing');
          case PrintStage.connecting:
            _scene = SceneState.connecting;
            _message = l10n.translate('printConnecting');
          case PrintStage.sending:
            _scene = SceneState.printing;
            _progress = p.fraction.clamp(.04, .97);
            _message = l10n.translate('printSending');
          case PrintStage.finishing:
            _scene = SceneState.waiting;
            _progress = p.fraction.clamp(.04, .98);
            _message = l10n.translate('printFinishing');
          case PrintStage.done:
            _progress = 1;
            _scene = p.confirmed ? SceneState.printed : SceneState.sent;
            _message = l10n.translate(p.confirmed ? 'printPrinted' : 'printSentNoConfirm');
            _messageColor = p.confirmed ? AppColors.success : AppColors.info;
            HapticFeedback.heavyImpact();
          case PrintStage.failed:
            final key = p.error ?? 'printErrPrinter';
            if (key == 'printErrDuplicate') duplicate = key;
            _scene = SceneState.failed;
            _message = l10n.translate(key);
            _messageColor = AppColors.danger;
            // Paper stops where the job stopped (never pretends to finish).
        }
      });
    }, onDone: () => done.complete(), onError: (_) => done.complete());
    await done.future;
    if (!mounted) return;
    setState(() => _job = null);
    if (duplicate != null) await _confirmDuplicate(test: test);
  }

  Future<void> _confirmDuplicate({required bool test}) async {
    final l10n = AppLocalizations.of(context);
    final again = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Text(l10n.translate('printErrDuplicate'),
            style: const TextStyle(fontFamily: 'Cairo')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(l10n.translate('cancel'), style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              key: const Key('print_again'),
              onPressed: () => Navigator.pop(c, true),
              child: Text(l10n.translate('printAgain'), style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
    if (again == true && mounted) await _print(test: test, force: true);
  }

  // ── Add a printer by hand (IP / host, port, IPP + credentials) ──

  Future<void> _addManual() async {
    final l10n = AppLocalizations.of(context);
    final host = TextEditingController();
    final name = TextEditingController();
    final port = TextEditingController(text: '9100');
    final user = TextEditingController();
    final pass = TextEditingController();
    var ipp = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(l10n.translate('printAddPrinter'),
              style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              FyonaTextField(
                key: const Key('print_host'),
                controller: host,
                keyboardType: TextInputType.url,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(labelText: l10n.translate('printIpAddress')),
              ),
              const SizedBox(height: 8),
              FyonaTextField(
                controller: name,
                decoration: InputDecoration(labelText: l10n.translate('printPrinterName')),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: ipp,
                activeThumbColor: AppColors.primary,
                title: Text(l10n.translate('printUseIpp'),
                    style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
                onChanged: (v) => set(() {
                  ipp = v;
                  if (port.text == '9100' || port.text == '631') port.text = v ? '631' : '9100';
                }),
              ),
              FyonaTextField(
                controller: port,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: l10n.translate('printPort')),
              ),
              if (ipp) ...[
                const SizedBox(height: 8),
                FyonaTextField(
                  controller: user,
                  decoration: InputDecoration(labelText: l10n.translate('printUser')),
                ),
                const SizedBox(height: 8),
                FyonaTextField(
                  controller: pass,
                  obscureText: true,
                  decoration: InputDecoration(labelText: l10n.translate('printPassword')),
                ),
              ],
              const SizedBox(height: 6),
              Text(l10n.translate('printProtocolAuto'),
                  style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary)),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: Text(l10n.translate('cancel'), style: const TextStyle(fontFamily: 'Cairo'))),
            FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: Text(l10n.translate('addLabel'), style: const TextStyle(fontFamily: 'Cairo'))),
          ],
        ),
      ),
    );
    if (ok != true || host.text.trim().isEmpty || !mounted) return;
    final d = ref.read(printServiceProvider).manualNetwork(
          host.text.trim(),
          port: int.tryParse(port.text.trim()) ?? (ipp ? 631 : 9100),
          name: name.text.trim(),
          ipp: ipp,
          username: user.text.trim().isEmpty ? null : user.text.trim(),
          password: pass.text.isEmpty ? null : pass.text,
          thermal: !ipp,
        );
    setState(() {
      _devices = [d, ..._devices.where((x) => x.id != d.id)];
      _selected = d;
    });
    _persist();
  }

  Future<void> _forget(PrinterDevice d) async {
    await ref.read(printServiceProvider).forget(d.id);
    if (!mounted) return;
    setState(() {
      _devices = _devices.where((x) => x.id != d.id).toList();
      if (_selected?.id == d.id) _selected = null;
    });
  }

  // ── UI ──

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
              decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle)),
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
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
              children: [
                RepaintBoundary(
                  child: PrinterScene(
                    key: const Key('printer_scene'),
                    state: _scene,
                    progress: _progress,
                    paperWidth: _paper == PrintPaper.thermal58 ? 120 : (_paper == PrintPaper.a4 ? 170 : 150),
                    paper: _paperContent(),
                  ),
                ),
                const SizedBox(height: 6),
                _statusCard(l10n),
                const SizedBox(height: 14),
                _printersSection(l10n),
                const SizedBox(height: 12),
                _paperSection(l10n),
                const SizedBox(height: 12),
                _copiesSection(l10n),
                const SizedBox(height: 12),
                _previewSection(l10n),
                const SizedBox(height: 80),
              ],
            ),
      bottomNavigationBar: _loadingPrefs ? null : _bottomBar(l10n),
    );
  }

  /// The real invoice, scaled to the paper on the drawing.
  Widget _paperContent() {
    final design = (widget.localPresets == null
            ? ref.watch(invoiceDesignProvider)[_templateId()]
            : widget.localPresets![_templateId()]) ??
        InvoiceDesignPreset.defaults(_templateId());
    return FittedBox(
      fit: BoxFit.fitWidth,
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: _paper.isThermal ? (_paper == PrintPaper.thermal58 ? 220 : 300) : 620,
        child: InvoicePreviewCard(
          invoice: widget.invoice,
          design: design,
          isPurchase: widget.isPurchase,
        ),
      ),
    );
  }

  Widget _statusCard(AppLocalizations l10n) {
    final color = _messageColor ?? AppColors.textSecondary;
    final icon = switch (_scene) {
      SceneState.printed => Icons.check_circle_rounded,
      SceneState.sent => Icons.send_rounded,
      SceneState.failed => Icons.error_rounded,
      SceneState.scanning => Icons.wifi_tethering,
      SceneState.idle => Icons.info_outline_rounded,
      _ => Icons.hourglass_top_rounded,
    };
    return AnimatedContainer(
      key: const Key('print_status'),
      duration: const Duration(milliseconds: 250),
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
                ? (_scanning ? l10n.translate('printScanning') : l10n.translate('printReady'))
                : _message,
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 12.5),
                fontWeight: FontWeight.w700,
                color: color),
          ),
        ),
        if (_busy)
          SizedBox(
            width: 34,
            child: Text('${(_progress * 100).round()}%',
                textAlign: TextAlign.end,
                style: TextStyle(fontFamily: 'Cairo', fontSize: 11, fontWeight: FontWeight.w800, color: color)),
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
              onTap: _busy
                  ? null
                  : () {
                      setState(() => _paper = p);
                      _persist();
                    },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _paper == p ? AppColors.primary : AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _paper == p ? AppColors.primary : AppColors.border),
                ),
                child: Column(children: [
                  Icon(p.icon, size: 18, color: _paper == p ? Colors.white : AppColors.textSecondary),
                  const SizedBox(height: 4),
                  Text(l10n.translate(p.labelKey),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 11),
                          fontWeight: FontWeight.w700,
                          color: _paper == p ? Colors.white : AppColors.textSecondary)),
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
        _stepBtn(Icons.remove, _copies > 1 && !_busy
            ? () => setState(() {
                  _copies--;
                  _persist();
                })
            : null),
        GestureDetector(
          onTap: _busy ? null : _editCopies,
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
        _stepBtn(Icons.add, _copies < 999 && !_busy
            ? () => setState(() {
                  _copies++;
                  _persist();
                })
            : null),
        const SizedBox(width: 8),
        if (_paper.isThermal)
          Expanded(
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            Flexible(
              child: Text(l10n.translate('printAutoCut'),
                  maxLines: 2,
                  textAlign: TextAlign.end,
                  style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textSecondary)),
            ),
            Switch(
                value: _autoCut,
                activeThumbColor: AppColors.primary,
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                          _autoCut = v;
                          _persist();
                        })),
          ]),
          ),
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
        title: Text(l10n.translate('printCopies'), style: const TextStyle(fontFamily: 'Cairo')),
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
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.translate('cancel'), style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text.trim())),
              child: Text(l10n.translate('save'), style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
    if (result == null) return;
    setState(() => _copies = result.clamp(1, 999));
    _persist();
  }

  Widget _stepBtn(IconData icon, VoidCallback? onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: onTap == null ? AppColors.surface : AppColors.primary.withAlpha(24),
            border: Border.all(color: onTap == null ? AppColors.border : AppColors.primary.withAlpha(90)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: onTap == null ? AppColors.textDisabled : AppColors.primary),
        ),
      );

  Widget _printersSection(AppLocalizations l10n) {
    return _card(
      title: l10n.translate('printPrinters'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          key: const Key('print_add'),
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_link, size: 18),
          color: AppColors.primary,
          tooltip: l10n.translate('printAddPrinter'),
          onPressed: _busy ? null : _addManual,
        ),
        IconButton(
          key: const Key('print_scan'),
          visualDensity: VisualDensity.compact,
          icon: _scanning
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh, size: 18),
          color: AppColors.primary,
          tooltip: l10n.translate('printScan'),
          onPressed: _scanning || _busy ? null : _discover,
        ),
      ]),
      child: _devices.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                  _scanning ? l10n.translate('printScanning') : l10n.translate('printNoPrinters'),
                  style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), color: AppColors.textSecondary)),
            )
          : Column(children: [for (final d in _devices) _deviceTile(d, l10n)]),
    );
  }

  Widget _deviceTile(PrinterDevice d, AppLocalizations l10n) {
    final active = _selected?.id == d.id;
    return GestureDetector(
      onTap: _busy ? null : () => _select(d),
      onLongPress: _busy ? null : () => _forgetPrompt(d, l10n),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: active ? AppColors.primary.withAlpha(16) : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? AppColors.primary : AppColors.border),
        ),
        child: Row(children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: AppColors.primary.withAlpha(20), borderRadius: BorderRadius.circular(10)),
            child: Icon(d.kind.icon, size: 18, color: AppColors.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
              Text(
                  active
                      ? '${l10n.translate(d.kind.labelKey)} · ${l10n.translate('printDefaultHere')}'
                      : l10n.translate(d.kind.labelKey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 10.5), color: AppColors.textSecondary)),
            ]),
          ),
          if (active) const Icon(Icons.check_circle_rounded, color: AppColors.primary, size: 20),
        ]),
      ),
    );
  }

  Future<void> _forgetPrompt(PrinterDevice d, AppLocalizations l10n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(d.name, style: const TextStyle(fontFamily: 'Cairo')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(l10n.translate('cancel'), style: const TextStyle(fontFamily: 'Cairo'))),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.pop(c, true),
              child: Text(l10n.translate('printForget'), style: const TextStyle(fontFamily: 'Cairo'))),
        ],
      ),
    );
    if (ok == true) await _forget(d);
  }

  Widget _previewSection(AppLocalizations l10n) {
    return _card(
      title: l10n.translate('printPreview'),
      child: Container(
        height: 220,
        decoration: BoxDecoration(
            color: AppColors.surfaceVariant.withAlpha(60), borderRadius: BorderRadius.circular(10)),
        clipBehavior: Clip.antiAlias,
        child: FittedBox(fit: BoxFit.scaleDown, child: _paperContent()),
      ),
    );
  }

  Widget _card({required String title, required Widget child, Widget? trailing}) {
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
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
          color: AppColors.surface, border: Border(top: BorderSide(color: AppColors.border))),
      child: Row(children: [
        Expanded(
          flex: 2,
          child: SizedBox(
            height: 52,
            child: OutlinedButton.icon(
              key: const Key('print_test'),
              onPressed: _busy || _selected == null ? null : () => _print(test: true),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primary,
                side: BorderSide(color: AppColors.primary.withAlpha(120)),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.science_outlined, size: 15),
              label: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(l10n.translate('printTest'),
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 12), fontWeight: FontWeight.w700)),
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
              key: const Key('print_now'),
              onPressed: _busy ? null : () => _print(test: false),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: _busy
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.print_rounded, size: 20),
              label: Text(l10n.translate('printNow'),
                  style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 15), fontWeight: FontWeight.w800)),
            ),
          ),
        ),
      ]),
    );
  }
}
