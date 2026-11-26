import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../auth2_api.dart';
import '../auth2_models.dart';
import '../auth2_service.dart';
import '../auth2_strings.dart';
import '../widgets/otp_view.dart' show formatCountdown;

String formatApprovalTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}/${two(t.month)}/${two(t.day)}  ${two(t.hour)}:${two(t.minute)}';
}

/// Shows the primary-device approval popup. Returns true when the attempt
/// was denied.
Future<bool?> showApprovalDialog(BuildContext context, PendingApproval approval) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ApprovalDialog(approval: approval),
  );
}

/// Professional sign-in approval card on the trusted device: who is trying
/// (device / OS / approximate location / time), the 6-digit code fetched
/// over the authenticated channel with a FRESH device proof, a countdown,
/// Deny, and the safety warning. The code disappears at expiry and as soon
/// as the request is no longer pending (success elsewhere / denied).
class ApprovalDialog extends ConsumerStatefulWidget {
  const ApprovalDialog({
    super.key,
    required this.approval,
    this.pendingPoll = const Duration(seconds: 4),
    this.clock,
  });

  final PendingApproval approval;
  final Duration pendingPoll;

  /// Time source (tests inject a controllable clock).
  final DateTime Function()? clock;

  @override
  ConsumerState<ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends ConsumerState<ApprovalDialog> {
  ApprovalCode? _code;
  String? _error;
  bool _done = false;
  bool _denying = false;
  DateTime _clock() => widget.clock?.call() ?? DateTime.now();
  late DateTime _now = _clock();
  Timer? _ticker;
  Timer? _pending;

  DateTime get _expiresAt {
    final c = _code?.expiresAt;
    final a = widget.approval.expiresAt;
    if (c == null) return a;
    return c.isBefore(a) ? c : a;
  }

  bool _hardExpired = false;
  bool get _expired => _hardExpired || !_now.isBefore(_expiresAt);

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _now = _clock();
        // Never keep an expired code around, not even in memory.
        if (_expired) {
          _hardExpired = true;
          _code = null;
        }
      });
      if (_expired) {
        _ticker?.cancel();
        _pending?.cancel();
      }
    });
    if (!widget.approval.isExpired(_now)) {
      unawaited(_fetchCode());
      _pending = Timer.periodic(widget.pendingPoll, (_) => _checkStillPending());
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pending?.cancel();
    super.dispose();
  }

  Future<void> _fetchCode() async {
    try {
      final code =
          await ref.read(auth2ServiceProvider).approvalCode(widget.approval.approvalId);
      if (!mounted) return;
      setState(() => _code = code);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = auth2ErrorTextOf(context, e);
        if (e is Auth2Exception &&
            const {'expired', 'not_found', 'already_used', 'verified', 'denied'}
                .contains(e.code)) {
          _done = true;
        }
      });
    }
  }

  Future<void> _checkStillPending() async {
    if (_done || _expired) return;
    try {
      final list = await ref.read(auth2ApiProvider).pendingApprovals();
      if (!mounted) return;
      final still = list.any((a) => a.approvalId == widget.approval.approvalId);
      if (!still) {
        setState(() {
          _done = true;
          _code = null;
        });
        _pending?.cancel();
      }
    } catch (_) {}
  }

  Future<void> _deny() async {
    setState(() => _denying = true);
    try {
      await ref.read(auth2ApiProvider).denyApproval(widget.approval.approvalId);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _denying = false;
        _error = auth2ErrorTextOf(context, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.approval;
    final showCode = _code != null && !_expired && !_done;
    final deviceLabel = [a.deviceName, if (a.deviceModel != a.deviceName) a.deviceModel]
        .where((s) => s.trim().isNotEmpty)
        .join(' · ');
    final osLabel = [a.os, a.osVersion].where((s) => s.trim().isNotEmpty).join(' ');

    return Dialog(
      key: const Key('approval_dialog'),
      backgroundColor: AppColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(28),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.shield_outlined,
                    color: AppColors.primary, size: 28),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              a2(context, 'approvalTitle'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            Text(
              a2(context, 'approvalSubtitle'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12.5,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  _row(context, Icons.smartphone_rounded, 'approvalDevice',
                      deviceLabel.isEmpty ? '—' : deviceLabel),
                  if (osLabel.isNotEmpty)
                    _row(context, Icons.memory_rounded, 'approvalOs', osLabel),
                  if (a.locationHint != null)
                    _row(context, Icons.place_outlined, 'approvalLocation',
                        a.locationHint!),
                  _row(context, Icons.schedule_rounded, 'approvalTime',
                      formatApprovalTime(a.createdAt)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            if (showCode) ...[
              Text(
                a2(context, 'approvalCode'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 4),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text(
                  '${_code!.code.substring(0, _code!.code.length ~/ 2)} '
                  '${_code!.code.substring(_code!.code.length ~/ 2)}',
                  key: const Key('approval_code'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 34,
                    letterSpacing: 6,
                    fontWeight: FontWeight.w900,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Text(
                a2(context, 'approvalExpiresIn',
                    {'t': formatCountdown(_expiresAt.difference(_now))}),
                key: const Key('approval_countdown'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.warning,
                ),
              ),
            ] else if (_expired)
              _state(context, a2(context, 'approvalExpired'), const Key('approval_expired'))
            else if (_done)
              _state(context, a2(context, 'approvalDone'), const Key('approval_done'))
            else if (_error != null)
              _state(context, _error!, const Key('approval_error'))
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(a2(context, 'approvalLoadingCode'),
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 12,
                              color: AppColors.textSecondary)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Container(
              key: const Key('approval_warning'),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.danger.withAlpha(20),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 18, color: AppColors.danger),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      a2(context, 'approvalWarning'),
                      style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12,
                        height: 1.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    key: const Key('approval_close'),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(a2(context, 'approvalClose'),
                        style: const TextStyle(
                            fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
                  ),
                ),
                if (!_expired && !_done) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      key: const Key('approval_deny'),
                      style: FilledButton.styleFrom(
                          backgroundColor: AppColors.danger),
                      onPressed: _denying ? null : _deny,
                      child: Text(a2(context, 'approvalDeny'),
                          style: const TextStyle(
                              fontFamily: 'Cairo', fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _state(BuildContext context, String text, Key key) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          text,
          key: key,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
          ),
        ),
      );

  Widget _row(BuildContext context, IconData icon, String labelKey, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.textTertiary),
          const SizedBox(width: 8),
          Text(
            '${a2(context, labelKey)}: ',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 12,
              color: AppColors.textTertiary,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
