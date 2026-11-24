import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/utils/server_image_url.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/offline/offline_guard.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../../../core/utils/bilingual_text.dart';
import '../../../../shared/widgets/business_widgets.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../providers/notifications_providers.dart';
import '../../di/notifications_providers.dart';
import '../../data/models/notification_models.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import 'package:fyona_flutter/core/router/role_config.dart';
import 'package:fyona_flutter/features/auth/presentation/providers/auth_provider.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

class NotificationListPage extends ConsumerStatefulWidget {
  final String? notifId;
  NotificationListPage({super.key, this.notifId});
  @override
  ConsumerState<NotificationListPage> createState() =>
      _NotificationListPageState();
}

class _NotificationListPageState extends ConsumerState<NotificationListPage>
    with WidgetsBindingObserver {
  Timer? _pollTimer;
  int _tab = 0; // 0 = system, 1 = admin
  bool _highlighted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      ref.invalidate(notificationListProvider);
      ref.invalidate(unreadCountProvider);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!mounted) return;
      ref.invalidate(notificationListProvider);
      ref.invalidate(unreadCountProvider);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    super.dispose();
  }

  /// Friendly offline-aware error view. Never dumps a raw stack trace.
  Widget _offlineSafeError(Object e) {
    final offline =
        isConnectivityError(e) ||
        !ref.read(connectivityServiceProvider).isOnline;
    if (offline) return _offlineEmpty();
    return EmptyStateWidget(
      title: AppLocalizations.of(context).translate('errorOccurred'),
      subtitle: AppLocalizations.t('coreServerUnavailable'),
      icon: Icons.error_outline,
    );
  }

  /// Shown when offline with no cached notifications yet: the user still needs
  /// a friendly "no notifications yet" message instead of a scary server error.
  Widget _offlineEmpty() {
    return EmptyStateWidget(
      title: AppLocalizations.of(context).translate('adminNoNotifications'),
      subtitle: AppLocalizations.of(
        context,
      ).translate('adminNoNotificationsHint'),
      icon: Icons.notifications_outlined,
    );
  }

  @override
  Widget build(BuildContext context) {
    final notifAsync = ref.watch(notificationListProvider);

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: Text(AppLocalizations.of(context).translate('notifications')),
        ),
        body: FyonaRefresh(
          onRefresh: () async {
            ref.invalidate(notificationListProvider);
            ref.invalidate(unreadCountProvider);
          },
          child: Builder(
            builder: (_) {
              // Offline-first: connectivity failures never surface as an error
              // screen here — the service returns the cached mirror (possibly
              // empty), and an empty offline list gets a friendly hint.
              final offline = !ref.watch(connectivityServiceProvider).isOnline;
              return notifAsync.when(
                loading: () => const LoadingShimmer(),
                error: (e, _) =>
                    offline ? _offlineEmpty() : _offlineSafeError(e),
                data: (notifs) {
                  // Opening the notifications screen marks EVERYTHING as read
                  // at once — no tap-to-read needed anymore.
                  if (notifs.any((n) => !n.isRead)) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _markAllReadSilent();
                    });
                  }
                  final system = notifs
                      .where((n) => !n.isAdminWritten)
                      .toList();
                  final admin = notifs.where((n) => n.isAdminWritten).toList();
                  // Auto-select the correct tab when opened from a notification tap.
                  if (!_highlighted &&
                      widget.notifId != null &&
                      notifs.isNotEmpty) {
                    _highlighted = true;
                    final target = notifs
                        .where((n) => n.id == widget.notifId)
                        .firstOrNull;
                    if (target != null) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted)
                          setState(() => _tab = target.isAdminWritten ? 1 : 0);
                      });
                    }
                  }
                  final shown = _tab == 0 ? system : admin;
                  return Column(
                    children: [
                      _buildTabs(system.length, admin.length),
                      Expanded(
                        child: shown.isEmpty
                            ? (offline
                                  ? _offlineEmpty()
                                  : EmptyStateWidget(
                                      title: AppLocalizations.of(
                                        context,
                                      ).translate('adminNoNotifications'),
                                      subtitle: AppLocalizations.of(context)
                                          .translate(
                                            'notificationsNotificationsWillBeDisplayed',
                                          ),
                                      icon: Icons.notifications,
                                    ))
                            : ListView.builder(
                                padding: EdgeInsets.all(16),
                                itemCount: shown.length,
                                itemBuilder: (context, index) {
                                  final notif = shown[index];
                                  return _buildNotifItem(notif);
                                },
                              ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildTabs(int systemCount, int adminCount) {
    Widget tab(String label, int count, int index, IconData icon) {
      final active = _tab == index;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _tab = index),
          child: Container(
            padding: EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: active ? AppColors.primary : AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: active ? AppColors.primary : AppColors.border,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: active ? Colors.white : AppColors.textSecondary,
                ),
                SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 12),
                      fontWeight: FontWeight.w700,
                      color: active ? Colors.white : AppColors.textSecondary,
                    ),
                  ),
                ),
                SizedBox(width: 6),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(
                    color: active
                        ? Colors.white.withAlpha(30)
                        : AppColors.primary.withAlpha(12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 11),
                      fontWeight: FontWeight.w700,
                      color: active ? Colors.white : AppColors.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          tab(
            AppLocalizations.of(context).translate('notifSystem'),
            systemCount,
            0,
            Icons.settings_outlined,
          ),
          SizedBox(width: 10),
          tab(
            AppLocalizations.of(context).translate('notifAdmin'),
            adminCount,
            1,
            Icons.admin_panel_settings_outlined,
          ),
        ],
      ),
    );
  }

  Widget _buildNotifItem(NotificationItem notif) {
    Color iconColor;
    IconData iconData;
    switch (notif.type) {
      case 'warning':
        iconColor = AppColors.warning;
        iconData = Icons.error_outline;
        break;
      case 'success':
        iconColor = AppColors.success;
        iconData = Icons.check_circle;
        break;
      default:
        iconColor = AppColors.info;
        iconData = Icons.info;
    }

    final isHighlighted = widget.notifId != null && notif.id == widget.notifId;

    return GestureDetector(
      onTap: () => _onNotifTap(notif),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        margin: EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: isHighlighted
              ? AppColors.primary.withAlpha(25)
              : (notif.isRead
                    ? AppColors.surface
                    : AppColors.primary.withAlpha(8)),
          borderRadius: AppRadius.mdBorder,
          border: Border.all(
            color: isHighlighted
                ? AppColors.primary
                : (notif.isRead
                      ? AppColors.border
                      : AppColors.primary.withAlpha(40)),
            width: isHighlighted ? 2.0 : 1.0,
          ),
        ),
        child: ListTile(
          contentPadding: EdgeInsets.all(12),
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconColor.withAlpha(25),
              borderRadius: BorderRadius.circular(10),
            ),
            child: serverImageUrl(notif.imageUrl) == null
                ? Icon(iconData, color: iconColor, size: 20)
                : ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: CachedNetworkImage(
                      imageUrl: serverImageUrl(notif.imageUrl)!,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) =>
                          Icon(iconData, color: iconColor, size: 20),
                    ),
                  ),
          ),
          title: Text(
            notif.title,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 13),
              fontWeight: notif.isRead ? FontWeight.w400 : FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          subtitle: notif.message != null
              ? Text(
                  localizedText(notif.message!),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 11),
                    color: AppColors.textSecondary,
                  ),
                )
              : null,
          trailing: Text(
            _timeAgo(notif.createdAt),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 10),
              color: AppColors.textDisabled,
            ),
          ),
        ),
      ),
    );
  }

  String _timeAgo(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inMinutes < 1)
      return AppLocalizations.of(context).translate('justNow');
    if (diff.inHours < 1)
      return AppLocalizations.of(
        context,
      ).translate('notificationsSinceD', params: {'inMinutes': diff.inMinutes});
    if (diff.inDays < 1)
      return AppLocalizations.of(
        context,
      ).translate('notificationsSinceS', params: {'inHours': diff.inHours});
    return AppLocalizations.of(
      context,
    ).translate('notificationsSinceJ', params: {'inDays': diff.inDays});
  }

  Future<void> _onNotifTap(NotificationItem notif) async {
    // No tap-to-read anymore: entering this page already marks everything
    // read. Tapping only navigates when the notification carries a route.
    if (!mounted) return;
    final payload = (notif.route != null && notif.route!.startsWith('/'))
        ? notif.route
        : notif.actionPayload;
    if (payload == null || !payload.startsWith('/')) return;
    final user = ref.read(authProvider).user;
    if (user == null) return;
    if (!isRouteAllowed(
      payload,
      user.role,
      preferredUsageMode: user.preferredUsageMode,
    ))
      return;
    context.push(payload);
  }

  /// Silent version used automatically on page open (no snackbar).
  Future<void> _markAllReadSilent() async {
    try {
      await ref.read(notificationServiceProvider).markAllRead();
      if (!mounted) return;
      ref.invalidate(notificationListProvider);
      ref.invalidate(unreadCountProvider);
    } catch (_) {}
  }

  Future<void> _markAllRead() async {
    try {
      await ref.read(notificationServiceProvider).markAllRead();
      ref.invalidate(notificationListProvider);
      ref.invalidate(unreadCountProvider);
      showSnackbar(
        context,
        message: AppLocalizations.of(
          context,
        ).translate('notificationsAllMarkedAsRead'),
      );
    } catch (e) {
      // Offline: stay silent instead of dumping a raw error — nothing was lost.
      if (isConnectivityError(e) ||
          !ref.read(connectivityServiceProvider).isOnline)
        return;
      showSnackbar(context, message: '$e', color: AppColors.danger);
    }
  }
}
