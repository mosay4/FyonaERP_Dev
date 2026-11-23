import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/theme/app_colors.dart';
import '../providers/notifications_providers.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/services/section_scope.dart';
import '../../../employees/presentation/providers/employee_providers.dart';

/// Notification bell that polls the unread count periodically and opens the
/// notifications page. Shows a badge with the number of unread items.
class UnreadNotificationBell extends ConsumerStatefulWidget {
  final IconData icon;
  final Color? color;
  final Color badgeColor;
  final double iconSize;
  final String? tooltip;
  final Duration pollInterval;

  UnreadNotificationBell({
    super.key,
    this.icon = Icons.notifications_outlined,
    this.color,
    this.badgeColor = AppColors.danger,
    this.iconSize = 22,
    this.tooltip,
    this.pollInterval = const Duration(seconds: 10),
  });

  @override
  ConsumerState<UnreadNotificationBell> createState() => _UnreadNotificationBellState();
}

class _UnreadNotificationBellState extends ConsumerState<UnreadNotificationBell> with WidgetsBindingObserver {
  Timer? _timer;
  bool _allowed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(widget.pollInterval, (_) {
      if (mounted && _allowed) ref.invalidate(unreadCountProvider);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (mounted && _allowed) ref.invalidate(unreadCountProvider);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _allowed = ref.watch(activeSectionProvider) == AppSection.personal ||
        ref.watch(employeeCanProvider('notifications'));
    if (!_allowed) return const SizedBox.shrink();
    // The bell must render in every situation (offline, cold start, provider
    // errors). Any failure below degrades to a plain bell with no badge —
    // the button itself never disappears.
    int unread = 0;
    try {
      unread = ref.watch(unreadCountProvider).value ?? 0;
    } catch (_) {
      unread = 0;
    }

    // Clean circular frame matching the profile avatar size, adapting to BOTH
    // themes (light: soft gray wash · dark: faint white wash).
    final bellSize = 32.0;
    final frameColor = widget.color ?? AppColors.textPrimary;
    final fillColor = AppColors.isLightMode
        ? Color(0xFF000000).withAlpha(10)   // light theme: soft gray wash
        : Colors.white.withAlpha(14);       // dark theme: faint white wash
    final borderColor = AppColors.isLightMode
        ? Color(0xFF9AA0A6).withAlpha(120)  // light theme: warm gray ring
        : Colors.white.withAlpha(70);       // dark theme: white ring

    Widget bell = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => context.push(RouteNames.notifications),
      child: Container(
        width: bellSize,
        height: bellSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: fillColor,
          border: Border.all(color: borderColor, width: 1.2),
        ),
        child: Center(
          child: Icon(
            widget.icon,
            color: frameColor,
            size: widget.iconSize,
          ),
        ),
      ),
    );

    if (unread > 0) {
      bell = Badge(
        backgroundColor: widget.badgeColor,
        label: Text(
          unread > 99 ? '99+' : '$unread',
          style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: Colors.white),
        ),
        child: bell,
      );
    }

    return bell;
  }
}
