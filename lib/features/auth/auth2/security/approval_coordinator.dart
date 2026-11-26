import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/session_timeout_provider.dart';
import '../../../../core/router/shell_keys.dart';
import '../../../../core/security/device_identity.dart';
import '../../di/auth_providers.dart';
import '../auth2_api.dart';
import '../auth2_models.dart';
import 'approval_dialog.dart';

/// Brings primary-device approval requests to the trusted device:
///  - FCM data `login_approval` (foreground) → [onPush];
///  - app open / resume / every [interval] while signed in → GET
///    /auth2/approvals/pending (works without FCM, e.g. in QA builds);
///  - notification-center row `/security/approvals?id=…` → ApprovalsPage.
/// One popup at a time; never over the app lock; a request closed by the
/// user is not pushed again in this session (the inbox entry reopens it).
class ApprovalCoordinator with WidgetsBindingObserver {
  ApprovalCoordinator(this._ref, {this.interval = const Duration(seconds: 20)});

  final Ref _ref;
  final Duration interval;
  Timer? _timer;
  bool _running = false;
  bool _showing = false;
  bool _checking = false;
  final Set<String> _seen = {};

  void start() {
    if (_running) return;
    _running = true;
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}
    _timer = Timer.periodic(interval, (_) => checkPending());
    unawaited(checkPending());
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _seen.clear();
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _running) {
      unawaited(checkPending());
    }
  }

  /// FCM `login_approval {approval_id}` while the app is open.
  Future<void> onPush(String approvalId) async {
    _seen.remove(approvalId);
    await checkPending(focusId: approvalId);
  }

  Future<void> checkPending({String? focusId}) async {
    if (_checking || _showing) return;
    bool authed = false;
    try {
      authed = _ref.read(authStateProvider).isAuthenticated;
    } catch (_) {}
    if (!authed) return;
    _checking = true;
    List<PendingApproval> list = const [];
    try {
      // The server answers per calling device (X-Device-Id must be ready).
      try {
        await _ref.read(deviceKeyIdentityProvider).deviceId();
      } catch (_) {}
      list = await _ref.read(auth2ApiProvider).pendingApprovals();
    } catch (_) {
      _checking = false;
      return;
    }
    _checking = false;
    final now = DateTime.now();
    final open = list.where((a) => !a.isExpired(now)).toList();
    PendingApproval? next;
    if (focusId != null) {
      for (final a in open) {
        if (a.approvalId == focusId) next = a;
      }
    }
    next ??= open.where((a) => !_seen.contains(a.approvalId)).firstOrNull;
    if (next == null) return;
    await _show(next);
  }

  Future<void> _show(PendingApproval approval) async {
    try {
      if (_ref.read(sessionTimeoutProvider).locked) return;
    } catch (_) {}
    final ctx = rootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    _showing = true;
    _seen.add(approval.approvalId);
    try {
      await showApprovalDialog(ctx, approval);
    } catch (_) {
    } finally {
      _showing = false;
    }
  }
}

final approvalCoordinatorProvider = Provider<ApprovalCoordinator>((ref) {
  final c = ApprovalCoordinator(ref);
  ref.onDispose(c.stop);
  return c;
});
