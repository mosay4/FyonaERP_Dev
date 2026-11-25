import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/models/personal_models.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/router/shell_keys.dart';
import '../../../shared/services/reminder_codec.dart';
import '../../../shared/widgets/two_tone_icon.dart';
import '../../../shared/widgets/two_tone_icons.dart';
import '../../../core/utils/currency_formatter.dart';
import '../../../core/localization/app_localizations.dart';

// ============================================================================
// DebtReminderService — Local offline reminder, no Firebase, no polling.
// Uses native AlarmManager (exact) + Full-Screen Intent notification.
// Works when app is closed, in background, or offline.
// ============================================================================
class DebtReminderService {
  static const MethodChannel _native = MethodChannel('com.fyona.erp/alarm_native');
  static bool _initialized = false;

  // Single SharedPreferences key holding all reminders as JSON map:
  // { "debt_<id>": { "debt": {...}, "millis": 1234567890 } }
  static const String _prefsKey = 'debt_reminders_v2';
  static const String _shownKey = 'debt_reminder_shown_v2';

  // Use debt.id directly as unique key — no fingerprint collision.
  static String _keyFor(PersonalDebt debt) => 'debt_${debt.id}';

  static BuildContext? Function()? _contextProvider;

  static void setContextProvider(BuildContext? Function()? provider) {
    _contextProvider = provider;
  }

  static Future<void> init() async {
    if (_initialized) return;
    if (Platform.isAndroid) {
      try {
        await _native.invokeMethod('createAlarmChannel');
      } catch (_) {}
      // Listen for alarm fired while app is in foreground
      _native.setMethodCallHandler((call) async {
        if (call.method == 'onAlarmReceived') {
          final debtId = call.arguments is Map ? (call.arguments as Map)['debtId']?.toString() : null;
          if (debtId != null && debtId.isNotEmpty) {
            final debt = await _findDebtById(debtId);
            if (debt != null) {
              final ctx = _contextProvider?.call();
              if (ctx != null && ctx.mounted) {
                await markAlarmShown(debt);
                final prefs = await SharedPreferences.getInstance();
                final all = _decodeAll(prefs.getString(_prefsKey));
                all.remove(_keyFor(debt));
                await prefs.setString(_prefsKey, jsonEncode(all));
                try { await showAlarm(ctx, debt); } catch (_) {}
              }
            }
          }
        }
      });
    }
    _initialized = true;
  }

  static Future<String?> getInitialAlarmDebtId() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _native.invokeMethod<String>('getInitialAlarmDebtId');
    } catch (_) { return null; }
  }

  static Future<void> showAlarmForDebtId(String debtId, BuildContext context) async {
    final debt = await _findDebtById(debtId);
    if (debt == null) return;
    await markAlarmShown(debt);
    final prefs = await SharedPreferences.getInstance();
    final all = _decodeAll(prefs.getString(_prefsKey));
    all.remove(_keyFor(debt));
    await prefs.setString(_prefsKey, jsonEncode(all));
    if (context.mounted) {
      try { await showAlarm(context, debt); } catch (_) {}
    }
  }

  static Future<PersonalDebt?> _findDebtById(String debtId) async {
    final prefs = await SharedPreferences.getInstance();
    final all = _decodeAll(prefs.getString(_prefsKey));
    for (final entry in all.values) {
      final debtJson = entry['debt'] as Map<String, dynamic>?;
      if (debtJson != null && debtJson['id']?.toString() == debtId) {
        try { return PersonalDebt.fromJson(debtJson); } catch (_) {}
      }
    }
    return null;
  }

  // ── Permissions ────────────────────────────────────────────────────────────

  /// Ensures POST_NOTIFICATIONS is granted (Android 13+). Returns true if granted.
  static Future<bool> ensureNotificationPermission() async {
    await init();
    if (!Platform.isAndroid) return true;
    try {
      // Use flutter_local_notifications check via native side to avoid permission_handler
      final ok = await _native.invokeMethod<bool>('areNotificationsEnabled');
      if (ok == true) return true;
      final granted = await _native.invokeMethod<bool>('requestNotificationsPermission');
      return granted == true;
    } catch (_) {
      return true; // best effort
    }
  }

  /// Requests SCHEDULE_EXACT_ALARM if not already granted (Android 12+).
  static Future<void> requestExactAlarmPermissionIfNeeded() async {
    if (!Platform.isAndroid) return;
    try {
      final can = await _native.invokeMethod<bool>('canScheduleExactAlarms');
      if (can == false) {
        await _native.invokeMethod('requestExactAlarmPermission');
      }
    } catch (_) {}
  }

  /// Returns true when exact alarms may currently be scheduled (Android
  /// 12+). Shared by BOTH reminder types (debt + recurring). Never throws.
  static Future<bool> canScheduleExactAlarms() async {
    if (!Platform.isAndroid) return true;
    try {
      final can = await _native.invokeMethod<bool>('canScheduleExactAlarms');
      return can != false;
    } catch (_) {
      return true;
    }
  }

  /// Requests battery exemption for Samsung / aggressive OEMs.
  /// Only opens settings if not already exempt.
  static Future<void> requestBatteryExemption() async {
    if (!Platform.isAndroid) return;
    try {
      final alreadyExempt = await _native.invokeMethod<bool>('isIgnoringBatteryOptimization');
      if (alreadyExempt == true) return;
      await _native.invokeMethod('requestBatteryExemption');
    } catch (_) {}
  }

  /// Returns true if battery optimization is already ignored for this app.
  static Future<bool> isBatteryExempt() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _native.invokeMethod<bool>('isIgnoringBatteryOptimization');
      return result == true;
    } catch (_) { return true; }
  }

  /// Requests Full-Screen Intent permission on Android 14+ where required.
  /// Only opens settings if not already granted.
  static Future<void> requestFullScreenIntentPermissionIfNeeded() async {
    if (!Platform.isAndroid) return;
    try {
      final alreadyGranted = await _native.invokeMethod<bool>('canUseFullScreenIntent');
      if (alreadyGranted == true) return;
      await _native.invokeMethod('requestFullScreenIntentPermission');
    } catch (_) {}
  }

  /// Returns true if full-screen intent permission is already granted.
  static Future<bool> isFullScreenIntentGranted() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _native.invokeMethod<bool>('canUseFullScreenIntent');
      return result == true;
    } catch (_) { return true; }
  }

  // ── Schedule / Cancel ────────────────────────────────────────────────────

  /// Concise body from the REAL debt: person • amount • due date.
  /// Direction (payable/receivable) already lives in the title.
  static String _bodyFor(PersonalDebt debt, DateTime dueDate) {
    final base =
        '${debt.personName} — ${fmtNum(debt.remaining)} ${currencySymbol(debt.currency)}';
    return '$base • ${dueDate.year}/${dueDate.month}/${dueDate.day}';
  }

  /// Schedules an exact alarm for [dueDate] at [time]. Persists locally.
  static Future<void> schedule(
    PersonalDebt debt,
    DateTime dueDate,
    TimeOfDay time,
  ) async {
    await init();
    final scheduled = DateTime(dueDate.year, dueDate.month, dueDate.day, time.hour, time.minute);

    // Persist (existing format kept; requestCode + route added for the
    // native bridge and tap routing).
    final requestCode = ReminderCodec.debtRequestCode(debt.id);
    final prefs = await SharedPreferences.getInstance();
    final all = _decodeAll(prefs.getString(_prefsKey));
    all[_keyFor(debt)] = {
      'debt': debt.toJson(),
      'millis': scheduled.millisecondsSinceEpoch,
      'requestCode': requestCode,
      'route': ReminderCodec.debtRouteFor(debt.id),
      'kind': 'debt',
      'refId': debt.id,
    };
    await prefs.setString(_prefsKey, jsonEncode(all));
    // Clear shown flag so it can fire again (for edits / snooze)
    await prefs.remove('$_shownKey${_keyFor(debt)}');

    // If time is in the past: show immediately if within 30 min, else don't schedule
    final now = DateTime.now();
    if (scheduled.isBefore(now)) {
      if (now.difference(scheduled).inMinutes < 30) {
        // Show via notification now (will use full-screen if possible)
        try {
          await _native.invokeMethod('showImmediateAlarm', {
            'title': AppLocalizations.t(debt.type == 'payable' ? 'debtNotifyTitlePayable' : 'debtNotifyTitleReceivable'),
            'body': _bodyFor(debt, dueDate),
            'debtId': debt.id,
          });
        } catch (_) {}
      }
      return;
    }

    final title = AppLocalizations.t(debt.type == 'payable' ? 'debtNotifyTitlePayable' : 'debtNotifyTitleReceivable');
    final body = _bodyFor(debt, dueDate);

    try {
      await _native.invokeMethod('scheduleExactAlarm', {
        'millis': scheduled.millisecondsSinceEpoch,
        'title': title,
        'body': body,
        'debtId': debt.id,
        // Stable FNV-1a request code (String.hashCode is NOT stable).
        'requestCode': requestCode,
      });
    } catch (e) {
      debugPrint('[DebtReminder] schedule failed: $e');
    }
  }

  static Future<void> cancel(PersonalDebt debt) async {
    final prefs = await SharedPreferences.getInstance();
    final all = _decodeAll(prefs.getString(_prefsKey));
    all.remove(_keyFor(debt));
    await prefs.setString(_prefsKey, jsonEncode(all));
    await prefs.remove('$_shownKey${_keyFor(debt)}');
    try {
      await _native.invokeMethod('cancelExactAlarm',
          {'requestCode': ReminderCodec.debtRequestCode(debt.id)});
    } catch (_) {}
  }

  /// Re-schedules all future reminders (called after boot or app start).
  static Future<void> rescheduleAll() async {
    await init();
    final prefs = await SharedPreferences.getInstance();
    final all = _decodeAll(prefs.getString(_prefsKey));
    final now = DateTime.now().millisecondsSinceEpoch;
    final toRemove = <String>[];
    for (final entry in all.entries) {
      final millis = (entry.value['millis'] as num?)?.toInt() ?? 0;
      if (millis == 0 || millis < now) {
        toRemove.add(entry.key);
        continue;
      }
      final debtJson = entry.value['debt'] as Map<String, dynamic>?;
      if (debtJson == null) continue;
      try {
        final debt = PersonalDebt.fromJson(debtJson);
        final title = AppLocalizations.t(debt.type == 'payable' ? 'debtNotifyTitlePayable' : 'debtNotifyTitleReceivable');
        final storedMillis =
            DateTime.fromMillisecondsSinceEpoch(millis);
        final body = _bodyFor(
            debt,
            DateTime(storedMillis.year, storedMillis.month,
                storedMillis.day));
        final storedCode = (entry.value['requestCode'] as num?)?.toInt();
        await _native.invokeMethod('scheduleExactAlarm', {
          'millis': millis,
          'title': title,
          'body': body,
          'debtId': debt.id,
          'requestCode':
              storedCode ?? ReminderCodec.debtRequestCode(debt.id),
        });
      } catch (_) {}
    }
    for (final k in toRemove) {
      all.remove(k);
    }
    if (toRemove.isNotEmpty) {
      await prefs.setString(_prefsKey, jsonEncode(all));
    }
  }

  // ── Show alarm from Flutter (when app is open) ───────────────────────────

  /// Returns debts whose time has passed and haven't been marked shown.
  static Future<List<PersonalDebt>> dueReminderDebts() async {
    final prefs = await SharedPreferences.getInstance();
    final all = _decodeAll(prefs.getString(_prefsKey));
    final due = <PersonalDebt>[];
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in all.entries) {
      final millis = (entry.value['millis'] as num?)?.toInt() ?? 0;
      if (millis != 0 && millis <= now) {
        // Check shown flag
        if (prefs.getBool('$_shownKey${entry.key}') == true) continue;
        final debtJson = entry.value['debt'] as Map<String, dynamic>?;
        if (debtJson != null) {
          try {
            due.add(PersonalDebt.fromJson(debtJson));
          } catch (_) {}
        }
      }
    }
    return due;
  }

  /// Shows alarm dialog for due debts (called when app is in foreground).
  /// Uses the live root-navigator context so it works from any page.
  static Future<void> checkAndShowAlarms(BuildContext? Function()? contextProvider) async {
    final ctx = contextProvider?.call();
    if (ctx == null || !ctx.mounted) return;
    final due = await dueReminderDebts();
    if (due.isEmpty) return;
    for (final debt in due) {
      if (!ctx.mounted) return;
      await markAlarmShown(debt);
      // Remove the scheduled entry so it doesn't fire again (unless snoozed)
      final prefs = await SharedPreferences.getInstance();
      final all = _decodeAll(prefs.getString(_prefsKey));
      all.remove(_keyFor(debt));
      await prefs.setString(_prefsKey, jsonEncode(all));
      try {
        if (ctx.mounted) await showAlarm(ctx, debt);
      } catch (_) {}
      break; // show one at a time
    }
  }

  static Future<void> markAlarmShown(PersonalDebt debt) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_shownKey${_keyFor(debt)}', true);
  }

  static Future<void> clearShownFlag(PersonalDebt debt) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_shownKey${_keyFor(debt)}');
  }

  static Future<void> showAlarm(BuildContext context, PersonalDebt debt) async {
    await showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withAlpha(180),
      pageBuilder: (_, __, ___) => DebtAlarmPage(debt: debt),
      transitionBuilder: (_, anim, __, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero)
            .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  static Map<String, dynamic> _decodeAll(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m;
    } catch (_) {
      return {};
    }
  }

  /// Called when native alarm fires while app is in foreground (via MethodChannel).
  static Future<void> handleNativeAlarm(String debtId) async {
    // This is called from MainActivity when alarm fires and app is open.
    // We look up the debt and show alarm.
    final prefs = await SharedPreferences.getInstance();
    final all = _decodeAll(prefs.getString(_prefsKey));
    for (final entry in all.values) {
      final debtJson = entry['debt'] as Map<String, dynamic>?;
      if (debtJson != null) {
        final id = debtJson['id']?.toString() ?? '';
        if (id == debtId) {
          try {
            PersonalDebt.fromJson(debtJson);
          } catch (_) {}
          break;
        }
      }
    }
  }
}

// ============================================================================
// DebtAlarmPage — Full-screen red/black alarm with debt details
// ============================================================================
class DebtAlarmPage extends StatefulWidget {
  final PersonalDebt debt;
  const DebtAlarmPage({super.key, required this.debt});
  @override
  State<DebtAlarmPage> createState() => _DebtAlarmPageState();
}

class _DebtAlarmPageState extends State<DebtAlarmPage> with TickerProviderStateMixin {
  late final AudioPlayer _player;
  late final AnimationController _pulseCtrl;
  late final AnimationController _ringCtrl;
  late final AnimationController _fadeCtrl;
  double _dragOffset = 0;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);
    _ringCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 3000))..repeat();
    _fadeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..forward();
    _player = AudioPlayer();
    _startAlarmSound();
  }

  Future<void> _startAlarmSound() async {
    try {
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(AssetSource('audio/sound_2.wav'), volume: 0.8);
    } catch (e) {
      debugPrint('[DebtAlarm] sound error: $e');
    }
  }

  @override
  void dispose() {
    _player.stop();
    _player.dispose();
    _pulseCtrl.dispose();
    _ringCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  void _dismiss() {
    if (_dismissed) return;
    _dismissed = true;
    _player.stop();
    HapticFeedback.heavyImpact();
    if (mounted) {
      final debtId = widget.debt.id;
      Navigator.pop(context);
      if (debtId.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = rootNavigatorKey.currentContext;
          if (ctx != null) ctx.go('/personal/debts?debtId=$debtId');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final debt = widget.debt;
    final isPayable = debt.type == 'payable';
    final l10nAmount = '${fmtNum(debt.remaining)} ${currencySymbol(debt.currency)}';
    final screenHeight = MediaQuery.of(context).size.height;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: GestureDetector(
          onVerticalDragUpdate: (d) => setState(() => _dragOffset += d.delta.dy),
          onVerticalDragEnd: (d) {
            if (_dragOffset < -screenHeight * 0.12 || (d.primaryVelocity ?? 0) < -500) {
              _dismiss();
            } else {
              setState(() => _dragOffset = 0);
            }
          },
          child: AnimatedBuilder(
            animation: _fadeCtrl,
            builder: (_, __) => Opacity(
              opacity: _fadeCtrl.value,
              child: Transform.translate(
                offset: Offset(0, _dragOffset),
                child: _buildBody(isPayable, l10nAmount),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(bool isPayable, String l10nAmount) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0D0008), Color(0xFF2A0015), Color(0xFF7A1020), Color(0xFF4A0A14)],
          stops: [0.0, 0.3, 0.7, 1.0],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 8),
            AnimatedOpacity(
              opacity: _dragOffset == 0 ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 24),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white12)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.keyboard_arrow_up, color: Colors.white.withAlpha(120), size: 18),
                  const SizedBox(width: 4),
                  Text(AppLocalizations.t('debtAlarmSwipeToCloseHint'), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Colors.white.withAlpha(150))),
                ]),
              ),
            ),
            const Spacer(),
            _buildAlarmIcon(),
            const SizedBox(height: 24),
            Text(AppLocalizations.t('debtAlarmTitle'), style: const TextStyle(fontFamily: 'Cairo', fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.5)),
            const SizedBox(height: 6),
            Text(isPayable ? AppLocalizations.t('debtAlarmSubtitlePayable') : AppLocalizations.t('debtAlarmSubtitleReceivable'), style: TextStyle(fontFamily: 'Cairo', fontSize: 13, color: Colors.white.withAlpha(160))),
            const SizedBox(height: 28),
            _buildDebtCard(isPayable, l10nAmount),
            const Spacer(),
            _buildButtons(),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.swipe_up, color: Colors.white.withAlpha(80), size: 14),
              const SizedBox(width: 6),
              Text(AppLocalizations.t('debtAlarmSwipeToClose'), style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: Colors.white.withAlpha(80))),
            ]),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildAlarmIcon() {
    return AnimatedBuilder(
      animation: Listenable.merge([_pulseCtrl, _ringCtrl]),
      builder: (_, __) {
        final pulse = 1.0 + _pulseCtrl.value * 0.08;
        final ringAngle = _ringCtrl.value * 2 * math.pi;
        return Stack(alignment: Alignment.center, children: [
          Transform.rotate(angle: ringAngle, child: Container(width: 140, height: 140, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white10, width: 1)))),
          Transform.rotate(angle: -ringAngle * 0.7, child: Container(width: 160, height: 160, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white.withAlpha(8), width: 1)))),
          Transform.scale(scale: pulse, child: Container(width: 120, height: 120, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [AppColors.primary.withAlpha(60), AppColors.primary.withAlpha(0)])))),
          Transform.scale(
            scale: pulse,
            child: Container(
              width: 100, height: 100,
              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white12, border: Border.all(color: Colors.white24, width: 2), boxShadow: [BoxShadow(color: AppColors.primary.withAlpha(80), blurRadius: 30, spreadRadius: 5)]),
              child: const Icon(Icons.alarm_rounded, color: Colors.white, size: 48),
            ),
          ),
        ]);
      },
    );
  }

  Widget _buildDebtCard(bool isPayable, String l10nAmount) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 24, offset: const Offset(0, 8))]),
      child: Column(children: [
        Row(children: [
          TwoToneIcon(data: isPayable ? TwoToneIcons.arrowUp : TwoToneIcons.arrowDown, size: 18, outlineColor: isPayable ? AppColors.danger : AppColors.success),
          const SizedBox(width: 10),
          Expanded(child: Text(widget.debt.personName, style: const TextStyle(fontFamily: 'Cairo', fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF1A1A1A)), overflow: TextOverflow.ellipsis)),
          Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: (isPayable ? AppColors.danger : AppColors.success).withAlpha(20), borderRadius: BorderRadius.circular(8)), child: Text(isPayable ? AppLocalizations.t('debtBadgePayable') : AppLocalizations.t('debtBadgeReceivable'), style: TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w700, color: isPayable ? AppColors.danger : AppColors.success))),
        ]),
        const SizedBox(height: 16),
        Text(l10nAmount, style: const TextStyle(fontFamily: 'Cairo', fontSize: 28, fontWeight: FontWeight.w800, color: Color(0xFF7A1020))),
        const SizedBox(height: 12),
        _detailRow(Icons.person_outline, AppLocalizations.t('debtDetailPerson'), widget.debt.personName),
        if (widget.debt.description != null && widget.debt.description!.isNotEmpty) _detailRow(Icons.notes, AppLocalizations.t('debtDetailDescription'), widget.debt.description!),
        if (widget.debt.dueDate != null) _detailRow(Icons.calendar_today, AppLocalizations.t('debtDetailDueDate'), '${widget.debt.dueDate!.year}/${widget.debt.dueDate!.month.toString().padLeft(2, '0')}/${widget.debt.dueDate!.day.toString().padLeft(2, '0')}'),
        _detailRow(Icons.money, AppLocalizations.t('debtDetailCurrency'), widget.debt.currency),
        _detailRow(Icons.check_circle_outline, AppLocalizations.t('debtDetailStatus'), widget.debt.isPaid ? AppLocalizations.t('debtStatusPaid') : widget.debt.isOverdue ? AppLocalizations.t('debtStatusOverdue') : AppLocalizations.t('debtStatusActive')),
        if (widget.debt.paid > 0) _detailRow(Icons.payments, AppLocalizations.t('debtDetailPaid'), '${fmtNum(widget.debt.paid)} ${currencySymbol(widget.debt.currency)}'),
        if (widget.debt.remaining > 0 && widget.debt.paid > 0) _detailRow(Icons.receipt_long, AppLocalizations.t('debtDetailRemaining'), '${fmtNum(widget.debt.remaining)} ${currencySymbol(widget.debt.currency)}'),
      ]),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Icon(icon, size: 14, color: const Color(0xFF7A1020)),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, color: Color(0xFF666666))),
        const Spacer(),
        Flexible(child: Text(value, style: const TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF1A1A1A)), overflow: TextOverflow.ellipsis)),
      ]),
    );
  }

  Widget _buildButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(children: [
        Expanded(child: OutlinedButton.icon(onPressed: _onSnooze, icon: const Icon(Icons.snooze, color: Colors.white, size: 18), label: Text(AppLocalizations.t('debtAlarmSnooze'), style: TextStyle(fontFamily: 'Cairo', color: Colors.white, fontWeight: FontWeight.w700)), style: OutlinedButton.styleFrom(side: BorderSide(color: Colors.white.withAlpha(50)), padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))))),
        const SizedBox(width: 12),
        Expanded(child: ElevatedButton.icon(onPressed: _dismiss, icon: Icon(Icons.check, color: AppColors.primary, size: 18), label: Text(AppLocalizations.t('debtAlarmDone'), style: TextStyle(fontFamily: 'Cairo', color: AppColors.primary, fontWeight: FontWeight.w700)), style: ElevatedButton.styleFrom(backgroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)), elevation: 4))),
      ]),
    );
  }

  Future<void> _onSnooze() async {
    _player.stop();
    final date = await showDatePicker(context: context, firstDate: DateTime.now(), lastDate: DateTime(2035), initialDate: DateTime.now().add(const Duration(days: 1)));
    if (date == null || !mounted) return;
    final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.now(),
        builder: (ctx, child) => MediaQuery(data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: false), child: Theme(data: Theme.of(ctx).copyWith(timePickerTheme: const TimePickerThemeData(backgroundColor: Colors.black, dialHandColor: Color(0xFF7A1020), dialBackgroundColor: Colors.black, dialTextColor: Color(0xFF7A1020), hourMinuteColor: Color(0xFF1A1A1A), hourMinuteTextColor: Color(0xFF7A1020))), child: child!)));
    if (time == null) {
      if (mounted) _startAlarmSound();
      return;
    }
    await DebtReminderService.clearShownFlag(widget.debt);
    final scheduled = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    await DebtReminderService.schedule(widget.debt, scheduled, time);
    if (mounted) {
      _dismiss();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.t('debtAlarmSnoozed', {'time': time.format(context), 'date': '${date.year}/${date.month}/${date.day}'}), style: const TextStyle(fontFamily: 'Cairo')), backgroundColor: AppColors.success));
    }
  }
}
