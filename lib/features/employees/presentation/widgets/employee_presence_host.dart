import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/section_scope.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../branches/data/branch_api.dart';
import '../../../branches/data/branch_scope.dart';
import '../../data/employee_api.dart';
import '../providers/employee_providers.dart';

/// A single app-level heartbeat, never tied to which business tab is mounted.
class EmployeePresenceHost extends ConsumerStatefulWidget {
  const EmployeePresenceHost({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<EmployeePresenceHost> createState() =>
      _EmployeePresenceHostState();
}

class _EmployeePresenceHostState extends ConsumerState<EmployeePresenceHost>
    with WidgetsBindingObserver {
  Timer? _timer;
  String? _organization;
  String? _scopeToken;
  bool _foreground = true;
  Future<void> _pending = Future.value();
  late EmployeeApi _api;

  @override
  void initState() {
    super.initState();
    _api = ref.read(employeeApiProvider);
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  void _send(bool online, String? token) {
    // Serialize transitions so an in-flight online request cannot follow offline.
    _pending = _pending.then(
      (_) => _api.heartbeat(online: online, scopeToken: token),
    );
  }

  void _sync() {
    final active =
        _foreground &&
        ref.read(authProvider).isAuthenticated &&
        ref.read(activeSectionProvider) == AppSection.business;
    final company = active ? ref.read(employeeWorkspaceCompanyProvider) : null;
    final organization = company?['organization_id']?.toString();
    if (_organization == organization && _scopeToken == BranchScope.token)
      return;
    _timer?.cancel();
    if (_organization != null) _send(false, _scopeToken);
    _organization = organization;
    _scopeToken = BranchScope.token;
    if (organization != null) {
      _send(true, _scopeToken);
      _timer = Timer.periodic(const Duration(seconds: 25), (_) {
        _send(true, _scopeToken);
        // The employee may remain on the same page while the merchant edits
        // grants on another device. Refresh the live permission source too.
        unawaited(refreshBranchAccessIfChanged(ref).catchError((Object _) {}));
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_organization != null) _send(false, _scopeToken);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authenticated = ref.watch(
      authProvider.select((state) => state.isAuthenticated),
    );
    final section = ref.watch(activeSectionProvider);
    ref.listen(authProvider, (_, _) => _sync());
    ref.listen(activeSectionProvider, (_, _) => _sync());
    if (authenticated && section == AppSection.business) {
      ref.listen(employeeWorkspaceCompanyProvider, (_, _) => _sync());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
    return widget.child;
  }
}
