import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_colors.dart';
import '../auth2_models.dart';
import '../auth2_strings.dart';

/// Extracts a 6-digit code from pasted text ("Your FYONA code: 123 456").
String? extractOtp(String? raw) {
  if (raw == null) return null;
  final digits = StringBuffer();
  for (final r in raw.runes) {
    if (r >= 0x30 && r <= 0x39) {
      digits.writeCharCode(r);
    } else if (r >= 0x660 && r <= 0x669) {
      digits.writeCharCode(0x30 + r - 0x660);
    } else if (r >= 0x6F0 && r <= 0x6F9) {
      digits.writeCharCode(0x30 + r - 0x6F0);
    }
  }
  final d = digits.toString();
  final m = RegExp(r'\d{6}').firstMatch(d);
  if (d.length == 6) return d;
  return m?.group(0);
}

String formatCountdown(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final m = s ~/ 60;
  final r = s % 60;
  return '$m:${r.toString().padLeft(2, '0')}';
}

/// Six-box code entry with live delivery status, resend timer, SMS fallback
/// (only when the server allows it), expiry countdown and error states.
class OtpView extends StatefulWidget {
  const OtpView({
    super.key,
    required this.challenge,
    required this.destination,
    required this.onVerify,
    this.loadStatus,
    this.resend,
    this.primaryDeviceName,
    this.pollInterval = const Duration(seconds: 3),
    this.clock,
  });

  final OtpChallenge challenge;

  /// Phone number shown in the subtitle (WhatsApp / SMS channels).
  final String destination;

  /// Throws [Auth2Exception] on a wrong / expired / locked code.
  final Future<void> Function(String code) onVerify;
  final Future<OtpStatus> Function(String challengeId)? loadStatus;
  final Future<OtpChallenge> Function(String challengeId, String? channel)? resend;
  final String? primaryDeviceName;
  final Duration pollInterval;

  /// Time source (tests inject a controllable clock).
  final DateTime Function()? clock;

  @override
  State<OtpView> createState() => _OtpViewState();
}

class _OtpViewState extends State<OtpView> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  late OtpChallenge _challenge = widget.challenge;
  OtpStatus? _status;
  String? _error;
  bool _busy = false;
  bool _locked = false;
  bool _serverExpired = false;
  DateTime _clock() => widget.clock?.call() ?? DateTime.now();
  late DateTime _now = _clock();
  Timer? _ticker;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = _clock());
    });
    _schedulePoll(immediate: true);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _poll?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// A primary-device challenge stays on the device channel whatever a
  /// status poll reports; WhatsApp may move to SMS (fallback).
  String get _channel => _challenge.channel == 'device'
      ? 'device'
      : (_status?.channel ?? _challenge.channel);

  bool get _expired =>
      _serverExpired || !_now.isBefore(_challenge.expiresAt);

  void _schedulePoll({bool immediate = false}) {
    _poll?.cancel();
    if (widget.loadStatus == null) return;
    _poll = Timer(immediate ? Duration.zero : widget.pollInterval, _pollOnce);
  }

  Future<void> _pollOnce() async {
    if (!mounted) return;
    try {
      final st = await widget.loadStatus!(_challenge.challengeId);
      if (!mounted) return;
      setState(() {
        _status = st;
        if (st.status == 'expired') _serverExpired = true;
        if (st.status == 'locked') _locked = true;
      });
      if (st.isTerminal) return;
    } catch (_) {
      // Status is informative only: a failed poll never blocks the code.
    }
    if (mounted && !_expired && !_locked) _schedulePoll();
  }

  Future<void> _submit() async {
    final code = _ctrl.text;
    if (code.length != 6 || _busy || _locked || _expired) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onVerify(code);
      if (!mounted) return;
      setState(() => _busy = false);
    } on Auth2Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        final c = e.code;
        if (c == 'locked' || c == 'challenge_locked') _locked = true;
        if (c == 'expired' || c == 'challenge_expired') _serverExpired = true;
        _error = auth2ErrorTextOf(context, e);
        _ctrl.clear();
      });
      _focus.requestFocus();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = auth2ErrorTextOf(context, e);
      });
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final code = extractOtp(data?.text);
    if (code == null || !mounted) return;
    _ctrl.value = TextEditingValue(
      text: code,
      selection: const TextSelection.collapsed(offset: 6),
    );
    setState(() {});
    unawaited(_submit());
  }

  Future<void> _resend([String? channel]) async {
    if (widget.resend == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final next = await widget.resend!(_challenge.challengeId, channel);
      if (!mounted) return;
      setState(() {
        _challenge = next;
        _status = null;
        _locked = false;
        _serverExpired = false;
        _busy = false;
        _ctrl.clear();
        _now = _clock();
      });
      _schedulePoll(immediate: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = auth2ErrorTextOf(context, e);
      });
    }
  }

  String _statusText(BuildContext context) {
    final channel = _channel;
    final st = _status?.status ?? _challenge.status;
    if (channel == 'device') return a2(context, 'stDevice');
    if (st == 'fallback_sms') return a2(context, 'stFallbackSms');
    if (channel == 'sms') return a2(context, 'stSms');
    switch (st) {
      case 'sent':
        return a2(context, 'stSent');
      case 'delivered':
        return a2(context, 'stDelivered');
      case 'read':
        return a2(context, 'stRead');
      case 'failed':
        return a2(context, 'stFailed');
      default:
        return a2(context, 'stQueued');
    }
  }

  IconData _statusIcon() {
    final channel = _channel;
    final st = _status?.status ?? _challenge.status;
    if (channel == 'device') return Icons.phonelink_lock_rounded;
    if (channel == 'sms' || st == 'fallback_sms') return Icons.sms_outlined;
    switch (st) {
      case 'delivered':
        return Icons.done_all_rounded;
      case 'read':
        return Icons.done_all_rounded;
      case 'failed':
        return Icons.error_outline;
      case 'sent':
        return Icons.check_rounded;
      default:
        return Icons.schedule_rounded;
    }
  }

  Color _statusColor() {
    final st = _status?.status ?? _challenge.status;
    if (st == 'read') return const Color(0xFF34B7F1);
    if (st == 'failed') return AppColors.danger;
    if (st == 'delivered') return AppColors.success;
    return AppColors.textSecondary;
  }

  @override
  Widget build(BuildContext context) {
    final channel = _channel;
    final isDevice = channel == 'device';
    final remainingResend = _challenge.resendAt.difference(_now);
    final canResend = remainingResend.inMilliseconds <= 0;
    final remaining = _challenge.expiresAt.difference(_now);
    final canSms = (_status?.canRequestSms ?? false) && channel != 'sms' && !isDevice;
    final subtitle = isDevice
        ? a2(context, 'otpSubtitleDevice', {
            'device': (widget.primaryDeviceName ?? '').isEmpty
                ? a2(context, 'optPrimary')
                : widget.primaryDeviceName,
          })
        : widget.destination.isEmpty
            ? a2(context, 'optWhatsappHint')
            : a2(context, 'otpSubtitle', {'phone': '\u2066${widget.destination}\u2069'});
    final inputEnabled = !_locked && !_expired;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          subtitle,
          key: const Key('otp_subtitle'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 13.5,
            height: 1.5,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 12),
        // Live delivery status.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_statusIcon(), size: 16, color: _statusColor()),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                _statusText(context),
                key: const Key('otp_status'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: _statusColor(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _boxes(context, inputEnabled),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton.icon(
              key: const Key('otp_paste'),
              onPressed: inputEnabled ? _paste : null,
              icon: const Icon(Icons.content_paste_rounded, size: 16),
              label: Text(a2(context, 'otpPaste'),
                  style: const TextStyle(fontFamily: 'Cairo', fontSize: 12.5)),
            ),
          ],
        ),
        if (_error != null)
          Container(
            key: const Key('otp_error'),
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.danger.withAlpha(22),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.danger,
              ),
            ),
          ),
        if (_locked && _error == null)
          _notice(context, a2(context, 'otpLocked'), key: const Key('otp_locked')),
        if (_expired && !_locked)
          _notice(context, a2(context, 'otpExpired'), key: const Key('otp_expired')),
        const SizedBox(height: 12),
        if (!_expired && !_locked)
          Text(
            a2(context, 'otpExpiresIn', {'t': formatCountdown(remaining)}),
            key: const Key('otp_expiry'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 12,
              color: AppColors.textTertiary,
            ),
          ),
        const SizedBox(height: 14),
        SizedBox(
          height: 50,
          child: ElevatedButton(
            key: const Key('otp_verify'),
            onPressed: (_busy || !inputEnabled || _ctrl.text.length != 6) ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2))
                : Text(a2(context, 'otpVerify'),
                    style: const TextStyle(
                        fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(height: 8),
        if (widget.resend != null)
          TextButton(
            key: const Key('otp_resend'),
            onPressed: (canResend || _expired || _locked) && !_busy ? () => _resend() : null,
            child: Text(
              (canResend || _expired || _locked)
                  ? a2(context, 'otpResend')
                  : a2(context, 'otpResendIn', {'s': (remainingResend.inMilliseconds / 1000).ceil()}),
              style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700),
            ),
          ),
        if (canSms && widget.resend != null)
          OutlinedButton.icon(
            key: const Key('otp_sms'),
            onPressed: _busy ? null : () => _resend('sms'),
            icon: const Icon(Icons.sms_outlined, size: 18),
            label: Text(a2(context, 'otpSendSms'),
                style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
          ),
      ],
    );
  }

  Widget _notice(BuildContext context, String text, {Key? key}) => Container(
        key: key,
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.warning.withAlpha(24),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Cairo',
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppColors.warning,
          ),
        ),
      );

  Widget _boxes(BuildContext context, bool enabled) {
    final text = _ctrl.text;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        height: 56,
        child: Stack(
          children: [
            Row(
              children: [
                for (var i = 0; i < 6; i++) ...[
                  if (i > 0) SizedBox(width: i == 3 ? 14 : 8),
                  Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          width: i == text.length && _focus.hasFocus ? 1.8 : 1.1,
                          color: _error != null
                              ? AppColors.danger
                              : (i == text.length && _focus.hasFocus
                                  ? AppColors.primary
                                  : AppColors.border),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        i < text.length ? text[i] : '',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            // One real field over the boxes: keyboard, SMS/one-time-code
            // autofill and long-press paste all work natively.
            Positioned.fill(
              child: Opacity(
                opacity: 0.011,
                child: TextField(
                  key: const Key('otp_input'),
                  controller: _ctrl,
                  focusNode: _focus,
                  enabled: enabled,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  showCursor: false,
                  maxLength: 6,
                  inputFormatters: [
                    _OtpDigitsFormatter(),
                    LengthLimitingTextInputFormatter(6),
                  ],
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    filled: false,
                    counterText: '',
                  ),
                  onChanged: (v) {
                    setState(() => _error = null);
                    if (v.length == 6) unawaited(_submit());
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Keeps only digits (Arabic-Indic converted); a pasted message keeps its code.
class _OtpDigitsFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text;
    var digits = '';
    for (final r in raw.runes) {
      if (r >= 0x30 && r <= 0x39) {
        digits += String.fromCharCode(r);
      } else if (r >= 0x660 && r <= 0x669) {
        digits += String.fromCharCode(0x30 + r - 0x660);
      } else if (r >= 0x6F0 && r <= 0x6F9) {
        digits += String.fromCharCode(0x30 + r - 0x6F0);
      }
    }
    if (digits.length > 6) digits = extractOtp(raw) ?? digits.substring(0, 6);
    return TextEditingValue(
      text: digits,
      selection: TextSelection.collapsed(offset: digits.length),
    );
  }
}
