import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/phone_format.dart';
import '../../../../features/personal/data/merchant_api.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../../../core/services/sync_engine.dart';
import '../../../../core/services/currency/money_format_service.dart';
import '../../../../core/utils/subscription_identity.dart';
import '../../../../shared/models/user_model.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../subscription/presentation/providers/subscription_providers.dart';
import '../../../subscription/domain/section_access.dart';
import '../../../auth/presentation/providers/biometric_provider.dart';
import '../../../auth/domain/services/biometric_service.dart';
import '../../../../shared/providers/theme_provider.dart'
    show themeModeProvider;
import '../../../../shared/providers/locale_provider.dart';
import '../../../../shared/widgets/language_transition_overlay.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../../core_business/presentation/providers/biz_payment_pref.dart';
import '../../../../core/services/currency/business_currency_scope.dart'
    show bizEnabledCurrenciesProvider;
import '../../../branches/data/branch_api.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../business_banks/data/business_bank_models.dart'
    show BusinessBankAccount, isBizCashAccount;
import '../../../business_banks/presentation/providers/business_banks_providers.dart'
    show businessBanksProvider, bizCashServiceProvider;
import '../../../business_banks/presentation/providers/local_business_banking.dart';
import '../../../../core/network/session_timeout_provider.dart';
import '../../../../core/network/dio_provider.dart';
import '../../../../core/utils/server_image_url.dart';
import '../../../../core/help/help_clicker_settings.dart';
import '../../../auth/presentation/widgets/app_pin_sheet.dart';
import '../../../auth/presentation/pages/pin_setup_page.dart';
import '../../../auth/di/auth_providers.dart' hide authProvider;
import '../../../../core/localization/app_localizations.dart';
import '../providers/avatar_provider.dart';
import '../providers/section_profile_provider.dart';
import 'package:fyona_flutter/core/responsive/r_api.dart';
import '../../../../shared/widgets/currency_selector.dart';
import '../../../../core/utils/currency_formatter.dart'
    show currencyName, currencyLabel, fmtNum;
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/database/database_helper.dart';
import '../../../../core/database/repositories/personal_cache_repository.dart';
import '../../../../core/database/providers/database_providers.dart';
import '../../../../features/personal/presentation/providers/personal_providers.dart';
import '../../../../features/personal/di/personal_providers.dart'
    hide backupServiceProvider;
import '../../../../features/personal/domain/services/backup_service.dart';
import '../../../../core/services/currency/enabled_currencies_service.dart'
    show defaultEnabledCurrencies;
import '../../../../features/ai/domain/agent/chat_persistence.dart';
import '../../../../features/dashboard/presentation/providers/business_dashboard_providers.dart';
import '../../../../features/invoices/presentation/providers/invoice_design_provider.dart';
import '../../../../features/returns/presentation/providers/returns_providers.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import '../../../employees/presentation/widgets/employee_avatar.dart';
import '../../../core_business/data/project_settings_api.dart';

class ProfilePage extends ConsumerStatefulWidget {
  /// true → the Business profile (Business-only tiles; Personal untouched).
  final bool business;
  final Map<String, dynamic>? employee;
  final bool employeeFull;
  const ProfilePage({
    super.key,
    this.business = false,
    this.employee,
    this.employeeFull = false,
  });
  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  bool get _employee => widget.employee != null;
  bool get _limitedEmployee => _employee && !widget.employeeFull;
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _newEmailCtrl = TextEditingController();
  final _emailOtpCtrl = TextEditingController();
  final _oldPwdCtrl = TextEditingController();
  final _newPwdCtrl = TextEditingController();
  final _confirmPwdCtrl = TextEditingController();
  bool _nameChanged = false;
  bool _savingName = false;
  bool _emailCodeSent = false;
  bool _isSendingEmailOtp = false;
  bool _isVerifyingEmail = false;
  int _pendingSync = 0;
  Timer? _syncProbe;

  /// Breathing pulse (0..1) driving the verification badge glow so the
  /// neon light fades gradually and then intensifies strongly — in BOTH
  /// themes and for every plan.
  Timer? _pulseTimer;
  double _pulsePhase = 0.0;
  double _pulse = 1.0;

  @override
  void initState() {
    super.initState();
    if (_employee)
      return; // Never reconcile/upload merchant identity from an employee device.
    _pulseTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (!mounted) return;
      _pulsePhase += 0.10;
      setState(() => _pulse = (1 + math.sin(_pulsePhase)) / 2);
    });
    // Fresh subscription snapshot on every profile visit: the card, badge
    // details and countdown can never show a state from before an admin
    // approval/extension.
    Future.microtask(() {
      if (!mounted) return;
      try {
        ref.invalidate(subscriptionStatusProvider);
      } catch (_) {}
    });
    _syncProbe = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!mounted) return;
      try {
        final engine = ref.read(syncEngineProvider);
        final snap = await engine.localSyncSnapshot();
        if (!mounted) return;
        setState(() => _pendingSync = (snap['pending'] as num?)?.toInt() ?? 0);
      } catch (_) {}
    });
    ref.listenManual(authProvider, (prev, next) {
      if (next.user != null) {
        final sectionName = ref.read(sectionProfileProvider).name;
        final display =
            sectionName ??
            (widget.business
                ? (next.user!.organizationName ?? next.user!.fullName)
                : next.user!.fullName) ??
            '';
        if (_nameCtrl.text != display) {
          _nameCtrl.text = display;
        }
        _emailCtrl.text = next.user!.email ?? '';
      }
    });
    ref.listenManual(sectionProfileProvider, (prev, next) {
      if (_nameChanged) return;
      final u = ref.read(authProvider).user;
      final display =
          next.name ??
          (widget.business
              ? (u?.organizationName ?? u?.fullName)
              : u?.fullName) ??
          '';
      if (_nameCtrl.text != display) _nameCtrl.text = display;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.invalidate(subscriptionStatusProvider);
      final user = ref.read(authProvider).user;
      if (user != null) {
        final sectionName = ref.read(sectionProfileProvider).name;
        _nameCtrl.text =
            sectionName ??
            (widget.business
                ? (user.organizationName ?? user.fullName)
                : user.fullName) ??
            '';
        _emailCtrl.text = user.email ?? '';
        if (ref.read(avatarProvider) == null) {
          ref.read(avatarProvider.notifier).load(userId: user.id);
        }
        // Pull a picture changed on another device (best-effort).
        unawaited(_reconcileAvatarFromServer());
        // Push an ALREADY-saved local name/avatar (from older builds or the
        // section override) to the account so every party sees it.
        unawaited(_syncLocalIdentity());
      }
    });
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    _syncProbe?.cancel();
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _newEmailCtrl.dispose();
    _emailOtpCtrl.dispose();
    _oldPwdCtrl.dispose();
    _newPwdCtrl.dispose();
    _confirmPwdCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg, {Color? bg}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: bg ?? AppColors.success,
      ),
    );
  }

  void _changePwd() {
    final l10n = AppLocalizations.of(context);
    final old = _oldPwdCtrl.text.trim();
    final nw = _newPwdCtrl.text;
    final confirm = _confirmPwdCtrl.text;
    if (old.isEmpty || nw.isEmpty || confirm.isEmpty) {
      _snack(l10n.translate('profileFillAll'), bg: AppColors.warning);
      return;
    }
    if (nw != confirm) {
      _snack(l10n.translate('passwordMismatch'), bg: AppColors.warning);
      return;
    }
    if (nw.length < 8) {
      _snack(l10n.translate('passwordTooShort'), bg: AppColors.warning);
      return;
    }
    ref
        .read(authProvider.notifier)
        .changePassword(
          currentPassword: old,
          newPassword: nw,
          confirmNewPassword: confirm,
        );
    _oldPwdCtrl.clear();
    _newPwdCtrl.clear();
    _confirmPwdCtrl.clear();
    _snack(l10n.translate('profilePwdChanged'));
  }

  Future<void> _pickAvatar() async {
    Uint8List? raw;
    try {
      final r = await FilePicker.pickFiles(type: FileType.image);
      if (r == null || r.files.isEmpty) return;
      final file = r.files.single;
      if (file.path != null) {
        raw = await File(file.path!).readAsBytes();
      } else if (file.bytes != null) {
        raw = file.bytes;
      }
    } catch (_) {
      if (mounted)
        _snack(
          AppLocalizations.of(context).translate('profileAvatarSaveFailed'),
          bg: AppColors.danger,
        );
      return;
    }
    if (raw == null) return;
    // Open the interactive circular crop screen; it returns the cropped,
    // circle-masked PNG bytes (or null if the user cancels).
    final cropped = await Navigator.of(context).push<Uint8List?>(
      PageRouteBuilder<Uint8List?>(
        opaque: false,
        barrierColor: Colors.black87,
        pageBuilder: (_, _, _) => _AvatarCropScreen(bytes: raw ?? Uint8List(0)),
      ),
    );
    if (cropped == null || !mounted) return;
    try {
      // Section-scoped: personal → account avatar; business → shop avatar.
      final uid = ref.read(authProvider).user?.id;
      await ref.read(sectionProfileProvider.notifier).setAvatar(cropped);
      if (uid != null) {
        if (widget.business) {
          await _syncBranchAvatar(cropped);
          await _uploadOrgAvatarToServer(cropped, uid);
        } else {
          await _uploadAvatarToServer(cropped, uid);
        }
      }
      if (mounted) {
        _snack(AppLocalizations.of(context).translate('profileAvatarUpdated'));
      }
    } catch (_) {
      if (mounted)
        _snack(
          AppLocalizations.of(context).translate('profileAvatarSaveFailed'),
          bg: AppColors.danger,
        );
    }
  }

  String _serverAvatarKey(String userId) => avatarServerKey(userId);

  /// Local tombstone for an offline delete: `DELETED:<url>` remembers WHICH
  /// server picture our delete targeted, so a later reconcile retries that
  /// exact delete instead of re-downloading it (zombie), while a DIFFERENT
  /// (newer, uploaded elsewhere) picture is still accepted.
  static const _avatarDeletedMark = avatarDeletedMark;

  String? _absoluteAvatarUrl(String? path) {
    return serverImageUrl(path);
  }

  /// Push the freshly saved picture to the server (best-effort).
  Future<void> _uploadAvatarToServer(Uint8List bytes, String userId) async {
    try {
      final dio = ref.read(apiClientProvider).dio;
      final form = FormData.fromMap({
        'file': MultipartFile.fromBytes(bytes, filename: 'avatar.jpg'),
      });
      final resp = await dio.post('/auth/me/avatar', data: form);
      final data = resp.data;
      String? rel;
      if (data is Map) {
        final inner = data['data'];
        rel =
            (inner is Map ? inner['avatar'] : null)?.toString() ??
            data['avatar']?.toString();
      }
      if (rel != null && rel.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_serverAvatarKey(userId), rel);
      }
    } catch (_) {}
  }

  Future<void> _uploadOrgAvatarToServer(Uint8List bytes, String userId) async {
    try {
      final dio = ref.read(apiClientProvider).dio;
      final form = FormData.fromMap({
        'file': MultipartFile.fromBytes(bytes, filename: 'avatar.jpg'),
      });
      final resp = await dio.post('/auth/me/organization/avatar', data: form);
      final data = resp.data;
      String? rel;
      if (data is Map) {
        final inner = data['data'];
        rel =
            (inner is Map ? inner['avatar'] : null)?.toString() ??
            data['avatar']?.toString();
      }
      if (rel != null && rel.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('org_avatar_server_$userId', rel);
      }
    } catch (_) {}
  }

  /// Pull a server-side picture changed on another device (best-effort).
  /// Compares the server URL with the last-synced one, so this never loops
  /// with the upload path above. Offline the local picture is NEVER
  /// touched: without a real network fetch we cannot tell "deleted
  /// elsewhere" from "stale cache", and the last correct local copy must
  /// stay visible without internet.
  Future<void> _reconcileAvatarFromServer() async {
    try {
      if (!ref.read(connectivityServiceProvider).isOnline) return;
    } catch (_) {
      return;
    }
    var fresh = false;
    try {
      await ref.read(authProvider.notifier).refreshProfile();
      fresh = true;
    } catch (_) {}
    if (!mounted) return;
    try {
      final user = ref.read(authProvider).user;
      if (user == null) return;
      final prefs = await SharedPreferences.getInstance();
      final knownRel = prefs.getString(_serverAvatarKey(user.id));
      final action = avatarSyncDecision(
        serverRel: user.avatar,
        knownRel: knownRel,
        fresh: fresh,
      );
      final dio = ref.read(apiClientProvider).dio;
      if (action == AvatarSyncAction.retryDelete) {
        try {
          await dio.delete('/auth/me/avatar');
          await prefs.remove(_serverAvatarKey(user.id));
        } catch (_) {}
        return;
      }
      if (action == AvatarSyncAction.clearLocal) {
        await ref.read(avatarProvider.notifier).clear();
        await prefs.remove(_serverAvatarKey(user.id));
        if (mounted) setState(() {});
        return;
      }
      if (action != AvatarSyncAction.download) return;
      final url = _absoluteAvatarUrl(user.avatar);
      if (url == null) return;
      final resp = await dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = resp.data;
      if (bytes != null && bytes.isNotEmpty) {
        await ref.read(avatarProvider.notifier).save(Uint8List.fromList(bytes));
        await prefs.setString(_serverAvatarKey(user.id), user.avatar ?? '');
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  /// Delete locally AND on the server (best-effort). Offline the intent is
  /// kept as a tombstone so a later reconcile retries the delete instead
  /// of resurrecting the picture.
  Future<void> _clearAvatar() async {
    // Section-scoped: removing the Business avatar never removes the Personal
    // one (or the shared account/Google picture).
    await ref.read(sectionProfileProvider.notifier).clearAvatar();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final user = authState.user;
    final theme = ref.watch(themeModeProvider);
    final isDark = theme == ThemeMode.dark;
    final sub = _employee
        ? const AsyncData<Map<String, dynamic>>({})
        : ref.watch(subscriptionStatusProvider);
    final isOnline = ref.watch(connectivityServiceProvider).isOnline;
    final sectionProfile = ref.watch(sectionProfileProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          AppLocalizations.of(context).translate('profile'),
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 16),
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: HugeIcon(
            icon: HugeIcons.strokeRoundedArrowRight01,
            size: 20,
            color: AppColors.textPrimary,
          ),
          onPressed: () {
            if (context.canPop()) context.pop();
          },
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionHeader(
            AppLocalizations.of(context).translate('profileAccountInfo'),
            icon: Icons.person_outline,
          ),
          const SizedBox(height: 10),
          if (_employee)
            _buildEmployeeIdentityHeader(widget.employee!)
          else
            _buildProfileHeader(
              sectionProfile.name ??
                  (widget.business
                      ? (user?.organizationName ?? user?.fullName)
                      : user?.fullName) ??
                  '',
              user?.email ?? '',
              _liveVerificationLevel(user, sub),
            ),
          if (!_employee) ...[
            const SizedBox(height: 24),
            _sectionHeader(
              AppLocalizations.of(context).translate('profileSubscription'),
              icon: Icons.workspace_premium_outlined,
            ),
            const SizedBox(height: 10),
            _buildSubscriptionCard(sub),
            if (widget.business &&
                hasSectionAccess(sub.valueOrNull, 'business'))
              ListTile(
                leading: const Icon(Icons.tune),
                title: Text(
                  AppLocalizations.of(context).translate('businessSetupTitle'),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/business-setup'),
              ),
          ],
          const SizedBox(height: 24),
          _sectionHeader(
            AppLocalizations.of(context).translate('profilePreferences'),
            icon: Icons.tune,
          ),
          const SizedBox(height: 10),
          _buildPreferencesSection(isDark),
          const SizedBox(height: 24),
          _sectionHeader(
            AppLocalizations.of(context).translate('profileSecurity'),
            icon: Icons.shield_outlined,
          ),
          const SizedBox(height: 10),
          _buildSecuritySection(),
          if (!_limitedEmployee) ...[
            const SizedBox(height: 24),
            _sectionHeader(
              AppLocalizations.of(context).translate('profileBackupSync'),
              icon: Icons.cloud_sync_outlined,
            ),
            const SizedBox(height: 10),
            // Personal keeps the ORIGINAL, fully-working sync + backup. Business
            // shows the SAME layout but the actions are "قريباً" until developed.
            if (!widget.business) ...[
              _buildSyncStatus(isOnline, pendingCount: _pendingSync),
              const SizedBox(height: 8),
            ],
            _buildBackupSection(isOnline),
          ],
          if (!_employee) ...[const SizedBox(height: 28), _buildLogoutButton()],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildEmployeeIdentityHeader(Map<String, dynamic> employee) {
    final number = '${employee['phone'] ?? ''}'.trim();
    final salary = num.tryParse('${employee['salary'] ?? 0}') ?? 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFC01838), AppColors.primary, Color(0xFF8A1028)],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withAlpha(40),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withAlpha(150), width: 2),
            ),
            child: EmployeeAvatar(
              photo: employee['photo_url'] as String?,
              size: 88,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '${employee['full_name'] ?? ''}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 17),
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          if (number.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                number,
                textDirection: TextDirection.ltr,
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  color: Colors.white70,
                  fontSize: 12,
                ),
              ),
            ),
          if (salary > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        fmtNum(salary),
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    currencyLabel('${employee['salary_currency'] ?? 'SAR'}'),
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 8,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildProfileHeader(String name, String email, int verificationLevel) {
    final avatarBytes =
        ref.watch(sectionProfileProvider).avatar ?? ref.watch(avatarProvider);
    final fs = R.fontSize(context, 17);

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFC01838), AppColors.primary, Color(0xFF8A1028)],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withAlpha(40),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // subtle decorative circles
          Positioned(
            top: -30,
            right: -20,
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withAlpha(12),
              ),
            ),
          ),
          Positioned(
            bottom: -40,
            left: -30,
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withAlpha(8),
              ),
            ),
          ),
          // content
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Column(
              children: [
                // ── Avatar + camera ──
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withAlpha(150),
                          width: 2,
                        ),
                      ),
                      child: CircleAvatar(
                        radius: 44,
                        backgroundColor: Colors.white.withAlpha(40),
                        backgroundImage: avatarBytes != null
                            ? MemoryImage(avatarBytes)
                            : null,
                        child: avatarBytes == null
                            ? HugeIcon(
                                icon: HugeIcons.strokeRoundedUser,
                                size: 42,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
                    // camera edit button
                    Positioned(
                      bottom: 0,
                      left: 0,
                      child: _avatarActionBtn(
                        icon: HugeIcons.strokeRoundedCamera01,
                        bg: Colors.white,
                        fg: AppColors.primary,
                        onTap: _pickAvatar,
                      ),
                    ),
                    // delete button (if avatar exists)
                    if (avatarBytes != null)
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: _avatarActionBtn(
                          icon: HugeIcons.strokeRoundedDelete01,
                          bg: AppColors.danger,
                          fg: Colors.white,
                          onTap: _clearAvatar,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),

                // ── Name field + inline save check ──
                Row(
                  children: [
                    Expanded(
                      child: FyonaTextField(
                        controller: _nameCtrl,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: fs,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                        cursorColor: Colors.white,
                        decoration: InputDecoration(
                          hintText: AppLocalizations.of(
                            context,
                          ).translate('profileEditNameHint'),
                          hintStyle: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: fs - 2,
                            color: Colors.white.withAlpha(100),
                          ),
                          filled: true,
                          fillColor: Colors.white.withAlpha(14),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: Colors.white.withAlpha(80),
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() => _nameChanged = true),
                      ),
                    ),
                    if (_nameChanged) ...[
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 44,
                        height: 44,
                        child: IconButton(
                          tooltip: AppLocalizations.of(
                            context,
                          ).translate('profileSaveName'),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: AppColors.primary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: _savingName ? null : _saveName,
                          icon: _savingName
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.check_rounded, size: 24),
                        ),
                      ),
                    ],
                  ],
                ),

                // ── Verification badge ──
                if (verificationLevel > 0) ...[
                  const SizedBox(height: 8),
                  _buildVerificationBadge(verificationLevel),
                ],

                const SizedBox(height: 12),

                // ── Info rows ──
                _headerInfoRow(
                  icon: Icons.email_outlined,
                  value: _emailCtrl.text.isNotEmpty
                      ? _emailCtrl.text
                      : AppLocalizations.of(context).translate('email'),
                ),
                const SizedBox(height: 6),
                _buildPhoneRow(),
                const SizedBox(height: 6),
                _buildCodeRow(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _syncLocalIdentity() async {
    final sec = ref.read(sectionProfileProvider);
    final user = ref.read(authProvider).user;
    if (user == null) return;
    var changed = false;
    final localName = (sec.name ?? '').trim();
    final serverName =
        (widget.business
                ? (user.organizationName ?? '')
                : (user.fullName ?? ''))
            .trim();
    if (localName.isNotEmpty && localName != serverName) {
      if (mounted) setState(() => _nameChanged = true);
      try {
        await ref
            .read(apiClientProvider)
            .dio
            .put(
              '/auth/me',
              data: {
                if (widget.business)
                  'organization_name': localName
                else
                  'full_name': localName,
              },
            );
        changed = true;
      } catch (_) {}
    }
    if (sec.avatar != null) {
      try {
        final sp = await SharedPreferences.getInstance();
        final key = widget.business
            ? 'org_avatar_server_${user.id}'
            : _serverAvatarKey(user.id);
        final known = sp.getString(key);
        final serverAvatar = widget.business
            ? user.organizationAvatar
            : user.avatar;
        if (serverAvatar == null || serverAvatar != known) {
          if (widget.business) {
            await _uploadOrgAvatarToServer(sec.avatar!, user.id);
          } else {
            await _uploadAvatarToServer(sec.avatar!, user.id);
          }
          changed = true;
        }
      } catch (_) {}
    }
    if (changed) {
      try {
        await ref.read(authProvider.notifier).refreshProfile();
      } catch (_) {}
      if (mounted) setState(() {});
    }
  }

  String _apiMessage(Object e, AppLocalizations l10n) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map) {
        final d = data['detail'] ?? data['message'] ?? data['error'];
        if (d is List && d.isNotEmpty) return '${d.first}';
        if (d != null) return '$d';
      }
    }
    return l10n.translate('profileDataSaveFailed');
  }

  Future<void> _syncBranchName(String name) async {
    if (!widget.business || BranchScope.allMode) return;
    final id = BranchScope.branchId;
    if (id == null || id.isEmpty) return;
    await ref.read(branchApiProvider).rename(id, name);
    await BranchScope.save(
      token: BranchScope.token,
      branchId: id,
      branchName: name,
      allMode: false,
      organizationId: BranchScope.organizationId,
    );
    ref.invalidate(branchesProvider);
    ref.invalidate(branchAccessProvider);
  }

  Future<void> _syncBranchAvatar(Uint8List bytes) async {
    if (!widget.business || BranchScope.allMode) return;
    final id = BranchScope.branchId;
    if (id == null || id.isEmpty) return;
    await ref.read(branchApiProvider).uploadImage(id, bytes);
    ref.invalidate(branchesProvider);
    ref.invalidate(branchAccessProvider);
  }

  Future<void> _saveName() async {
    final l10n = AppLocalizations.of(context);
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    setState(() => _savingName = true);
    try {
      if (widget.business) await _syncBranchName(name);
      await ref
          .read(apiClientProvider)
          .dio
          .put(
            '/auth/me',
            data: {
              if (widget.business)
                'organization_name': name
              else
                'full_name': name,
            },
          );
      // Section-scoped: the personal and business names stay independent.
      await ref.read(sectionProfileProvider.notifier).setName(name);
      try {
        await ref.read(authProvider.notifier).refreshProfile();
      } catch (_) {}
      if (!mounted) return;
      setState(() => _nameChanged = false);
      _snack(l10n.translate('profileDataSaved'));
    } catch (e) {
      if (mounted) {
        _snack(_apiMessage(e, l10n), bg: AppColors.danger);
      }
    } finally {
      if (mounted) setState(() => _savingName = false);
    }
  }

  Widget _avatarActionBtn({
    required List<List<dynamic>> icon,
    required Color bg,
    required Color fg,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withAlpha(180), width: 2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(40),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: HugeIcon(icon: icon, size: 13, color: fg),
      ),
    );
  }

  /// Verification level derived from the LIVE subscription snapshot
  /// (plan_name) so the badge instantly follows an admin plan change
  /// (personal→blue, business→red, premium→gold). Falls back to the cached
  /// user model when the live snapshot is unavailable (offline).
  int _liveVerificationLevel(
    UserModel? user,
    AsyncValue<Map<String, dynamic>> sub,
  ) {
    final livePlan = sub.valueOrNull?['plan_name']?.toString();
    final liveLevel = subscriptionIdentityLevel(livePlan);
    return liveLevel > 0 ? liveLevel : (user?.verificationLevel ?? 0);
  }

  Widget _buildVerificationBadge(int level) {
    // Elegant translucent badge: soft inner fill (glassy), a neon border ring
    // in the brand accent, and a subtle smoky-black outer glow so it stays
    // clearly readable above the red profile header — without being heavy.
    // In LIGHT theme a crisp white chip is used instead (vivid accent border,
    // accent icon + accent text) so the badge never looks washed-out.
    final (neon, glowRing, tint, label) = switch (level) {
      1 => (
        const Color(0xFF2E8BFF),
        const Color(0xFF8FC7FF),
        const Color(0xFF1E6FD8),
        AppLocalizations.of(context).translate('subVerifiedPersonal'),
      ),
      2 => (
        const Color(0xFFFF3B30),
        const Color(0xFFFFB3A8),
        const Color(0xFFC2262E),
        AppLocalizations.of(context).translate('subVerifiedBusiness'),
      ),
      3 => (
        const Color(0xFFFFC63D),
        const Color(0xFFFFE9A8),
        const Color(0xFFB8860B),
        AppLocalizations.of(context).translate('profileVerifiedPremium'),
      ),
      _ => (
        const Color(0xFF2E8BFF),
        const Color(0xFF8FC7FF),
        const Color(0xFF1565C0),
        AppLocalizations.of(context).translate('sharedVerifiedAccount'),
      ),
    };

    // Identify the verification level letter for the glyph.
    // NOTE: the SAME design is used in BOTH themes (the profile header is a
    // dark-red gradient in light mode too, so the glassy dark badge remains
    // perfectly readable). Deliberately no light-theme variant.
    final pulse = _pulse; // 0..1 breathing
    final glowAlpha = 70 + (150 * pulse).round();
    final pulseIcon = Color.lerp(neon.withAlpha(90), neon, pulse);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        // Glassy translucent fill (adapts naturally over the header gradient).
        color: tint.withAlpha(48),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: glowRing.withAlpha(200), width: 1.3),
        boxShadow: [
          // Smoky black under-glow (subtle, dark, airy).
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 14,
            spreadRadius: 1,
            offset: const Offset(0, 3),
          ),
          // Neon rim glow in the brand accent — BREATHES with the pulse.
          BoxShadow(
            color: neon.withAlpha(glowAlpha),
            blurRadius: 11.0 + (7 * pulse).round(),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified, size: 12, color: pulseIcon),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 10.5),
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerInfoRow({required IconData icon, required String value}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withAlpha(22)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.white.withAlpha(180)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 12),
                fontWeight: FontWeight.w600,
                color: Colors.white.withAlpha(220),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// The account's code is shown at once like the rest of the profile:
  /// kept in memory and on the device, refreshed quietly from the server.
  static final Map<String, String> _savedCodes = {};
  String? _myCode;
  bool _codeLoaded = false;

  String get _codeKey => 'profile_my_code_${ref.read(currentUserProvider)?.id ?? ''}';

  Future<void> _loadMyCode() async {
    final key = _codeKey;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(key);
      if (saved != null && saved.isNotEmpty && mounted && _myCode == null) {
        _savedCodes[key] = saved;
        setState(() => _myCode = saved);
      }
    } catch (_) {}
    try {
      final c = await ref.read(merchantApiProvider).myCode();
      if (c.isNotEmpty) {
        _savedCodes[key] = c;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(key, c);
        } catch (_) {}
      }
      if (mounted && c.isNotEmpty && c != _myCode) setState(() => _myCode = c);
    } catch (_) {}
  }

  Widget _buildCodeRow() {
    if (!_codeLoaded) {
      _codeLoaded = true;
      _myCode ??= _savedCodes[_codeKey];
      _loadMyCode();
    }
    final l10n = AppLocalizations.of(context);
    if (_myCode == null || _myCode!.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withAlpha(45)),
      ),
      child: Row(
        children: [
          Icon(Icons.tag_rounded, size: 16, color: Colors.white.withAlpha(200)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.translate('merchantCodeLbl'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 10.5,
                    color: Colors.white.withAlpha(175),
                  ),
                ),
                Text(
                  _myCode!,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 3,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy_rounded, size: 16),
            color: Colors.white.withAlpha(200),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _myCode!));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    l10n.translate('merchantCopied'),
                    style: const TextStyle(fontFamily: 'Cairo'),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPhoneRow() {
    final user = ref.watch(authProvider).user;
    final phoneDisplay = (user?.phone != null && user!.phone!.isNotEmpty)
        ? user.phone!
        : (user?.phoneMasked ?? '');
    final hasPhone = phoneDisplay.isNotEmpty;
    return GestureDetector(
      onTap: () async {
        await context.push(RouteNames.phoneEntry);
        if (mounted) setState(() {});
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(14),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withAlpha(22)),
        ),
        child: Row(
          children: [
            Icon(
              Icons.phone_outlined,
              size: 16,
              color: hasPhone
                  ? Colors.white.withAlpha(180)
                  : Colors.white.withAlpha(100),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: hasPhone
                  ? Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(
                        formatIntlPhone(phoneDisplay),
                        textAlign: TextAlign.left,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 12),
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withAlpha(220),
                        ),
                      ),
                    )
                  : Text(
                      AppLocalizations.of(context).translate('profileAddPhone'),
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        fontWeight: FontWeight.w600,
                        color: hasPhone
                            ? Colors.white.withAlpha(220)
                            : Colors.white.withAlpha(130),
                      ),
                    ),
            ),
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(25),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(
                hasPhone ? Icons.edit_outlined : Icons.add,
                size: 12,
                color: Colors.white.withAlpha(180),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSyncStatus(
    bool isOnline, {
    String syncStatus = '',
    int pendingCount = 0,
  }) {
    final s = syncStatus;
    final syncing = s == 'syncing';
    final syncError = s == 'sync_error' || s == 'failed';
    final pending = pendingCount > 0;
    final offline = !isOnline;
    final Color color;
    final String label;
    if (syncing) {
      color = AppColors.info;
      label = 'جارٍ المزامنة…';
    } else if (offline) {
      color = AppColors.warning;
      label = pending
          ? 'غير متصل — لديك تغييرات تنتظر المزامنة'
          : AppLocalizations.of(context).translate('profileOffline');
    } else if (syncError) {
      color = AppColors.danger;
      label = pending
          ? 'فشلت المزامنة — التغييرات محفوظة محلياً وستُرسل لاحقاً'
          : 'فشلت المزامنة';
    } else {
      color = AppColors.success;
      label = pending
          ? 'متصل — جارٍ تحميل تغييراتك'
          : AppLocalizations.of(context).translate('profileOnline');
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withAlpha(15),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withAlpha(50)),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 12),
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubscriptionCard(AsyncValue<Map<String, dynamic>> sub) {
    final l10n = AppLocalizations.of(context);
    final user = ref.watch(authProvider).user;

    // Offline-first: when the live status is unavailable (no internet), build
    // the same card from the locally-cached user model so the section always
    // renders — subscription + live countdown included.
    Widget renderFrom(Map<String, dynamic> s) {
      final status = s['status'] as String? ?? 'none';
      final plan =
          s['plan_name'] as String? ??
          (user?.subscriptionPlan != null &&
                  (user!.subscriptionPlan!.isNotEmpty)
              ? user!.subscriptionPlan!
              : l10n.translate('profilePlanTrial'));
      final badgeText = status == 'active'
          ? l10n.translate('status_active')
          : (status == 'trial'
                ? l10n.translate('profileTrialBadge')
                : l10n.translate('profileExpiredBadge'));
      final identity = status == 'trial'
          ? AppColors.success
          : subscriptionIdentityColor(plan);
      final endDate =
          s['end_date']?.toString() ??
          (status == 'trial'
              ? (user?.trialEndDate ?? '')
              : (user?.subscriptionEndDate ?? ''));
      final displayDate = endDate != null && endDate.isNotEmpty
          ? _formatDate(endDate)
          : null;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _showSubscriptionDetails(s),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [AppColors.surface, identity.withAlpha(14)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: identity.withAlpha(110)),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: identity.withAlpha(25),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: HugeIcon(
                        icon: HugeIcons.strokeRoundedAward01,
                        size: 22,
                        color: identity,
                      ),
                    ),
                  ),
                  SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          plan,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 15),
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          AppLocalizations.of(
                            context,
                          ).translate('profileSubStatus'),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: R.fontSize(context, 11),
                            color: AppColors.textDisabled,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: identity.withAlpha(22),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: identity.withAlpha(90)),
                    ),
                    child: Text(
                      badgeText,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        color: identity,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  SizedBox(width: 8),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _showSubscriptionDetails(s),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceVariant,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: HugeIcon(
                          icon: HugeIcons.strokeRoundedArrowLeft01,
                          size: 16,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (displayDate != null) ...[
                SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: identity.withAlpha(8),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: identity.withAlpha(40)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.calendar_today_rounded,
                        size: 14,
                        color: identity,
                      ),
                      SizedBox(width: 8),
                      Text(
                        '${l10n.translate('subInvoiceEnd')}: $displayDate',
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 12),
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return sub.when(
      data: (s) => renderFrom(s),
      loading: () => renderFrom(_mapFromCachedUser(user)),
      error: (_, __) => renderFrom(_mapFromCachedUser(user)),
    );
  }

  /// Builds a subscription snapshot purely from the cached user model — used
  /// as an offline fallback so the profile subscription card NEVER disappears.
  Map<String, dynamic> _mapFromCachedUser(UserModel? user) {
    if (user == null) return {'status': 'none', 'plan_name': null};
    final status = user.status ?? 'none';
    return {
      'status': status,
      'plan_name': user.subscriptionPlan,
      'start_date': user.subscriptionStartDate,
      'end_date': status == 'trial'
          ? user.trialEndDate
          : user.subscriptionEndDate,
    };
  }

  String _formatDate(String dateStr) {
    try {
      final dt = DateTime.parse(dateStr);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return dateStr;
    }
  }

  /// Opens a bottom sheet with the user's full subscription details and a
  /// "renew" button that jumps straight to payment for the SAME plan.
  void _showSubscriptionDetails(Map<String, dynamic> s) {
    final plan = s['plan_name'] as String? ?? '';
    final identityKey = subscriptionIdentityKey(plan);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: _SubscriptionDetailsSheet(
          data: s,
          identityKey: identityKey,
          onRenew: () {
            final price = s['plan_price']?.toString() ?? '0';
            final cur = (s['currency']?.toString() ?? 'SAR').toUpperCase();
            final params = {
              'plan_id': identityKey,
              'plan_name': (s['plan_name']?.toString() ?? identityKey),
              'plan_price': price,
              'plan_currency': cur,
              'period': 'yearly',
            };
            final qs = params.entries
                .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
                .join('&');
            Navigator.pop(ctx);
            // push (not go): keeps the profile underneath so the payment
            // page back arrow pops back to it. `go` would replace the stack
            // and leave the arrow with nowhere to return to.
            context.push('/subscription/pay?$qs');
          },
          onBrowse: () {
            Navigator.pop(ctx);
            context.go(RouteNames.subscription);
          },
        ),
      ),
    );
  }

  Widget _buildBackupSection(bool isOnline) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.primary.withAlpha(20),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Icon(
                    Icons.cloud_sync_outlined,
                    size: 18,
                    color: AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppLocalizations.of(
                        context,
                      ).translate('profileBackupSync'),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 14),
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      AppLocalizations.of(
                        context,
                      ).translate('profileBackupNote'),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        color: AppColors.textDisabled,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                if (widget.business) {
                  context.push('/business/backup');
                  return;
                }
                context.push(RouteNames.personalBackup);
              },
              icon: const Icon(
                Icons.settings_outlined,
                size: 18,
                color: Colors.white,
              ),
              label: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  AppLocalizations.of(context).translate('profileSetupBackup'),
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                elevation: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreferencesSection(bool isDark) {
    final helpClicker = ref.watch(helpClickerProvider);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          _buildThemeTile(isDark),
          _settingsDivider(),
          _settingsTile(
            HugeIcons.strokeRoundedCursor01,
            AppLocalizations.of(context).translate('helpClickerTitle'),
            AppColors.primary,
            trailing: Switch(
              value: helpClicker.enabled,
              activeThumbColor: AppColors.primary,
              onChanged: (v) =>
                  ref.read(helpClickerProvider.notifier).setEnabled(v),
            ),
            onTap: () => ref
                .read(helpClickerProvider.notifier)
                .setEnabled(!helpClicker.enabled),
          ),
          if (helpClicker.enabled)
            Padding(
              padding: const EdgeInsets.only(left: 14, right: 14, bottom: 12),
              child: GestureDetector(
                onTap: _openHelpClickerSecondsSheet,
                behavior: HitTestBehavior.opaque,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        AppLocalizations.of(
                          context,
                        ).translate('helpClickerPressDuration'),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 12),
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: AppColors.primary.withAlpha(18),
                        border: Border.all(
                          color: AppColors.primary.withAlpha(110),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            AppLocalizations.of(context).translate(
                              'helpClickerSeconds',
                              params: {'n': helpClicker.seconds},
                            ),
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: R.fontSize(context, 12),
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 18,
                            color: AppColors.primary,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          _settingsDivider(),
          _buildLanguageTile(),
          _settingsDivider(),
          if (!_limitedEmployee) ...[
            _settingsTile(
              HugeIcons.strokeRoundedDocumentAttachment,
              AppLocalizations.of(context).translate(
                widget.business
                    ? 'invDesignHubTitle'
                    : 'profileCustomizeReports',
              ),
              AppColors.primary,
              onTap: () => context.push(
                widget.business
                    ? '/invoices/design'
                    : '/personal/receipt-design',
              ),
            ),
            _settingsDivider(),
            if (widget.business)
              _buildBizCurrencyCustomizationTile()
            else
              _buildCurrencyCustomizationTile(),
            _settingsDivider(),
          ],
          _buildMoneyFormatTile(),
          if (widget.business && !_limitedEmployee) ...[
            _settingsDivider(),
            _settingsTile(
              HugeIcons.strokeRoundedCursor01,
              AppLocalizations.of(context).translate('prefAllowNegative'),
              AppColors.primary,
              trailing: Switch(
                value: ref.watch(bizPaymentPrefProvider).allowNegative,
                activeThumbColor: AppColors.primary,
                onChanged: _saveAllowNegative,
              ),
              onTap: () {
                final cur = ref.read(bizPaymentPrefProvider).allowNegative;
                _saveAllowNegative(!cur);
              },
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openHelpClickerSecondsSheet() async {
    final l10n = AppLocalizations.of(context);
    final notifier = ref.read(helpClickerProvider.notifier);
    const presets = <int>[2, 3, 4, 5, 6, 8, 10];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                l10n.translate('helpClickerChooseDuration'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            ...presets.map((s) {
              final selected = s == ref.read(helpClickerProvider).seconds;
              return ListTile(
                onTap: () async {
                  await notifier.setSeconds(s);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                dense: true,
                leading: Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: selected ? AppColors.primary : AppColors.textDisabled,
                ),
                title: Text(
                  l10n.translate('helpClickerSeconds', params: {'n': s}),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    color: AppColors.textPrimary,
                  ),
                ),
              );
            }),
            ListTile(
              onTap: () async {
                final custom = await _askHelpClickerCustomSeconds(ctx, l10n);
                if (custom != null) {
                  await notifier.setSeconds(custom);
                  if (ctx.mounted) Navigator.pop(ctx);
                }
              },
              dense: true,
              leading: Icon(Icons.edit_rounded, color: AppColors.textSecondary),
              title: Text(
                l10n.translate('custom'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<int?> _askHelpClickerCustomSeconds(
    BuildContext ctx,
    AppLocalizations l10n,
  ) async {
    final ctrl = TextEditingController();
    try {
      return await showDialog<int>(
        context: ctx,
        builder: (dctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            l10n.translate('custom'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          content: FyonaTextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(2),
            ],
            decoration: InputDecoration(
              hintText: l10n.translate('helpClickerSeconds', params: {'n': 5}),
              hintStyle: TextStyle(color: AppColors.textDisabled),
            ),
            style: TextStyle(fontFamily: 'Cairo', color: AppColors.textPrimary),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: Text(
                l10n.translate('cancel'),
                style: TextStyle(
                  fontFamily: 'Cairo',
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            ElevatedButton(
              onPressed: () {
                var v = int.tryParse(ctrl.text.trim()) ?? 0;
                if (v < 1) v = 1;
                if (v > 15) v = 15;
                Navigator.pop(dctx, v);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
              ),
              child: Text(
                l10n.translate('confirm'),
                style: const TextStyle(
                  fontFamily: 'Cairo',
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }
  }

  Future<void> _saveAllowNegative(bool value) async {
    try {
      await ref.read(bizPaymentPrefProvider.notifier).setAllowNegative(value);
    } catch (_) {
      if (mounted) _snack('تعذر حفظ إعداد الدفع. لم يتم تغييره عند الآخرين.');
    }
  }

  Widget _buildSecuritySection() {
    if (_employee)
      return Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            _buildBiometricTile(true),
            _settingsDivider(),
            _buildSessionTimeoutTile(),
          ],
        ),
      );
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          _buildAccountSecuritySection(),
          _settingsDivider(),
          _buildBiometricTile(true),
          _settingsDivider(),
          _buildSessionTimeoutTile(),
          _settingsDivider(),
          _settingsTile(
            HugeIcons.strokeRoundedDelete02,
            AppLocalizations.of(context).translate('profileResetAccount'),
            AppColors.danger,
            onTap: widget.business ? _confirmBusinessReset : _confirmResetData,
          ),
        ],
      ),
    );
  }

  Widget _buildAccountSecuritySection() {
    return ExpansionTile(
      tilePadding: EdgeInsets.symmetric(horizontal: 16, vertical: 0),
      childrenPadding: EdgeInsets.zero,
      shape: Border(),
      collapsedShape: Border(),
      leading: HugeIcon(
        icon: HugeIcons.strokeRoundedSecurityLock,
        size: 20,
        color: AppColors.warning,
      ),
      title: Text(
        AppLocalizations.of(context).translate('profileAccountSecurity'),
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: R.fontSize(context, 14),
          color: AppColors.textPrimary,
        ),
      ),
      children: [_buildChangePwdTile(), _buildChangeEmailTile()],
    );
  }

  Widget _buildSessionTimeoutTile() {
    final timeout = ref.watch(sessionTimeoutProvider).duration;
    final l10n = AppLocalizations.of(context);
    final label = _timeoutLabel(l10n, timeout);
    return _settingsTile(
      HugeIcons.strokeRoundedClock01,
      l10n.sessionTimeout,
      AppColors.primary,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 12),
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(width: 4),
          const Icon(
            Icons.chevron_right,
            size: 18,
            color: AppColors.textDisabled,
          ),
        ],
      ),
      onTap: () => _openTimeoutPicker(),
    );
  }

  String _timeoutLabel(AppLocalizations l10n, Duration? duration) {
    if (duration == null) return l10n.timeoutNever;
    switch (duration.inMinutes) {
      case 15:
        return l10n.timeout15;
      case 30:
        return l10n.timeout30;
      case 60:
        return l10n.timeout1h;
      case 120:
        return l10n.timeout2h;
      case 240:
        return l10n.timeout4h;
      case 480:
        return l10n.timeout8h;
      case 720:
        return l10n.timeout12h;
      case 1440:
        return l10n.timeout24h;
      default:
        return l10n.timeoutNever;
    }
  }

  Future<void> _openTimeoutPicker() async {
    final l10n = AppLocalizations.of(context);
    final current = ref.read(sessionTimeoutProvider).duration;
    final options = <_TimeoutPick>[
      const _TimeoutPick(null),
      const _TimeoutPick(Duration(minutes: 15)),
      const _TimeoutPick(Duration(minutes: 30)),
      const _TimeoutPick(Duration(hours: 1)),
      const _TimeoutPick(Duration(hours: 2)),
      const _TimeoutPick(Duration(hours: 4)),
      const _TimeoutPick(Duration(hours: 8)),
      const _TimeoutPick(Duration(hours: 12)),
      const _TimeoutPick(Duration(hours: 24)),
    ];
    final pick = await showModalBottomSheet<_TimeoutPick>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.sessionTimeout,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 16),
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.sessionTimeoutSubtitle,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: options.map((option) {
                    final isSelected = _picksEqual(option.duration, current);
                    return ListTile(
                      onTap: () => Navigator.pop(ctx, option),
                      leading: Icon(
                        isSelected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 20,
                        color: isSelected
                            ? AppColors.primary
                            : AppColors.textDisabled,
                      ),
                      title: Text(
                        _timeoutLabel(l10n, option.duration),
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: R.fontSize(context, 13),
                          fontWeight: isSelected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
    if (pick != null) {
      if (pick.duration != null && mounted) {
        // First-time enable requires creating the 5-digit app PIN
        // (explain → create → confirm). Cancelling leaves it disabled.
        bool hasPin = false;
        try {
          hasPin =
              (await ref.read(authLocalDataSourceProvider).getAppPin())
                  ?.isNotEmpty ==
              true;
        } catch (_) {}
        if (!hasPin) {
          final done = await Navigator.of(
            context,
          ).push<bool>(MaterialPageRoute(builder: (_) => const PinSetupPage()));
          if (done != true || !mounted) return;
        }
      }
      await ref
          .read(sessionTimeoutProvider.notifier)
          .setDuration(pick.duration);
    }
  }

  bool _picksEqual(Duration? a, Duration? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return a.inMinutes == b.inMinutes;
  }

  /// Day/night appearance switch: animated sun/moon toggle with sliding
  /// thumb, rotating icon, stars and sky gradient. Tapping flips the whole
  /// app palette (persisted); MaterialApp cross-fades Material widgets while
  /// the AppColors palette swap repaints custom UI in the same frame.
  Widget _buildThemeTile(bool isDark) {
    final l10n = AppLocalizations.of(context);
    return InkWell(
      onTap: () {
        HapticFeedback.mediumImpact();
        ref.read(themeModeProvider.notifier).toggleTheme();
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeInOutCubic,
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color:
                    (isDark ? const Color(0xFF7C8CF8) : const Color(0xFFF5A623))
                        .withAlpha(16),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                  color:
                      (isDark
                              ? const Color(0xFF7C8CF8)
                              : const Color(0xFFF5A623))
                          .withAlpha(35),
                ),
              ),
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  transitionBuilder: (child, anim) => RotationTransition(
                    turns: Tween<double>(begin: 0.5, end: 1.0).animate(anim),
                    child: ScaleTransition(scale: anim, child: child),
                  ),
                  child: HugeIcon(
                    key: ValueKey(isDark),
                    icon: isDark
                        ? HugeIcons.strokeRoundedMoon02
                        : HugeIcons.strokeRoundedSun03,
                    size: 18,
                    color: isDark
                        ? const Color(0xFF7C8CF8)
                        : const Color(0xFFF5A623),
                  ),
                ),
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.translate('themeAppearance'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13.5),
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.4),
                          end: Offset.zero,
                        ).animate(anim),
                        child: child,
                      ),
                    ),
                    child: Text(
                      isDark
                          ? l10n.translate('darkMode')
                          : l10n.translate('lightMode'),
                      key: ValueKey(isDark),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 11),
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _DayNightToggle(
              isDark: isDark,
              onTap: () {
                HapticFeedback.mediumImpact();
                ref.read(themeModeProvider.notifier).toggleTheme();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLanguageTile() {
    final locale = ref.watch(localeProvider);
    final isArabic = locale.languageCode == 'ar';
    final l10n = AppLocalizations.of(context);
    return _settingsTile(
      HugeIcons.strokeRoundedGlobe,
      l10n.translate('language'),
      AppColors.primary,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isArabic ? l10n.translate('arabic') : 'English',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 12),
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(width: 4),
          const Icon(
            Icons.chevron_right,
            size: 18,
            color: AppColors.textDisabled,
          ),
        ],
      ),
      onTap: _openLanguagePicker,
    );
  }

  Widget _buildCurrencyCustomizationTile() {
    return _settingsTile(
      HugeIcons.strokeRoundedCoins01,
      AppLocalizations.of(context).translate('profileCustomizeCurrencies'),
      AppColors.primary,
      onTap: () => _openCurrencyCustomization(),
    );
  }

  /// Business currency customization — the Business enabled-set, fully
  /// separate from the Personal one above. Saving here materializes /
  /// removes BUSINESS cash rows only; Personal cash is never touched.
  Widget _buildBizCurrencyCustomizationTile() {
    ref.watch(branchEpochProvider);
    ref.watch(branchAccessProvider);
    return _settingsTile(
      HugeIcons.strokeRoundedBank,
      _bizCurrencyCustomizationTitle(),
      AppColors.primary,
      onTap: () => _openBizCurrencyCustomization(),
    );
  }

  String _bizCurrencyCustomizationTitle() {
    final companies = ref.read(branchAccessProvider).valueOrNull ?? const [];
    final org =
        BranchScope.organizationId ??
        ref.read(currentUserProvider)?.organizationId;
    final company = companies
        .where((company) => '${company['organization_id']}' == org)
        .firstOrNull;
    final branches = company?['branches'] as List? ?? const [];
    final granted = widget.employee?['branch_ids'] as List?;
    final count = company != null ? branches.length : (granted?.length ?? 1);
    final arabic = AppLocalizations.of(context).locale.languageCode == 'ar';
    return count > 1
        ? (arabic
              ? 'تخصيص عملات هذا الفرع'
              : 'Customize this branch currencies')
        : (arabic
              ? 'تخصيص عملات قسم الأعمال'
              : 'Customize business currencies');
  }

  Future<void> _openBizCurrencyCustomization() async {
    final locale = ref.read(localeProvider);
    final isArabic = locale.languageCode == 'ar';
    final userId = ref.read(currentUserIdProvider);
    final title = _bizCurrencyCustomizationTitle();
    final local = ref.read(localBusinessBankingProvider);
    final epoch = ref.read(branchEpochProvider);
    if (local == null) ref.invalidate(projectSettingsProvider);
    final Set<String> initial;
    try {
      initial = await ref.refresh(bizEnabledCurrenciesProvider.future);
    } catch (_) {
      if (mounted) {
        _snack(AppLocalizations.of(context).translate('txOperationFailed'), bg: AppColors.danger);
      }
      return;
    }
    final opened = ref.read(localBusinessBankingProvider);
    if (!mounted || epoch != ref.read(branchEpochProvider) ||
        (local == null) != (opened == null) ||
        (opened != null && !opened.isCurrent)) return;

    var savingLocal = false;
    final command = const Uuid().v4();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _CurrencyCustomizationSheet(
        title: title,
        isArabic: isArabic,
        initialSelected: initial,
        onSave: (selected) async {
          if (!mounted || !ctx.mounted || epoch != ref.read(branchEpochProvider)) return;
          // The same branch may hand out a fresh banking object (connectivity,
          // sync); only a different branch or a revoked scope stops the save.
          final current = ref.read(localBusinessBankingProvider);
          if ((local == null) != (current == null) ||
              (current != null && !current.isCurrent)) return;
          if (current != null) {
            if (savingLocal) return;
            savingLocal = true;
            try {
              // Compare against the device's cash slots as they are now.
              final before = await current.cashCurrencies();
              await current.saveCashCurrencies(
                before,
                selected,
                const Uuid().v5(
                  Uuid.NAMESPACE_URL,
                  'fyona-cash-currencies:$command:${(selected.toList()..sort()).join(',')}',
                ),
              );
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted && current.isCurrent) {
                _snack(
                  AppLocalizations.of(context).translate('profileCurrenciesSaved'),
                  bg: AppColors.success,
                );
              }
            } catch (_) {
              if (mounted && ctx.mounted) {
                _snack(
                  AppLocalizations.of(context).translate('txOperationFailed'),
                  bg: AppColors.danger,
                );
              }
            } finally {
              savingLocal = false;
            }
            return;
          }
          await ref.read(branchApiProvider).saveCurrencies(selected.toList());
          ref.invalidate(bizEnabledCurrenciesProvider);
          await ref.read(bizEnabledCurrenciesProvider.future);
          // Business cash follows Business customization only.
          try {
            final notifier = ref.read(businessBanksProvider.notifier);
            await notifier.load();
            final removed = initial.difference(selected);
            final added = selected.difference(initial);
            for (final c in removed) {
              BusinessBankAccount? target;
              for (final a in ref.read(businessBanksProvider).accounts) {
                if (isBizCashAccount(a.bankName) &&
                    a.currency.toUpperCase() == c.toUpperCase()) {
                  target = a;
                  break;
                }
              }
              if (target != null) {
                try {
                  await notifier.deleteCashCurrency(target, userId: userId);
                } catch (_) {
                  // Last-cash guard: keep at least one cash currency.
                }
              }
            }
            if (added.isNotEmpty) {
              await ref
                  .read(bizCashServiceProvider)
                  .ensureCashAccounts(
                    added.toList(),
                    enabled: selected,
                    userId: userId,
                  );
              await notifier.load();
            }
          } catch (_) {}
          if (ctx.mounted) Navigator.pop(ctx);
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  AppLocalizations.of(
                    context,
                  ).translate('profileCurrenciesSaved'),
                  style: TextStyle(fontFamily: 'Cairo'),
                ),
                backgroundColor: AppColors.success,
              ),
            );
        },
      ),
    );
  }

  Widget _buildMoneyFormatTile() {
    return _settingsTile(
      HugeIcons.strokeRoundedMoney01,
      AppLocalizations.of(context).translate('profileMoneyFormat'),
      AppColors.primary,
      onTap: () => _openMoneyFormatCustomization(),
    );
  }

  Future<void> _openCurrencyCustomization() async {
    final locale = ref.read(localeProvider);
    final isArabic = locale.languageCode == 'ar';
    final userId = ref.read(currentUserIdProvider);
    final prefs = await SharedPreferences.getInstance();
    final savedRaw = prefs.getStringList('enabled_currencies_$userId');
    Set<String> initial = savedRaw?.toSet() ?? _defaultCurrencies().toSet();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _CurrencyCustomizationSheet(
        isArabic: isArabic,
        initialSelected: initial,
        onSave: (selected) async {
          await prefs.setStringList(
            'enabled_currencies_$userId',
            selected.toList(),
          );
          // Cash follows customization: unchecked currencies leave cash
          // (with snapshot for restore), newly checked ones come back.
          try {
            final svc = ref.read(personalFinanceServiceProvider);
            final removed = initial.difference(selected);
            final added = selected.difference(initial);
            for (final c in removed) {
              await svc.removeCashCurrency(c);
            }
            if (added.isNotEmpty) {
              await svc.ensureCashAccounts(added.toList(), enabled: selected);
            }
          } catch (_) {}
          if (ctx.mounted) Navigator.pop(ctx);
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  AppLocalizations.of(
                    context,
                  ).translate('profileCurrenciesSaved'),
                  style: TextStyle(fontFamily: 'Cairo'),
                ),
                backgroundColor: AppColors.success,
              ),
            );
        },
      ),
    );
  }

  static List<String> _defaultCurrencies() => const [
    'YER_OLD',
    'YER_NEW',
    'SAR',
    'USD',
  ];

  Future<void> _openMoneyFormatCustomization() async {
    final locale = ref.read(localeProvider);
    final isArabic = locale.languageCode == 'ar';
    final userId = ref.read(currentUserIdProvider);
    final scope = '$userId-${widget.business ? 'business' : 'personal'}';
    var settings = await MoneyFormatService.loadAll(scope);

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          void update(MoneyFormatSettings next) {
            setSheetState(() => settings = next);
            MoneyFormatService.save(next, scope);
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppLocalizations.of(
                      context,
                    ).translate('profileMoneyFormat'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 16),
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    AppLocalizations.of(
                      context,
                    ).translate('profileMoneyFormatHint'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 12),
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 16),

                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      AppLocalizations.of(
                        context,
                      ).translate('profileThousandsSep'),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 14),
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    subtitle: Text(
                      settings.useThousandsSeparator
                          ? AppLocalizations.of(
                              context,
                            ).translate('profileExThousandsOn')
                          : AppLocalizations.of(
                              context,
                            ).translate('profileExThousandsOff'),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        color: AppColors.textSecondary,
                      ),
                    ),
                    activeThumbColor: AppColors.primary,
                    value: settings.useThousandsSeparator,
                    onChanged: (v) =>
                        update(settings.copyWith(useThousandsSeparator: v)),
                  ),
                  const SizedBox(height: 4),

                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      AppLocalizations.of(context).translate('profileDecimals'),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 14),
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    subtitle: Text(
                      settings.showDecimals
                          ? AppLocalizations.of(
                              context,
                            ).translate('profileExDecimalsOn')
                          : AppLocalizations.of(
                              context,
                            ).translate('profileExDecimalsOff'),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        color: AppColors.textSecondary,
                      ),
                    ),
                    activeThumbColor: AppColors.primary,
                    value: settings.showDecimals,
                    onChanged: (v) =>
                        update(settings.copyWith(showDecimals: v)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openLanguagePicker() async {
    final l10n = AppLocalizations.of(context);
    final locale = ref.read(localeProvider);
    final isArabic = locale.languageCode == 'ar';
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.translate('language'),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 16),
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.translate('profileChooseLang'),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 12),
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              ListTile(
                onTap: () => Navigator.pop(ctx, 'ar'),
                leading: Icon(
                  isArabic
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 20,
                  color: isArabic ? AppColors.primary : AppColors.textDisabled,
                ),
                title: Text(
                  l10n.translate('arabic'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: isArabic ? FontWeight.w700 : FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              ListTile(
                onTap: () => Navigator.pop(ctx, 'en'),
                leading: Icon(
                  !isArabic
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 20,
                  color: !isArabic ? AppColors.primary : AppColors.textDisabled,
                ),
                title: Text(
                  'English',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    fontWeight: !isArabic ? FontWeight.w700 : FontWeight.w500,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
    if (selected != null && mounted) {
      await requestLanguageChange(ref, Locale(selected));
    }
  }

  Widget _settingsTile(
    List<List<dynamic>> icon,
    String title,
    Color color, {
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color.withAlpha(16),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: color.withAlpha(35)),
              ),
              child: Center(
                child: HugeIcon(icon: icon, size: 18, color: color),
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13.5),
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            if (trailing != null) trailing,
            if (trailing == null && onTap != null)
              HugeIcon(
                icon: HugeIcons.strokeRoundedArrowLeft01,
                size: 18,
                color: AppColors.textDisabled,
              ),
          ],
        ),
      ),
    );
  }

  Widget _settingsDivider() {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16),
      child: Divider(color: AppColors.border, height: 1),
    );
  }

  Widget _buildBiometricTile(bool isDark) {
    final biometricState = ref.watch(biometricProvider);
    final canUseBiometric =
        biometricState.isDeviceSupported && biometricState.canCheckBiometrics;
    final l10n = AppLocalizations.of(context);
    return _settingsTile(
      HugeIcons.strokeRoundedLock,
      l10n.translate('profileBioLogin'),
      AppColors.primary,
      trailing: Switch(
        value: biometricState.isEnabled && canUseBiometric,
        activeThumbColor: AppColors.primary,
        onChanged: canUseBiometric
            ? (v) async {
                if (v) {
                  AuthResult result;
                  try {
                    result = await ref
                        .read(biometricProvider.notifier)
                        .authenticate(
                          reason: l10n.translate('sharedBioReason'),
                        );
                  } catch (e) {
                    if (!mounted) return;
                    _snack(
                      l10n.translate('profileBioNoAccess'),
                      bg: AppColors.warning,
                    );
                    return;
                  }
                  if (!mounted) return;
                  if (result == AuthResult.success) {
                    // Fingerprint alone enables biometric login instantly: the
                    // current session (tokens + user + mode) is snapshotted so a
                    // later fingerprint entry restores the account directly —
                    // no password prompt is ever needed.
                    await ref
                        .read(biometricProvider.notifier)
                        .snapshotCurrentSession();
                    await ref.read(biometricProvider.notifier).setEnabled(true);
                    if (mounted) _snack(l10n.translate('profileBioEnabled'));
                  } else if (result == AuthResult.notEnrolled) {
                    _snack(
                      l10n.translate('profileBioNotEnrolled'),
                      bg: AppColors.warning,
                    );
                  } else if (result == AuthResult.lockedOut ||
                      result == AuthResult.permanentlyLockedOut) {
                    _snack(
                      l10n.translate('profileBioLockedTemp'),
                      bg: AppColors.warning,
                    );
                  } else if (result == AuthResult.notAvailable ||
                      result == AuthResult.notSupported) {
                    _snack(
                      l10n.translate('profileBioNotAvailable'),
                      bg: AppColors.warning,
                    );
                  } else if (result == AuthResult.cancelled) {
                    // User cancelled — do nothing
                  } else if (result == AuthResult.error) {
                    _snack(
                      l10n.translate('profileBioUnitError'),
                      bg: AppColors.warning,
                    );
                  } else {
                    _snack(
                      l10n.translate('profileVerifyFailed'),
                      bg: AppColors.warning,
                    );
                  }
                } else {
                  await ref.read(biometricProvider.notifier).setEnabled(false);
                  if (mounted) _snack(l10n.translate('profileBioDisabled'));
                }
              }
            : null,
      ),
    );
  }

  void _requestEmailChange() async {
    final l10n = AppLocalizations.of(context);
    final newEmail = _newEmailCtrl.text.trim();
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (newEmail.isEmpty || !emailRegex.hasMatch(newEmail)) {
      _snack(l10n.translate('profileEmailInvalid'), bg: AppColors.warning);
      return;
    }
    setState(() => _isSendingEmailOtp = true);
    final err = await ref.read(authProvider.notifier).requestEmailChange();
    setState(() => _isSendingEmailOtp = false);
    if (err != null) {
      _snack(err, bg: AppColors.danger);
      return;
    }
    setState(() => _emailCodeSent = true);
    _snack(l10n.translate('profileEmailOtpSent'), bg: AppColors.success);
  }

  void _verifyEmailChange() async {
    final l10n = AppLocalizations.of(context);
    final code = _emailOtpCtrl.text.trim();
    final newEmail = _newEmailCtrl.text.trim();
    if (code.isEmpty) {
      _snack(l10n.translate('otpHint'), bg: AppColors.warning);
      return;
    }
    setState(() => _isVerifyingEmail = true);
    final err = await ref
        .read(authProvider.notifier)
        .verifyEmailChange(code: code, newEmail: newEmail);
    setState(() => _isVerifyingEmail = false);
    if (err != null) {
      _snack(err, bg: AppColors.danger);
      return;
    }
    setState(() {
      _emailCodeSent = false;
      _newEmailCtrl.clear();
      _emailOtpCtrl.clear();
    });
    if (mounted) {
      final user = ref.read(authProvider).user;
      if (user != null) _emailCtrl.text = user.email ?? '';
    }
    _snack(l10n.translate('profileEmailChanged'), bg: AppColors.success);
  }

  void _resetEmailChange() {
    setState(() {
      _emailCodeSent = false;
      _newEmailCtrl.clear();
      _emailOtpCtrl.clear();
    });
  }

  Widget _buildChangeEmailTile() {
    final l10n = AppLocalizations.of(context);
    return ExpansionTile(
      tilePadding: EdgeInsets.symmetric(horizontal: 16, vertical: 0),
      childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
      shape: Border(),
      collapsedShape: Border(),
      leading: Icon(Icons.email_outlined, size: 20, color: AppColors.primary),
      title: Text(
        l10n.translate('profileChangeEmail'),
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: R.fontSize(context, 14),
          color: AppColors.textPrimary,
        ),
      ),
      children: [
        FyonaTextField(
          controller: _newEmailCtrl,
          keyboardType: TextInputType.emailAddress,
          textAlign: TextAlign.right,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 14),
            color: AppColors.textPrimary,
          ),
          decoration: InputDecoration(
            labelText: l10n.translate('profileNewEmail'),
            labelStyle: TextStyle(
              fontFamily: 'Cairo',
              color: AppColors.textSecondary,
            ),
            filled: true,
            fillColor: AppColors.surfaceVariant,
            border: OutlineInputBorder(borderSide: BorderSide.none),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
        const SizedBox(height: 8),
        if (_emailCodeSent) ...[
          FyonaTextField(
            controller: _emailOtpCtrl,
            keyboardType: const TextInputType.numberWithOptions(),
            textAlign: TextAlign.right,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 14),
              color: AppColors.textPrimary,
            ),
            decoration: InputDecoration(
              labelText: l10n.translate('profileOtpSentToCurrent'),
              labelStyle: TextStyle(
                fontFamily: 'Cairo',
                color: AppColors.textSecondary,
              ),
              filled: true,
              fillColor: AppColors.surfaceVariant,
              border: OutlineInputBorder(borderSide: BorderSide.none),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            if (!_emailCodeSent)
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isSendingEmailOtp ? null : _requestEmailChange,
                  icon: Icon(Icons.send, size: 16, color: Colors.white),
                  label: Text(
                    _isSendingEmailOtp
                        ? l10n.translate('profileSending')
                        : l10n.translate('profileSendCode'),
                    style: TextStyle(fontFamily: 'Cairo', color: Colors.white),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                  ),
                ),
              )
            else
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _isVerifyingEmail ? null : _verifyEmailChange,
                  icon: Icon(Icons.check, size: 16, color: Colors.white),
                  label: Text(
                    _isVerifyingEmail
                        ? l10n.translate('profileVerifying')
                        : l10n.translate('confirm'),
                    style: TextStyle(fontFamily: 'Cairo', color: Colors.white),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                  ),
                ),
              ),
            if (_emailCodeSent) ...[
              const SizedBox(width: 8),
              Expanded(
                child: TextButton(
                  onPressed: _resetEmailChange,
                  child: Text(
                    l10n.translate('cancel'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildChangePwdTile() {
    final l10n = AppLocalizations.of(context);
    return ExpansionTile(
      tilePadding: EdgeInsets.symmetric(horizontal: 16, vertical: 0),
      childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
      shape: Border(),
      collapsedShape: Border(),
      leading: HugeIcon(
        icon: HugeIcons.strokeRoundedLock,
        size: 20,
        color: AppColors.warning,
      ),
      title: Text(
        l10n.translate('changePasswordTitle'),
        style: TextStyle(
          fontFamily: 'Cairo',
          fontSize: R.fontSize(context, 14),
          color: AppColors.textPrimary,
        ),
      ),
      children: [
        FyonaTextField(
          controller: _oldPwdCtrl,
          obscureText: true,
          textAlign: TextAlign.right,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 14),
            color: AppColors.textPrimary,
          ),
          decoration: InputDecoration(
            labelText: l10n.translate('currentPasswordLabel'),
            labelStyle: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 13),
              color: AppColors.textSecondary,
            ),
            filled: true,
            fillColor: AppColors.surfaceVariant,
            border: OutlineInputBorder(borderSide: BorderSide.none),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
        SizedBox(height: 8),
        FyonaTextField(
          controller: _newPwdCtrl,
          obscureText: true,
          textAlign: TextAlign.right,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 14),
            color: AppColors.textPrimary,
          ),
          decoration: InputDecoration(
            labelText: l10n.translate('newPasswordLabel'),
            hintText: l10n.translate('profilePwdHint'),
            hintStyle: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 12),
              color: AppColors.textDisabled,
            ),
            filled: true,
            fillColor: AppColors.surfaceVariant,
            border: OutlineInputBorder(borderSide: BorderSide.none),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
        SizedBox(height: 8),
        FyonaTextField(
          controller: _confirmPwdCtrl,
          obscureText: true,
          textAlign: TextAlign.right,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: R.fontSize(context, 14),
            color: AppColors.textPrimary,
          ),
          decoration: InputDecoration(
            labelText: l10n.translate('confirmPassword'),
            labelStyle: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 13),
              color: AppColors.textSecondary,
            ),
            filled: true,
            fillColor: AppColors.surfaceVariant,
            border: OutlineInputBorder(borderSide: BorderSide.none),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _changePwd,
            icon: HugeIcon(
              icon: HugeIcons.strokeRoundedKey01,
              size: 16,
              color: Colors.white,
            ),
            label: Text(
              l10n.translate('changePasswordTitle'),
              style: TextStyle(fontFamily: 'Cairo', color: Colors.white),
            ),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.warning),
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(String title, {IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Row(
        children: [
          if (icon != null) ...[
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(16),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 14, color: AppColors.primary),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            title,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 12.5),
              fontWeight: FontWeight.w800,
              color: AppColors.textSecondary,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Divider(color: AppColors.border.withAlpha(120), height: 1),
          ),
        ],
      ),
    );
  }

  Widget _buildLogoutButton() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.danger.withAlpha(8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.danger.withAlpha(30)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _confirmLogout,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                HugeIcon(
                  icon: HugeIcons.strokeRoundedLogout01,
                  size: 18,
                  color: AppColors.danger,
                ),
                const SizedBox(width: 8),
                Text(
                  AppLocalizations.of(context).translate('logout'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 14),
                    fontWeight: FontWeight.w800,
                    color: AppColors.danger,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: null,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppColors.danger.withAlpha(15),
                shape: BoxShape.circle,
              ),
              child: HugeIcon(
                icon: HugeIcons.strokeRoundedLogout01,
                size: 26,
                color: AppColors.danger,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.of(context).translate('logout'),
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 17),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              AppLocalizations.of(context).translate('profileLogoutConfirm'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 13),
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  style: TextButton.styleFrom(
                    backgroundColor: AppColors.surfaceVariant,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text(
                    AppLocalizations.of(context).translate('cancel'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: TextButton.styleFrom(
                    backgroundColor: AppColors.danger,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text(
                    AppLocalizations.of(context).translate('adminExit'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(authProvider.notifier).logout();
      if (mounted) context.go(RouteNames.login);
    }
  }

  Future<void> _confirmResetData() async {
    // Require internet to wipe server data.
    final svc = ref.read(personalFinanceServiceProvider);
    final connectivity = ref.read(connectivityServiceProvider);
    final online = connectivity.isOnline;
    if (!online) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).translate('noInternet'),
            style: const TextStyle(fontFamily: 'Cairo'),
          ),
          backgroundColor: AppColors.warning,
        ),
      );
      return;
    }

    // Step 1: simple confirmation (identity verification comes next).
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: null,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.danger.withAlpha(15),
                shape: BoxShape.circle,
              ),
              child: HugeIcon(
                icon: HugeIcons.strokeRoundedDelete02,
                size: 26,
                color: AppColors.danger,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.of(context).translate('profileResetAccount'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 17),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              AppLocalizations.of(context).translate('profileResetBody'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 12.5),
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              AppLocalizations.of(context).translate('profileResetHint'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 11),
                color: AppColors.textDisabled,
              ),
            ),
          ],
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  style: TextButton.styleFrom(
                    backgroundColor: AppColors.surfaceVariant,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text(
                    AppLocalizations.of(context).translate('cancel'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: TextButton.styleFrom(
                    backgroundColor: AppColors.danger,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text(
                    AppLocalizations.of(context).translate('profileResetBtn'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Let the confirm route finish animating out before opening the next dialog
    // — otherwise deactivating the previous route while its InheritedElements
    // still have dependents can fire `_dependents.isEmpty`.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    // Step 2: verify identity (fingerprint if available/enabled, otherwise
    // the app PIN; a missing PIN opens secure creation with a clear reason).
    final ok = await verifySensitiveAction(
      context,
      ref,
      reason: AppLocalizations.of(context).translate('profileResetBioReason'),
    );
    if (ok && mounted) await _performReset();
  }

  /// Business-section reset — fully independent from Personal. Clears the
  /// Business local caches/chat on this device and forces a refetch from the
  /// server (shared org data is never destroyed). Personal is never touched.
  Future<void> _confirmBusinessReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.danger.withAlpha(15),
                shape: BoxShape.circle,
              ),
              child: HugeIcon(
                icon: HugeIcons.strokeRoundedDelete02,
                size: 26,
                color: AppColors.danger,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.of(context).translate('profileResetAccount'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 17),
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              AppLocalizations.of(context).translate('profileResetBizBody'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 12.5),
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              AppLocalizations.of(context).translate('profileResetHint'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 11),
                color: AppColors.textDisabled,
              ),
            ),
          ],
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  style: TextButton.styleFrom(
                    backgroundColor: AppColors.surfaceVariant,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text(
                    AppLocalizations.of(context).translate('cancel'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: TextButton.styleFrom(
                    backgroundColor: AppColors.danger,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text(
                    AppLocalizations.of(context).translate('profileResetBtn'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 13),
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    final ok = await verifySensitiveAction(
      context,
      ref,
      reason: AppLocalizations.of(context).translate('profileResetBioReason'),
    );
    if (ok && mounted) await _performBusinessReset();
  }

  Future<void> _performBusinessReset() async {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ResetProgressDialog(),
    );
    final userId = ref.read(authProvider).user?.id ?? '';
    try {
      // Server first: delete EVERY branch + all its operations/staff links,
      // then recreate a fresh main branch. Subscription/account stay intact.
      await ref.read(branchApiProvider).resetAllBusiness();
      // Business-only local state (Personal is never touched).
      try {
        ChatPersistence.instance.clearMessages('${userId}_business');
      } catch (_) {}
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys().toList()) {
        if (key.startsWith('biz_invoice_design_') ||
            key.startsWith('enabled_currencies_biz_')) {
          await prefs.remove(key);
        }
      }
      await BranchScope.clear();
      try {
        await ref.read(branchApiProvider).select();
      } catch (_) {}
      ref.read(branchEpochProvider.notifier).state++;
      ref.invalidate(branchAccessProvider);
      ref.invalidate(branchesProvider);
      ref.invalidate(businessAccountsProvider);
      ref.invalidate(businessRecentProvider);
      ref.invalidate(invoiceDesignProvider);
      ref.invalidate(returnsListProvider);
      ref.invalidate(businessBanksProvider);
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showResetSuccess();
      });
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _snack(
        AppLocalizations.of(
          context,
        ).translate('profileResetFailed', params: {'error': e}),
        bg: AppColors.danger,
      );
    }
  }

  /// Success banner after reset. Local state is already reloaded, so the
  /// restart is offered — not required. A failed server wipe is stated
  /// plainly instead of a clean bill of health.
  void _showResetSuccess({bool serverOk = true}) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: (serverOk ? AppColors.success : AppColors.warning)
                    .withAlpha(30),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check_rounded,
                color: serverOk ? AppColors.success : AppColors.warning,
                size: 32,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.of(context).translate('profileResetOk'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            if (!serverOk) ...[
              const SizedBox(height: 8),
              Text(
                AppLocalizations.of(
                  context,
                ).translate('profileResetServerWarn'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 12,
                  color: AppColors.warning,
                ),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => _restartApp(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  AppLocalizations.of(context).translate('restartApp'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// True cold restart: asks Android to relaunch the app, then kills the
  /// process. The app closes AND starts again by itself with a fresh
  /// engine, landing the user on the freshly-reset data.
  Future<void> _restartApp() async {
    try {
      await const MethodChannel(
        'com.fyona.erp/alarm_native',
      ).invokeMethod('restartApp');
    } catch (_) {
      SystemNavigator.pop();
    }
  }

  Future<void> _performReset() async {
    if (!mounted) return;
    // Progress UI FIRST: an animated red trash bin with data chips flowing
    // in, so the (multi-second) wipe never looks frozen. Closed on both
    // completion paths below, right before the success/failure UI.
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ResetProgressDialog(),
    );
    final userId = ref.read(currentUserIdProvider).trim();
    final scope = userId.isEmpty ? 'global' : userId;
    // Canonical local namespaces for this user (warmed stable id, else the
    // deterministic FNV fallback) — NEVER String.hashCode, which is random
    // per launch and made the old wipe miss every mirror/legacy row while
    // transactions visibly survived. Both namespaces are wiped to cover
    // rows written before the stable mapping was warmed.
    final stableNs = PersonalCacheRepository.stableIdSync(userId);
    final fnvNs = PersonalCacheRepository.fnvNamespace(userId);

    final svc = ref.read(personalFinanceServiceProvider);
    // Freeze auto-backup for the whole reset: no empty/torn snapshots.
    BackupService.setResetGuard(true);
    // BEFORE the wipe: snapshot the cash currency set so the defaults
    // survive the reset with zero balances. Currencies the user removed
    // manually are absent from the snapshot, so they stay deleted.
    Set<String> cashSnapshot = {};
    try {
      cashSnapshot = await svc.snapshotCashCurrencies();
    } catch (_) {}
    // Server reset first, LOUDLY: local wipe proceeds regardless, but the
    // user is told when the server half failed (stale server data would
    // otherwise silently reseed the "clean" account on next sync).
    var serverResetOk = true;
    try {
      await svc.resetAccount();
    } catch (_) {
      serverResetOk = false;
    }

    try {
      final repo = ref.read(personalRepositoryProvider);
      await repo.resetAllData(stableNs);
      if (fnvNs != stableNs) {
        await repo.resetAllData(fnvNs);
      }
      await DatabaseHelper.rawDelete(
        'DELETE FROM personal_entity_cache WHERE user_id IN (?, ?)',
        [stableNs, fnvNs],
      );
      // User-scoped outbox wipe only: never touch other users' queues.
      await DatabaseHelper.rawDelete(
        'DELETE FROM sync_queue WHERE user_id IN (?, ?)',
        [stableNs, fnvNs],
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('money_format_${scope}_sep');
      await prefs.remove('money_format_${scope}_dec');
      if (cashSnapshot.isNotEmpty) {
        // Keep the currency set (defaults + user-added), zeroed: the pref
        // is re-saved (not deleted) and every snapshotted cash currency is
        // recreated empty. Stashed balances are cleared so no old money
        // resurrects after a full wipe.
        await prefs.setStringList(
          'enabled_currencies_$scope',
          cashSnapshot.toList(),
        );
        await svc.clearCashVault();
        await svc.ensureCashAccounts(
          cashSnapshot.toList(),
          enabled: cashSnapshot,
        );
      } else {
        // No prior currencies: restore factory defaults (setting + empty
        // cash rows) so the account is usable immediately, no restart.
        await prefs.setStringList(
          'enabled_currencies_$scope',
          defaultEnabledCurrencies,
        );
        await svc.clearCashVault();
        await svc.ensureCashAccounts(
          List<String>.from(defaultEnabledCurrencies),
          enabled: defaultEnabledCurrencies.toSet(),
        );
      }
      await MoneyFormatService.loadAll('$userId-personal');
      await ref.read(avatarProvider.notifier).clear();
      await ref.read(personalFinanceProvider.notifier).load();
      await ref.read(budgetProvider.notifier).load();
      await ref.read(recurringProvider.notifier).load();
      await ref.read(categoryProvider.notifier).load();
      await ChatPersistence.instance.clearMessages('${userId}_personal');
      await ChatPersistence.instance.clearMessages('${userId}_business');
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showResetSuccess(serverOk: serverResetOk);
      });
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _snack(
          AppLocalizations.of(
            context,
          ).translate('profileResetFailed', params: {'error': e}),
          bg: AppColors.danger,
        );
      });
    } finally {
      BackupService.setResetGuard(false);
    }
  }
}

/// Reset progress dialog: an elegant red trash bin with data chips flowing
/// into it in a loop, plus the "resetting account data" label. Shown for the
/// whole duration of [_performReset]; closed right before the success dialog
/// (which carries the restart button) or the failure snackbar.
class _ResetProgressDialog extends StatefulWidget {
  const _ResetProgressDialog();

  @override
  State<_ResetProgressDialog> createState() => _ResetProgressDialogState();
}

class _ResetProgressDialogState extends State<_ResetProgressDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  static const _chipColors = [
    AppColors.primary,
    AppColors.success,
    AppColors.warning,
  ];

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Data chips falling into the bin, staggered in a loop.
                for (var i = 0; i < 3; i++)
                  SlideTransition(
                    position:
                        Tween<Offset>(
                          begin: Offset((i - 1) * 0.9, -1.7),
                          end: Offset((i - 1) * 0.9, -0.1),
                        ).animate(
                          CurvedAnimation(
                            parent: _ctrl,
                            curve: Interval(
                              i * 0.18,
                              0.55 + i * 0.18,
                              curve: Curves.easeIn,
                            ),
                          ),
                        ),
                    child: FadeTransition(
                      opacity: Tween<double>(begin: 1, end: 0).animate(
                        CurvedAnimation(
                          parent: _ctrl,
                          curve: Interval(i * 0.18, 0.55 + i * 0.18),
                        ),
                      ),
                      child: Container(
                        width: 26,
                        height: 10,
                        decoration: BoxDecoration(
                          color: _chipColors[i],
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                // Pulsing red trash bin.
                ScaleTransition(
                  scale: Tween<double>(begin: 1, end: 1.08).animate(
                    CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
                  ),
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: AppColors.danger.withAlpha(15),
                      shape: BoxShape.circle,
                    ),
                    child: HugeIcon(
                      icon: HugeIcons.strokeRoundedDelete02,
                      size: 30,
                      color: AppColors.danger,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            AppLocalizations.of(context).translate('profileResetProgress'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 14),
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Animated day/night switch: sliding thumb with rotating sun/moon icon,
/// twinkling stars at night and a sky gradient that cross-fades.
class _DayNightToggle extends StatelessWidget {
  final bool isDark;
  final VoidCallback onTap;
  const _DayNightToggle({required this.isDark, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
        width: 62,
        height: 32,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [const Color(0xFF2B3A67), const Color(0xFF0E1430)]
                : [const Color(0xFF5EB6F2), const Color(0xFFFFD98A)],
          ),
          border: Border.all(
            color: isDark ? const Color(0xFF3D4E89) : const Color(0xFFE8B04B),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color:
                  (isDark ? const Color(0xFF2B3A67) : const Color(0xFFFFB300))
                      .withAlpha(70),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Stack(
          children: [
            // ── Stars (night only) ──
            Align(
              alignment: const Alignment(0.35, -0.55),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 350),
                opacity: isDark ? 1 : 0,
                child: Container(
                  width: 3,
                  height: 3,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            Align(
              alignment: const Alignment(0.05, 0.55),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 450),
                opacity: isDark ? 0.8 : 0,
                child: Container(
                  width: 2.2,
                  height: 2.2,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            Align(
              alignment: const Alignment(0.62, 0.35),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 300),
                opacity: isDark ? 0.9 : 0,
                child: Container(
                  width: 2.6,
                  height: 2.6,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            // ── Sliding thumb ──
            AnimatedAlign(
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOutCubic,
              alignment: isDark
                  ? const Alignment(-0.82, 0)
                  : const Alignment(0.82, 0),
              child: Container(
                width: 26,
                height: 26,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color:
                          (isDark
                                  ? const Color(0xFFF4F1BB)
                                  : const Color(0xFFFFB300))
                              .withAlpha(130),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 400),
                    transitionBuilder: (child, anim) => RotationTransition(
                      turns: anim,
                      child: ScaleTransition(scale: anim, child: child),
                    ),
                    child: Icon(
                      isDark ? Icons.nightlight_round : Icons.wb_sunny_rounded,
                      key: ValueKey(isDark),
                      size: 15,
                      color: isDark
                          ? const Color(0xFF5B6BA8)
                          : const Color(0xFFFF9800),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeoutPick {
  final Duration? duration;
  const _TimeoutPick(this.duration);
}

/// ISO country per currency code, used to paint the country's flag in the
/// customization list. Both Yemeni rials (new and old) fly Yemen's flag.
const Map<String, String> _currencyFlagCountry = {
  'USD': 'US',
  'EUR': 'EU',
  'SAR': 'SA',
  'AED': 'AE',
  'KWD': 'KW',
  'QAR': 'QA',
  'BHD': 'BH',
  'OMR': 'OM',
  'EGP': 'EG',
  'YER': 'YE',
  'YER_NEW': 'YE',
  'YER_OLD': 'YE',
  'GBP': 'GB',
  'TRY': 'TR',
  'AFN': 'AF',
  'ALL': 'AL',
  'DZD': 'DZ',
  'AUD': 'AU',
  'CAD': 'CA',
  'CNY': 'CN',
  'JPY': 'JP',
  'INR': 'IN',
  'KRW': 'KR',
  'RUB': 'RU',
  'CHF': 'CH',
  'SEK': 'SE',
  'NOK': 'NO',
  'DKK': 'DK',
  'PLN': 'PL',
  'CZK': 'CZ',
  'HUF': 'HU',
  'RON': 'RO',
  'BGN': 'BG',
  'ZAR': 'ZA',
  'NGN': 'NG',
  'MAD': 'MA',
  'TND': 'TN',
  'LYD': 'LY',
  'SDG': 'SD',
  'IQD': 'IQ',
  'JOD': 'JO',
  'LBP': 'LB',
  'SYP': 'SY',
  'ILS': 'IL',
  'IRR': 'IR',
  'PKR': 'PK',
  'BDT': 'BD',
  'MYR': 'MY',
  'IDR': 'ID',
  'PHP': 'PH',
  'THB': 'TH',
  'VND': 'VN',
  'SGD': 'SG',
  'HKD': 'HK',
  'TWD': 'TW',
  'MXN': 'MX',
  'BRL': 'BR',
  'ARS': 'AR',
  'CLP': 'CL',
  'COP': 'CO',
  'PEN': 'PE',
  'VES': 'VE',
  'UAH': 'UA',
  'KZT': 'KZ',
  'UZS': 'UZ',
  'AZN': 'AZ',
  'GEL': 'GE',
  'AMD': 'AM',
  'RSD': 'RS',
  'HRK': 'HR',
  'ISK': 'IS',
  'XOF': 'SN',
  'XAF': 'CM',
  'MUR': 'MU',
  'ETB': 'ET',
  'KES': 'KE',
  'TZS': 'TZ',
  'UGX': 'UG',
  'GHS': 'GH',
};

/// Regional-indicator flag emoji for a currency code, or '' when the
/// currency has no mapped country (callers fall back to the code text).
String _flagForCurrency(String code) {
  final iso = _currencyFlagCountry[code.trim().toUpperCase()] ?? '';
  if (iso.length != 2) return '';
  return String.fromCharCodes([
    iso.codeUnitAt(0) + 127397,
    iso.codeUnitAt(1) + 127397,
  ]);
}

class _CurrencyCustomizationSheet extends StatefulWidget {
  final String? title;
  final bool isArabic;
  final Set<String> initialSelected;
  final ValueChanged<Set<String>> onSave;

  const _CurrencyCustomizationSheet({
    this.title,
    required this.isArabic,
    required this.initialSelected,
    required this.onSave,
  });

  @override
  State<_CurrencyCustomizationSheet> createState() =>
      _CurrencyCustomizationSheetState();
}

class _CurrencyCustomizationSheetState
    extends State<_CurrencyCustomizationSheet> {
  late Set<String> _selected;
  late List<String> _allCodes;
  late List<String> _filtered;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // "YER" and "YER_NEW" are the same Yemeni currency. The customization list
    // shows the "YER" key, so fold any persisted YER_NEW into YER for display.
    _selected = widget.initialSelected
        .map((c) => c == 'YER_NEW' ? 'YER' : c)
        .toSet();
    _allCodes = worldCurrencies.keys.toList();
    _filtered = List.from(_allCodes);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String _name(String code) =>
      currencyName(code, locale: widget.isArabic ? 'ar' : 'en');

  void _filter(String q) {
    setState(() {
      if (q.isEmpty) {
        _filtered = List.from(_allCodes);
      } else {
        _filtered = _allCodes
            .where(
              (c) =>
                  c.toLowerCase().contains(q.toLowerCase()) ||
                  _name(c).toLowerCase().contains(q.toLowerCase()),
            )
            .toList();
      }
    });
  }

  void _selectAll() {
    setState(() => _selected = _allCodes.toSet());
  }

  void _clearAll() {
    setState(() => _selected = <String>{});
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title ??
                        AppLocalizations.of(
                          context,
                        ).translate('profileCustomizeCurrencies'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 16),
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                Text(
                  '${_selected.length}/${_allCodes.length}',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: R.fontSize(context, 13),
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceVariant,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.border, width: 0.5),
                    ),
                    child: Icon(
                      Icons.close_rounded,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Search field
            FyonaTextField(
              controller: _searchCtrl,
              onChanged: _filter,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: R.fontSize(context, 14),
                color: AppColors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: AppLocalizations.of(
                  context,
                ).translate('profileSearchCurrency'),
                hintStyle: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 13),
                  color: AppColors.textDisabled,
                ),
                prefixIcon: Icon(
                  Icons.search,
                  size: 20,
                  color: AppColors.primary,
                ),
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: Icon(
                          Icons.clear,
                          size: 18,
                          color: AppColors.textDisabled,
                        ),
                        onPressed: () {
                          _searchCtrl.clear();
                          _filter('');
                        },
                      ),
                filled: true,
                fillColor: AppColors.surfaceVariant,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 10),
            // Select all / clear buttons
            Row(
              children: [
                Expanded(
                  child: _selectAllBtn(
                    icon: Icons.select_all,
                    label: AppLocalizations.of(
                      context,
                    ).translate('profileSelectAll'),
                    bg: AppColors.primary,
                    onTap: _selectAll,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _selectAllBtn(
                    icon: Icons.deselect,
                    label: AppLocalizations.of(
                      context,
                    ).translate('profileClearSelection'),
                    bg: AppColors.textSecondary,
                    onTap: _clearAll,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _filtered.length,
                itemBuilder: (_, i) {
                  final code = _filtered[i];
                  final name = _name(code);
                  final sel = _selected.contains(code);
                  final flag = _flagForCurrency(code);
                  return ListTile(
                    dense: true,
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: sel
                            ? AppColors.primary.withAlpha(20)
                            : AppColors.surfaceVariant,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: sel ? AppColors.primary : AppColors.border,
                        ),
                      ),
                      child: Center(
                        child: flag.isNotEmpty
                            ? Text(
                                flag,
                                style: TextStyle(
                                  fontSize: R.fontSize(context, 22),
                                ),
                              )
                            : Text(
                                code,
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: R.fontSize(context, 10),
                                  fontWeight: FontWeight.w700,
                                  color: sel
                                      ? AppColors.primary
                                      : AppColors.textSecondary,
                                ),
                              ),
                      ),
                    ),
                    title: Text(
                      name,
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: R.fontSize(context, 13),
                        fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    trailing: Checkbox(
                      value: sel,
                      activeColor: AppColors.primary,
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _selected.add(code);
                          } else {
                            _selected.remove(code);
                          }
                        });
                      },
                    ),
                    onTap: () {
                      setState(() {
                        if (sel) {
                          _selected.remove(code);
                        } else {
                          _selected.add(code);
                        }
                      });
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _selected.isEmpty
                    ? null
                    : () => widget.onSave(
                        Set<String>.from(
                          _selected.map((c) => c == 'YER' ? 'YER_NEW' : c),
                        ),
                      ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  disabledBackgroundColor: AppColors.primary.withAlpha(80),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    AppLocalizations.of(context).translate('saveChanges'),
                    maxLines: 1,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: R.fontSize(context, 14),
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectAllBtn({
    required IconData icon,
    required String label,
    required Color bg,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 42,
        padding: EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: bg.withAlpha(15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: bg.withAlpha(45)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: bg),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: R.fontSize(context, 12),
                  fontWeight: FontWeight.w700,
                  color: bg,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  SUBSCRIPTION DETAILS SHEET
// ═══════════════════════════════════════════════════════════════

/// Bottom sheet with the user's full subscription details, styled with the
/// plan identity color, and a "renew" button that jumps to payment for the
/// same plan.
class _SubscriptionDetailsSheet extends StatefulWidget {
  final Map<String, dynamic> data;
  final String identityKey;
  final VoidCallback onRenew;
  final VoidCallback onBrowse;
  const _SubscriptionDetailsSheet({
    required this.data,
    this.identityKey = '',
    required this.onRenew,
    required this.onBrowse,
  });

  @override
  State<_SubscriptionDetailsSheet> createState() =>
      _SubscriptionDetailsSheetState();
}

class _SubscriptionDetailsSheetState extends State<_SubscriptionDetailsSheet> {
  Timer? _ticker;
  Duration _remaining = Duration.zero;
  bool _hasEnd = false;

  @override
  void initState() {
    super.initState();
    _recompute();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _recompute());
  }

  void _recompute() {
    final endStr = widget.data['end_date']?.toString();
    final end = endStr != null ? DateTime.tryParse(endStr) : null;
    final rem = end != null ? end.difference(DateTime.now()) : Duration.zero;
    if (!mounted) return;
    setState(() {
      _hasEnd = end != null;
      _remaining = rem.isNegative ? Duration.zero : rem;
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final data = widget.data;
    final identityKey = widget.identityKey;
    final onRenew = widget.onRenew;
    final onBrowse = widget.onBrowse;
    final plan = data['plan_name']?.toString() ?? '';
    final status = data['status']?.toString() ?? 'pending';
    final statusText = status == 'active'
        ? l10n.translate('status_active')
        : (status == 'trial'
              ? l10n.translate('profileTrialBadge')
              : l10n.translate('profileExpiredBadge'));
    final planLabel = _planLabel(plan);
    final start = data['start_date']?.toString();
    final end = data['end_date']?.toString();
    final amount = data['plan_price']?.toString();
    final cur = data['currency']?.toString() ?? 'SAR';
    final method = _methodLabel(data['payment_method']?.toString());
    final period = data['period']?.toString() == 'monthly'
        ? l10n.translate('plansMonthly')
        : l10n.translate('plansYearly');
    final invoiceNo = data['invoice_number']?.toString();
    final bankName = data['bank_name']?.toString();
    final hasInvoice = amount != null || invoiceNo != null;
    // Free/trial plans resolve to the 'free' identity key (non-empty!) but
    // must NEVER route to payment: they are one-time and have no price.
    // Only personal/business/premium are renewable paid plans.
    final isRealPlan = identityKey.isNotEmpty && identityKey != subIdentityFree;
    final identity = status == 'trial'
        ? AppColors.success
        : subscriptionIdentityColor(
            identityKey.isNotEmpty ? identityKey : plan,
          );

    return SafeArea(
      child: SizedBox(
        width: double.infinity,
        height: double.infinity,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              SizedBox(height: 10),
              Center(
                child: Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: identity.withAlpha(22),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: identity.withAlpha(100),
                      width: 1.5,
                    ),
                  ),
                  child: Center(
                    child: HugeIcon(
                      icon: HugeIcons.strokeRoundedAward01,
                      size: 28,
                      color: identity,
                    ),
                  ),
                ),
              ),
              SizedBox(height: 8),
              Center(
                child: Text(
                  planLabel,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: identity,
                  ),
                ),
              ),
              SizedBox(height: 3),
              Center(
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: identity.withAlpha(20),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: identity.withAlpha(90)),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: identity,
                    ),
                  ),
                ),
              ),
              SizedBox(height: 18),
              if (_hasEnd) ...[
                _buildCountdown(context, l10n, identity),
                SizedBox(height: 16),
              ],
              if (hasInvoice) ...[
                _detailCard(context, l10n, [
                  if (invoiceNo != null && invoiceNo.isNotEmpty)
                    (l10n.translate('subInvoiceNo'), invoiceNo),
                  if (bankName != null && bankName.isNotEmpty)
                    (l10n.translate('subInvoiceBank'), bankName),
                  if (amount != null)
                    (l10n.translate('subInvoiceAmount'), '$amount $cur'),
                  (l10n.translate('subInvoicePaymentMethod'), method),
                  (l10n.translate('subInvoicePeriod'), period),
                  if (start != null) (l10n.translate('subInvoiceStart'), start),
                  if (end != null) (l10n.translate('subInvoiceEnd'), end),
                ]),
                SizedBox(height: 16),
              ],
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.border),
                ),
                child: Text(
                  isRealPlan
                      ? l10n.translate('subDetailsRenewHint')
                      : l10n.translate('subDetailsTrialHint'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    color: AppColors.textSecondary,
                    height: 1.5,
                  ),
                ),
              ),
              SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: isRealPlan ? onRenew : onBrowse,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: identity,
                    foregroundColor: identity == AppColors.gold
                        ? const Color(0xFF3A2E00)
                        : Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26),
                    ),
                  ),
                  icon: isRealPlan
                      ? const Icon(Icons.autorenew)
                      : const Icon(Icons.workspace_premium_outlined),
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      isRealPlan
                          ? l10n.translate('subRenewSubscription')
                          : l10n.translate('gateChoosePlan'),
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(height: 6),
              Center(
                child: GestureDetector(
                  onTap: onBrowse,
                  child: Text(
                    l10n.translate('subDetailsViewPlans'),
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
              SizedBox(height: 14),
            ],
          ),
        ),
      ),
    );
  }

  /// Live countdown (day / hour / minute / second), ticking every second.
  Widget _buildCountdown(
    BuildContext context,
    AppLocalizations l10n,
    Color identity,
  ) {
    final d = _remaining.inDays;
    final h = _remaining.inHours % 24;
    final m = _remaining.inMinutes % 60;
    final s = _remaining.inSeconds % 60;
    Widget cell(String value, String label) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: identity.withAlpha(18),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: identity.withAlpha(70)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: identity,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Text(
            l10n.translate('subCountdownTitle'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            cell('$d', l10n.translate('day')),
            const SizedBox(width: 8),
            cell(h.toString().padLeft(2, '0'), l10n.translate('hour')),
            const SizedBox(width: 8),
            cell(m.toString().padLeft(2, '0'), l10n.translate('minute')),
            const SizedBox(width: 8),
            cell(s.toString().padLeft(2, '0'), l10n.translate('second')),
          ],
        ),
      ],
    );
  }

  Widget _detailCard(
    BuildContext context,
    AppLocalizations l10n,
    List<(String, String)> rows,
  ) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.translate('subDetailsTitle'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          SizedBox(height: 8),
          for (final (k, v) in rows) ...[_detailRow(k, v), SizedBox(height: 6)],
        ],
      ),
    );
  }

  Widget _detailRow(String k, String v) {
    final identity = subscriptionIdentityColor(
      widget.identityKey.isNotEmpty
          ? widget.identityKey
          : (widget.data['plan_name']?.toString() ?? ''),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            k,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        SizedBox(width: 10),
        Flexible(
          child: Text(
            v,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: identity,
            ),
          ),
        ),
      ],
    );
  }

  String _planLabel(String? p) {
    return switch ((p ?? '').toLowerCase()) {
      'free' => AppLocalizations.t('planFree'),
      'personal' => AppLocalizations.t('planPersonal'),
      'business' => AppLocalizations.t('planBusiness'),
      'premium' => AppLocalizations.t('planPremium'),
      'trial' => AppLocalizations.t('profilePlanTrial'),
      _ => p ?? '—',
    };
  }

  String _methodLabel(String? m) {
    return switch (m) {
      'card' => 'دفع إلكتروني (بطاقة)',
      'stripe' => 'دفع إلكتروني (بطاقة)',
      'international' => 'دفع إلكتروني (بطاقة)',
      _ => 'تحويل بنكي',
    };
  }
}

// ═══════════════════════════════════════════════════════════════
//  INTERACTIVE CIRCULAR AVATAR CROP
// ═══════════════════════════════════════════════════════════════

/// Full-screen interactive crop screen that lets the user pan & pinch-zoom
/// the picked photo over a fixed circular frame, showing EXACTLY how the
/// avatar will look once applied. The visible circle == the final crop.
class _AvatarCropScreen extends ConsumerStatefulWidget {
  final Uint8List bytes;
  const _AvatarCropScreen({required this.bytes});

  @override
  ConsumerState<_AvatarCropScreen> createState() => _AvatarCropScreenState();
}

class _AvatarCropScreenState extends ConsumerState<_AvatarCropScreen> {
  late final TransformationController _transformer;
  ui.Image? _image;
  ui.Codec? _codec;
  double _imageW = 1;
  double _imageH = 1;
  double _viewW = 0;
  double _viewH = 0;
  bool _ready = false;
  bool _working = false;
  bool _initialFitDone = false;

  @override
  void initState() {
    super.initState();
    _transformer = TransformationController();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        codec.dispose();
        return;
      }
      _codec = codec;
      _image = frame.image;
      _imageW = _image!.width.toDouble();
      _imageH = _image!.height.toDouble();
      setState(() => _ready = true);
    } catch (_) {
      if (mounted) Navigator.of(context).pop(widget.bytes);
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    _codec?.dispose();
    _transformer.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    if (!_ready || _working || _image == null) return;
    setState(() => _working = true);
    try {
      final cropped = await _cropToCircle();
      if (mounted) Navigator.of(context).pop(cropped);
    } catch (_) {
      if (mounted) {
        setState(() => _working = false);
        _snack(
          AppLocalizations.of(context).translate('profileAvatarSaveFailed'),
          danger: true,
        );
      }
    }
  }

  /// Fit the whole image inside the viewport on first layout so the user
  /// starts from a predictable "what you see" state.
  void _applyInitialFit() {
    if (_initialFitDone || _viewW <= 0 || _viewH <= 0) return;
    _initialFitDone = true;
    final s0 = math.min(_viewW / _imageW, _viewH / _imageH);
    final tx = (_viewW - _imageW * s0) / 2;
    final ty = (_viewH - _imageH * s0) / 2;
    _transformer.value = Matrix4.identity()
      ..translate(tx, ty)
      ..scale(s0);
  }

  /// Crop the exact visible circle region from the original image.
  ///
  /// The InteractiveViewer child is a [SizedBox] of exactly
  /// (_imageW × _imageH) with the image rendered 1:1 inside it, and the
  /// viewer uses `constrained: false` + null alignment, so
  /// `toScene()` maps viewport points DIRECTLY to image pixel
  /// coordinates — no extra scale or offset math. What the user sees
  /// inside the circle is exactly what gets saved.
  Future<Uint8List> _cropToCircle() async {
    const outSize = 720;
    final img = _image!;
    final vw = _viewW;
    final vh = _viewH;

    // Circle radius in screen pixels — identical to the overlay painter.
    final circleR = vw.clamp(240.0, 320.0) / 2;

    // Circle center + edge in screen coords.
    final cx = vw / 2;
    final cy = vh / 2;

    // Viewport → image pixels (1:1 child mapping, see above).
    final imgCenter = _transformer.toScene(Offset(cx, cy));
    final imgRight = _transformer.toScene(Offset(cx + circleR, cy));
    final imgBottom = _transformer.toScene(Offset(cx, cy + circleR));

    final imgCx = imgCenter.dx;
    final imgCy = imgCenter.dy;
    final imgR = math.min(
      (imgRight.dx - imgCx).abs(),
      (imgBottom.dy - imgCy).abs(),
    );

    // Square crop region in image pixels.
    double x0 = imgCx - imgR;
    double y0 = imgCy - imgR;
    double side = imgR * 2;

    // Intersect the requested square with the image bounds.
    final ix0 = x0.clamp(0.0, _imageW);
    final iy0 = y0.clamp(0.0, _imageH);
    final ix1 = (x0 + side).clamp(0.0, _imageW);
    final iy1 = (y0 + side).clamp(0.0, _imageH);
    final interW = ix1 - ix0;
    final interH = iy1 - iy0;

    if (side < 2 ||
        interW <= 0 ||
        interH <= 0 ||
        (interW * interH) < (side * side * 0.25)) {
      // Circle is (mostly) outside the photo — fall back to a center
      // square crop instead of saving edge garbage.
      side = math.min(_imageW, _imageH);
      x0 = (_imageW - side) / 2;
      y0 = (_imageH - side) / 2;
    } else {
      x0 = ix0;
      y0 = iy0;
      side = math.min(interW, interH);
    }
    side = side.clamp(1.0, _imageW - x0).clamp(1.0, _imageH - y0);

    final src = ui.Rect.fromLTWH(x0, y0, side, side);
    final dst = ui.Rect.fromLTWH(0, 0, outSize.toDouble(), outSize.toDouble());

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, dst);

    // Clip to circle.
    canvas.clipPath(ui.Path()..addOval(dst));

    // Draw the cropped region stretched to fill the output square.
    canvas.drawImageRect(img, src, dst, ui.Paint());

    final picture = recorder.endRecording();
    final out = await picture.toImage(outSize, outSize);
    final byteData = await out.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    out.dispose();
    if (byteData == null) throw Exception('encode-failed');
    return byteData.buffer.asUint8List();
  }

  void _snack(String msg, {bool danger = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontFamily: 'Cairo')),
        backgroundColor: danger ? AppColors.danger : AppColors.primary,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final circleSize = screenW.clamp(240.0, 320.0);
    final childW = _imageW;
    final childH = _imageH;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          AppLocalizations.of(context).translate('avatarCropTitle'),
          style: const TextStyle(
            fontFamily: 'Cairo',
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _ready
                ? LayoutBuilder(
                    builder: (ctx, constraints) {
                      _viewW = constraints.maxWidth;
                      _viewH = constraints.maxHeight;
                      // Fit the whole photo on first layout (post-frame so
                      // layout sizes are final; only once — never fight
                      // the user's own pan/zoom afterwards).
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && _ready) _applyInitialFit();
                      });
                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          // Interactive pan/zoom photo.
                          // constrained:false + null alignment keeps the
                          // child at exactly (_imageW × _imageH) with the
                          // transform pivoting at the origin, so
                          // toScene() == image pixels (exact WYSIWYG crop).
                          InteractiveViewer(
                            transformationController: _transformer,
                            panEnabled: true,
                            scaleEnabled: true,
                            constrained: false,
                            minScale: 0.02,
                            maxScale: 8.0,
                            boundaryMargin: EdgeInsets.all(double.infinity),
                            child: SizedBox(
                              width: childW,
                              height: childH,
                              child: Image.memory(
                                widget.bytes,
                                width: childW,
                                height: childH,
                                fit: BoxFit.fill,
                              ),
                            ),
                          ),
                          // Dark overlay OUTSIDE the circle using evenOdd path.
                          IgnorePointer(
                            child: CustomPaint(
                              size: Size(
                                constraints.maxWidth,
                                constraints.maxHeight,
                              ),
                              painter: _CircleMaskPainter(
                                circleRadius: circleSize / 2,
                              ),
                            ),
                          ),
                          // White circle border.
                          IgnorePointer(
                            child: Center(
                              child: SizedBox(
                                width: circleSize,
                                height: circleSize,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2.5,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  )
                : const Center(
                    child: SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.pan_tool,
                      color: Colors.white.withAlpha(180),
                      size: 17,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        AppLocalizations.of(
                          context,
                        ).translate('avatarCropHint'),
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          color: Colors.white70,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: _working ? null : _apply,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(26),
                      ),
                    ),
                    icon: _working
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.done_rounded),
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        AppLocalizations.of(
                          context,
                        ).translate('avatarCropApply'),
                        style: const TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints a dark semi-transparent overlay with a transparent circle cutout
/// using the evenOdd fill rule — no BlendMode needed.
class _CircleMaskPainter extends CustomPainter {
  final double circleRadius;
  _CircleMaskPainter({required this.circleRadius});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRect(Offset.zero & size)
      ..addOval(
        Rect.fromCircle(
          center: Offset(size.width / 2, size.height / 2),
          radius: circleRadius,
        ),
      )
      ..fillType = PathFillType.evenOdd;

    final paint = Paint()
      ..color = Colors.black.withAlpha(170)
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CircleMaskPainter oldDelegate) =>
      oldDelegate.circleRadius != circleRadius;
}
