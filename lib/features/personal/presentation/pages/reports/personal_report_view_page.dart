import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../../core/localization/app_localizations.dart';
import '../../../../../core/responsive/r_api.dart';
import '../../../../../core/services/connectivity_service.dart';
import '../../../../../core/services/currency/currency_engine.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/utils/storage_util.dart';
import '../../../../../shared/providers/current_user_provider.dart';
import '../../../../../shared/widgets/styled_snack.dart';
import '../../../../reports/presentation/widgets/report_scenes.dart';
import '../../providers/personal_providers.dart';
import 'personal_report_data.dart';
import 'personal_report_pdf.dart';
import 'personal_report_sections.dart';
import 'personal_report_source.dart';
import 'personal_report_widgets.dart';

/// Cue played when the Personal report PDF is ready.
const personalReportExportCue = 'audio/report_personal_export.wav';

/// One Personal report. Opens behind the Personal report motion (wallet →
/// spending ring, with its synced sounds), then shows the sections of
/// [kind]; currency and period can be changed in place, and the PDF is built
/// from exactly what is on screen.
class PersonalReportViewPage extends ConsumerStatefulWidget {
  const PersonalReportViewPage({
    super.key,
    required this.kind,
    this.currency,
    this.period,
    this.from,
    this.to,
    this.playScene = true,
  });
  final String kind;
  final String? currency, period, from, to;

  /// Off in tests/screenshots that render the report directly.
  final bool playScene;

  @override
  ConsumerState<PersonalReportViewPage> createState() =>
      _PersonalReportViewPageState();
}

class _PersonalReportViewPageState
    extends ConsumerState<PersonalReportViewPage> {
  String? _currency;
  late String _period = widget.period ?? 'month';
  late DateTime? _from = DateTime.tryParse(widget.from ?? '');
  late DateTime? _to = DateTime.tryParse(widget.to ?? '');
  bool _ready = false, _exporting = false;
  Route<void>? _scene;

  String get _kind =>
      personalReportKinds.contains(widget.kind) ? widget.kind : 'overview';

  @override
  void initState() {
    super.initState();
    final c = widget.currency?.trim().toUpperCase();
    if (c != null && c.isNotEmpty) _currency = c;
    _ready = !widget.playScene;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_currency == null) {
        unawaited(
          PersonalReportSource.savedCurrency(ref).then((saved) {
            if (mounted && saved != null && saved.isNotEmpty) {
              setState(() => _currency = saved);
            }
          }),
        );
      }
      if (widget.playScene) {
        _openScene();
      } else {
        unawaited(PersonalReportSource.warm(ref));
      }
    });
  }

  @override
  void dispose() {
    final scene = _scene;
    if (scene != null && scene.isActive) scene.navigator?.removeRoute(scene);
    super.dispose();
  }

  void _openScene() {
    final l10n = AppLocalizations.of(context);
    final navigator = Navigator.of(context);
    final pending = () async {
      await PersonalReportSource.warm(ref);
      return const {'ok': true};
    }();
    var done = false;
    final route = MaterialPageRoute<void>(
      builder: (_) => ReportSceneOverlay(
        scene: ReportScene.personal,
        sceneText: l10n.translate('prepScene'),
        processingText: l10n.translate('repProcessing'),
        future: pending,
        onResult: (overlay, _) {
          done = true;
          if (ModalRoute.of(overlay)?.isCurrent == true) {
            Navigator.of(overlay).pop();
          }
          if (mounted) setState(() => _ready = true);
        },
        onError: (overlay, _) {
          done = true;
          if (ModalRoute.of(overlay)?.isCurrent == true) {
            Navigator.of(overlay).pop();
          }
          // The data is on the device: show what is there.
          if (mounted) setState(() => _ready = true);
        },
      ),
    );
    _scene = route;
    unawaited(
      navigator.push<void>(route).then((_) {
        _scene = null;
        // Back during the motion leaves the report, like Business.
        if (!done && mounted && navigator.canPop()) navigator.pop();
      }),
    );
  }

  String get _ccy =>
      _currency ?? ref.read(personalFinanceProvider).walletCurrency;

  Future<void> _pickCurrency() async {
    final picked = await showPersonalReportCurrencyPicker(
      context,
      mine: PersonalReportSource.mine(ref),
      all: PersonalReportSource.all(ref),
      current: _ccy,
    );
    if (picked == null || picked == _ccy || !mounted) return;
    setState(() => _currency = picked);
    unawaited(PersonalReportSource.saveCurrency(ref, picked));
    if (ref.read(connectivityServiceProvider).isOnline) {
      unawaited(
        ref
            .read(currencyEngineProvider)
            .refreshIfStale(maxAge: const Duration(minutes: 30))
            .catchError((_) {}),
      );
    }
  }

  PersonalReportData _data() => PersonalReportSource.build(
    ref,
    currency: _ccy,
    window: PersonalReportWindow.of(_period, customFrom: _from, customTo: _to),
  );

  Future<void> _export() async {
    if (_exporting) return;
    final l10n = AppLocalizations.of(context);
    HapticFeedback.mediumImpact();
    setState(() => _exporting = true);
    try {
      final data = _data();
      final bytes = await PersonalReportPdf.build(
        data: data,
        kind: _kind,
        l10n: l10n,
        owner: ref.read(currentUserProvider)?.fullName,
      );
      final dir = await Directory.systemTemp.createTemp('personal_report');
      final file = File(
        '${dir.path}/fyona_personal_${_kind}_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      unawaited(ReportSceneSound.playOnce(personalReportExportCue));
      HapticFeedback.lightImpact();
      setState(() => _exporting = false);
      await StorageUtil.showPdfOptions(
        context,
        file,
        file.path.split('/').last,
      );
    } catch (_) {
      if (mounted) {
        showFyonaSnack(context, l10n.translate('repFailed'), success: false);
      }
    } finally {
      if (mounted && _exporting) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    ref.watch(personalFinanceProvider);
    ref.watch(budgetProvider);
    ref.watch(rateSnapshotRevisionProvider);
    final meta = personalReportMeta(_kind);
    final appBar = AppBar(
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new, size: 20),
        color: AppColors.textPrimary,
        onPressed: () => context.pop(),
      ),
      title: Text(
        l10n.translate(meta.title),
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: R.fontSize(context, 16),
          fontWeight: FontWeight.w800,
          color: AppColors.textPrimary,
        ),
      ),
      actions: [PrCurrencyChip(currency: _ccy, onTap: _pickCurrency)],
    );
    if (!_ready) {
      return Scaffold(backgroundColor: AppColors.background, appBar: appBar);
    }
    final data = _data();
    final blocks = PersonalReportSections(context, data).forKind(_kind);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: appBar,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
          children: [
            PrPeriodBar(
              period: _period,
              from: _from,
              to: _to,
              onChanged: (p, f, t) => setState(() {
                _period = p;
                _from = f;
                _to = t;
              }),
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < blocks.length; i++)
              PrEntrance(index: i, child: blocks[i]),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'personal-report-pdf',
        onPressed: _exporting ? null : _export,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _exporting
              ? const SizedBox(
                  key: ValueKey('busy'),
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.picture_as_pdf_rounded, key: ValueKey('pdf')),
        ),
        label: Text(
          l10n.translate('exportPdf'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}
