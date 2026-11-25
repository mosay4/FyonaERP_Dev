import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/localization/app_localizations.dart';
import '../../../../core/network/api_interceptors.dart' show DeviceIdentity;
import '../../../../core/responsive/breakpoints.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../../../shared/widgets/connectivity_widgets.dart';
import '../../../../shared/widgets/fyona_refresh.dart';
import '../../../../shared/widgets/fyona_text_field.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../data/models/session_model.dart';
import '../providers/auth_provider.dart';

/// Default device cap when an older server does not report one.
const int kDefaultSessionLimit = 3;

/// Fixed card order: the PRIMARY (first) device on top, then THIS device,
/// then the rest oldest first (the order they signed in). Pure (tested).
List<SessionModel> orderedSessions(
  List<SessionModel> sessions,
  bool Function(SessionModel) isMine,
) {
  final list = [...sessions];
  list.sort((a, b) {
    final aPrm = a.isPrimary ? 0 : 1;
    final bPrm = b.isPrimary ? 0 : 1;
    if (aPrm != bPrm) return aPrm - bPrm;
    final aMine = isMine(a) ? 0 : 1;
    final bMine = isMine(b) ? 0 : 1;
    if (aMine != bMine) return aMine - bMine;
    return a.createdAt.compareTo(b.createdAt);
  });
  return list;
}

/// Card frame: red ONLY on the device in hand (current). Primary /
/// secondary is status info (badges), never a border reason.
({Color color, double width}) sessionCardBorder({required bool isMine}) =>
    isMine
        ? (color: AppColors.danger, width: 1.5)
        : (color: AppColors.border, width: 1);

/// Who may sign a device out: never the primary; the primary device may
/// sign out any other device; any device may sign itself out. Mirrors the
/// server rules (auth_service.revoke_session).
bool canSignOutSession(SessionModel s,
    {required bool amPrimary, required bool isMine}) {
  if (s.isPrimary) return false;
  return amPrimary || isMine;
}

/// Who may rename a device: itself, or the primary device for any device
/// (server: auth_service.update_session_custom_name).
bool canRenameSession(SessionModel s,
    {required bool amPrimary, required bool isMine}) =>
    amPrimary || isMine;

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
  final Set<String> _busy = {};

  /// Legacy local nicknames (renames used to stay on the phone). Shown only
  /// when the server has no name for that device.
  Map<String, String> _nicknames = {};

  AppLocalizations get l10n => AppLocalizations.of(context);

  String _nickKey(String userId) => 'session_nicknames_$userId';
  String _cacheKey(String userId) => 'sessions_cache_$userId';

  bool get _amPrimary => _sessions.any((s) => _isMine(s) && s.isPrimary);

  int get _limit {
    for (final s in _sessions) {
      if (s.sessionLimit != null && s.sessionLimit! > 0) return s.sessionLimit!;
    }
    return kDefaultSessionLimit;
  }

  /// True when the row is THIS physical device: server `is_current`
  /// (refresh-token match) OR the stable device fingerprint.
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
          .map((e) => SessionModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// The device's own name (model as the platform reports it).
  String _deviceName(SessionModel s) {
    final info = s.deviceInfo?.trim() ?? '';
    if (info.isNotEmpty) return info;
    final model = s.deviceModel?.trim() ?? '';
    if (model.isNotEmpty) return model;
    return l10n.translate('deviceUnknown');
  }

  /// Display name: the name given on the server, then a legacy local
  /// nickname, then the device's own name.
  String _displayName(SessionModel s) {
    final custom = s.customName?.trim() ?? '';
    if (custom.isNotEmpty) return custom;
    final local = _nicknames[s.id]?.trim() ?? '';
    if (local.isNotEmpty) return local;
    return _deviceName(s);
  }

  Future<void> _loadSessions() async {
    setState(() {
      _loading = _sessions.isEmpty;
      _loadError = false;
      _showingCached = false;
    });
    try {
      final userId = ref.read(authProvider).user?.id;
      if (userId != null) {
        final sessions =
            await ref.read(authProvider.notifier).getActiveSessions(userId);
        await _saveSessionsCache(userId, sessions);
        if (mounted) setState(() => _sessions = sessions);
      }
    } catch (_) {
      // Keep the last known-good list instead of an empty screen that reads
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
      if (!restored) _snack(l10n.translate('errorOccurred'), error: true);
    }
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: error ? AppColors.danger : AppColors.success,
      ),
    );
  }

  String _errorText(Object e) {
    final msg = e
        .toString()
        .replaceFirst('Exception: ', '')
        .replaceFirst('ApiException: ', '')
        .replaceAll(RegExp(r'\s*\(status: [\dnull]+\)'), '')
        .trim();
    return msg.isEmpty ? l10n.translate('errorOccurred') : msg;
  }

  Future<bool> _requireOnline() async {
    final connectivity = ref.read(connectivityServiceProvider);
    if (connectivity.isOnline) return true;
    await showOfflineDialog(context, connectivity: connectivity);
    return false;
  }

  Future<void> _signOutSession(SessionModel session) async {
    if (session.isPrimary) {
      _snack(l10n.translate('sessionsCannotDeletePrimary'), error: true);
      return;
    }
    if (!await _requireOnline()) return;
    if (!mounted) return;
    final mine = _isMine(session);
    final confirm = await showConfirmDialog(
      context,
      title: l10n.translate(mine ? 'sessionsSignOutSelfTitle' : 'sessionsSignOutTitle'),
      message: l10n.translate(
        mine ? 'sessionsSignOutSelfMsg' : 'sessionsSignOutMsg',
        params: {'name': _displayName(session)},
      ),
      confirmText: l10n.translate('sessionsSignOutAction'),
      danger: true,
    );
    if (confirm != true || !mounted) return;
    if (mine) {
      // Signing THIS device out is a normal logout.
      await ref.read(authProvider.notifier).logout();
      if (mounted) context.go(RouteNames.login);
      return;
    }
    setState(() => _busy.add(session.id));
    try {
      await ref.read(authProvider.notifier).logoutSession(session.id);
      _snack(l10n.translate('sessionsSignedOut',
          params: {'name': _displayName(session)}));
    } catch (e) {
      _snack(_errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(session.id));
    }
    await _loadSessions();
  }

  Future<void> _renameSession(SessionModel session) async {
    if (!await _requireOnline()) return;
    if (!mounted) return;
    final controller = TextEditingController(text: session.customName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.mdBorder),
        title: Text(l10n.translate('sessionsDeviceName'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 16),
                fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.translate('sessionsRenameHint',
                  params: {'name': _deviceName(session)}),
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 12),
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 10),
            FyonaTextField(
              key: const Key('sessionRenameField'),
              controller: controller,
              autofocus: true,
              maxLength: 60,
              textInputAction: TextInputAction.done,
              style: TextStyle(
                  fontFamily: 'Cairo', fontSize: R.fontSize(context, 14)),
              decoration: InputDecoration(
                hintText: l10n.translate('sessionsDeviceHint'),
                hintStyle: TextStyle(
                    fontFamily: 'Cairo', color: AppColors.textTertiary),
                filled: true,
                fillColor: AppColors.surfaceVariant,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppColors.border),
                ),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.translate('cancel'),
                style: TextStyle(
                    fontFamily: 'Cairo', color: AppColors.textSecondary)),
          ),
          FilledButton(
            key: const Key('sessionRenameSave'),
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
            child: Text(l10n.translate('save'),
                style: const TextStyle(fontFamily: 'Cairo')),
          ),
        ],
      ),
    );
    if (name == null || !mounted) return;
    setState(() => _busy.add(session.id));
    try {
      await ref.read(authProvider.notifier).updateSessionName(session.id, name);
      _snack(l10n.translate('sessionsRenamed'));
    } catch (e) {
      _snack(_errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(session.id));
    }
    await _loadSessions();
  }

  Future<void> _logoutAll() async {
    if (!await _requireOnline()) return;
    if (!mounted) return;
    final confirm = await showConfirmDialog(
      context,
      title: l10n.translate('sessionsLogoutAllTitle'),
      message: l10n.translate('sessionsLogoutAllMsg'),
      danger: true,
    );
    if (confirm != true) return;
    try {
      final userId = ref.read(authProvider).user?.id;
      final current = _sessions.firstWhere(
        _isMine,
        orElse: () => _sessions.first,
      );
      await ref.read(authProvider.notifier).forceLogoutAll(
            userId: userId,
            excludeSessionId: current.id,
          );
    } catch (e) {
      _snack(_errorText(e), error: true);
      return;
    }
    await _loadSessions();
  }

  IconData _deviceIcon(SessionModel s) {
    final haystack = [s.platform, s.deviceInfo, s.deviceModel, s.osVersion]
        .whereType<String>()
        .join(' ')
        .toLowerCase();
    if (haystack.contains('ipad')) return Icons.tablet_mac;
    if (haystack.contains('iphone') || haystack.contains('ios')) {
      return Icons.phone_iphone;
    }
    if (haystack.contains('android') ||
        haystack.contains('samsung') ||
        haystack.contains('xiaomi') ||
        haystack.contains('huawei') ||
        haystack.contains('oppo') ||
        haystack.contains('vivo') ||
        haystack.contains('pixel') ||
        haystack.contains('sm-')) {
      return Icons.phone_android;
    }
    if (haystack.contains('windows')) return Icons.desktop_windows;
    if (haystack.contains('mac')) return Icons.laptop_mac;
    if (haystack.contains('linux')) return Icons.computer;
    return Icons.devices_other;
  }

  String? _platformLabel(String? platform) {
    switch ((platform ?? '').toLowerCase()) {
      case 'android':
        return 'Android';
      case 'ios':
        return 'iOS';
      case 'windows':
        return 'Windows';
      case 'macos':
        return 'macOS';
      case 'linux':
        return 'Linux';
      case 'web':
        return 'Web';
      case '':
        return null;
      default:
        return platform;
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isPhone = Breakpoints.isPhone(width);
    final ordered = orderedSessions(_sessions, _isMine);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.translate('sessionsPageTitle'),
            style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 17),
                fontWeight: FontWeight.w700)),
        leading: IconButton(
          icon: TwoToneIcon(data: TwoToneIcons.arrowRight),
          onPressed: () => context.pop(),
        ),
        actions: [
          if (_amPrimary && _sessions.length > 1)
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
              ? _buildEmpty()
              : FyonaRefresh(
                  onRefresh: _loadSessions,
                  child: ListView(
                    padding:
                        EdgeInsets.all(isPhone ? AppSpacing.md : AppSpacing.lg),
                    children: [
                      if (_showingCached) _buildCachedNotice(),
                      _buildSummary(),
                      const SizedBox(height: 14),
                      for (final s in ordered) _buildSessionCard(s),
                    ],
                  ),
                ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TwoToneIcon(
              data: TwoToneIcons.device,
              size: 64,
              outlineColor: AppColors.textDisabled),
          const SizedBox(height: 16),
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
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _loadSessions,
              style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
              child: Text(l10n.translate('retry'),
                  style: const TextStyle(fontFamily: 'Cairo')),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCachedNotice() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.warning.withAlpha(20),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          const Icon(Icons.cloud_off_outlined,
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
    );
  }

  /// "2 of 3 devices" with a slot meter, the account-wide scope note and,
  /// for secondary devices, who may sign devices out.
  Widget _buildSummary() {
    final used = _sessions.length;
    final limit = _limit;
    final full = used >= limit;
    final accent = full ? AppColors.warning : AppColors.primary;
    return Container(
      key: const Key('sessionsSummary'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.mdBorder,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: accent.withAlpha(25),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(Icons.devices_rounded, color: accent, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.translate('sessionsUsage',
                          params: {'used': used, 'limit': limit}),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 14),
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      l10n.translate('sessionsScopeNote'),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < limit; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: i < used ? accent : AppColors.surfaceVariant,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (full) ...[
            const SizedBox(height: 10),
            _note(Icons.info_outline, l10n.translate('sessionsLimitReachedNote'),
                AppColors.warning),
          ],
          if (!_amPrimary) ...[
            const SizedBox(height: 8),
            _note(Icons.lock_outline, l10n.translate('sessionsOnlyPrimaryNote'),
                AppColors.textSecondary),
          ],
        ],
      ),
    );
  }

  Widget _note(IconData icon, String text, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 14, color: color),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 11),
              color: color,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: R.fontSize(context, 10),
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Widget _detail(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppColors.textTertiary),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 11),
              color: AppColors.textTertiary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 11.5),
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionCard(SessionModel session) {
    final isMine = _isMine(session);
    final isPrimary = session.isPrimary;
    final frame = sessionCardBorder(isMine: isMine);
    final busy = _busy.contains(session.id);
    final canSignOut =
        canSignOutSession(session, amPrimary: _amPrimary, isMine: isMine);
    final canRename =
        canRenameSession(session, amPrimary: _amPrimary, isMine: isMine);
    final displayName = _displayName(session);
    final ownName = _deviceName(session);
    final platform = _platformLabel(session.platform);

    return Container(
      key: ValueKey('session-card-${session.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.mdBorder,
        border: Border.all(color: frame.color, width: frame.width),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: isPrimary
                      ? AppColors.primary.withAlpha(25)
                      : AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  _deviceIcon(session),
                  color:
                      isPrimary ? AppColors.primary : AppColors.textSecondary,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 14.5),
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (displayName != ownName)
                      Text(
                        ownName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 11.5),
                          color: AppColors.textTertiary,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        if (isPrimary)
                          _badge(l10n.translate('sessionsPrimaryBadge'),
                              AppColors.primary),
                        if (isMine)
                          _badge(l10n.translate('sessionsCurrentBadge'),
                              AppColors.success),
                        if (!isPrimary && !isMine)
                          _badge(l10n.translate('sessionsSecondaryBadge'),
                              AppColors.textSecondary),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant.withAlpha(110),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                if (session.deviceModel?.trim().isNotEmpty ?? false)
                  _detail(Icons.smartphone, l10n.translate('sessionsDetailModel'),
                      session.deviceModel!.trim()),
                if ((session.osVersion?.trim().isNotEmpty ?? false) ||
                    platform != null)
                  _detail(
                      Icons.settings_suggest_outlined,
                      l10n.translate('sessionsDetailSystem'),
                      (session.osVersion?.trim().isNotEmpty ?? false)
                          ? session.osVersion!.trim()
                          : platform!),
                if (session.appVersion?.trim().isNotEmpty ?? false)
                  _detail(Icons.apps_outlined,
                      l10n.translate('sessionsDetailAppVersion'),
                      session.appVersion!.trim()),
                _detail(Icons.access_time, l10n.translate('sessionsDetailLastActive'),
                    _relative(session.lastActivity)),
                _detail(
                    Icons.login_rounded,
                    l10n.translate('sessionsDetailFirstSignIn'),
                    '${_absolute(session.createdAt)} · ${_relative(session.createdAt)}'),
                if (session.locationLabel.isNotEmpty)
                  _detail(Icons.location_on_outlined,
                      l10n.translate('sessionsDetailLocation'),
                      session.locationLabel),
                if (session.ipAddress?.trim().isNotEmpty ?? false)
                  _detail(Icons.lan_outlined, l10n.translate('sessionsDetailIp'),
                      session.ipAddress!.trim()),
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Center(
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: ValueKey('session-rename-${session.id}'),
                    onPressed: canRename ? () => _renameSession(session) : null,
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: Text(l10n.translate('sessionsRename'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 12))),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textPrimary,
                      side: BorderSide(color: AppColors.border),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: isPrimary
                      ? Container(
                          key: ValueKey('session-locked-${session.id}'),
                          height: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withAlpha(15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.verified_user_outlined,
                                  size: 15, color: AppColors.primary),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  l10n.translate('sessionsPrimaryLocked'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: R.fontSize(context, 11.5),
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : FilledButton.icon(
                          key: ValueKey('session-signout-${session.id}'),
                          onPressed:
                              canSignOut ? () => _signOutSession(session) : null,
                          icon: const Icon(Icons.logout_rounded, size: 16),
                          label: Text(
                              l10n.translate(isMine
                                  ? 'sessionsSignOutSelfAction'
                                  : 'sessionsSignOutAction'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: R.fontSize(context, 12))),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.danger,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  String _relative(DateTime date) {
    final parts = relativeTimeParts(date, DateTime.now());
    return l10n.translate(parts.key, params: parts.params);
  }

  String _absolute(DateTime date) {
    final d = date.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}/${two(d.month)}/${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}

/// Pure relative-time mapping for session timestamps (unit-tested):
/// minutes → hours → 1 day → 2 days → N days.
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
