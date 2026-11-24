import 'package:flutter/material.dart';
import '../../../../shared/widgets/connectivity_widgets.dart';
import '../../../../core/services/connectivity_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/network/api_interceptors.dart' show DeviceIdentity;
import '../../../../core/responsive/breakpoints.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../data/models/session_model.dart';
import '../providers/auth_provider.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../../../core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

/// Fixed card order: THIS device first, then the primary, then the rest by
/// newest. Pure (unit-tested) so the current device is always on top and
/// the primary keeps its unmistakable highlighted frame.
List<SessionModel> orderedSessions(
  List<SessionModel> sessions,
  bool Function(SessionModel) isMine,
) {
  final list = [...sessions];
  list.sort((a, b) {
    final aMine = isMine(a) ? 0 : 1;
    final bMine = isMine(b) ? 0 : 1;
    if (aMine != bMine) return aMine - bMine;
    final aPrm = a.isPrimary ? 0 : 1;
    final bPrm = b.isPrimary ? 0 : 1;
    if (aPrm != bPrm) return aPrm - bPrm;
    return b.createdAt.compareTo(a.createdAt);
  });
  return list;
}

/// Card frame: red ONLY on the device in hand (current). Primary /
/// secondary is status info (badges), never a border reason — every other
/// card shares the same neutral black/grey frame.
({Color color, double width}) sessionCardBorder({required bool isMine}) =>
    isMine
        ? (color: AppColors.danger, width: 1.5)
        : (color: AppColors.border, width: 1);

class SessionsPage extends ConsumerStatefulWidget {
  const SessionsPage({super.key});

  @override
  ConsumerState<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends ConsumerState<SessionsPage> {
  List<SessionModel> _sessions = [];
  bool _loading = true;
  bool _loadError = false;
  bool _showingCached = false;

  /// Local per-device nicknames: renaming here never leaves this phone
  /// (keyed per user + session id).
  Map<String, String> _nicknames = {};

  AppLocalizations get l10n => AppLocalizations.of(context);

  String _nickKey(String userId) => 'session_nicknames_$userId';
  String _cacheKey(String userId) => 'sessions_cache_$userId';

  /// True when THIS device holds the primary session: the only viewer
  /// allowed admin actions on other sessions (the server enforces the
  /// same rule; this only hides the options).
  bool get _amPrimary => _sessions.any((s) => _isMine(s) && s.isPrimary);

  /// True when the row is THIS physical device: the server `is_current`
  /// flag (refresh-token match) OR the stable device fingerprint. The
  /// fingerprint survives token rotation and identifies the device even
  /// among identical phone models sharing one account.
  bool _isMine(SessionModel session) {
    if (session.isCurrent) return true;
    final fp = DeviceIdentity.fingerprint;
    final rowFp = session.fingerprint;
    return fp != null &&
        fp.isNotEmpty &&
        rowFp != null &&
        rowFp.isNotEmpty &&
        rowFp == fp;
  }

  @override
  void initState() {
    super.initState();
    _loadNicknames();
    _loadSessions();
  }

  Future<void> _loadNicknames() async {
    try {
      final userId = ref.read(authProvider).user?.id;
      if (userId == null) return;
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_nickKey(userId));
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map && mounted) {
        setState(() => _nicknames = decoded.map(
            (k, v) => MapEntry(k.toString(), v.toString())));
      }
    } catch (_) {}
  }

  Future<void> _saveNickname(String userId, String sessionId, String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final nicknames = Map<String, String>.from(_nicknames);
      final trimmed = name.trim();
      if (trimmed.isEmpty) {
        nicknames.remove(sessionId);
      } else {
        nicknames[sessionId] = trimmed;
      }
      await prefs.setString(_nickKey(userId), jsonEncode(nicknames));
      if (mounted) setState(() => _nicknames = nicknames);
    } catch (_) {}
  }

  /// Last-known-good list for offline opens (display only; management
  /// actions still require connectivity).
  Future<void> _saveSessionsCache(
      String userId, List<SessionModel> sessions) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _cacheKey(userId),
          jsonEncode({
            'at': DateTime.now().toIso8601String(),
            'items': sessions.map((s) => s.toJson()).toList(),
          }));
    } catch (_) {}
  }

  Future<List<SessionModel>> _readSessionsCache(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey(userId));
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      final items = decoded is Map ? decoded['items'] : null;
      if (items is! List) return const [];
      return items
          .whereType<Map>()
          .map((e) =>
              SessionModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Display name: this phone's local nickname first (renames never leave
  /// the device), then the device info, never blank.
  String _displayName(SessionModel session) {
    final local = _nicknames[session.id];
    if (local != null && local.trim().isNotEmpty) return local.trim();
    return session.customName?.isNotEmpty == true
        ? session.customName!
        : session.deviceInfo ?? l10n.translate('deviceUnknown');
  }

  Future<void> _loadSessions() async {
    setState(() {
      _loading = true;
      _loadError = false;
      _showingCached = false;
    });
    try {
      final userId = ref.read(authProvider).user?.id;
      if (userId != null) {
        final sessions = await ref.read(authProvider.notifier).getActiveSessions(userId);
        await _adoptServerNames(userId, sessions);
        await _saveSessionsCache(userId, sessions);
        if (mounted) setState(() => _sessions = sessions);
      }
    } catch (_) {
      // Fetch failed (e.g. Wi-Fi blip on pull-to-refresh): fall back to the
      // last known-good list instead of showing an empty screen that reads
      // as "all sessions deleted".
      if (!mounted) return;
      var restored = false;
      try {
        final userId = ref.read(authProvider).user?.id;
        if (userId != null && _sessions.isEmpty) {
          final cached = await _readSessionsCache(userId);
          if (cached.isNotEmpty) {
            setState(() {
              _sessions = cached;
              _showingCached = true;
            });
            restored = true;
          }
        }
      } catch (_) {}
      setState(() => _loadError = true);
      if (!restored) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.translate('errorOccurred'),
                style: const TextStyle(fontFamily: 'Cairo')),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  /// One-time import: server-side custom names (set before this change)
  /// become this phone's local nicknames; afterwards renames never leave
  /// the device.
  Future<void> _adoptServerNames(
      String userId, List<SessionModel> sessions) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final nicknames =
          Map<String, String>.from(_nicknames.isNotEmpty ? _nicknames : {});
      var changed = false;
      for (final s in sessions) {
        final name = s.customName;
        if (name != null &&
            name.trim().isNotEmpty &&
            !nicknames.containsKey(s.id)) {
          nicknames[s.id] = name.trim();
          changed = true;
        }
      }
      if (changed) {
        await prefs.setString(_nickKey(userId), jsonEncode(nicknames));
      }
      if (mounted) setState(() => _nicknames = nicknames);
    } catch (_) {}
  }

  Future<void> _logoutSession(SessionModel session) async {
    if (!ref.read(connectivityServiceProvider).isOnline) {
      // Same alert as every other online-only service.
      await showOfflineDialog(context, connectivity: ref.read(connectivityServiceProvider));
      return;
    }
    if (session.isPrimary) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.translate('sessionsCannotDeletePrimary'), style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppColors.danger,
        ),
      );
      return;
    }
    final confirm = await showConfirmDialog(context,
      title: l10n.translate('sessionsDeleteTitle'),
      message: l10n.translate('sessionsDeleteConfirm'),
      danger: true,
    );
    if (confirm == true) {
      try {
        await ref.read(authProvider.notifier).logoutSession(session.id);
      } catch (e) {
        if (!mounted) return;
        final msg = e.toString().replaceFirst('Exception: ', '');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg.isEmpty ? l10n.translate('errorOccurred') : msg,
                style: const TextStyle(fontFamily: 'Cairo')),
            backgroundColor: AppColors.danger,
          ),
        );
        return;
      }
      _loadSessions();
    }
  }

  Future<void> _renameSession(SessionModel session) async {
    if (!ref.read(connectivityServiceProvider).isOnline) {
      // Same alert as every other online-only service.
      await showOfflineDialog(context, connectivity: ref.read(connectivityServiceProvider));
      return;
    }
    final controller = TextEditingController(
        text: _nicknames[session.id] ?? session.customName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.mdBorder),
        title: Text(l10n.translate('sessionsDeviceName'),
            style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 16), fontWeight: FontWeight.w700)),
        content: FyonaTextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 14)),
          decoration: InputDecoration(
            hintText: l10n.translate('sessionsDeviceHint'),
            hintStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.textTertiary),
            filled: true,
            fillColor: AppColors.surfaceVariant,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppColors.border),
            ),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.translate('cancel'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: Text(l10n.translate('save'), style: TextStyle(fontFamily: 'Cairo')),
          ),
        ],
      ),
    );
    if (name != null && mounted) {
      // Local-only rename: stored on THIS phone, never sent anywhere, so a
      // nickname is visible solely to its own device owner.
      final userId = ref.read(authProvider).user?.id;
      if (userId != null) await _saveNickname(userId, session.id, name);
    }
  }

  Future<void> _logoutAll() async {
    if (!ref.read(connectivityServiceProvider).isOnline) {
      // Same alert as every other online-only service.
      await showOfflineDialog(context, connectivity: ref.read(connectivityServiceProvider));
      return;
    }
    final confirm = await showConfirmDialog(context,
      title: l10n.translate('sessionsLogoutAllTitle'),
      message: l10n.translate('sessionsLogoutAllMsg'),
      danger: true,
    );
    if (confirm == true) {
      try {
        final userId = ref.read(authProvider).user?.id;
        final currentSession = _sessions.firstWhere(
          (s) => _isMine(s),
          orElse: () => _sessions.firstWhere(
            (s) => s.isCurrent,
            orElse: () => _sessions.first,
          ),
        );
        await ref.read(authProvider.notifier).forceLogoutAll(
          userId: userId,
          excludeSessionId: currentSession.id,
        );
      } catch (e) {
        if (!mounted) return;
        final msg = e.toString().replaceFirst('Exception: ', '');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg.isEmpty ? l10n.translate('errorOccurred') : msg,
                style: const TextStyle(fontFamily: 'Cairo')),
            backgroundColor: AppColors.danger,
          ),
        );
        return;
      }
      _loadSessions();
    }
  }

  IconData _deviceIcon(SessionModel session) {
    final haystack = [
      session.deviceInfo,
      session.deviceModel,
      session.osVersion,
    ].whereType<String>().join(' ').toLowerCase();
    if (haystack.contains('android') || haystack.contains('samsung') || haystack.contains('xiaomi') || haystack.contains('huawei') || haystack.contains('oppo') || haystack.contains('vivo') || haystack.contains('pixel') || haystack.contains('sm-')) return Icons.android;
    if (haystack.contains('iphone') || haystack.contains('ipad') || haystack.contains('ios')) return Icons.phone_iphone;
    if (haystack.contains('windows')) return Icons.desktop_windows;
    if (haystack.contains('mac')) return Icons.laptop_mac;
    if (haystack.contains('linux')) return Icons.computer;
    return Icons.devices;
  }

  /// Fixed order: THIS device first, then the primary, then the rest by
  /// newest. The current device is therefore always on top, and the
  /// primary keeps its unmistakable highlighted frame.
  List<SessionModel> get _orderedSessions =>
      orderedSessions(_sessions, _isMine);

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isPhone = Breakpoints.isPhone(width);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.translate('activeSessionsTitle'),
            style: TextStyle(fontFamily: 'Cairo', fontSize: R.fontSize(context, 17), fontWeight: FontWeight.w700)),
        leading: IconButton(
          icon: TwoToneIcon(data: TwoToneIcons.arrowRight),
          onPressed: () => context.pop(),
        ),
        actions: [
          if (_sessions.length > 1)
            IconButton(
              icon: const Icon(Icons.logout, color: AppColors.danger, size: 22),
              tooltip: l10n.translate('sessionsLogoutOthersTooltip'),
              onPressed: _logoutAll,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _sessions.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TwoToneIcon(data: TwoToneIcons.device, size: 64, outlineColor: AppColors.textDisabled),
                      SizedBox(height: 16),
                      Text(
                        _loadError
                            ? l10n.translate('errorOccurred')
                            : l10n.translate('noActiveSessions'),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 16),
                          color: AppColors.textSecondary,
                        ),
                      ),
                      if (_loadError) ...[
                        SizedBox(height: 12),
                        FilledButton(
                          onPressed: _loadSessions,
                          style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
                          child: Text(l10n.translate('retry'),
                              style: TextStyle(fontFamily: 'Cairo')),
                        ),
                      ],
                    ],
                  ),
                )
                : FyonaRefresh(
                  onRefresh: _loadSessions,
                  child: ListView(
                    padding: EdgeInsets.all(isPhone ? AppSpacing.md : AppSpacing.lg),
                    children: [
                      if (_showingCached)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: AppColors.warning.withAlpha(20),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                  color: AppColors.warning.withAlpha(50)),
                            ),
                            child: Row(children: [
                              Icon(Icons.cloud_off_outlined,
                                  size: 14, color: AppColors.warning),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  l10n.translate('sessionsCachedNotice'),
                                  style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: R.fontSize(context, 11),
                                    color: AppColors.warning,
                                  ),
                                ),
                              ),
                            ]),
                          ),
                        ),
                      // ── Current device first, then primary, then rest ──
                      ..._orderedSessions.map((s) =>
                          _buildSessionCard(s, isPrimary: s.isPrimary)),
                    ],
                  ),
                ),
    );
  }

  Widget _buildSessionCard(SessionModel session, {bool isPrimary = false}) {
    final displayName = _displayName(session);
    final isMine = _isMine(session);
    final frame = sessionCardBorder(isMine: isMine);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.mdBorder,
        border: Border.all(color: frame.color, width: frame.width),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header row ──
          Row(
            children: [
              // Device icon
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: isPrimary
                      ? AppColors.primary.withAlpha(25)
                      : AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  _deviceIcon(session),
                  color: isPrimary ? AppColors.primary : AppColors.textSecondary,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              // Name + device info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            displayName,
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 14),
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isPrimary) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withAlpha(20),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              l10n.translate('sessionsPrimaryBadge'),
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: R.fontSize(context, 10),
                                fontWeight: FontWeight.w600,
                                color: AppColors.primary,
                              ),
                            ),
                          ),
                        ],
                        if (isMine) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.success.withAlpha(25),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              l10n.translate('sessionsCurrentBadge'),
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: R.fontSize(context, 10),
                                fontWeight: FontWeight.w600,
                                color: AppColors.success,
                              ),
                            ),
                          ),
                        ],
                        if (!isPrimary && !isMine) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.textSecondary.withAlpha(20),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              l10n.translate('sessionsSecondaryBadge'),
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: R.fontSize(context, 10),
                                fontWeight: FontWeight.w600,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      session.deviceInfo ?? '',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              // Actions: rename is a local-only operation (any device);
              // delete is an admin action shown only when THIS device holds
              // the primary session (the server enforces the same rule).
              if (!isPrimary)
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert, size: 20, color: AppColors.textSecondary),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  onSelected: (v) {
                    if (v == 'rename') _renameSession(session);
                    if (v == 'delete') _logoutSession(session);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'rename',
                      child: Row(
                        children: [
                          Icon(Icons.edit_outlined, size: 18, color: AppColors.textSecondary),
                          const SizedBox(width: 8),
                          Text(l10n.translate('sessionsRename'), style: TextStyle(fontFamily: 'Cairo', fontSize: 13)),
                        ],
                      ),
                    ),
                    if (_amPrimary)
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline, size: 18, color: AppColors.danger),
                            const SizedBox(width: 8),
                            Text(l10n.translate('sessionsDeleteTitle'), style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: AppColors.danger)),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
          // ── Details row ──
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant.withAlpha(80),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.access_time, size: 14, color: AppColors.textTertiary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        l10n.translate('sessionsLastActivity', params: {'date': _formatDate(session.lastActivity)}),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 11),
                          color: AppColors.textTertiary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Icon(Icons.calendar_today, size: 14, color: AppColors.textTertiary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        l10n.translate('sessionsRegisteredAt', params: {'date': _formatDate(session.createdAt)}),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 11),
                          color: AppColors.textTertiary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (session.ipAddress != null) ...[
                      const SizedBox(width: 16),
                      Icon(Icons.wifi, size: 14, color: AppColors.textTertiary),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          session.ipAddress!,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 11),
                            color: AppColors.textTertiary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
                if ((session.deviceModel?.isNotEmpty ?? false) ||
                    (session.osVersion?.isNotEmpty ?? false) ||
                    session.locationLabel.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if ((session.deviceModel?.isNotEmpty ?? false) ||
                          (session.osVersion?.isNotEmpty ?? false)) ...[
                        Icon(Icons.smartphone, size: 14, color: AppColors.textTertiary),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            [
                              if (session.deviceModel?.isNotEmpty ?? false)
                                session.deviceModel!,
                              if (session.osVersion?.isNotEmpty ?? false)
                                session.osVersion!,
                            ].join(' • '),
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 11),
                              color: AppColors.textTertiary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      if (session.locationLabel.isNotEmpty) ...[
                        const SizedBox(width: 16),
                        Icon(Icons.location_on_outlined, size: 14, color: AppColors.textTertiary),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            session.locationLabel,
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 11),
                              color: AppColors.textTertiary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    final parts = relativeTimeParts(date, DateTime.now());
    return l10n.translate(parts.key, params: parts.params);
  }
}

/// Pure relative-time mapping for session timestamps (unit-tested):
/// minutes → hours → 1 day → 2 days → N days. Takes both instants so
/// tests pin "now" deterministically.
({String key, Map<String, Object> params}) relativeTimeParts(
    DateTime date, DateTime now) {
  final diff = now.difference(date);
  if (diff.inMinutes < 1) return (key: 'justNow', params: const {});
  if (diff.inMinutes < 60) {
    return (key: 'sessionsMinutesAgo', params: {'minutes': diff.inMinutes});
  }
  if (diff.inHours < 24) {
    return (key: 'sessionsHoursAgo', params: {'hours': diff.inHours});
  }
  final days = diff.inDays;
  if (days <= 1) return (key: 'sessionsDayAgo', params: const {});
  if (days == 2) return (key: 'sessionsTwoDaysAgo', params: const {});
  return (key: 'sessionsDaysAgo', params: {'days': days});
}
