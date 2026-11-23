import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/security/app_pin_crypto.dart';
import '../../../../core/theme/app_colors.dart';
import '../../di/auth_providers.dart';
import '../widgets/app_pin_pad.dart';

/// Three-screen app-PIN onboarding shown when the user enables the session
/// timeout: (1) what the PIN is for, (2) create 5 digits, (3) confirm.
/// Pops `true` when the PIN was saved, `false`/`null` on cancel.
class PinSetupPage extends ConsumerStatefulWidget {
  final String? reason;
  const PinSetupPage({super.key, this.reason});

  @override
  ConsumerState<PinSetupPage> createState() => _PinSetupPageState();
}

class _PinSetupPageState extends ConsumerState<PinSetupPage> {
  int _step = 0;
  String _first = '';
  final _padKey = GlobalKey<AppPinPadState>();

  Future<bool> _onPop() async {
    if (_step > 0) {
      setState(() => _step--);
      return false;
    }
    return true;
  }

  Future<void> _save(String pin) async {
    try {
      final ds = ref.read(authLocalDataSourceProvider);
      await ds.saveAppPin(packAppPin(pin));
    } catch (_) {}
    if (mounted) Navigator.of(context).pop(true);
  }

  void _onCreateCompleted(String pin) {
    setState(() {
      _first = pin;
      _step = 2;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _padKey.currentState?.clear();
    });
  }

  void _onConfirmCompleted(String pin) {
    if (pin == _first && _first.isNotEmpty) {
      _save(pin);
      return;
    }
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.translate('pinMismatch'),
            style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppColors.danger,
      ),
    );
    setState(() {
      _first = '';
      _step = 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _padKey.currentState?.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _onPop() && mounted) Navigator.of(context).pop(false);
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 20),
            color: AppColors.textPrimary,
            onPressed: () async {
              if (await _onPop() && mounted) {
                Navigator.of(context).pop(false);
              }
            },
          ),
          title: Text(l10n.translate('pinSetupTitle'),
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary)),
          centerTitle: true,
        ),
        body: SafeArea(
          child: _step == 0
              ? _buildExplain(l10n)
              : _step == 1
                  ? _buildCreate(l10n)
                  : _buildConfirm(l10n),
        ),
      ),
    );
  }

  Widget _buildExplain(AppLocalizations l10n) {
    Widget bullet(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.check_circle_rounded,
                  size: 20, color: AppColors.success),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 14),
                        color: AppColors.textPrimary,
                        height: 1.6)),
              ),
            ],
          ),
        );
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(14),
              borderRadius: BorderRadius.circular(24),
              border:
                  Border.all(color: AppColors.primary.withAlpha(60)),
            ),
            child: const Icon(Icons.shield_outlined,
                size: 40, color: AppColors.primary),
          ),
          const SizedBox(height: 24),
          Text(l10n.translate('pinExplainTitle'),
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 20),
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary)),
          if (widget.reason != null && widget.reason!.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(14),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.primary.withAlpha(60)),
              ),
              child: Text(widget.reason!.trim(),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                      height: 1.5)),
            ),
          ],
          const SizedBox(height: 16),
          bullet(l10n.translate('pinExplainA')),
          bullet(l10n.translate('pinExplainB')),
          bullet(l10n.translate('pinExplainC')),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.warning.withAlpha(14),
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: AppColors.warning.withAlpha(80)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 20, color: AppColors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(l10n.translate('pinExplainWarn'),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 13),
                          color: AppColors.textPrimary,
                          height: 1.6)),
                ),
              ],
            ),
          ),
          const Spacer(),
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: () => setState(() => _step = 1),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: Text(l10n.translate('pinNext'),
                  style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCreate(AppLocalizations l10n) {
    return _pinStep(
      l10n: l10n,
      title: l10n.translate('pinCreateTitle'),
      onCompleted: _onCreateCompleted,
    );
  }

  Widget _buildConfirm(AppLocalizations l10n) {
    return _pinStep(
      l10n: l10n,
      title: l10n.translate('pinConfirmTitle'),
      onCompleted: _onConfirmCompleted,
    );
  }

  Widget _pinStep({
    required AppLocalizations l10n,
    required String title,
    required ValueChanged<String> onCompleted,
  }) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 32),
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppColors.primary.withAlpha(14),
              borderRadius: BorderRadius.circular(20),
              border:
                  Border.all(color: AppColors.primary.withAlpha(60)),
            ),
            child: const Icon(Icons.dialpad_rounded,
                size: 34, color: AppColors.primary),
          ),
          const SizedBox(height: 20),
          Text(title,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 18),
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary)),
          const SizedBox(height: 28),
          AppPinPad(key: _padKey, onCompleted: onCompleted),
        ],
      ),
    );
  }
}
