import '../../features/ai/domain/agent/business_device_router.dart';
import '../../features/ai/domain/agent/business_device_loop.dart';
import '../providers/platform_controls_provider.dart' show platformControlsProvider;
import '../../features/core_business/data/local_commerce/local_commerce_api.dart' show localCommerceBridgeProvider;
import '../../features/core_business/presentation/providers/business_all_branches_provider.dart' show businessAllBranchesProvider;
import 'dart:math';
import 'dart:io';
import 'dart:async';
import 'package:dio/dio.dart';
import '../../features/branches/data/branch_scope.dart';
import '../../core/router/route_names.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart' hide TextDirection;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/utils/date_formatter.dart';
import '../../core/utils/currency_formatter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/theme/app_colors.dart';
import '../../core/di/providers.dart';
import '../../core/network/api_client.dart';
import '../../core/services/currency/currency_engine.dart';
import '../../core/localization/app_localizations.dart';
import '../../core/help/information_clicker.dart';
import 'secure_image.dart';
import 'two_tone_icon.dart';
import 'two_tone_icons.dart';
import 'sara_action_dispatcher.dart';
import 'connectivity_widgets.dart';
import '../../core/services/connectivity_service.dart';
import '../../features/ai/di/ai_providers.dart';
import '../../features/auth/presentation/providers/auth_provider.dart';
import '../../features/profile/presentation/providers/avatar_provider.dart';
import '../../features/personal/di/personal_providers.dart';
import '../../features/personal/presentation/providers/personal_providers.dart' as personal_ui;
import '../../features/personal/domain/services/personal_finance_service.dart';
import '../../features/personal/data/merchant_api.dart' show MerchantApi, merchantApiProvider;
import '../../features/personal/presentation/providers/financial_tree_provider.dart' show financialTreeProvider;
import '../../features/ai/domain/agent/tool_executor.dart';
import '../../features/ai/domain/agent/agent_context.dart';
import '../../features/ai/domain/agent/param_normalizer.dart';
import '../../features/ai/domain/agent/parameter_collector.dart';
import '../../features/ai/domain/agent/confirmation_handler.dart';
import '../../features/ai/domain/agent/currency_mismatch.dart';
import '../../features/ai/domain/agent/tts_preparation.dart';
import '../../features/ai/domain/agent/tool_registry.dart';
import '../../features/ai/domain/agent/sara_screen_catalog.dart';
import '../../features/ai/domain/agent/sara_link_fallback.dart';
import '../../features/ai/domain/agent/chat_persistence.dart';
import '../../features/ai/domain/agent/sara_display.dart';
import '../../features/ai/presentation/widgets/sara_premium.dart';
import '../../features/ai/presentation/widgets/sara_sounds.dart';
import '../../features/ai/presentation/widgets/sara_ambient_controller.dart';
import '../../features/ai/presentation/widgets/sara_ambient_scene.dart';
import '../../features/profile/presentation/providers/section_profile_provider.dart';
import '../../features/branches/data/branch_api.dart';
import '../../core/utils/server_image_url.dart';
import 'package:go_router/go_router.dart';
import '../../features/ai/domain/services/ai_service.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import '../../features/branches/data/branch_pictures.dart';

/// ── Sara adaptive palette ──────────────────────────────────────────
/// Dark theme keeps the original blacks exactly as they were.
/// Light theme uses a calm soft-white with light smoky grays — every text
/// stays readable.
bool _saraLight(BuildContext context) =>
    Theme.of(context).brightness == Brightness.light;

Color _saraPageBg(BuildContext context) =>
    _saraLight(context) ? const Color(0xFFF7F5F6) : const Color(0xFF101115);

Color _saraCard(BuildContext context) =>
    _saraLight(context) ? Colors.white : const Color(0xFF1A1A1A);

Color _saraBubble(BuildContext context) =>
    _saraLight(context) ? Colors.white.withAlpha(232) : const Color(0xFF1B1C21).withAlpha(236);

Color _saraConfirmBg(BuildContext context) =>
    _saraLight(context) ? Colors.white : const Color(0xFF1E1E2E);

Color _saraLine(BuildContext context) =>
    _saraLight(context) ? const Color(0xFFE6E1E4) : const Color(0xFF2C2E35);

Color _saraText(BuildContext context) =>
    _saraLight(context) ? const Color(0xFF1B1E23) : const Color(0xFFF0F0F0);

Color _saraSub(BuildContext context) =>
    _saraLight(context) ? const Color(0xFF6B7280) : const Color(0xFF888888);

Color _saraFaint(BuildContext context) =>
    _saraLight(context) ? const Color(0xFF9AA1AB) : const Color(0xFF666666);

Color _saraAvatarBg(BuildContext context) =>
    _saraLight(context) ? const Color(0xFFE5E7EB) : const Color(0xFF1E1E1E);


Color _saraCardStrong(BuildContext context) =>
    _saraLight(context) ? const Color(0xFF23272E) : Colors.white70;

Color _saraCardSoft(BuildContext context) =>
    _saraLight(context) ? const Color(0xFF6B7280) : Colors.white54;

/// «افتح: <screen>» for a Sara link, from the live screen catalog.
String? saraRouteLinkLabel(String route, {required bool arabic}) {
  final path = SaraScreenCatalog.liveRoute(route).split('?').first;
  for (final entry in SaraScreenCatalog.entries(arabic: arabic)) {
    if (entry['route'] == path && (entry['title'] ?? '').trim().isNotEmpty) {
      return '${arabic ? 'افتح' : 'Open'}: ${entry['title']!.trim()}';
    }
  }
  return null;
}

String _cleanMarkdown(String text) {
  return text
    .replaceAll(RegExp(r'^###?\s*', multiLine: true), '')
    .replaceAllMapped(RegExp(r'\*\*(.*?)\*\*'), (m) => m[1]!)
    .replaceAllMapped(RegExp(r'\*(.*?)\*'), (m) => m[1]!)
    .replaceAll(RegExp(r'^\s*[-*]\s', multiLine: true), '• ')
    .replaceAll(RegExp(r'#+'), '')
    .trim();
}

class SaraChatPage extends ConsumerStatefulWidget {
  final String assistantName;
  final String welcomeMessage;
  final List<String> suggestedQuestions;
  final TwoToneIconData icon;
  final String typingText;
  final String inputHint;
  final bool enableFilePicker;
  final String accountType;
  /// When false, [welcomeMessage] is shown as-is (it already contains the
  /// greeting with the user name) instead of prepending "greeting, name".
  final bool prefixWelcomeWithName;

  const SaraChatPage({
    super.key,
    this.assistantName = '',
    this.welcomeMessage = '',
    this.suggestedQuestions = const [],
    this.icon = TwoToneIcons.ai,
    this.typingText = '',
    this.inputHint = 'Type your message...',
    this.enableFilePicker = false,
    this.accountType = 'personal',
    this.prefixWelcomeWithName = true,
  });

  @override
  ConsumerState<SaraChatPage> createState() => _SaraChatPageState();
}

enum MessageRole { user, assistant, typing, error, reportCard, image, audio, assistantAudio, confirmation }
enum AssistantStatus { connected, typing, thinking, preparing, recording, executing }

class _ChatMessage {
  final String id;
  final String text;
  final MessageRole role;
  final String? query;
  final DateTime time;
  final String? imagePath;
  final String? audioPath;
  final int audioDuration;
  final String? routeLink;
  final List<SaraAction> actions;

  // Confirmation card fields
  final String? confirmToolName;
  final Map<String, dynamic>? confirmParams;
  final String? confirmTitle;
  final RiskLevel? confirmRiskLevel;

  // Welcome message marker — persists but is re-localized on every open.
  final bool isWelcome;

  // P2: full memory — file/voice metadata
  final String? fileName;
  final String? mimeType;
  final int? fileSize;
  final String? transcript;
  final String? analysis;

  _ChatMessage({
    String? id,
    required this.text,
    required this.role,
    this.query,
    DateTime? time,
    this.imagePath,
    this.audioPath,
    this.audioDuration = 0,
    this.routeLink,
    this.actions = const [],
    this.confirmToolName,
    this.confirmParams,
    this.confirmTitle,
    this.confirmRiskLevel,
    this.isWelcome = false,
    this.fileName,
    this.mimeType,
    this.fileSize,
    this.transcript,
    this.analysis,
  }) : id = id ?? DateTime.now().microsecondsSinceEpoch.toString(),
       time = time ?? DateTime.now();
}

class _SaraChatPageState extends ConsumerState<SaraChatPage> with TickerProviderStateMixin {
  final _ambient = SaraAmbientController();
  final _ambientSceneKey = GlobalKey();
  final _ambientInputKey = GlobalKey();
  final _ambientAudioKey = GlobalKey();
  final _ambientUserKey = GlobalKey();
  final _ambientReplyKey = GlobalKey();
  final _composerFocus = FocusNode(debugLabel: 'Sara composer');
  String? _ambientReplyId;
  final _headerAvatarKey = GlobalKey();
  final _newReplyIds = <String>{};
  final _activeReveals = <String>{};
  late final SaraPremiumSounds _sounds;
  bool _introVisible = false;
  bool _autoFollow = true;
  SaraVisualState? _outcome;
  Timer? _outcomeTimer;
  late final String _scopeSuffix = widget.accountType == 'personal'
      ? 'personal'
      : 'business_${BranchScope.organizationId ?? 'own'}_${BranchScope.allMode ? 'all' : BranchScope.branchId ?? 'main'}';
  String _conversationKey(String userId) => '${userId}_$_scopeSuffix';
  final List<_ChatMessage> _messages = [];
  bool _messagesLoaded = false;
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _imagePicker = ImagePicker();
  final _audioRecorder = AudioRecorder();
  final _audioPlayer = AudioPlayer();
  bool _busy = false;
  String? _pendingFileName;
  XFile? _pendingImage;
  bool _isRecording = false;
  int _recordingDuration = 0;
  String? _audioPath;
  Timer? _recordingTimer;
  Timer? _waveformTimer;
  String _lastQuery = '';
  final _history = <Map<String, String>>[];
  List<String> _dynamicSuggestions = [];
  SaraActionDispatcher? _dispatcher;
  bool _showScrollDown = false;
  AssistantStatus _assistantStatus = AssistantStatus.connected;
  bool _isPlayingPreview = false;
  String? _pendingAudioPath;
  double _waveformValue = 0.0;
  late AnimationController _inputTransitionCtrl;
  String _lastScreen = '';
  String _lastOperation = '';
  final AgentContext _agentContext = AgentContext();

  // ── Voice Agent (TTS) settings ──
  static const _saraSpeed = 1.0;
  bool _isSpeaking = false;
  bool _isVoiceMessage = false;

  // NOTE: canned casual replies were removed — every turn flows to the real
  // path (route continuation → collecting → confirmation → backend), so
  // follow-ups like "تمام" or "شكراً" are never swallowed. The localization
  // keys (saraGreeting*, saraThanks*, ...) stay in AR/EN files untouched.

  @override
  void didUpdateWidget(SaraChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the app language changed while the chat is open, the parent
    // rebuilds and passes a new welcomeMessage — refresh the welcome bubble
    // so it follows the language immediately.
    if (oldWidget.welcomeMessage != widget.welcomeMessage &&
        _messagesLoaded &&
        _messages.isNotEmpty) {
      _refreshWelcomeIfPersisted();
    }
  }

  @override
  void initState() {
    super.initState();
    _composerFocus.addListener(_ambientFocusChanged);
    _sounds = SaraPremiumSounds(_getUserId());
    _sounds.ready.then((_) { if (mounted) setState(() {}); });
    WidgetsBinding.instance.addPostFrameCallback((_) => _startEncounter());
    _inputTransitionCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _loadMessages();
    _scrollCtrl.addListener(() {
      final max = _scrollCtrl.position.maxScrollExtent;
      final current = _scrollCtrl.position.pixels;
      _ambient.scroll(current);
      _autoFollow = max - current < 110;
      final show = max > 0 && max - current > 300;
      if (show != _showScrollDown) setState(() => _showScrollDown = show);
    });
    // Offline guard: Sara (AI Assistant) needs the network to talk to the
    // cloud. Show a centered modal and DO NOT enter the conversation UI.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        final connectivity = ref.read(connectivityServiceProvider);
        if (!connectivity.isOnline) {
          final retryOk = await showOfflineDialog(
            context,
            title: AppLocalizations.of(context).translate('noInternet'),
            buttonLabel: AppLocalizations.of(context).translate('retry'),
            connectivity: connectivity,
          );
          if (retryOk && mounted) {
            // Internet restored — reload messages
            _loadMessages();
          }
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _composerFocus.removeListener(_ambientFocusChanged);
    _composerFocus.dispose();
    _ambient.dispose();
    _sounds.dispose();
    _outcomeTimer?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _recordingTimer?.cancel();
    _waveformTimer?.cancel();
    _inputTransitionCtrl.dispose();
    super.dispose();
  }

  String _getUserId() {
    // Dispose-proof: ref.read throws after dispose, and background
    // continuations run after the user leaves the chat. Cache the id while
    // mounted and fall back to it — never let persistence die silently.
    try {
      final user = ref.read(authProvider).user;
      final id = user?.id.toString() ?? 'guest';
      _cachedUserId = id;
      return id;
    } catch (_) {
      return _cachedUserId ?? 'guest';
    }
  }

  /// Last known user id, captured while mounted (see [_getUserId]).
  String? _cachedUserId;

  /// Permanent folder for Sara's audio (recordings + TTS replies).
  ///
  /// Lives under [getApplicationDocumentsDirectory] so files survive app
  /// restarts and OS temp-dir cleanups — recordings always replay.
  Future<Directory> _permanentAudioDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/sara_audio');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Current chat language ('ar' / 'en'). All assistant-authored strings
  /// (tool results, slot questions, confirmations) follow it.
  String _chatLang() {
    try {
      return AppLocalizations.of(context).locale.languageCode == 'en' ? 'en' : 'ar';
    } catch (_) {
      return 'ar';
    }
  }

  bool _isEn() => _chatLang() == 'en';

  /// Picks the localized side of an agent tool result.
  String _toolText(String ar, String en) => _isEn() ? en : ar;

  /// True when [s] is the instructional voice placeholder (saraVoiceQuery,
  /// AR/EN) rather than real user words. Such notes are backend query text
  /// only and must never render under a voice bubble.
  bool _isVoiceNote(String s) =>
      s.contains('استمع إليها') || s.contains('listen to it');

  /// Builds a fully-wired ToolExecutor: gateway server-confirmation via the
  /// app API client and real FX rates via the currency engine. Both are
  /// best-effort — the gateway degrades honestly without them.
  ToolExecutor _wiredExecutor(PersonalFinanceService financeService) {
    ApiClient? api;
    CurrencyEngine? fx;
    try {
      api = ref.read(apiClientProvider);
    } catch (_) {}
    try {
      fx = ref.read(currencyEngineProvider);
    } catch (_) {}
    ProviderContainer? container;
    try {
      container = ProviderScope.containerOf(context, listen: false);
    } catch (_) {}
    MerchantApi? merchants;
    try {
      merchants = ref.read(merchantApiProvider);
    } catch (_) {}
    return ToolExecutor(financeService, apiClient: api, fxEngine: fx,
        merchantApi: merchants,
        // The tree screens hold their nodes in memory: reload after Sara.
        onTreesChanged: () async {
          final trees = container?.read(financialTreeProvider.notifier);
          if (trees == null) return;
          final open = container?.read(financialTreeProvider).currentTreeId;
          await (open != null ? trees.openTree(open) : trees.refresh());
        },
        maintenanceBlocked: (feature) {
          try {
            final controls = container?.read(platformControlsProvider).valueOrNull;
            return controls != null && (controls.isAppMaintenance || controls.isRouteUnderMaintenance(feature));
          } catch (_) {
            return false;
          }
        });
  }

  Future<void> _loadMessages() async {
    if (_messagesLoaded) return;
    final userId = _getUserId();
    final key = _conversationKey(userId);
    final persistMsgs = await ChatPersistence.instance.loadMessages(key);
    if (!mounted) return;
    if (persistMsgs.isNotEmpty) {
      setState(() {
        _messages.clear();
        _history.clear();
        for (final pm in persistMsgs) {
          if (pm.isWelcome) {
            _messages.add(_ChatMessage(
              id: pm.id, text: pm.text, role: MessageRole.assistant,
              time: pm.time, isWelcome: true,
            ));
            continue;
          }
          final role = MessageRole.values.firstWhere(
            (r) => r.name == pm.role, orElse: () => MessageRole.assistant);
          // Skip error/typing/reportCard from history for LLM
          final histRole = role == MessageRole.user || role == MessageRole.image || role == MessageRole.audio
              ? 'user' : role == MessageRole.assistant || role == MessageRole.assistantAudio ? 'assistant' : null;
          // Rebuild display text for voice/image/file from persisted transcript/fileName
          String displayText = pm.text;
          if (pm.messageType == 'voice' && (pm.transcript ?? '').isNotEmpty) {
            // Legacy instructional notes (saraVoiceQuery) were once persisted
            // as transcripts — never render them; keep the bubble title.
            displayText = _isVoiceNote(pm.transcript!) ? pm.text : pm.transcript!;
          }
          _messages.add(_ChatMessage(
            id: pm.id, text: displayText, role: role, time: pm.time,
            routeLink: pm.routeLink,
            actions: pm.actions.map((a) => SaraAction(
              type: SaraActionType.values.firstWhere((t) => t.name == (a['type'] ?? ''), orElse: () => SaraActionType.openEntity),
              params: Map<String, dynamic>.from(a['params'] as Map? ?? const {}), label: a['label'] as String?,
            )).toList(),
            imagePath: pm.imagePath, audioPath: pm.audioPath, audioDuration: pm.audioDuration,
            isWelcome: pm.isWelcome, fileName: pm.fileName, mimeType: pm.mimeType,
            fileSize: pm.fileSize, transcript: pm.transcript, analysis: pm.analysis,
          ));
          if (histRole != null) {
            // For LLM history, use the real textual content (transcript for voice, analysis for image/file if present)
            String histContent = pm.transcript != null && pm.transcript!.isNotEmpty ? pm.transcript! : pm.text;
            if ((pm.analysis ?? '').isNotEmpty) {
              histContent = histContent.isNotEmpty ? '$histContent\n[analysis: ${pm.analysis}]' : pm.analysis!;
            }
            if (histContent.trim().isNotEmpty) {
              _history.add({'role': histRole, 'content': histContent});
            } else if ((pm.imagePath ?? '').isNotEmpty) {
              _history.add({'role': 'user', 'content': '[image: ${pm.fileName ?? 'image'}]'});
            } else if ((pm.audioPath ?? '').isNotEmpty) {
              _history.add({'role': histRole, 'content': histContent.isNotEmpty ? histContent : displayText});
            }
          }
        }
        _messagesLoaded = true;
      });
      _refreshWelcomeIfPersisted();
      _migratePersistedMedia();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollDown());
    } else {
      setState(() => _messagesLoaded = true);
      WidgetsBinding.instance.addPostFrameCallback((_) => _addWelcome());
    }
  }

  Future<void> _saveMessages() async {
    final userId = _getUserId();
    final key = _conversationKey(userId);
    final conversationId = key;
    final persistMsgs = _messages.where((m) => m.role != MessageRole.typing).map((m) => ChatPersistMessage(
      id: m.id, text: m.text, role: m.role.name, time: m.time,
      routeLink: m.routeLink,
      actions: m.actions.map((a) => {'type': a.type.name, 'params': a.params, 'label': a.label}).toList(),
      imagePath: m.imagePath, audioPath: m.audioPath, audioDuration: m.audioDuration,
      isWelcome: m.isWelcome,
      conversationId: conversationId, userId: userId, accountType: widget.accountType,
      messageType: m.role == MessageRole.audio ? 'voice' : m.role == MessageRole.image ? 'image' : m.role == MessageRole.assistantAudio ? 'assistant_voice' : m.fileName != null ? 'file' : 'text',
      transcript: m.transcript,
      fileName: m.fileName, mimeType: m.mimeType, fileSize: m.fileSize, analysis: m.analysis,
    )).toList();
    await ChatPersistence.instance.saveMessages(key, persistMsgs);
  }

  /// Bounded retrieval: recent 6 + up to 4 relevant older messages for the current query.
  /// Excludes the current user turn (already in _history as last entry) — history
  /// should be previous context only. Never rewrites originals.
  List<Map<String, String>> _buildHistoryForLLM(String currentQuery) {
    if (_history.isEmpty) return [];
    // Exclude the current user turn that was just appended to _history
    final historyWithoutCurrent = _history.length > 1 &&
            _history.last['role'] == 'user' &&
            _history.last['content'] == currentQuery
        ? _history.sublist(0, _history.length - 1)
        : List.of(_history);
    if (historyWithoutCurrent.isEmpty) return [];
    const recentCount = 6;
    const relevantCount = 4;
    if (historyWithoutCurrent.length <= recentCount + relevantCount) {
      return List.of(historyWithoutCurrent);
    }
    final recent = historyWithoutCurrent.sublist(historyWithoutCurrent.length - recentCount);
    if (currentQuery.trim().isEmpty) return recent;
    final q = currentQuery.toLowerCase();
    final keywords = q.split(RegExp(r'\s+')).where((w) => w.length > 2).toSet();
    final older = historyWithoutCurrent.sublist(0, historyWithoutCurrent.length - recentCount);
    final scored = <int, int>{};
    for (var i = 0; i < older.length; i++) {
      final content = older[i]['content']?.toLowerCase() ?? '';
      int score = 0;
      for (final kw in keywords) {
        if (content.contains(kw)) score++;
      }
      if (q.contains('صورة') || q.contains('image')) {
        if (content.contains('[image') || content.contains('صورة')) score += 2;
      }
      if (q.contains('ملف') || q.contains('file')) {
        if (content.contains('file') || content.contains('ملف') || content.contains('[file')) score += 2;
      }
      if (q.contains('مبلغ') || q.contains('amount') || q.contains('راتب') || q.contains('ميزانية') || q.contains('budget')) {
        if (RegExp(r'\d').hasMatch(content)) score += 1;
      }
      if (RegExp(r'\d').hasMatch(q) && RegExp(r'\d').hasMatch(content)) score += 1;
      if (score > 0) scored[i] = score;
    }
    final sorted = scored.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final relevant = sorted.take(relevantCount).map((e) => older[e.key]).toList();
    relevant.sort((a, b) {
      final ia = older.indexOf(a);
      final ib = older.indexOf(b);
      return ia.compareTo(ib);
    });
    return [...relevant, ...recent];
  }

  /// Copies any audio/image that still lives under the temporary directory
  /// into the permanent media folder, then persists the updated paths so
  /// replays keep working across restarts.
  Future<void> _migratePersistedMedia() async {
    try {
      final userId = _getUserId();
      final key = _conversationKey(userId);
      final tempDir = await getTemporaryDirectory();
      final tempPrefix = tempDir.path;
      final permanentDir = await _permanentAudioDir();
      var changed = false;

      final migrated = _messages.map((m) {
        var audio = m.audioPath;
        var image = m.imagePath;
        if (audio != null && audio.isNotEmpty) {
          final src = File(audio);
          if (src.existsSync() && audio.startsWith(tempPrefix)) {
            final dest = File('${permanentDir.path}/${src.uri.pathSegments.last}');
            if (!dest.existsSync()) {
              try { src.copySync(dest.path); } catch (_) {}
            }
            if (dest.existsSync()) {
              audio = dest.path;
              changed = true;
            }
          }
        }
        if (image != null && image.isNotEmpty) {
          final src = File(image);
          if (src.existsSync() && image.startsWith(tempPrefix)) {
            final dest = File('${permanentDir.path}/${src.uri.pathSegments.last}');
            if (!dest.existsSync()) {
              try { src.copySync(dest.path); } catch (_) {}
            }
            if (dest.existsSync()) {
              image = dest.path;
              changed = true;
            }
          }
        }
        return _ChatMessage(
          id: m.id,
          text: m.text,
          role: m.role,
          time: m.time,
          routeLink: m.routeLink,
          actions: m.actions,
          imagePath: image,
          audioPath: audio,
          audioDuration: m.audioDuration,
          confirmToolName: m.confirmToolName,
          confirmParams: m.confirmParams,
          confirmTitle: m.confirmTitle,
          confirmRiskLevel: m.confirmRiskLevel,
          isWelcome: m.isWelcome,
        );
      }).toList();

      if (changed && mounted) {
        _messages
          ..clear()
          ..addAll(migrated);
        await _saveMessages();
      }
    } catch (e) {
      debugPrint('migratePersistedMedia error: $e');
    }
  }

  void _addWelcome() {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    String msg = widget.welcomeMessage.isNotEmpty ? widget.welcomeMessage : l10n.translate('saraDefaultWelcome');
    if (widget.prefixWelcomeWithName) {
      final user = ref.read(authProvider).user;
      final name = user?.fullName ?? '';
      final firstName = name.split(' ').firstWhere((s) => s.isNotEmpty, orElse: () => '');
      msg = msg.replaceAll('{name}', firstName);
    }
    setState(() {
      _messages.clear();
      _messages.add(_ChatMessage(text: msg, role: MessageRole.assistant, isWelcome: true));
    });
    _saveMessages();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollDown());
  }

  /// Replaces the stored welcome bubble with the CURRENT-language version so
  /// switching the app language updates Sara's greeting immediately.
  ///
  /// Detects the welcome even for legacy conversations saved before the
  /// `isWelcome` flag existed (first assistant message with no prior user msg).
  void _refreshWelcomeIfPersisted() {
    if (_messages.isEmpty) return;
    var idx = _messages.indexWhere((m) => m.isWelcome);
    if (idx < 0) {
      // Legacy: first assistant bubble with no user message before it.
      final first = _messages.first;
      if (first.role == MessageRole.assistant) idx = 0;
    }
    if (idx < 0) return;
    final l10n = AppLocalizations.of(context);
    String msg = widget.welcomeMessage.isNotEmpty ? widget.welcomeMessage : l10n.translate('saraDefaultWelcome');
    if (widget.prefixWelcomeWithName) {
      final user = ref.read(authProvider).user;
      final name = user?.fullName ?? '';
      final firstName = name.split(' ').firstWhere((s) => s.isNotEmpty, orElse: () => '');
      msg = msg.replaceAll('{name}', firstName);
    }
    final existing = _messages[idx];
    _messages[idx] = _ChatMessage(
      id: existing.id,
      text: msg,
      role: MessageRole.assistant,
      time: existing.time,
      isWelcome: true,
    );
    _saveMessages();
  }

  void _scrollDown() {
    if (!_autoFollow) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients && mounted) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  String _getStatusText(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    switch (_assistantStatus) {
      case AssistantStatus.connected: return l10n.translate('statusConnected');
      case AssistantStatus.typing: return l10n.translate('statusTyping');
      case AssistantStatus.thinking: return l10n.translate('statusThinking');
      case AssistantStatus.preparing: return l10n.translate('statusPreparing');
      case AssistantStatus.recording: return l10n.translate('saraRecordingStatus');
      case AssistantStatus.executing: return _isEn() ? 'Executing…' : 'جاري التنفيذ…';
    }
  }

  Future<void> _startEncounter() async {
    final first = await SaraWelcomeLedger.claim(_getUserId());
    if (!mounted || !first) return;
    setState(() => _introVisible = true);
    unawaited(_sounds.play(SaraSound.welcome));
  }

  SaraVisualState get _visualState {
    if (_outcome != null) return _outcome!;
    if (_assistantStatus == AssistantStatus.executing) return SaraVisualState.executing;
    if (_activeReveals.isNotEmpty) return SaraVisualState.typing;
    if (_busy && _assistantStatus != AssistantStatus.connected) return SaraVisualState.thinking;
    return SaraVisualState.ready;
  }

  void _ambientFocusChanged() => _ambient.focus(_composerFocus.hasFocus);

  SaraAmbientActivity get _ambientActivity {
    if (_ambient.operationActive) return SaraAmbientActivity.executing;
    if (_busy && _assistantStatus != AssistantStatus.connected) return SaraAmbientActivity.thinking;
    if (_activeReveals.isNotEmpty) return SaraAmbientActivity.responding;
    return SaraAmbientActivity.none;
  }

  Offset _ambientPoint(Offset global) {
    final box = _ambientSceneKey.currentContext?.findRenderObject();
    return box is RenderBox ? box.globalToLocal(global) : Offset.zero;
  }

  bool _ambientReplyVisible(String id) {
    if (_ambientReplyId != id) return false;
    final origin = _ambientSceneKey.currentContext?.findRenderObject();
    final reply = _ambientReplyKey.currentContext?.findRenderObject();
    if (origin is! RenderBox || reply is! RenderBox || !origin.hasSize || !reply.hasSize) return false;
    final point = origin.globalToLocal(reply.localToGlobal(Offset.zero));
    final input = (_pendingAudioPath != null ? _ambientAudioKey : _ambientInputKey).currentContext?.findRenderObject();
    final bottom = input is RenderBox && input.hasSize
        ? origin.globalToLocal(input.localToGlobal(Offset.zero)).dy - 8 : origin.size.height;
    return (point & reply.size).overlaps(Rect.fromLTWH(0, 0, origin.size.width, max(0.0, bottom)));
  }

  ({int generation, int? operation, bool write}) _ambientToolStarted(String name, {int? generation}) {
    final write = AgentToolRegistry.findByName(name)?.category == ToolCategory.write;
    if (generation != null && generation != _ambient.generation) return (generation: generation, operation: null, write: write);
    final operation = write ? _ambient.beginOperation() : null;
    return (generation: _ambient.generation, operation: operation, write: write);
  }

  void _ambientToolFinished(ToolExecutionResult result, ({int generation, int? operation, bool write}) work) {
    if (work.generation != _ambient.generation || !_ambient.hasRequest) return;
    final pending = const {'local_pending', 'unverifiable', 'pending'}.contains(result.verificationStatus);
    if (work.write && work.operation != null) {
      _ambient.finishOperation(confirmed: result.success && result.verified && result.verificationStatus == 'confirmed',
          failed: !result.success && !pending, token: work.operation);
    } else if (!work.write && !result.success && !pending) {
      _ambient.error(generation: work.generation);
    }
  }

  void _flashOutcome(bool success) {
    if (!mounted) return;
    _outcomeTimer?.cancel();
    setState(() => _outcome = success ? SaraVisualState.success : SaraVisualState.error);
    unawaited(_sounds.play(success ? SaraSound.success : SaraSound.error));
    _outcomeTimer = Timer(const Duration(milliseconds: 750), () { if (mounted) setState(() => _outcome = null); });
  }

  String _friendlyError(Object e, AppLocalizations l10n) {
    if (e is DioException) {
      final status = e.response?.statusCode;
      final data = e.response?.data;
      final detail = data is Map ? data['message'] ?? data['detail'] : null;
      final ar = l10n.locale.languageCode != 'en';
      if (status == 403) return ar
          ? (detail is String && RegExp('[ء-ي]').hasMatch(detail) ? detail : 'هذه العملية غير مسموحة في نطاقك الحالي.')
          : 'This operation is not permitted in the current scope.';
      if (status == 422) return ar
          ? (detail is String && RegExp('[ء-ي]').hasMatch(detail) ? detail : 'تعذر قراءة الطلب. تحقق من البيانات أو أعد تسجيل الرسالة بوضوح.')
          : 'The request could not be read. Check the details or send a clearer recording.';
    }
    final s = e.toString();
    if (s.toLowerCase().contains('timeout') || s.contains('timed out')) {
      return '${l10n.translate('errorTimeout')}.';
    }
    if (s.toLowerCase().contains('connection') || s.toLowerCase().contains('socket') || s.contains('Failed host lookup')) {
      return '${l10n.translate('errorConnectionFailed')}.';
    }
    if (s.contains('403')) return _toolText('هذه العملية غير مسموحة في نطاقك الحالي.', 'This operation is not permitted in the current scope.');
    if (s.contains('401')) {
      return '${l10n.translate('errorSessionExpiredChat')}.';
    }
    if (s.contains('500')) {
      return '${l10n.translate('errorServerTemporary')}.';
    }
    return '${l10n.translate('errorUnexpectedChat')}.';
  }

  /// Pending bank name waiting for currency disambiguation in a direct
  /// delete-bank command (multi-currency bank).
  String? _pendingDeleteBank;

  /// Pending account/currency mismatch: the executor refused a write because
  /// the requested currency differs from the target account's own currency.
  /// The next user message is parsed as a numbered choice — never executed.
  _MismatchPending? _pendingMismatch;

  /// Arabic-agnostic normalization for entity name matching.
  String _normAr(String s) {
    var t = s.replaceAll(RegExp(r'[أإآ]'), 'ا').replaceAll('ة', 'ه').replaceAll('ى', 'ي');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.startsWith('ال') && t.length > 4) t = t.substring(2);
    return t;
  }

  static const _deleteVerbsAr = ['احذف', 'احذفي', 'امسح', 'امسحي', 'حذف', 'مسح', 'ازاله', 'ازالة', 'إزالة'];
  static const _deleteVerbsEn = ['delete', 'remove', 'del'];
  static const _bankWordsAr = ['بنك', 'بنوك', 'حساب', 'حسابات'];
  static const _bankWordsEn = ['bank', 'banks', 'account', 'accounts'];
  // Other entities: never hijack their commands, let the backend handle them.
  static const _otherEntityAr = ['هدف', 'اهداف', 'أهداف', 'دين', 'ديون', 'ميزاني', 'مصروف', 'مصاريف', 'راتب', 'فاتوره', 'فاتورة', 'تقرير', 'عميل'];
  static const _otherEntityEn = ['goal', 'debt', 'budget', 'expense', 'salary', 'invoice', 'report', 'client', 'customer'];
  static const _stripTokensAr = [
    'ادخلي', 'ادخل', 'ادخلو', 'روحي', 'روح', 'افتحي', 'افتح', 'انتقلي', 'انتقل',
    'الى', 'إلى', 'علي', 'على', 'قسم', 'البنوك', 'بنوك', 'قومي', 'قوم', 'قم',
    'من', 'في', 'لو', 'سمحت', 'سمحتي', 'فضل', 'فضلك', 'فضلا', 'يا', 'ساره', 'سارة',
    'هذ', 'هذا', 'هذه', 'اللي', 'الذي', 'التي', 'عايز', 'عايزه', 'ابغى', 'ابغي', 'اريد', 'أريد',
    'بنك', 'البنك', 'حساب', 'الحساب', 'احذف', 'احذفي', 'امسح', 'امسحي', 'حذف', 'مسح',
  ];
  static const _stripTokensEn = [
    'delete', 'remove', 'del', 'bank', 'banks', 'account', 'accounts',
    'the', 'a', 'an', 'please', 'sara', 'go', 'to', 'open', 'section', 'from', 'my',
  ];
  static const _cancelWords = ['إلغاء', 'الغاء', 'بطلت', 'خلاص لا', 'cancel', 'never mind'];

  /// Direct in-app bank commands (e.g. "احذفي بنك الكريمي"): resolve the
  /// bank locally and run the standard confirmation → execution flow, so
  /// destructive requests are never deflected. Returns true when handled.
  Future<bool> _tryDirectBankCommand(String msg) async {
    final q = msg.trim();
    if (q.isEmpty) return false;
    final ql = q.toLowerCase();

    // Cancel words abort a pending disambiguation.
    if (_pendingDeleteBank != null &&
        _cancelWords.any((w) => ql.contains(w.toLowerCase()))) {
      _pendingDeleteBank = null;
      _agentContext.cancel();
      setState(() {
        _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
        _addAssistantMessage(AppLocalizations.of(context).translate('saraOpCancelled'));
        _inputCtrl.clear();
      });
      _saveMessages();
      _scrollDown();
      return true;
    }

    final stop = <String>{..._stripTokensAr, ..._stripTokensEn};
    final tokens = ql.split(RegExp(r'\s+')).map((t) {
      var w = t;
      if (w.startsWith('و') && w.length > 3) w = w.substring(1);
      if (w.startsWith('ب') && w.length > 4) w = w.substring(1);
      if (w.startsWith('ال') && w.length > 5 && stop.contains(w.substring(2))) {
        w = w.substring(2);
      }
      return w;
    }).toList();
    final hasDeleteVerb = tokens.any((t) =>
        _deleteVerbsAr.contains(t) || _deleteVerbsEn.contains(t));
    final hasBankWord = tokens.any((t) =>
        _bankWordsAr.contains(t) || _bankWordsEn.contains(t));

    // Pending disambiguation: user is answering with a currency/choice.
    if (_pendingDeleteBank != null && !hasDeleteVerb) {
      if (_otherEntityAr.any((w) => ql.contains(w)) ||
          _otherEntityEn.any((w) => ql.contains(w))) {
        _pendingDeleteBank = null; // new topic — release the pending bank
        return false;
      }
      return await _resolvePendingDeleteBank(msg);
    }

    // Never hijack other entities' commands.
    if (_otherEntityAr.any((w) => ql.contains(w)) ||
        _otherEntityEn.any((w) => ql.contains(w))) {
      _pendingDeleteBank = null;
      return false;
    }
    if (!hasDeleteVerb || !hasBankWord) return false;

    // Extract the bank name candidate by stripping command words.
    final nameParts = tokens.where((t) => !stop.contains(t)).toList();
    final candidate = nameParts.join(' ').trim();
    if (candidate.isEmpty) {
      _pendingDeleteBank = null;
      return false; // nothing to resolve — let backend ask/route
    }
    return await _startDeleteBankFlow(msg, candidate);
  }

  /// Resolve [candidate] to a bank and either confirm deletion or ask for
  /// the currency when the bank holds several accounts.
  Future<bool> _startDeleteBankFlow(String msg, String candidate) async {
    final en = _isEn();
    List accounts;
    try {
      accounts = await ref.read(personalFinanceServiceProvider).getBankAccounts();
    } catch (_) {
      return false;
    }
    final bankNames = <String>[];
    for (final a in accounts) {
      final n = (a.bankName ?? '').toString();
      if (n.isNotEmpty && !bankNames.contains(n)) bankNames.add(n);
    }
    final normC = _normAr(candidate);
    final matched = bankNames.where((n) {
      final normB = _normAr(n);
      return normB == normC || normB.contains(normC) || (normC.length > 2 && normC.contains(normB));
    }).toList();

    setState(() {
      _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
      _inputCtrl.clear();
    });

    if (matched.isEmpty) {
      final list = bankNames.isEmpty
          ? (en ? 'No bank accounts found.' : 'لا توجد حسابات بنكية.')
          : (en ? 'Available banks: ${bankNames.join(', ')}' : 'البنوك الحالية: ${bankNames.join('، ')}');
      setState(() {
        _addAssistantMessage((en
                ? 'I could not find a bank named "$candidate". '
                : 'لم أجد بنكاً باسم "$candidate". ') +
            list);
      });
      _saveMessages();
      _scrollDown();
      return true;
    }

    // Prefer exact normalized match when several contain the word.
    String bank = matched.first;
    for (final m in matched) {
      if (_normAr(m) == normC) {
        bank = m;
        break;
      }
    }
    final bankAccs = accounts.where((a) => (a.bankName ?? '').toString() == bank).toList();
    if (bankAccs.length == 1) {
      _pendingDeleteBank = null;
      _askDeleteBankConfirm(bankAccs.first);
      return true;
    }
    // Multi-currency bank: ask which currency, keep the bank pending.
    _pendingDeleteBank = bank;
    final opts = bankAccs
        .map((a) => '${(a.currency ?? '').toString()} (${_fmtAmt(a.balance)})')
        .toSet()
        .join(en ? ' / ' : ' / ');
    setState(() {
      _addAssistantMessage(en
          ? 'Bank "$bank" has ${bankAccs.length} accounts ($opts). Which currency should I delete? Reply with the currency, or cancel.'
          : 'بنك "$bank" لديه ${bankAccs.length} حسابات ($opts). أي عملة تريد حذفها؟ رد باسم العملة، أو اكتب إلغاء.');
    });
    _saveMessages();
    _scrollDown();
    return true;
  }

  /// User replied while a multi-currency bank deletion is pending.
  Future<bool> _resolvePendingDeleteBank(String msg) async {
    final bank = _pendingDeleteBank!;
    final ql = msg.trim().toLowerCase();
    List accounts;
    try {
      accounts = await ref.read(personalFinanceServiceProvider).getBankAccounts();
    } catch (_) {
      return false;
    }
    var bankAccs = accounts.where((a) => (a.bankName ?? '').toString() == bank).toList();
    if (bankAccs.isEmpty) {
      _pendingDeleteBank = null;
      return false;
    }
    // Numbered choice: 1 / 2 / الأول / الثاني ...
    const ordAr = ['الأول', 'الاول', 'الثاني', 'الثالث', 'الرابع'];
    int? pick;
    final digit = RegExp(r'(\d+)').firstMatch(ql);
    if (digit != null) {
      pick = int.tryParse(digit.group(1)!);
    } else {
      for (var i = 0; i < ordAr.length; i++) {
        if (ql.contains(_normAr(ordAr[i]))) {
          pick = i + 1;
          break;
        }
      }
    }
    if (pick != null && pick >= 1 && pick <= bankAccs.length) {
      final acc = bankAccs[pick - 1];
      setState(() {
        _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
        _inputCtrl.clear();
      });
      _pendingDeleteBank = null;
      _askDeleteBankConfirm(acc);
      return true;
    }
    // Currency match (code or Arabic alias).
    final normQ = _normAr(ql);
    final byCur = bankAccs.where((a) {
      final c = (a.currency ?? '').toString();
      final nc = _normAr(c.toLowerCase());
      return nc == normQ ||
          normQ.contains(nc) ||
          _currencyAliases(c).any((al) => normQ.contains(_normAr(al)));
    }).toList();
    setState(() {
      _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
      _inputCtrl.clear();
    });
    if (byCur.length == 1) {
      _pendingDeleteBank = null;
      _askDeleteBankConfirm(byCur.first);
      return true;
    }
    if (byCur.length > 1) {
      final en = _isEn();
      final opts = <String>[];
      for (var i = 0; i < byCur.length; i++) {
        opts.add('${i + 1}. ${(byCur[i].currency ?? '').toString()} (${_fmtAmt(byCur[i].balance)})');
      }
      setState(() {
        _addAssistantMessage((en ? 'Multiple accounts match. Choose one: ' : 'يوجد عدة حسابات مطابقة. اختر واحداً: ') + opts.join('، '));
      });
      _saveMessages();
      _scrollDown();
      return true;
    }
    // No match — re-ask once, keep pending.
    final en = _isEn();
    final opts = bankAccs.map((a) => (a.currency ?? '').toString()).toSet().join(' / ');
    setState(() {
      _addAssistantMessage(en
          ? 'Please reply with one of these currencies: $opts (or cancel).'
          : 'فضلاً رد بإحدى هذه العملات: $opts (أو اكتب إلغاء).');
    });
    _saveMessages();
    _scrollDown();
    return true;
  }

  /// Arabic/English aliases for common currency codes.
  List<String> _currencyAliases(String code) {
    switch (code.toUpperCase()) {
      case 'SAR':
        return ['sar', 'ريال سعودي', 'سعودي', 'ر.س'];
      case 'USD':
        return ['usd', 'دولار', 'امريكي', 'أمريكي', r'$'];
      case 'EUR':
        return ['eur', 'يورو', 'اوروبي', 'أوروبي'];
      case 'AED':
        return ['aed', 'درهم', 'اماراتي'];
      case 'EGP':
        return ['egp', 'جنيه', 'مصري'];
      case 'KWD':
        return ['kwd', 'دينار كويتي', 'كويتي'];
      case 'YER':
      case 'YER_OLD':
        return ['yer', 'yer_old', 'ريال يمني', 'يمني', 'قديم'];
      case 'YER_NEW':
        return ['yer_new', 'ريال يمني جديد', 'جديد', 'عدني'];
      default:
        return [code.toLowerCase()];
    }
  }

  String _fmtAmt(dynamic v) {
    final d = v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
    final s = fmtNum(d);
    return s.endsWith('.00') ? s.substring(0, s.length - 3) : s;
  }

  /// Show the standard irreversible-operation confirmation, then let the
  /// existing awaiting-confirmation flow execute it.
  void _askDeleteBankConfirm(dynamic acc) {
    final en = _isEn();
    final bank = (acc.bankName ?? '').toString();
    final cur = (acc.currency ?? '').toString();
    final bal = _fmtAmt(acc.balance);
    final id = (acc.id ?? '').toString();
    _agentContext.cancel();
    _pendingDeleteBank = null;
    _agentContext.startCollecting('delete_bank_account');
    _agentContext.updateCollectedParams({'account_id': id});
    _agentContext.startConfirmation();
    setState(() {
      _addAssistantMessage(en
          ? '⚠️ You are about to permanently delete bank "$bank" ($cur, balance $bal)!\n🔴 Warning: this cannot be undone!\nProceed? (yes / no)'
          : '⚠️ أنت على وشك حذف بنك "$bank" (عملة $cur، رصيد $bal) نهائياً!\n🔴 تحذير: لا يمكن التراجع عن الحذف!\nهل أنت متأكد؟ (نعم / لا)');
    });
    _saveMessages();
    _scrollDown();
  }

  Future<void> _sendBusiness(String message, {required int visualGeneration}) async {
    var effectGeneration = visualGeneration;
    final api = ref.read(aiServiceProvider);
    final network = ref.read(apiClientProvider);
    final scope = BranchScope.token;
    final saveKey = _conversationKey(_getUserId());
    final audio = _audioPath;
    final image = _pendingImage?.path;
    final query = message;
    final language = _chatLang();
    final catalog = SaraScreenCatalog.entries(arabic: language != 'en');
    setState(() {
      _busy = true;
      _assistantStatus = AssistantStatus.thinking;
      _messages.add(_ChatMessage(text: query.isEmpty ? (image != null ? 'صورة مرفقة' : 'رسالة صوتية') : query,
          role: audio != null ? MessageRole.audio : image != null ? MessageRole.image : MessageRole.user,
          audioPath: audio, imagePath: image));
      _inputCtrl.clear();
      _audioPath = null;
      _pendingImage = null;
      _pendingFileName = null;
    });
    await _saveMessages();
    _scrollDown();
    try {
      if (!mounted || BranchScope.token != scope) return;
      // Device-ledger branch: Sara's reads and operations are answered by
      // this phone (same APIs as the buttons), never by the server.
      final deviceRoutes = ref.read(localCommerceBridgeProvider).active
          ? BusinessDeviceRouter.supportedRoutes
          // «جميع الفروع» on the device: every branch's data, reads only.
          : ref.read(businessAllBranchesProvider) != null
          ? BusinessDeviceRouter.readRoutes
          : null;
      var response = audio != null || image != null
          ? await api.askQuestionWithAudio(query, audioFile: audio,
              imagePath: image,
              accountType: 'business', language: language, history: _buildHistoryForLLM(query), screenCatalog: catalog,
              deviceRoutes: deviceRoutes)
          : await api.askQuestion(query, accountType: 'business', language: language,
              history: _buildHistoryForLLM(query), screenCatalog: catalog, deviceRoutes: deviceRoutes);
      final spokenFirst = response.userQuery;
      if (deviceRoutes != null && response.deviceCalls.isNotEmpty && response.state != null) {
        // Every read has a deadline and the whole loop a budget, so Sara
        // always ends with a message (also in «جميع الفروع», where one
        // branch's read can be slow and merged answers are large).
        final finished = await BusinessDeviceLoop.run(response,
          arabic: language != 'en',
          alive: () => mounted && BranchScope.token == scope,
          onRound: (round) {
            if (mounted && round > 0) setState(() => _assistantStatus = AssistantStatus.thinking);
          },
          handle: (call) => BusinessDeviceRouter.handle(ref.read,
              method: '${call['method'] ?? 'GET'}', path: '${call['path'] ?? ''}',
              params: call['params'] is Map ? Map<String, dynamic>.from(call['params'] as Map) : null,
              screen: ref),
          resume: (state, results) => api.continueBusiness(state: state, results: results,
              deviceRoutes: deviceRoutes, language: language, screenCatalog: catalog));
        if (finished == null) return;
        response = finished;
      }
      if (response.userQuery == null && spokenFirst != null) {
        response = AiAgentResponse(text: response.text, actions: response.actions,
            pendingTools: response.pendingTools, userQuery: spokenFirst);
      }
      if (response.text.trim().isEmpty && response.pendingTools.isEmpty) {
        response = AiAgentResponse(text: _toolText('لم تصلني إجابة مكتملة. أعد صياغة السؤال أو اجعله أضيق.',
            'No complete answer arrived. Rephrase or narrow the question.'),
            actions: response.actions, userQuery: response.userQuery);
      }
      _ambient.responseReady(visualGeneration);
      if (!mounted) {
        await ChatPersistence.instance.appendMessage(saveKey, ChatPersistMessage(
          id: 'sara_${DateTime.now().microsecondsSinceEpoch}',
          text: '${response.text}${response.pendingTools.isNotEmpty ? '\nلم يتم التنفيذ؛ أعد طلب العملية لتأكيدها.' : ''}',
          role: 'assistant', time: DateTime.now()));
        return;
      }
      // A response can only be applied to the originating branch conversation.
      if (BranchScope.token != scope) {
        _addAssistantMessage(_toolText('تغير الفرع أثناء الطلب. ارجع للفرع الأصلي وأعد الطلب.', 'The branch changed. Return to the original branch and retry.'));
        return;
      }
      final spoken = response.userQuery;
      if (audio != null && spoken != null && spoken.isNotEmpty) {
        final last = _messages.removeLast();
        _messages.add(_ChatMessage(id: last.id, text: spoken, role: MessageRole.audio,
            audioPath: audio, transcript: spoken));
      }
      _history.add({'role': 'user', 'content': spoken ?? query});
      _history.add({'role': 'assistant', 'content': response.text});
      setState(() => _addAssistantMessage(_cleanMarkdown(response.text), actions: response.actions,
          routeLink: SaraActionDispatcher.resolveRouteFromActions(response.actions), visualGeneration: effectGeneration));
      await _saveMessages();
      for (final pending in response.pendingTools) {
        if (pending['tool'] != 'business_operation' || BranchScope.readOnly) continue;
        final params = Map<String, dynamic>.from(pending['params'] as Map);
        final arabic = language != 'en';
        final rows = (params['fields'] as List?)?.whereType<Map>().map((e) => MapEntry('${e['label']}', '${e['value']}')).toList()
            ?? saraDetailRows(Map<String, dynamic>.from(params['details'] as Map? ?? {}), arabic: arabic);
        setState(() => _assistantStatus = AssistantStatus.connected);
        final approved = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
          title: Text(arabic ? 'راجع تفاصيل العملية' : 'Review operation'),
          content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(saraDisplayText('${params['summary']}', arabic: arabic), style: const TextStyle(fontFamily: 'Cairo', height: 1.6)),
              const SizedBox(height: 16),
              for (final row in rows) Padding(padding: const EdgeInsets.only(bottom: 12), child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(row.key, style: Theme.of(ctx).textTheme.labelMedium),
                  const SizedBox(height: 3), Text(row.value, style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600, height: 1.5)),
                ])),
            ]))),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(arabic ? 'إلغاء' : 'Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(arabic ? 'تأكيد التنفيذ' : 'Confirm'))],
        ));
        if (!mounted || approved != true) {
          _ambient.cancel();
          if (mounted) setState(() => _addAssistantMessage(_toolText('لم يتم تنفيذ العملية.', 'The operation was not executed.')));
          continue;
        }
        if (BranchScope.token != scope || BranchScope.readOnly) {
          setState(() => _addAssistantMessage(_toolText('تغير نطاق الفرع. لم يتم التنفيذ.', 'The branch changed. Nothing was executed.')));
          continue;
        }
        setState(() => _assistantStatus = AssistantStatus.executing);
        final effectOperation = _ambient.beginOperation();
        effectGeneration = _ambient.generation;
        final Map<String, dynamic> outcome;
        final deviceCall = params['device_call'];
        if (deviceCall is Map) {
          // Confirmed by the user: executed on this phone, like the button.
          outcome = await BusinessDeviceRouter.handle(ref.read,
              method: '${deviceCall['method']}', path: '${deviceCall['path']}',
              params: deviceCall['params'] is Map ? Map<String, dynamic>.from(deviceCall['params'] as Map) : null,
              body: deviceCall['body'] is Map ? Map<String, dynamic>.from(deviceCall['body'] as Map) : null,
              screen: ref);
        } else {
          final result = await network.post('/business-sara/execute', data: {'token': params['token']});
          final envelope = result.data as Map;
          outcome = Map<String, dynamic>.from((envelope['data'] ?? envelope) as Map);
        }
        final success = outcome['success'] == true;
        if (effectOperation != null) _ambient.finishOperation(confirmed: success, failed: !success, token: effectOperation);
        _flashOutcome(success);
        if (!mounted) return;
        final text = saraOutcomeMessage(outcome, arabic: arabic);
        setState(() => _addAssistantMessage(text, visualGeneration: effectGeneration));
        _history.add({'role': 'assistant', 'content': text});
        await _saveMessages();
      }
    } catch (error) {
      _ambient.error(generation: effectGeneration);
      _flashOutcome(false);
      if (mounted) setState(() => _addAssistantMessage(_friendlyError(error, AppLocalizations.of(context))));
    } finally {
      if (mounted) {
        setState(() { _busy = false; _assistantStatus = AssistantStatus.connected; });
        await _saveMessages();
        _scrollDown();
      }
    }
  }

  Future<void> _send({String? text}) async {
    final msg = text ?? _inputCtrl.text.trim();
    if (msg.isEmpty && _pendingFileName == null && _pendingImage == null && _audioPath == null) return;
    if (_busy) return;
    _autoFollow = true;
    _ambient.send();
    final visualGeneration = _ambient.generation;
    unawaited(_sounds.play(SaraSound.sent));
    if (widget.accountType == 'business') {
      await _sendBusiness(msg, visualGeneration: visualGeneration);
      return;
    }
    final l10n = AppLocalizations.of(context);

    // ── Pending account/currency mismatch choice: the next message only
    // selects an option (or cancels) — never executes.
    if (_pendingMismatch != null &&
        _pendingFileName == null &&
        _pendingImage == null &&
        _audioPath == null) {
      if (await _handleMismatchReply(msg)) return;
    }

    String query;
    String displayText;
    MessageRole role;

    if (_pendingImage != null) {
      query = msg.isNotEmpty
          ? '$msg (${l10n.translate('saraImageQuery')})'
          : l10n.translate('saraImageQueryStandalone');
      displayText = msg;
      role = MessageRole.image;
    } else if (_pendingFileName != null) {
      query = msg.isNotEmpty
          ? '$msg (${l10n.translate('saraAttachment')}: $_pendingFileName)'
          : '${l10n.translate('saraAttachment')}: $_pendingFileName';
      displayText = msg.isNotEmpty ? '$msg\n📎 $_pendingFileName' : '📎 $_pendingFileName';
      role = MessageRole.user;
    } else if (_audioPath != null) {
      query = msg.isNotEmpty ? msg : l10n.translate('saraVoiceQuery');
      displayText = l10n.translate('saraVoiceMessage');
      role = MessageRole.audio;
    } else {
      // No canned replies: every turn flows to the real path below (route
      // continuation → collecting → confirmation → backend), so follow-ups
      // like "تمام" or "شكراً" are never swallowed by a static response.
      final lastAssistantMsg = _messages.where((m) => m.role == MessageRole.assistant).lastOrNull;
      final pendingRoute = lastAssistantMsg?.routeLink;
      if (pendingRoute != null) {
        final positive = ['نعم', 'ايوه', 'اه', 'طيب', 'تمام', 'yes', 'ok', 'خلص', 'موافق', 'يب', 'بلى', 'أكيد', 'طبعاً', 'حسنا'];
        if (positive.any((w) => msg.trim().toLowerCase().startsWith(w))) {
          _lastQuery = msg;
          setState(() {
            _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
            _addAssistantMessage(l10n.translate('saraOpeningSection'));
            _inputCtrl.clear();
          });
          if (context.mounted) openSaraRoute(context, pendingRoute);
          return;
        }
      }

      // ── AgentContext: Handle parameter collection state ──
      if (_agentContext.state == AgentState.collectingParams) {
        final pendingTool = _agentContext.pendingToolName;
        if (pendingTool != null) {
          final toolDef = AgentToolRegistry.findByName(pendingTool);
          if (toolDef != null) {
            // Topic change: if user asks a new question (balance, currencies, etc.)
            // don't treat it as an answer to the pending param.
            if (_isNewTopic(msg, pendingTool)) {
              // Answer the new topic first, keep pending for later if still valid
              // (don't cancel — the next turn can resume).
              // Fall through to normal query handling below.
            } else {
              // Try to infer missing params from persistent history before asking
              final inferred = _inferFromHistory(toolDef);
              final withHistory = ParameterCollector.mergeParams(_agentContext.collectedParams, inferred);
              if (withHistory.length != _agentContext.collectedParams.length) {
                _agentContext.updateCollectedParams(withHistory);
              }
              final extracted = _extractParamFromInput(toolDef, msg);
              // Handle ambiguous bank: if bank param is required and user gave a short name
              // that matches multiple accounts, show choices instead of picking one.
              if (extracted.containsKey('account_id') || extracted.containsKey('from_account_id') || extracted.containsKey('bank_name')) {
                final bankVal = extracted['account_id'] ?? extracted['from_account_id'] ?? extracted['bank_name'];
                if (bankVal != null) {
                  final ambiguous = await _checkAmbiguousBank(bankVal.toString());
                  if (ambiguous != null && ambiguous.length > 1) {
                    setState(() {
                      _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
                      _addAssistantMessage(ambiguous);
                      _inputCtrl.clear();
                    });
                    _scrollDown();
                    return;
                  }
                }
              }
              final merged = ParameterCollector.mergeParams(_agentContext.collectedParams, extracted);
              // Handle YER vs YER_NEW explicitly already in _extractCurrency
              _agentContext.updateCollectedParams(merged);
              final check = ParameterCollector.checkCompletion(toolDef, merged);
              if (check.isComplete) {
                if (ConfirmationHandler.requiresConfirmation(toolDef)) {
                  _agentContext.startConfirmation();
                  final confirmMsg = ConfirmationHandler.buildConfirmationMessage(toolDef, merged, lang: _chatLang());
                  setState(() {
                    _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
                    _addAssistantMessage(confirmMsg);
                    _inputCtrl.clear();
                  });
                  _saveMessages();
                  _scrollDown();
                  return;
                }
                _executeToolFromContext(pendingTool, merged);
                setState(() {
                  _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
                  _inputCtrl.clear();
                });
                _saveMessages();
                _scrollDown();
                return;
              }
              final nextQ = ParameterCollector.nextQuestion(toolDef, merged, lang: _chatLang());
              if (nextQ != null) {
                setState(() {
                  _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
                  _addAssistantMessage(nextQ);
                  _inputCtrl.clear();
                });
                _saveMessages();
                _scrollDown();
                return;
              }
              // Still not complete but no next question (edge) — ask again
              setState(() {
                _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
                _addAssistantMessage(nextQ ?? AppLocalizations.of(context).translate('saraConfirmAgain'));
                _inputCtrl.clear();
              });
              _saveMessages();
              _scrollDown();
              return;
            }
          }
        }
        // If we fell through due to new topic, don't cancel — keep pending for later
        // (unless the new query is clearly unrelated, we keep it).
      }

      // ── AgentContext: Handle confirmation state ──
      if (_agentContext.state == AgentState.awaitingConfirmation) {
        final pendingTool = _agentContext.pendingToolName;
        final toolDef = pendingTool != null ? AgentToolRegistry.findByName(pendingTool) : null;
        // Check if user is correcting a param (e.g., "غير البنك إلى الكريمي" or "لا 5000 وليس 500")
        if (toolDef != null) {
          final correction = _extractParamFromInput(toolDef, msg);
          // If correction contains a param that was already collected, treat as update and re-confirm
          bool isCorrection = false;
          for (final k in correction.keys) {
            if (_agentContext.collectedParams.containsKey(k)) {
              isCorrection = true;
              break;
            }
          }
          if (isCorrection) {
            final merged = ParameterCollector.mergeParams(_agentContext.collectedParams, correction);
            _agentContext.updateCollectedParams(merged);
            final confirmMsg = ConfirmationHandler.buildConfirmationMessage(toolDef, merged, lang: _chatLang());
            setState(() {
              _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
              _addAssistantMessage('تم التحديث:\n$confirmMsg');
              _inputCtrl.clear();
            });
            _saveMessages();
            _scrollDown();
            return;
          }
        }
        final confirmResult = ConfirmationHandler.parseConfirmation(msg);
        if (confirmResult == ConfirmResult.confirmed) {
          final params = _agentContext.collectedParams;
          setState(() {
            _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
            _inputCtrl.clear();
          });
          _saveMessages();
          if (pendingTool != null) {
            _executeToolFromContext(pendingTool, params);
          }
          _scrollDown();
          return;
        } else if (confirmResult == ConfirmResult.cancelled) {
          _agentContext.cancel();
          setState(() {
            _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
            _addAssistantMessage(AppLocalizations.of(context).translate('saraOpCancelled'));
            _inputCtrl.clear();
          });
          _saveMessages();
          _scrollDown();
          return;
        }
        // If user sent a new topic while awaiting confirmation (e.g., "كم رصيدي؟"),
        // handle it as new query but keep confirmation pending
        if (pendingTool != null && _isNewTopic(msg, pendingTool)) {
          // Fall through to normal handling below, keep pending
        } else {
          setState(() {
            _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
            _addAssistantMessage(AppLocalizations.of(context).translate('saraConfirmAgain'));
            _inputCtrl.clear();
          });
          _saveMessages();
          _scrollDown();
          return;
        }
      }

      // ── Direct in-app commands (bank operations): resolve + confirm +
      // execute locally so valid requests are never deflected to chat.
      if (_agentContext.state == AgentState.idle) {
        if (await _tryDirectBankCommand(msg)) return;
      } else if (_agentContext.state == AgentState.awaitingConfirmation || _agentContext.state == AgentState.collectingParams) {
        // For pending states where _isNewTopic was true, we fell through — now handle the new topic
        // as a normal query but preserve the pending context (don't cancel).
        // The new query will be added to _history and sent to backend below.
      }

      query = msg;
      displayText = msg;
      role = MessageRole.user;
    }

    _lastQuery = query;
    _busy = true;
    final _sentAt = DateTime.now();
    _history.add({'role': 'user', 'content': query});
    final audioFile = _audioPath;
    final pendingImage = _pendingImage;
    _isVoiceMessage = _audioPath != null;
    // Capture a live handle to the finance service while the widget is mounted.
    // It stays usable after dispose, letting Sara's task finish in the
    // background when the user leaves the chat screen.
    final capturedFinanceService = ref.read(personalFinanceServiceProvider);
    // Background-proofing: ref/context/widget die with dispose (ref.read
    // throws after dispose), so snapshot everything the async tail needs
    // right here while mounted. Nothing below the first await may touch
    // ref, context, or _getUserId() directly.
    final bgUserId = _getUserId();
    final bgAccountType = widget.accountType;
    final bgSaveKey = '${bgUserId}_$bgAccountType';
    final bgLang = _chatLang();
    // Preserve file metadata for persistence (reference, not copy)
    final fileNameForMsg = _pendingFileName;
    setState(() {
      _assistantStatus = AssistantStatus.thinking;
      _messages.add(_ChatMessage(
        text: displayText,
        role: role,
        imagePath: _pendingImage?.path,
        audioPath: _audioPath,
        audioDuration: _recordingDuration,
        fileName: fileNameForMsg,
        mimeType: _pendingImage != null ? 'image/*' : (fileNameForMsg != null ? 'application/octet-stream' : null),
        // Voice without typed text: keep no transcript until the backend
        // returns the real Whisper transcript (resp.userQuery replaces it).
        // The instructional note (saraVoiceQuery) is backend query text
        // only — it must never render under the voice bubble.
        transcript: _isVoiceMessage ? (msg.isNotEmpty ? query : null) : null,
      ));
      _inputCtrl.clear();
      _pendingFileName = null;
      _pendingImage = null;
      _audioPath = null;
      _recordingDuration = 0;
    });
    // Persist immediately so voice/image/file are not lost if app closes before LLM reply
    _saveMessages();
    _scrollDown();
    Future.delayed(const Duration(milliseconds: 800), () {
      if (!mounted || _isVoiceMessage) return;
      setState(() => _assistantStatus = AssistantStatus.preparing);
    });

    final user = ref.read(authProvider).user;
    final aiService = ref.read(aiServiceProvider);
    final appLanguage = AppLocalizations.of(context).locale.languageCode;

    final appState = SaraAppState(
      subscriptionPlan: user?.subscriptionPlan,
      subscriptionStatus: user?.effectiveStatus,
      currentTab: widget.accountType == 'personal'
          ? l10n.translate('personal')
          : l10n.translate('business'),
      lastScreen: _lastScreen,
      lastOperation: _lastOperation,
    );

    Future<AiAgentResponse> _doQuery() async {
      final boundedHistory = _buildHistoryForLLM(query);
      // Live screen catalog: every route this app build ships, so Sara can
      // explain/open any section — including screens added later — without
      // any backend update.
      final catalog = SaraScreenCatalog.entries(arabic: appLanguage != 'en');
      if (audioFile != null || pendingImage != null) {
        return await aiService.askQuestionWithAudio(query,
          audioFile: audioFile,
          imagePath: pendingImage?.path,
          userName: user?.fullName,
          accountType: widget.accountType,
          language: appLanguage,
          screenCatalog: catalog,
          history: boundedHistory.isEmpty ? null : boundedHistory,
          appState: appState);
      }
      return aiService.askQuestion(query,
          userName: user?.fullName,
          accountType: widget.accountType,
          currentScreen: _lastScreen,
          language: appLanguage,
          screenCatalog: catalog,
          history: boundedHistory.isEmpty ? null : boundedHistory,
          appState: appState);
    }

    _doQuery().then((resp) async {
      _ambient.responseReady(visualGeneration);
      // Reveal the returned response immediately; no simulated thinking delay.
      // If backend returned the final merged query (with Whisper transcript / image analysis / file text),
      // update the last user bubble and the LLM history so the transcript becomes the source of truth.
      // A backend echo of the instructional voice note is NOT a transcript — keep the bubble title instead.
      if (resp.userQuery != null && resp.userQuery!.trim().isNotEmpty && resp.userQuery != query && !_isVoiceNote(resp.userQuery!)) {
        final idx = _messages.lastIndexWhere((m) => m.role == MessageRole.user || m.role == MessageRole.image || m.role == MessageRole.audio);
        if (idx >= 0) {
          final old = _messages[idx];
          final isVoice = old.role == MessageRole.audio;
          final isImage = old.role == MessageRole.image;
          _messages[idx] = _ChatMessage(
            id: old.id, text: isVoice ? resp.userQuery! : old.text, role: old.role, time: old.time,
            imagePath: old.imagePath, audioPath: old.audioPath, audioDuration: old.audioDuration,
            routeLink: old.routeLink, actions: old.actions, isWelcome: old.isWelcome,
            fileName: old.fileName, mimeType: old.mimeType, fileSize: old.fileSize,
            transcript: isVoice ? resp.userQuery : old.transcript,
            analysis: isImage || old.fileName != null ? resp.userQuery : old.analysis,
          );
          if (_history.isNotEmpty && _history.last['role'] == 'user') {
            _history[_history.length - 1] = {'role': 'user', 'content': resp.userQuery!};
          }
          _saveMessages();
          if (mounted) setState(() {});
        }
      }

      // ── Execute pending tools even if the user left the chat ──
      // The query result belongs to the app state, not to the UI. Auto-execute
      // tools that don't need confirmation so Sara's task completes in the
      // background. If the user is still in the chat, the UI reflects it.
      // All identifiers below are send-time snapshots (bg*) — never touch
      // ref/context here; the widget may already be disposed.
      final accountType = bgAccountType;
      final userId = bgUserId;
      final chatLang = bgLang;

      Future<void> executeToolSet(Map<String, dynamic> toolParams) async {
        final toolName = toolParams['tool'] as String? ?? '';
        final params = (toolParams['params'] as Map<String, dynamic>?) ?? {};
        final toolDef = AgentToolRegistry.findByName(toolName);
        if (toolDef == null) return;

        if (!ConfirmationHandler.requiresConfirmation(toolDef)) {
          final check = ParameterCollector.checkCompletion(toolDef, params);
          if (check.isComplete) {
            // Runs without any widget state — valid after dispose.
            await _executeToolFromService(
              capturedFinanceService,
              toolName,
              params,
              saveKey: '${userId}_$accountType',
              lang: chatLang,
              effectGeneration: visualGeneration,
            );
          }
        }
      }

      if (resp.pendingTools.isNotEmpty && mounted) {
        // A sensitive operation anywhere in the batch: its confirmation card
        // comes first and nothing of the batch runs before the user decides
        // (previously only the FIRST tool was checked, so a sensitive one
        // later in the batch was silently dropped).
        final firstTool = resp.pendingTools.firstWhere((t) {
          final def = AgentToolRegistry.findByName(t['tool'] as String? ?? '');
          return def != null && ConfirmationHandler.requiresConfirmation(def);
        }, orElse: () => resp.pendingTools.first);
        final toolName = firstTool['tool'] as String? ?? '';
        final toolParams = (firstTool['params'] as Map<String, dynamic>?) ?? {};
        final toolDef = AgentToolRegistry.findByName(toolName);
        if (toolDef != null && ConfirmationHandler.requiresConfirmation(toolDef)) {
          if (resp.pendingTools.length > 1) {
            _addAssistantMessage(_toolText('في طلبك أكثر من عملية. أؤكد معك هذه أولًا، ثم اطلب الباقي بعدها.',
                'Your request has several operations. Confirm this one first, then ask for the rest.'));
          }
          setState(() {
            _messages.add(_ChatMessage(
              text: '',
              role: MessageRole.confirmation,
              confirmToolName: toolName,
              confirmParams: toolParams,
              confirmTitle: ConfirmationHandler.buildConfirmationMessage(toolDef, toolParams, lang: _chatLang()),
              confirmRiskLevel: toolDef.riskLevel,
            ));
          });
          _scrollDown();
          _busy = false;
          return;
        }
      }

      // Background: confirmation cards cannot render while away — persist
      // their questions as plain text so the user sees exactly what awaits
      // approval on return (replying "نعم" continues via rebuilt history).
      final bgConfirmQs = <String>[];
      if (!mounted) {
        for (final t in resp.pendingTools) {
          final toolName = (t['tool'] as String?) ?? '';
          final toolParams = (t['params'] as Map<String, dynamic>?) ?? {};
          final toolDef = AgentToolRegistry.findByName(toolName);
          if (toolDef != null && ConfirmationHandler.requiresConfirmation(toolDef)) {
            try {
              bgConfirmQs.add(ConfirmationHandler.buildConfirmationMessage(toolDef, toolParams, lang: bgLang));
            } catch (_) {}
          }
        }
      }

      for (final t in resp.pendingTools) {
        await executeToolSet(t);
      }

      // Add the main response
      final cleaned = _cleanMarkdown(resp.text);
      _history.add({'role': 'assistant', 'content': cleaned});

      if (!mounted) {
        // User left before Sara answered — persist the reply (+ any pending
        // confirmation questions) so the conversation is complete on return.
        try {
          await ChatPersistence.instance.appendMessage(
            bgSaveKey,
            ChatPersistMessage(
              id: 'resp_${DateTime.now().millisecondsSinceEpoch}',
              text: cleaned,
              role: 'assistant',
              time: DateTime.now(),
            ),
          );
          for (var i = 0; i < bgConfirmQs.length; i++) {
            await ChatPersistence.instance.appendMessage(
              bgSaveKey,
              ChatPersistMessage(
                id: 'confirm_${DateTime.now().millisecondsSinceEpoch}_$i',
                text: bgConfirmQs[i],
                role: 'assistant',
                time: DateTime.now(),
              ),
            );
          }
        } catch (_) {}
        return;
      }
      
      {
        setState(() {
          _assistantStatus = AssistantStatus.connected;
          final actions = _withScreenLink(resp.userQuery ?? query, cleaned, resp.actions);
          final routeLink = SaraActionDispatcher.resolveRouteFromActions(actions);
          _addAssistantMessage(cleaned, routeLink: routeLink, actions: actions, visualGeneration: visualGeneration);
          _dynamicSuggestions = resp.suggestions;
        });
        _busy = false;
        _saveMessages();
        _scrollDown();
      }
    }).catchError((e) async {
      _ambient.error(generation: visualGeneration);
      // Never swallow: even a failure must leave a trace while away, or the
      // returning user faces silence with no way to know what happened.
      if (!mounted) {
        try {
          await ChatPersistence.instance.appendMessage(
            bgSaveKey,
            ChatPersistMessage(
              id: 'err_${DateTime.now().millisecondsSinceEpoch}',
              text: bgLang == 'en'
                  ? '❌ Something went wrong while handling your request — please try again.'
                  : '❌ حدث خطأ أثناء تنفيذ طلبك — حاول مرة أخرى.',
              role: 'assistant',
              time: DateTime.now(),
            ),
          );
        } catch (_) {}
        return;
      }
      final elapsed = DateTime.now().difference(_sentAt).inMilliseconds;
      final remaining = 1200 - elapsed;
      if (remaining > 0) {
        await Future.delayed(Duration(milliseconds: remaining));
        if (!mounted) return;
      }
      setState(() {
        _assistantStatus = AssistantStatus.connected;
        _messages.add(_ChatMessage(text: _friendlyError(e, l10n), role: MessageRole.error, query: _lastQuery));
      });
      _busy = false;
      _saveMessages();
      _scrollDown();
    });
  }

  /// Personal: a reply that promises a screen button (or answers a request
  /// for one) always carries it — derived from the words when the model
  /// forgot the open-screen action (see sara_link_fallback.dart).
  List<SaraAction> _withScreenLink(String userQuery, String reply, List<SaraAction> actions) {
    if (widget.accountType == 'business') return actions;
    return saraEnsureScreenAction(userQuery: userQuery, reply: reply, actions: actions, arabic: _chatLang() != 'en');
  }

  void _addAssistantMessage(String text, {String? routeLink, List<SaraAction> actions = const [], int? visualGeneration}) {
    final message = _ChatMessage(text: saraDisplayText(text, arabic: _chatLang() != 'en'), role: MessageRole.assistant, routeLink: routeLink, actions: actions);
    _messages.add(message);
    if (text != AppLocalizations.of(context).translate('saraExecuting')) {
      _newReplyIds.add(message.id);
      if (_ambient.registerReply(message.id, generation: visualGeneration)) _ambientReplyId = message.id;
    }
    if (text.startsWith('✅')) { _flashOutcome(true); }
    else if (text.startsWith('❌')) { _flashOutcome(false); }
    else { unawaited(_sounds.play(SaraSound.reply)); }
  }

  void _handleConfirmAction(_ChatMessage msg) {
    if (msg.confirmToolName == null) return;
    final params = msg.confirmParams ?? {};
    final toolName = msg.confirmToolName!;

    // Mark confirmation as done
    setState(() {
      msg.text; // keep existing text
    });

    _executeToolDirectly(toolName, params);
  }

  void _handleCancelAction(_ChatMessage msg) {
    _ambient.cancel();
    setState(() {
      _messages.add(_ChatMessage(
        text: _isEn() ? 'Operation cancelled.' : 'تم إلغاء العملية.',
        role: MessageRole.assistant,
      ));
    });
    _scrollDown();
    HapticFeedback.lightImpact();
  }

  void _executeToolDirectly(String toolName, Map<String, dynamic> params, {int? effectGeneration}) async {
    if (_busy) return;
    final visualGeneration = effectGeneration ?? _ambient.generation;
    // Snapshot for the background tail (user may leave mid-execution).
    final bgKey = '${_getUserId()}_${widget.accountType}';
    setState(() {
      _busy = true;
      _assistantStatus = AssistantStatus.executing;
      _addAssistantMessage(AppLocalizations.of(context).translate('saraExecuting'));
    });
    _scrollDown();

    try {
      final financeService = ref.read(personalFinanceServiceProvider);
      final toolExecutor = _wiredExecutor(financeService);
      final visualWork = _ambientToolStarted(toolName, generation: visualGeneration);
      final result = await toolExecutor.execute(toolName, params);
      _ambientToolFinished(result, visualWork);

      // User left mid-execution — persist the outcome instead of silence.
      if (!mounted) {
        await _persistToolOutcome(bgKey, toolName, params, result);
        return;
      }

      // Account/currency mismatch refusal → ask the numbered options
      // instead of showing a bare error. Nothing is executed.
      final mismatchQ = _stashMismatch(toolName, params, result);
      if (mismatchQ != null && mounted) {
        setState(() {
          _messages.removeLast(); // Remove "جاري التنفيذ" message
          _addAssistantMessage(mismatchQ, visualGeneration: visualGeneration);
        });
        _scrollDown();
        return;
      }

      final toolMessages = <String>[];
      final toolActions = <SaraAction>[];
      // Tone comes from the verification gateway (saraToneOf), never from
      // success/bool alone: pending/unverifiable states must not render as
      // false ✅ or ❌.
      final tone = saraToneOf(result);
      if (result.success) {
        toolMessages.add('$tone ${_toolText(result.messageAr, result.messageEn)}');
        if (result.entityId != null && result.entityType != null) {
          toolActions.add(SaraAction(
            type: SaraActionType.openEntity,
            params: {
              'entity_type': result.entityType!,
              'id': result.entityId.toString(),
            },
            label: '${AppLocalizations.of(context).translate('actionShow')} ${_entityLabel(toolName)}',
          ));
        }
      } else {
        final recoveryQuestion = _slotRecoveryQuestion(toolName, params, result);
        if (recoveryQuestion != null) {
          toolMessages.add(recoveryQuestion);
        } else {
          toolMessages.add('$tone ${_toolText(result.messageAr, result.messageEn)}');
          if (tone != '❌' &&
              result.entityId != null &&
              result.entityType != null) {
            toolActions.add(SaraAction(
              type: SaraActionType.openEntity,
              params: {
                'entity_type': result.entityType!,
                'id': result.entityId.toString(),
              },
              label: '${AppLocalizations.of(context).translate('actionShow')} ${_entityLabel(toolName)}',
            ));
          }
        }
      }

      if (toolMessages.isNotEmpty && mounted) {
        setState(() {
          _messages.removeLast(); // Remove "جاري التنفيذ" message
          _addAssistantMessage(toolMessages.join('\n'), actions: toolActions, visualGeneration: visualGeneration);
        });
        _scrollDown();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.removeLast();
        _ambient.error(generation: visualGeneration);
        _addAssistantMessage('❌ ${AppLocalizations.of(context).translate('saraExecFailed')}', visualGeneration: visualGeneration);
      });
      _scrollDown();
    } finally {
      if (mounted) {
        setState(() { _busy = false; _assistantStatus = AssistantStatus.connected; });
        await _saveMessages();
      }
    }
  }

  /// Runs a Sara tool with a captured service — safe even after the chat widget
  /// is disposed. Ensures the task completes while the user is on another
  /// screen, then persists the result message so it appears on return.
  Future<void> _executeToolFromService(
    PersonalFinanceService financeService,
    String toolName,
    Map<String, dynamic> params, {
    required String saveKey,
    required String lang,
    int? effectGeneration,
  }) async {
    final visualGeneration = effectGeneration ?? _ambient.generation;
    if (mounted) setState(() { _busy = true; _assistantStatus = AssistantStatus.executing; });
    try {
      final toolExecutor = _wiredExecutor(financeService);
      final visualWork = _ambientToolStarted(toolName, generation: visualGeneration);
      final result = await toolExecutor.execute(toolName, params);
      _ambientToolFinished(result, visualWork);

      if (mounted) {
        // Chat still open — reflect directly without a second run.
        // Tone is gateway-owned (pending/unverifiable never render as ✅/❌).
        final tone = saraToneOf(result);
        if (result.success) {
          setState(() {
            _assistantStatus = AssistantStatus.connected;
            _addAssistantMessage('$tone ${_toolText(result.messageAr, result.messageEn)}', visualGeneration: visualGeneration);
          });
          _scrollDown();
        } else {
          setState(() {
            _assistantStatus = AssistantStatus.connected;
            _addAssistantMessage('$tone ${_toolText(result.messageAr, result.messageEn)}', visualGeneration: visualGeneration);
          });
          _scrollDown();
        }
        await _saveMessages();
        return;
      }

      // Widget disposed — persist the full outcome (mismatch options,
      // recovery question, or tone + message) for the next visit.
      await ChatPersistence.instance.appendMessage(saveKey, ChatPersistMessage(
        id: 'tool_${DateTime.now().millisecondsSinceEpoch}',
        text: _toolOutcomeText(toolName, params, result),
        role: 'assistant',
        time: DateTime.now(),
      ));
    } catch (e) {
      debugPrint('executeToolFromContainer error: $e');
      _ambient.error(generation: visualGeneration);
      if (mounted) {
        setState(() => _addAssistantMessage('❌ ${_toolText('تعذر التنفيذ. لم يتم تأكيد أي عملية.', 'Execution could not be confirmed.')}', visualGeneration: visualGeneration));
        await _saveMessages();
      }
      if (!mounted) {
        await ChatPersistence.instance.appendMessage(saveKey, ChatPersistMessage(
          id: 'tool_${DateTime.now().millisecondsSinceEpoch}',
          text: AppLocalizations.t('saraExecFailed'),
          role: 'assistant',
          time: DateTime.now(),
        ));
      }
    } finally {
      if (mounted) setState(() { _busy = false; _assistantStatus = AssistantStatus.connected; });
    }
  }

  String _entityLabel(String tool) {
    final en = _isEn();
    if (tool.contains('goal')) return en ? 'Goal' : 'الهدف';
    if (tool.contains('debt')) return en ? 'Debt' : 'الدين';
    if (tool.contains('bank')) return en ? 'Account' : 'الحساب';
    if (tool.contains('budget')) return en ? 'Budget' : 'الميزانية';
    if (tool.contains('recurring')) {
      return en ? 'Recurring transaction' : 'المعاملة المتكررة';
    }
    if (tool.contains('transaction')) return en ? 'Transaction' : 'المعاملة';
    if (tool.contains('transfer')) return en ? 'Transfer' : 'التحويل';
    if (tool.contains('category')) return en ? 'Categories' : 'التصنيفات';
    if (tool.contains('tree')) return en ? 'Financial tree' : 'الشجرة المالية';
    if (tool.contains('merchant')) return en ? 'Merchant accounts' : 'حسابات التجار';
    return en ? 'Item' : 'العنصر';
  }

  /// Extract parameters from user text — handles multi-param, corrections,
  /// YER/YER_NEW, currency, bank disambiguation and reuse of history.
  Map<String, dynamic> _extractParamFromInput(ToolDefinition tool, String userText) {
    final params = <String, dynamic>{};
    final text = userText.trim();
    final lower = text.toLowerCase();
    final isCorrection = lower.contains('لا') || lower.contains('وليس') || lower.contains('غير') || lower.contains('بدل') || lower.contains('أقصد') || lower.contains('اقصد') || lower.contains('تصحيح');

    // Amount: handle corrections like "5000 وليس 500" → 5000 is the new, 500 is old
    final normText = ParamNormalizer.normalizeDigits(text);
    final numMatches = RegExp(r'(\d+(?:\.\d+)?)').allMatches(normText).map((m) => double.tryParse(m.group(1)!)).whereType<double>().toList();
    if (numMatches.isNotEmpty) {
      double amount;
      if (isCorrection && lower.contains('وليس')) {
        // "5000 وليس 500" → first is new, second is old
        amount = numMatches.first;
      } else if (isCorrection) {
        amount = numMatches.last;
        // For "لا, 5000" the last is the correction
        // Also try word numbers if no digits
        if (numMatches.length == 1) {
          final wordVal = ParamNormalizer.extractWordNumber(text);
          if (wordVal != null) amount = wordVal;
        }
      } else {
        amount = numMatches.first;
      }
      // Also try word number if no digit found
      if (amount == null) {
        final wordVal = ParamNormalizer.extractWordNumber(text);
        if (wordVal != null) amount = wordVal;
      }
      if (amount != null) {
        for (final p in tool.params) {
          if (p.type == ParamType.number && (isCorrection || !_agentContext.collectedParams.containsKey(p.name)) && !params.containsKey(p.name)) {
            if (p.name == 'amount' || p.name == 'target_amount' || p.name == 'opening_balance' || p.name == 'balance' || p.name == 'rate') {
              params[p.name] = amount;
              break;
            }
          }
        }
        if (!params.containsKey('amount')) {
          for (final p in tool.params) {
            if (p.type == ParamType.number && p.required && !_agentContext.collectedParams.containsKey(p.name) && !params.containsKey(p.name)) {
              params[p.name] = amount;
              break;
            }
          }
        }
      }
    } else {
      // No digits, try word numbers
      final wordVal = ParamNormalizer.extractWordNumber(text);
      if (wordVal != null) {
        for (final p in tool.params) {
          if (p.type == ParamType.number && (isCorrection || !_agentContext.collectedParams.containsKey(p.name)) && !params.containsKey(p.name)) {
            if (p.name == 'amount' || p.name == 'target_amount' || p.name == 'opening_balance' || p.name == 'balance' || p.name == 'rate') {
              params[p.name] = wordVal;
              break;
            }
          }
        }
      }
    }

    // Currency: explicit extraction for YER/YER_NEW and common codes
    final currency = _extractCurrency(text);
    if (currency != null) {
      for (final p in tool.params) {
        if ((p.name == 'currency' || p.name == 'from_currency' || p.name == 'to_currency') && (isCorrection || !_agentContext.collectedParams.containsKey(p.name))) {
          params[p.name] = currency;
          break;
        }
      }
    }

    // Enum values
    for (final p in tool.params) {
      if (p.type == ParamType.enum_ && p.allowedValues != null && (isCorrection || !_agentContext.collectedParams.containsKey(p.name))) {
        for (final val in p.allowedValues!) {
          if (lower.contains(val.toLowerCase())) {
            params[p.name] = val;
            break;
          }
        }
      }
    }

    // Date
    for (final p in tool.params) {
      if (p.type == ParamType.date && (isCorrection || !_agentContext.collectedParams.containsKey(p.name)) && !params.containsKey(p.name)) {
        final d = ParamNormalizer.normalizeDigits(text);
        // Try to find a date pattern
        if (RegExp(r'\d{4}[/-]\d{1,2}[/-]\d{1,2}').hasMatch(d) || RegExp(r'\d{1,2}[/-]\d{1,2}[/-]\d{4}').hasMatch(d)) {
          final parsed = ParamNormalizer.extractFirstNumber(d); // not ideal, but try
          // Use the raw text fragment that looks like a date
          final m = RegExp(r'(\d{4}[/-]\d{1,2}[/-]\d{1,2}|\d{1,2}[/-]\d{1,2}[/-]\d{4})').firstMatch(d);
          if (m != null) params[p.name] = m.group(1);
        }
      }
    }

    // String params: handle bank/account and category with history-aware logic
    for (final p in tool.params) {
      if (p.type == ParamType.string && p.required && (isCorrection || !_agentContext.collectedParams.containsKey(p.name)) && !params.containsKey(p.name)) {
        // Skip if text looks like a command ("سجل مصروف...") — not a short answer
        final hasCommand = ['سجل', 'انشاء', 'إنشاء', 'أضف', 'اضف', 'سجل', 'حذف', 'تعديل', 'انشاء'].any((w) => lower.contains(w));
        if (hasCommand && text.split(' ').length > 3) continue;
        // For bank/account, try to keep the text as is if it's short (≤6 words) and not a question
        final isQuestion = lower.contains('كم') || lower.contains('ما') || lower.contains('؟') || lower.contains('?');
        if (!isQuestion && text.split(' ').length <= 6) {
          // For bank, we keep the raw bank name; for category, keep as is
          // But don't override if it's a correction that already set amount/currency
          params[p.name] = text;
        }
      }
    }

    return params;
  }

  String? _extractCurrency(String text) {
    final l = text.toLowerCase();
    if (l.contains('ريال يمني جديد') || l.contains('yer_new') || l.contains('yer new') || l.contains('الريال الجديد') || l.contains('ريال جديد')) return 'YER_NEW';
    if (l.contains('ريال يمني قديم') || l.contains('yer_old') || l.contains('قديم')) return 'YER';
    if (l.contains('ريال يمني') || l.contains('yer')) {
      if (l.contains('جديد')) return 'YER_NEW';
      if (l.contains('قديم')) return 'YER';
      return null;
    }
    if (l.contains('sar') || l.contains('ريال سعودي') || l.contains('سعودي')) return 'SAR';
    if (l.contains('usd') || l.contains('دولار')) return 'USD';
    if (l.contains('eur') || l.contains('يورو')) return 'EUR';
    if (l.contains('aed') || l.contains('درهم')) return 'AED';
    if (l.contains('egp') || l.contains('جنيه')) return 'EGP';
    return null;
  }

  Future<String?> _checkAmbiguousBank(String bankName) async {
    try {
      final financeService = ref.read(personalFinanceServiceProvider);
      final accounts = await financeService.getBankAccounts();
      final normInput = _normAr(bankName.toLowerCase());
      final matched = accounts.where((a) {
        final n = _normAr((a.bankName ?? '').toString().toLowerCase());
        return n == normInput || n.contains(normInput) || normInput.contains(n);
      }).toList();
      if (matched.length > 1) {
        final isEn = _isEn();
        final opts = matched.asMap().entries.map((e) {
          final idx = e.key + 1;
          final acc = e.value;
          return isEn
              ? '$idx. ${acc.bankName} (${acc.currency} - ${acc.balance})'
              : '${idx}. ${acc.bankName} (${acc.currency} - ${acc.balance})';
        }).join('\n');
        return isEn
            ? 'Multiple accounts match "$bankName":\n$opts\nPlease specify which one (e.g., "the second" or the full name).'
            : 'يوجد أكثر من حساب يطابق "$bankName":\n$opts\nحدد المطلوب (مثلاً "الثاني" أو الاسم كاملاً).';
      }
    } catch (_) {}
    return null;
  }

  String _handleOrdinalBank(String text, List<dynamic> accounts) {
    final lower = text.toLowerCase();
    if (lower.contains('الثاني') || lower.contains('ثاني') || lower.contains('2') || lower.contains('second')) {
      if (accounts.length >= 2) return (accounts[1].bankName ?? '').toString();
    }
    if (lower.contains('الأول') || lower.contains('اول') || lower.contains('1') || lower.contains('first')) {
      if (accounts.isNotEmpty) return (accounts[0].bankName ?? '').toString();
    }
    if (lower.contains('الثالث') || lower.contains('3') || lower.contains('third')) {
      if (accounts.length >= 3) return (accounts[2].bankName ?? '').toString();
    }
    return text;
  }

  bool _isNewTopic(String msg, String pendingTool) {
    final q = msg.toLowerCase();
    // Read intents that should be treated as new topic, not as param answer
    final readKeywords = ['كم رصيد', 'ما رصيد', 'اعرض', 'ما العملات', 'ما سعر', 'كم سعر', 'اظهر', 'اعرض لي', 'ما هي', 'كم لدي', 'ارني', 'افتح'];
    if (readKeywords.any((w) => q.contains(w))) return true;
    // If pending is write and message is a question about balance/currencies/rates, it's new
    if (pendingTool.contains('transaction') || pendingTool.contains('goal') || pendingTool.contains('budget')) {
      if (q.contains('رصيد') || q.contains('عملات') || q.contains('سعر')) return true;
    }
    return false;
  }

  Map<String, dynamic> _inferFromHistory(ToolDefinition tool) {
    final inferred = <String, dynamic>{};
    if (_history.isEmpty) return inferred;
    // Scan last 10 history entries for bank/currency/category
    final recent = _history.length > 10 ? _history.sublist(_history.length - 10) : _history;
    for (final entry in recent.reversed) {
      final content = entry['content']?.toLowerCase() ?? '';
      for (final p in tool.params) {
        if (inferred.containsKey(p.name) || _agentContext.collectedParams.containsKey(p.name)) continue;
        if (p.name == 'account_id' || p.name == 'from_account_id' || p.name == 'to_account_id' || p.name == 'bank_name') {
          // Look for bank names in history
          if (content.contains('كريمي') || content.contains('karimi')) inferred[p.name] = 'الكريمي';
          else if (content.contains('راجحي') || content.contains('rajhi')) inferred[p.name] = 'الراجحي';
        }
        if (p.name == 'currency' || p.name == 'from_currency') {
          final cur = _extractCurrency(content);
          if (cur != null) inferred[p.name] = cur;
        }
      }
    }
    return inferred;
  }

  /// Builds the pending mismatch from an executor CURRENCY_MISMATCH refusal.
  /// Returns the numbered options question, or null when there is no real
  /// option to offer (caller then falls back to the plain error message).
  /// Fully generic: every option comes from result.data (real account rows +
  /// real FX rates) — no hardcoded accounts or currencies.
  String? _stashMismatch(
    String toolName,
    Map<String, dynamic> attemptedParams,
    ToolExecutionResult result,
  ) {
    if (result.errorCode != 'CURRENCY_MISMATCH') return null;
    final d = result.data ?? {};
    final fxRaw = (d['fx_options'] as List?) ?? const [];
    final sibRaw = (d['sibling_accounts'] as List?) ?? const [];
    final fx = <MismatchFxOption>[];
    for (final e in fxRaw) {
      if (e is! Map) continue;
      final rate = (e['rate'] as num?)?.toDouble() ?? 0;
      final converted = (e['converted'] as num?)?.toDouble() ?? 0;
      if (rate <= 0 || !rate.isFinite) continue;
      fx.add(MismatchFxOption(
        currency: '${e['currency'] ?? ''}',
        accountId: '${e['account_id'] ?? ''}',
        accountName: '${e['account_name'] ?? ''}',
        rate: rate,
        converted: converted,
      ));
    }
    final sibs = <MismatchSibling>[];
    for (final e in sibRaw) {
      if (e is! Map) continue;
      sibs.add(MismatchSibling(
        accountId: '${e['account_id'] ?? ''}',
        accountName: '${e['account_name'] ?? ''}',
        currency: '${e['currency'] ?? ''}',
      ));
    }
    final options = MismatchOptions(
      accountId: '${d['account_id'] ?? ''}',
      accountName: '${d['account_name'] ?? ''}',
      accountCurrency: '${d['account_currency'] ?? ''}',
      requestedCurrency: '${d['requested_currency'] ?? ''}',
      amount: (d['amount'] as num?)?.toDouble() ?? 0,
      fxOptions: fx,
      siblings: sibs,
    );
    if (options.isEmpty) return null;
    _pendingMismatch = _MismatchPending(
      toolName: toolName,
      params: attemptedParams,
      options: options,
    );
    return buildMismatchQuestion(options, arabic: !_isEn());
  }

  /// Handles the user's reply to a pending mismatch choice. The reply only
  /// ever selects an option (or cancels) — it never executes a write.
  /// A chosen option resolves into params that go through the standard
  /// confirmation → execution → verification flow.
  Future<bool> _handleMismatchReply(String msg) async {
    final pending = _pendingMismatch;
    if (pending == null) return false;
    final arabic = !_isEn();
    final choice = parseMismatchChoice(msg, pending.options);
    if (choice.kind == 'cancel') {
      _pendingMismatch = null;
      _agentContext.cancel();
      setState(() {
        _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
        _addAssistantMessage(
            arabic ? 'تم إلغاء العملية.' : 'Operation cancelled.');
        _inputCtrl.clear();
      });
      _saveMessages();
      _scrollDown();
      return true;
    }
    if (choice.kind == 'unknown') {
      // Never guess: re-ask the same options instead of executing.
      setState(() {
        _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
        _addAssistantMessage(
            buildMismatchQuestion(pending.options, arabic: arabic));
        _inputCtrl.clear();
      });
      _saveMessages();
      _scrollDown();
      return true;
    }
    final resolved = Map<String, dynamic>.from(pending.params);
    if (choice.kind == 'fx' && choice.fx != null) {
      final fx = choice.fx!;
      resolved['account_id'] = fx.accountId;
      resolved['currency'] = fx.currency;
      resolved['amount'] = fx.converted;
    } else if (choice.kind == 'account' && choice.sibling != null) {
      resolved['account_id'] = choice.sibling!.accountId;
      // Currency stays the requested one — the sibling supports it natively.
    }
    final toolDef = AgentToolRegistry.findByName(pending.toolName);
    _pendingMismatch = null;
    if (toolDef != null && ConfirmationHandler.requiresConfirmation(toolDef)) {
      _agentContext.startCollecting(pending.toolName);
      _agentContext.updateCollectedParams(resolved);
      _agentContext.startConfirmation();
      final confirmMsg = ConfirmationHandler.buildConfirmationMessage(
          toolDef, resolved,
          lang: _chatLang());
      setState(() {
        _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
        _addAssistantMessage(confirmMsg);
        _inputCtrl.clear();
      });
      _saveMessages();
      _scrollDown();
    } else {
      setState(() {
        _messages.add(_ChatMessage(text: msg, role: MessageRole.user));
        _inputCtrl.clear();
      });
      _saveMessages();
      await _executeToolFromContext(pending.toolName, resolved);
    }
    return true;
  }

  /// Renders a tool outcome as plain text for background persistence — the
  /// same words the mounted path would show (mismatch options, recovery
  /// question, or tone + message). Pure display logic: safe after dispose.
  String _toolOutcomeText(
    String toolName,
    Map<String, dynamic> attemptedParams,
    ToolExecutionResult result,
  ) {
    final mismatchQ = _stashMismatch(toolName, attemptedParams, result);
    if (mismatchQ != null) return mismatchQ;
    String? recoveryQuestion;
    if (!result.success) {
      recoveryQuestion = _slotRecoveryQuestion(toolName, attemptedParams, result);
    }
    return recoveryQuestion ??
        '${saraToneOf(result)} ${_toolText(result.messageAr, result.messageEn)}';
  }

  /// Persists a tool outcome so a user who left mid-execution finds the
  /// result on return instead of silence. Never throws.
  Future<void> _persistToolOutcome(
    String saveKey,
    String toolName,
    Map<String, dynamic> params,
    ToolExecutionResult result,
  ) async {
    try {
      await ChatPersistence.instance.appendMessage(
        saveKey,
        ChatPersistMessage(
          id: 'tool_${DateTime.now().millisecondsSinceEpoch}',
          text: _toolOutcomeText(toolName, params, result),
          role: 'assistant',
          time: DateTime.now(),
        ),
      );
    } catch (_) {}
  }

  /// When a tool refuses to run because a slot is missing or invalid
  /// (error codes MISSING_* / INVALID_*), re-enter slot-filling with the
  /// already-known params and return the next organized question to ask.
  /// Returns null when the failure is NOT recoverable (real error to show).
  /// No setState here — callers render the returned question themselves.
  String? _slotRecoveryQuestion(
    String toolName,
    Map<String, dynamic> attemptedParams,
    ToolExecutionResult result,
  ) {
    final code = result.errorCode ?? '';
    if (!code.startsWith('MISSING_') && !code.startsWith('INVALID_')) {
      return null;
    }
    final toolDef = AgentToolRegistry.findByName(toolName);
    if (toolDef == null) return null;
    final merged = ParameterCollector.mergeParams(
      _agentContext.collectedParams,
      attemptedParams,
    );
    _agentContext.startCollecting(toolName);
    _agentContext.updateCollectedParams(merged);
    return ParameterCollector.nextQuestion(toolDef, merged, lang: _chatLang()) ??
        _toolText(result.messageAr, result.messageEn);
  }

  /// Execute a tool from AgentContext state (after params collected or confirmed).
  Future<void> _executeToolFromContext(String toolName, Map<String, dynamic> params) async {
    final visualGeneration = _ambient.generation;
    // Snapshot for the background tail (user may leave mid-execution).
    final bgKey = '${_getUserId()}_${widget.accountType}';
    _agentContext.startExecution();
    setState(() {
      _assistantStatus = AssistantStatus.executing;
      _addAssistantMessage(AppLocalizations.of(context).translate('saraExecuting'));
    });
    _scrollDown();

    try {
      final financeService = ref.read(personalFinanceServiceProvider);
      final toolExecutor = _wiredExecutor(financeService);
      final visualWork = _ambientToolStarted(toolName, generation: visualGeneration);
      final result = await toolExecutor.execute(toolName, params);
      _ambientToolFinished(result, visualWork);

      // User left mid-execution — persist the outcome instead of silence.
      if (!mounted) {
        await _persistToolOutcome(bgKey, toolName, params, result);
        return;
      }

      // Account/currency mismatch refusal → ask the numbered options.
      // The write stays refused until the user picks one explicitly.
      final mismatchQ = _stashMismatch(toolName, params, result);
      if (mismatchQ != null) {
        _agentContext.cancel();
        setState(() {
          _messages.removeLast(); // Remove "جاري التنفيذ"
          _addAssistantMessage(mismatchQ, visualGeneration: visualGeneration);
        });
        _scrollDown();
        return;
      }

      // Recoverable validation failure (missing/invalid slot) → ask the
      // next organized question instead of showing an error. Otherwise close.
      String? recoveryQuestion;
      if (!result.success) {
        recoveryQuestion = _slotRecoveryQuestion(toolName, params, result);
      }
      if (recoveryQuestion == null) {
        _agentContext.completeOperation(toolName, {
          'success': result.success,
          'message': _toolText(result.messageAr, result.messageEn),
        }, entityId: result.entityId, entityType: result.entityType);
      }

      final toolActions = <SaraAction>[];
      final tone = saraToneOf(result);
      if (result.entityId != null &&
          result.entityType != null &&
          result.verificationStatus != 'failed' &&
          result.verificationStatus != 'not_found') {
        toolActions.add(SaraAction(
          type: SaraActionType.openEntity,
          params: {
            'entity_type': result.entityType!,
            'id': result.entityId.toString(),
          },
          label: '${AppLocalizations.of(context).translate('actionShow')} ${_entityLabel(toolName)}',
        ));
      }

      setState(() {
        _messages.removeLast(); // Remove "جاري التنفيذ"
        if (result.success) {
          _addAssistantMessage('$tone ${_toolText(result.messageAr, result.messageEn)}', actions: toolActions, visualGeneration: visualGeneration);
        } else if (recoveryQuestion != null) {
          _addAssistantMessage(recoveryQuestion);
        } else {
          _addAssistantMessage('$tone ${_toolText(result.messageAr, result.messageEn)}', actions: toolActions, visualGeneration: visualGeneration);
        }
      });
      _scrollDown();
    } catch (e) {
      if (!mounted) return;
      _agentContext.cancel();
      setState(() {
        _messages.removeLast();
        _ambient.error(generation: visualGeneration);
        _addAssistantMessage('❌ ${AppLocalizations.of(context).translate('saraExecFailed')}', visualGeneration: visualGeneration);
      });
      _scrollDown();
    }
  }

  void _retry(String query) {
    _ambient.send();
    final visualGeneration = _ambient.generation;
    _busy = true;
    final l10n = AppLocalizations.of(context);
    final _sentAt = DateTime.now();
    setState(() {
      _assistantStatus = AssistantStatus.thinking;
    });
    _scrollDown();
    Future.delayed(const Duration(milliseconds: 800), () {
      if (!mounted || _isVoiceMessage) return;
      setState(() => _assistantStatus = AssistantStatus.preparing);
    });
    final user = ref.read(authProvider).user;
    final appState = SaraAppState(
      subscriptionPlan: user?.subscriptionPlan,
      subscriptionStatus: user?.effectiveStatus,
      currentTab: widget.accountType == 'personal'
          ? l10n.translate('personal')
          : l10n.translate('business'),
      lastScreen: _lastScreen,
      lastOperation: _lastOperation,
    );
    ref.read(aiServiceProvider).askQuestion(query,
        userName: user?.fullName,
        accountType: widget.accountType,
        currentScreen: _lastScreen,
        language: l10n.locale.languageCode,
        screenCatalog:
            SaraScreenCatalog.entries(arabic: l10n.locale.languageCode != 'en'),
        appState: appState).then((resp) async {
      _ambient.responseReady(visualGeneration);
      if (!mounted) return;
      final elapsed = DateTime.now().difference(_sentAt).inMilliseconds;
      final remaining = 1200 - elapsed;
      if (remaining > 0) {
        await Future.delayed(Duration(milliseconds: remaining));
        if (!mounted) return;
      }

      // Execute pending tools from Sara Agent
      if (resp.pendingTools.isNotEmpty) {
        // A sensitive tool anywhere in the batch is confirmed first.
        final firstTool = resp.pendingTools.firstWhere((t) {
          final def = AgentToolRegistry.findByName(t['tool'] as String? ?? '');
          return def != null && ConfirmationHandler.requiresConfirmation(def);
        }, orElse: () => resp.pendingTools.first);
        final toolName = firstTool['tool'] as String? ?? '';
        final toolParams = (firstTool['params'] as Map<String, dynamic>?) ?? {};
        final toolDef = AgentToolRegistry.findByName(toolName);

        if (toolDef != null && ConfirmationHandler.requiresConfirmation(toolDef)) {
          // Show confirmation card for sensitive operations
          setState(() {
            _messages.add(_ChatMessage(
              text: '',
              role: MessageRole.confirmation,
              confirmToolName: toolName,
              confirmParams: toolParams,
              confirmTitle: ConfirmationHandler.buildConfirmationMessage(toolDef, toolParams, lang: _chatLang()),
              confirmRiskLevel: toolDef.riskLevel,
            ));
          });
          _scrollDown();
        } else {
          // Execute directly
          _executeToolDirectly(toolName, toolParams, effectGeneration: visualGeneration);
        }
      }

      final cleaned = _cleanMarkdown(resp.text);
      
      {
        setState(() {
          _assistantStatus = AssistantStatus.connected;
          final actions = _withScreenLink(resp.userQuery ?? query, cleaned, resp.actions);
          final routeLink = SaraActionDispatcher.resolveRouteFromActions(actions);
          _addAssistantMessage(cleaned, routeLink: routeLink, actions: actions, visualGeneration: visualGeneration);
          _dynamicSuggestions = resp.suggestions;
        });
        _busy = false;
        _saveMessages();
        _scrollDown();
      }
    }).catchError((e) async {
      _ambient.error(generation: visualGeneration);
      if (!mounted) return;
      final elapsed = DateTime.now().difference(_sentAt).inMilliseconds;
      final remaining = 1200 - elapsed;
      if (remaining > 0) {
        await Future.delayed(Duration(milliseconds: remaining));
        if (!mounted) return;
      }
      setState(() {
        _assistantStatus = AssistantStatus.connected;
        _messages.add(_ChatMessage(text: _friendlyError(e, l10n), role: MessageRole.error, query: query));
      });
      _busy = false;
      _saveMessages();
      _scrollDown();
    });
  }

  Future<void> _pickImage() async {
    final file = await _imagePicker.pickImage(source: ImageSource.gallery, maxWidth: 1024, maxHeight: 1024);
    if (file != null && mounted) {
      setState(() { _pendingImage = file; _pendingFileName = null; });
    }
  }

  Future<void> _clearPending() async {
    setState(() { _pendingImage = null; _pendingFileName = null; });
  }

  Future<void> _startRecording() async {
    _inputTransitionCtrl.forward();
    final hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) { _inputTransitionCtrl.reverse(); return; }
    _composerFocus.unfocus();
    // Permanent folder — temporary dir gets wiped (this is why replays broke).
    final dir = await _permanentAudioDir();
    final path = '${dir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _audioRecorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    _recordingDuration = 0;
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (mounted) setState(() => _recordingDuration++);
    });
    _waveformTimer = Timer.periodic(const Duration(milliseconds: 150), (t) {
      if (mounted) setState(() => _waveformValue = Random().nextDouble());
    });
    setState(() => _isRecording = true);
  }

  Future<void> _stopRecording() async {
    _recordingTimer?.cancel();
    _waveformTimer?.cancel();
    final path = await _audioRecorder.stop();
    _inputTransitionCtrl.reverse();
    if (path != null && mounted) {
      setState(() { _pendingAudioPath = path; _isRecording = false; });
    } else {
      setState(() => _isRecording = false);
    }
  }

  Future<void> _playPreviewAudio() async {
    if (_pendingAudioPath == null) return;
    if (_isPlayingPreview) {
      await _audioPlayer.stop();
      if (mounted) setState(() => _isPlayingPreview = false);
      return;
    }
    setState(() => _isPlayingPreview = true);
    try {
      await _audioPlayer.play(DeviceFileSource(_pendingAudioPath!));
      _audioPlayer.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => _isPlayingPreview = false);
      });
    } catch (e) {
      if (mounted) setState(() => _isPlayingPreview = false);
    }
  }

  void _cancelPendingAudio() {
    _ambient.cancel();
    if (_pendingAudioPath != null) {
      final f = File(_pendingAudioPath!);
      if (f.existsSync()) f.delete();
    }
    setState(() {
      _pendingAudioPath = null;
      _isPlayingPreview = false;
      _recordingDuration = 0;
    });
  }

  void _sendPendingAudio() {
    if (_pendingAudioPath == null) return;
    _audioPath = _pendingAudioPath;
    _pendingAudioPath = null;
    _isPlayingPreview = false;
    _inputCtrl.clear();
    _send();
  }

  // ═══════════ Voice Agent (Text-to-Speech) ═══════════

  Future<void> _speak(String text, {bool addAsMessage = false}) async {
    if (text.isEmpty || _isSpeaking) return;
    setState(() => _isSpeaking = true);
    try {
      final isArabic = AppLocalizations.of(context).locale.languageCode == 'ar';
      final spokenText = isArabic ? TtsPreparation.prepare(text, lang: 'ar') : TtsPreparation.prepare(text, lang: 'en');
      final voice = isArabic ? 'nova' : 'shimmer';
      final bytes = await ref.read(aiServiceProvider).speak(spokenText, voice: voice, speed: _saraSpeed);
      if (bytes == null || bytes.isEmpty) return;
      
      // Save audio to permanent folder so it can be replayed even after the
      // temporary directory is cleared / the chat is revisited.
      final dir = await _permanentAudioDir();
      final fileName = 'sara_${DateTime.now().millisecondsSinceEpoch}.mp3';
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes);
      
      if (addAsMessage && mounted) {
        // Persist the spoken text (not empty) so memory can recall "what did you say?"
        // The audio file is the reference; the text is the source for retrieval.
        setState(() {
          _messages.add(_ChatMessage(
            text: text,
            role: MessageRole.assistantAudio,
            audioPath: file.path,
            audioDuration: 0,
            transcript: spokenText,
          ));
        });
        _scrollDown();
        _saveMessages();
        // Also ensure LLM history has the assistant text (already added via _history, but keep file in sync)
      }
      
      // DON'T auto-play — user taps to play
      if (mounted) setState(() => _isSpeaking = false);
    } catch (_) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.translate('voiceReplyUnavailable'), style: TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppColors.warning,
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ));
      }
    } finally {
      if (mounted && !_isSpeaking) setState(() => _isSpeaking = false);
    }
  }

  void _stopSpeaking() {
    _audioPlayer.stop();
    if (mounted) setState(() => _isSpeaking = false);
  }

  bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    // Page direction follows the app language: RTL for Arabic (natural
    // message layout, emojis and mixed names render correctly), LTR for
    // English. Previously forced to LTR which mirrored Arabic content.
    final isRtl = Localizations.localeOf(context).languageCode == 'ar';
    return _SaraIdentityScope(business: widget.accountType == 'business', child: Directionality(
      textDirection: isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
        child: Stack(children: [Scaffold(
        backgroundColor: _saraPageBg(context),
        appBar: _buildAppBar(),
        body: Stack(
          children: [
            Positioned.fill(child: SaraAmbientScene(key: _ambientSceneKey, controller: _ambient,
              activity: _ambientActivity, inputKey: _pendingAudioPath != null ? _ambientAudioKey : _ambientInputKey,
              avatarKey: _headerAvatarKey, userKey: _ambientUserKey, replyKey: _ambientReplyKey,
              enabled: !_introVisible, business: widget.accountType == 'business')),
            Column(children: [
              Expanded(child: _buildMessageList()),
              if (_dynamicSuggestions.isNotEmpty) _buildDynamicSuggestions()
              else if (widget.suggestedQuestions.isNotEmpty && _messages.length <= 2) _buildSuggestedGrid(),
              _buildPreviewBar(),
              _buildInputBar(),
            ]),
            Positioned.fill(child: SaraAmbientAccents(controller: _ambient, business: widget.accountType == 'business')),
            if (_showScrollDown)
              Positioned(
                left: 16, bottom: 80,
                child: GestureDetector(
                  onTap: () { _autoFollow = true; _scrollDown(); },
                  child: Container(
                    width: 38, height: 38,
                    decoration: BoxDecoration(
                      color: _saraCard(context),
                      borderRadius: BorderRadius.circular(19),
                      border: Border.all(color: _saraLine(context)),
                      boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 8, offset: Offset(0, 2))],
                    ),
                    child: Icon(Icons.keyboard_arrow_down, color: _saraSub(context), size: 20),
                  ),
                ),
              ),
          ],
        ),
      ),
      if (_introVisible) Positioned.fill(child: SaraFirstEncounter(targetKey: _headerAvatarKey,
        arabic: isRtl, onComplete: () {
          if (mounted) setState(() => _introVisible = false);
          unawaited(_sounds.stop());
        })),
      ]),
    ));
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _saraPageBg(context),
      toolbarHeight: 84,
      automaticallyImplyLeading: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleSpacing: 0,
      title: SaraIntelligentHeader(avatarKey: _headerAvatarKey, state: _visualState,
        onBack: () {
          if (context.canPop()) { context.pop(); }
          else { context.go(widget.accountType == 'business' ? RouteNames.dashboard : RouteNames.personalDashboard); }
        },
        onAvatarTap: () => unawaited(_sounds.play(SaraSound.tap)),
        arabic: !_isEn(), hidden: _introVisible, business: widget.accountType == 'business',
        name: widget.assistantName.isEmpty ? null : widget.assistantName),
      actions: const [],
    );
  }

  Widget _buildPreviewBar() {
    if (_pendingImage == null && _pendingFileName == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: _saraCard(context),
      child: Row(children: [
        if (_pendingImage != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(File(_pendingImage!.path), width: 36, height: 36, fit: BoxFit.cover),
          )
        else
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(color: AppColors.primary.withAlpha(20), borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.attach_file, color: AppColors.primary, size: 18),
          ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _pendingImage != null ? l10n.translate('attachedImage') : _pendingFileName ?? '',
            style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: _saraSub(context)),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        GestureDetector(
          onTap: _clearPending,
          child: Container(
            padding: const EdgeInsets.all(6),
            child: Icon(Icons.close, size: 16, color: _saraFaint(context)),
          ),
        ),
      ]),
    );
  }

  Widget _buildMessageList() {
    final lastUser = _messages.reversed.where((m) => const {MessageRole.user, MessageRole.image, MessageRole.audio}.contains(m.role)).firstOrNull?.id;
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _messages.length,
      itemBuilder: (_, i) {
        final msg = _messages[i];
        final prev = i > 0 ? _messages[i - 1] : null;
        final showDate = prev == null || !_sameDay(prev.time, msg.time);
        return Column(children: [
          if (showDate) _DateSeparator(date: msg.time),
          _AnimatedMessage(
            child: _buildMessageWidget(msg, isGrouped: prev?.role == msg.role && _sameDay(prev!.time, msg.time), anchorUser: msg.id == lastUser),
          ),
        ]);
      },
    );
  }

  Widget _buildMessageWidget(_ChatMessage msg, {bool isGrouped = false, bool anchorUser = false}) {
    final avatarBytes = ref.watch(avatarProvider);
    final l10n = AppLocalizations.of(context);
    switch (msg.role) {
      case MessageRole.user:
        return _UserBubble(text: msg.text, time: msg.time, isGrouped: isGrouped, avatarBytes: avatarBytes,
            anchorKey: anchorUser ? _ambientUserKey : null);
      case MessageRole.image:
        return KeyedSubtree(key: anchorUser ? _ambientUserKey : null,
            child: _ImageBubble(text: msg.text, imagePath: msg.imagePath, time: msg.time, isGrouped: isGrouped, avatarBytes: avatarBytes));
      case MessageRole.audio:
        return KeyedSubtree(key: anchorUser ? _ambientUserKey : null, child: _AudioBubble(
          text: msg.text, audioPath: msg.audioPath, duration: msg.audioDuration,
          time: msg.time, isGrouped: isGrouped,
          avatarBytes: avatarBytes,
        ));
      case MessageRole.assistantAudio:
        return _AssistantAudioBubble(
          audioPath: msg.audioPath, duration: msg.audioDuration,
          time: msg.time, isGrouped: isGrouped,
        );
      case MessageRole.assistant:
        return _AssistantBubble(
          key: ValueKey(msg.id),
          anchorKey: msg.id == _ambientReplyId ? _ambientReplyKey : null,
          text: saraDisplayText(msg.text, arabic: !_isEn()), time: msg.time, isGrouped: isGrouped,
          animate: _newReplyIds.contains(msg.id),
          onRevealStart: () {
            _ambient.replyStarted(msg.id, visible: _autoFollow || _ambientReplyVisible(msg.id));
            if (mounted) setState(() => _activeReveals.add(msg.id));
          },
          onRevealProgress: () { _ambient.word(msg.id); _scrollDown(); },
          onRevealComplete: () {
            _ambient.replyFinished(msg.id, visible: _ambientReplyVisible(msg.id));
            if (mounted) setState(() { _newReplyIds.remove(msg.id); _activeReveals.remove(msg.id); });
            Future<void>.delayed(const Duration(milliseconds: 120), () { if (mounted) _scrollDown(); });
          },
          routeLink: msg.routeLink,
          actions: msg.actions,
          onAction: (action) {
            _dispatcher ??= SaraActionDispatcher(context, ref);
            _dispatcher!.dispatch(action);
          },
          onCopy: () {
            Clipboard.setData(ClipboardData(text: msg.text));
            HapticFeedback.lightImpact();
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(l10n.translate('copied'), style: TextStyle(fontFamily: 'Cairo', color: Colors.white)),
              duration: Duration(seconds: 1),
              backgroundColor: AppColors.primary,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ));
          },
        );
      case MessageRole.confirmation:
        return _ConfirmationCard(
          title: msg.confirmTitle ?? '',
          params: msg.confirmParams ?? {},
          toolName: msg.confirmToolName ?? '',
          riskLevel: msg.confirmRiskLevel ?? RiskLevel.medium,
          onConfirm: () => _handleConfirmAction(msg),
          onCancel: () => _handleCancelAction(msg),
        );
      case MessageRole.typing:
        return const _TypingIndicator();
      case MessageRole.error:
        return _ErrorBubble(text: msg.text, query: msg.query ?? '', onRetry: _retry);
      case MessageRole.reportCard:
        return _ReportCard(text: msg.text);
    }
  }

  Widget _buildSuggestedGrid() {
    final qs = widget.suggestedQuestions;
    if (qs.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
      child: Wrap(
        spacing: 6, runSpacing: 6,
        children: qs.map((q) => Listener(onPointerDown: (event) {
          if (!_busy) _ambient.suggestion(_ambientPoint(event.position));
        }, child: SaraPressable(child: ActionChip(
          label: Text(q, style: TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w600,
              color: _saraLight(context) ? AppColors.primary : const Color(0xFFF1B5C0))),
          backgroundColor: _saraBubble(context),
          side: BorderSide(color: AppColors.primary.withAlpha(_saraLight(context) ? 45 : 80), width: 0.7),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          onPressed: _busy ? null : () => _send(text: q),
        )))).toList(),
      ),
    );
  }

  Widget _buildDynamicSuggestions() {
    if (_dynamicSuggestions.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: _dynamicSuggestions.map((q) => Padding(
          padding: const EdgeInsetsDirectional.only(end: 8),
          child: Listener(onPointerDown: (event) {
            if (!_busy) _ambient.suggestion(_ambientPoint(event.position));
          }, child: ActionChip(
            label: Text(q, style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: _saraSub(context))),
            backgroundColor: _saraCard(context),
            side: BorderSide(color: _saraLine(context), width: 0.7),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            onPressed: _busy ? null : () { setState(() => _dynamicSuggestions = []); _send(text: q); },
          )),
        )).toList()),
      ),
    );
  }

  Widget _buildInputBar() {
    final hasText = _inputCtrl.text.trim().isNotEmpty;
    final hasAttachment = _pendingImage != null || _pendingFileName != null;
    final canSend = (hasText || hasAttachment) && !_busy;

    return Container(
      padding: EdgeInsets.only(
        left: 12, right: 12, top: 6,
        bottom: MediaQuery.of(context).padding.bottom + 10,
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: _isRecording
            ? _buildRecordingInput()
            : _pendingAudioPath != null
                ? _buildAudioPreviewInput()
                : _buildTextInput(canSend, hasText),
      ),
    );
  }

  Widget _buildTextInput(bool canSend, bool hasText) {
    final light = _saraLight(context);
    final focused = _composerFocus.hasFocus;
    Widget tool(IconData icon, VoidCallback onTap, {Color? color, String? tooltip}) => Semantics(
      button: true, label: tooltip,
      child: InkResponse(onTap: onTap, radius: 22, child: SizedBox(width: 40, height: 40,
          child: Icon(icon, color: color ?? _saraSub(context), size: 22))));
    // One floating composer (Gemini-like): attachments, text and voice in a
    // single soft pill; the send button lights up in the brand gradient.
    return AnimatedContainer(
      key: const ValueKey('text_input'),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      decoration: BoxDecoration(
        color: light ? Colors.white.withAlpha(242) : const Color(0xFF1B1C21).withAlpha(240),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: focused ? AppColors.primary.withAlpha(light ? 45 : 60) : _saraLine(context),
          width: focused ? 1 : 0.7),
        boxShadow: [BoxShadow(
          color: (focused ? AppColors.primary : Colors.black).withAlpha(light ? (focused ? 16 : 10) : (focused ? 30 : 34)),
          blurRadius: focused ? 26 : 18, offset: const Offset(0, 6))],
      ),
      child: Row(
        key: _ambientInputKey,
        textDirection: ui.TextDirection.ltr,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          GestureDetector(
            onTap: canSend ? () => _send() : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 44, height: 44,
              decoration: BoxDecoration(
                gradient: canSend ? const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                    colors: [Color(0xFFC2334F), AppColors.primary, Color(0xFF7A1020)]) : null,
                color: canSend ? null : (light ? const Color(0xFFF1EDEF) : const Color(0xFF25272D)),
                shape: BoxShape.circle,
                boxShadow: canSend ? [BoxShadow(color: AppColors.primary.withAlpha(80), blurRadius: 14, offset: const Offset(0, 4))] : null,
              ),
              child: Transform.flip(
                flipX: true,
                child: Icon(_busy ? Icons.hourglass_bottom : Icons.send_rounded, color: canSend ? Colors.white : _saraFaint(context), size: 20),
              ),
            ),
          ),
          Expanded(
            child: FyonaTextField(
              controller: _inputCtrl,
              focusNode: _composerFocus,
              onTap: _ambient.touchInput,
              textAlign: TextAlign.right,
              textInputAction: TextInputAction.send,
              maxLines: 5, minLines: 1,
              textDirection: ui.TextDirection.rtl,
              onChanged: (value) { _ambient.edit(value); setState(() {}); },
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: widget.inputHint,
                hintTextDirection: ui.TextDirection.rtl,
                hintStyle: TextStyle(fontFamily: 'Cairo', fontSize: 14, color: _saraFaint(context)),
                border: InputBorder.none,
                // The pill is the field: no theme focus frame inside it.
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              style: TextStyle(fontFamily: 'Cairo', fontSize: 14.5, color: _saraText(context), height: 1.35),
            ),
          ),
          tool(Icons.image_outlined, _pickImage, tooltip: _isEn() ? 'Image' : 'صورة'),
          tool(_isRecording ? Icons.stop_rounded : Icons.mic, _isRecording ? _stopRecording : _startRecording,
              color: _isRecording ? AppColors.danger : null, tooltip: _isEn() ? 'Voice' : 'رسالة صوتية'),
        ],
      ),
    );
  }

  Widget _buildRecordingInput() {
    final mins = (_recordingDuration ~/ 60).toString().padLeft(2, '0');
    final secs = (_recordingDuration % 60).toString().padLeft(2, '0');

    return Container(
      key: const ValueKey('recording_input'),
      height: 40,
      margin: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        color: _saraCard(context),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.danger.withAlpha(80), width: 0.5),
      ),
      child: Row(
        textDirection: ui.TextDirection.ltr,
        children: [
          const SizedBox(width: 12),
          Container(
            width: 10, height: 10,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.danger),
          ),
          const SizedBox(width: 8),
          Text('$mins:$secs',
            style: TextStyle(fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w600, color: _saraText(context))),
          const SizedBox(width: 10),
          Expanded(child: _buildLiveWaveform()),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _stopRecording,
            child: Container(
              width: 36, height: 36,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: AppColors.danger,
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(Icons.stop_rounded, color: Colors.white, size: 18),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _buildLiveWaveform() {
    return SizedBox(
      height: 28,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(20, (i) {
          final base = 4.0 + (i % 3 == 0 ? 2.0 : 0.0);
          final h = base + _waveformValue * 18 * (0.5 + 0.5 * ((i * 7 + _recordingDuration * 3) % 10) / 10);
          return AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 3,
            height: h.clamp(4.0, 28.0),
            margin: const EdgeInsetsDirectional.only(end: 2),
            decoration: BoxDecoration(
              color: AppColors.danger.withAlpha(180),
              borderRadius: BorderRadius.circular(1.5),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildAudioPreviewInput() {
    final mins = (_recordingDuration ~/ 60).toString().padLeft(2, '0');
    final secs = (_recordingDuration % 60).toString().padLeft(2, '0');
    return Container(
      key: const ValueKey('audio_preview_input'),
      height: 40,
      margin: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        color: _saraCard(context),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.primary.withAlpha(60), width: 0.5),
      ),
      child: Row(
        textDirection: ui.TextDirection.ltr,
        children: [
          const SizedBox(width: 4),
          GestureDetector(
            onTap: _sendPendingAudio,
            child: Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Transform.flip(flipX: true, child: const Icon(Icons.send_rounded, color: Colors.white, size: 16)),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: _playPreviewAudio,
            child: Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: AppColors.primary.withAlpha(30),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                _isPlayingPreview ? Icons.stop_rounded : Icons.play_arrow_rounded,
                color: AppColors.primary, size: 18,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(key: _ambientAudioKey, child: Align(alignment: Alignment.centerLeft,
              child: FittedBox(fit: BoxFit.scaleDown, child: _buildStaticWaveform(dark: true)))),
          const SizedBox(width: 8),
          Text('$mins:$secs',
            style: TextStyle(fontFamily: 'Cairo', fontSize: 13, fontWeight: FontWeight.w600, color: _saraText(context))),
          const SizedBox(width: 8),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: _cancelPendingAudio,
            child: Container(
              width: 32, height: 32,
              decoration: BoxDecoration(
                color: _saraLine(context),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(Icons.close_rounded, color: _saraSub(context), size: 16),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _buildStaticWaveform({bool dark = false}) {
    const heights = [4.0, 8.0, 14.0, 20.0, 16.0, 22.0, 18.0, 24.0, 20.0, 14.0, 22.0, 18.0, 26.0, 20.0, 14.0, 8.0, 16.0, 22.0, 18.0, 12.0, 8.0, 4.0];
    final color = dark ? _saraFaint(context) : const Color(0x99FFFFFF);
    return SizedBox(
      height: 28,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: heights.map((h) => Container(
          width: 3,
          height: h,
          margin: const EdgeInsetsDirectional.only(end: 1.5),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(1.5)),
        )).toList(),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  SARA AVATAR — Custom Painted Professional Female Avatar
// ═══════════════════════════════════════════════════════════════

class _SaraAvatar extends StatelessWidget {
  final double size;
  const _SaraAvatar({this.size = 38});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: AppColors.primary.withAlpha(80), blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: Image.asset('assets/images/sara_avatar.jpg',
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFFA01530), Color(0xFF6B0F20)], begin: Alignment.topLeft, end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Center(child: Text('S', style: TextStyle(fontFamily: 'Cairo', fontSize: size * 0.5, fontWeight: FontWeight.w600, color: Colors.white))),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  USER AVATAR
// ═══════════════════════════════════════════════════════════════

class _SaraIdentityScope extends InheritedWidget {
  final bool business;
  const _SaraIdentityScope({required this.business, required super.child});
  @override
  bool updateShouldNotify(_SaraIdentityScope oldWidget) => business != oldWidget.business;
}

class _UserAvatar extends ConsumerWidget {
  final Uint8List? bytes;
  final double size;
  const _UserAvatar({this.bytes, this.size = 30});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final business = context.dependOnInheritedWidgetOfExactType<_SaraIdentityScope>()?.business ?? false;
    if (business) {
      if (BranchScope.allMode) return Icon(Icons.hub_rounded, size: size, color: AppColors.primary);
      final branch = ref.watch(branchesProvider).valueOrNull
          ?.where((b) => '${b['id']}' == BranchScope.branchId).firstOrNull;
      final raw = '${branch?['image'] ?? ''}'.trim();
      final fallback = Icon(Icons.store_rounded, size: size * .6, color: AppColors.primary);
      // A picture saved on this device (offline) or the uploaded one, kept in
      // the image cache so it also shows without internet.
      final url = raw.startsWith('local://') ? null : serverImageUrl(raw);
      final Widget? picture = raw.startsWith('local://')
          ? Image.file(File(raw.substring('local://'.length)), width: size, height: size,
              fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback)
          : url == null
          ? null
          : SecureImage(url: url, deviceKey: 'branch_${BranchScope.branchId}', width: size, height: size, fit: BoxFit.cover,
              placeholder: fallback, errorBuilder: (_, _, _) => fallback);
      return BranchPicture(
          branchId: BranchScope.branchId,
          size: size,
          fallback: CircleAvatar(radius: size / 2, backgroundColor: AppColors.primary.withAlpha(20),
              child: picture == null ? fallback : ClipOval(child: picture)));
    }
    final photo = ref.watch(sectionProfileProvider).avatar ?? ref.watch(avatarProvider) ?? bytes;
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: _saraAvatarBg(context)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: photo != null
            ? Image.memory(photo, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _fallback(context))
            : _fallback(context),
      ),
    );
  }

  // User slots show only the user photo (or a person icon) — never
  // the company logo.
  Widget _fallback(BuildContext context) =>
      Icon(Icons.person, color: _saraFaint(context), size: 18);
}

// ═══════════════════════════════════════════════════════════════
//  DATE SEPARATOR
// ═══════════════════════════════════════════════════════════════

class _DateSeparator extends StatelessWidget {
  final DateTime date;
  const _DateSeparator({required this.date});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final diff = now.difference(date).inDays;
    String label;
    if (diff == 0) label = l10n.translate('today');
    else if (diff == 1) label = l10n.translate('yesterday');
    else label = localizedShortDate(context, date);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(children: [
        Expanded(child: Divider(color: _saraLine(context), height: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(label, style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: _saraFaint(context))),
        ),
        Expanded(child: Divider(color: _saraLine(context), height: 1)),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  ANIMATED MESSAGE WRAPPER
// ═══════════════════════════════════════════════════════════════

class _AnimatedMessage extends StatefulWidget {
  final Widget child;
  const _AnimatedMessage({required this.child});
  @override
  State<_AnimatedMessage> createState() => _AnimatedMessageState();
}

class _AnimatedMessageState extends State<_AnimatedMessage> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 250));
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
    _ctrl.forward();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: _anim, child: widget.child);
}

// ═══════════════════════════════════════════════════════════════
//  USER BUBBLE — Right-aligned, Red
// ═══════════════════════════════════════════════════════════════

class _UserBubble extends StatelessWidget {
  final String text;
  final DateTime time;
  final bool isGrouped;
  final Uint8List? avatarBytes;
  final GlobalKey? anchorKey;
  const _UserBubble({required this.text, required this.time, this.isGrouped = false, this.avatarBytes, this.anchorKey});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Message bubbles copy on press — quiet for the Information Clicker.
    return ClickerQuiet(
      child: Padding(
      padding: EdgeInsets.only(top: isGrouped ? 1 : 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        textDirection: ui.TextDirection.ltr,
        children: [
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                GestureDetector(
                  onLongPress: () {
                    HapticFeedback.lightImpact();
                    if (text.isNotEmpty) {
                      Clipboard.setData(ClipboardData(text: text));
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(l10n.translate('copied'), style: TextStyle(fontFamily: 'Cairo', color: Colors.white)),
                        duration: Duration(seconds: 1),
                        backgroundColor: AppColors.primary,
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ));
                    }
                  },
                  child: Container(
                    key: anchorKey,
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
                          colors: [Color(0xFFB8243F), Color(0xFFA01530), Color(0xFF861127)]),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(20),
                        topRight: isGrouped ? const Radius.circular(8) : const Radius.circular(20),
                        bottomLeft: const Radius.circular(20),
                        bottomRight: const Radius.circular(6),
                      ),
                      boxShadow: [BoxShadow(color: AppColors.primary.withAlpha(45), blurRadius: 14, offset: const Offset(0, 5))],
                    ),
                    child: Text(text, style: const TextStyle(fontFamily: 'Cairo', fontSize: 14, color: Colors.white, height: 1.4)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(DateFormat('HH:mm').format(time), style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: _saraFaint(context))),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _UserAvatar(bytes: avatarBytes, size: 28),
        ],
      ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  IMAGE BUBBLE — Right-aligned user image
// ═══════════════════════════════════════════════════════════════

class _ImageBubble extends StatelessWidget {
  final String text;
  final String? imagePath;
  final DateTime time;
  final bool isGrouped;
  final Uint8List? avatarBytes;
  const _ImageBubble({required this.text, this.imagePath, required this.time, this.isGrouped = false, this.avatarBytes});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Message bubbles copy on press — quiet for the Information Clicker.
    return ClickerQuiet(
      child: Padding(
      padding: EdgeInsets.only(top: isGrouped ? 1 : 6),
      child: Align(
        alignment: Alignment.centerRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          textDirection: ui.TextDirection.ltr,
          children: [
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  GestureDetector(
                    onLongPress: () {
                      HapticFeedback.lightImpact();
                      if (text.isNotEmpty) {
                        Clipboard.setData(ClipboardData(text: text));
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(l10n.translate('copied'), style: TextStyle(fontFamily: 'Cairo', color: Colors.white)),
                          duration: Duration(seconds: 1),
                          backgroundColor: AppColors.primary,
                          behavior: SnackBarBehavior.floating,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ));
                      }
                    },
                    child: Container(
                      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.65),
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFA01530),
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(18),
                          topRight: isGrouped ? const Radius.circular(6) : const Radius.circular(18),
                          bottomLeft: const Radius.circular(18),
                          bottomRight: const Radius.circular(6),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (imagePath != null)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.file(File(imagePath!), width: 200, height: 160, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(
                                width: 200, height: 160,
                                color: Colors.white12,
                                child: const Icon(Icons.broken_image, color: Colors.white54, size: 40),
                              )),
                            ),
                          if (text.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(text, style: const TextStyle(fontFamily: 'Cairo', fontSize: 13, color: Colors.white, height: 1.4)),
                          ],
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(DateFormat('HH:mm').format(time), style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: _saraFaint(context))),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _UserAvatar(bytes: avatarBytes, size: 30),
          ],
        ),
      ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  AUDIO BUBBLE — Right-aligned user audio
// ═══════════════════════════════════════════════════════════════

class _AudioBubble extends StatefulWidget {
  final String text;
  final String? audioPath;
  final int duration;
  final DateTime time;
  final bool isGrouped;
  final Uint8List? avatarBytes;
  const _AudioBubble({
    required this.text, this.audioPath, required this.duration,
    required this.time, this.isGrouped = false, this.avatarBytes,
  });

  @override
  State<_AudioBubble> createState() => _AudioBubbleState();
}

class _AudioBubbleState extends State<_AudioBubble> {
  final _player = AudioPlayer();
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onPositionChanged.listen((p) { if (mounted) setState(() => _position = p); });
    _player.onDurationChanged.listen((d) { if (mounted) setState(() => _total = d); });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() { _playing = false; _position = Duration.zero; });
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (widget.audioPath == null) return;
    if (_playing) {
      await _player.pause();
      if (mounted) setState(() => _playing = false);
    } else {
      try {
        await _player.play(DeviceFileSource(widget.audioPath!));
        if (mounted) setState(() => _playing = true);
      } catch (_) {}
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final totalSec = _total.inSeconds > 0 ? _total.inSeconds : widget.duration;
    final progress = totalSec > 0 ? _position.inSeconds / totalSec : 0.0;
    final mins = (widget.duration ~/ 60).toString().padLeft(2, '0');
    final secs = (widget.duration % 60).toString().padLeft(2, '0');

    // Message bubbles copy on press — quiet for the Information Clicker.
    return ClickerQuiet(
      child: Padding(
      padding: EdgeInsets.only(top: widget.isGrouped ? 1 : 6),
      child: Align(
        alignment: Alignment.centerRight,
        child: Row(
          textDirection: ui.TextDirection.ltr,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFA01530),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(18),
                        topRight: widget.isGrouped ? const Radius.circular(6) : const Radius.circular(18),
                        bottomLeft: const Radius.circular(18),
                        bottomRight: const Radius.circular(6),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GestureDetector(
                              onTap: _togglePlay,
                              child: Container(
                                width: 32, height: 32,
                                decoration: BoxDecoration(color: Colors.white.withAlpha(30), shape: BoxShape.circle),
                                child: Icon(_playing ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 18),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _buildWaveform(progress),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _playing ? _fmt(_position) : '$mins:$secs',
                              style: const TextStyle(fontFamily: 'Cairo', fontSize: 11, color: Colors.white70),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (widget.text.isNotEmpty && widget.text != AppLocalizations.of(context).translate('saraVoiceMessage'))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(widget.text, style: TextStyle(fontFamily: 'Cairo', fontSize: 12, color: _saraFaint(context))),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(DateFormat('HH:mm').format(widget.time), style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: _saraFaint(context))),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _UserAvatar(bytes: widget.avatarBytes, size: 30),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildWaveform(double progress) {
    const barCount = 24;
    const barHeights = [0.3, 0.5, 0.7, 0.9, 1.0, 0.8, 0.6, 0.9, 1.0, 0.7, 0.5, 0.8,
                        1.0, 0.6, 0.4, 0.7, 0.9, 1.0, 0.8, 0.5, 0.7, 0.9, 0.6, 0.4];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(barCount, (i) {
        final barProgress = i / barCount;
        final active = barProgress <= progress;
        return Container(
          width: 3, height: 16 * barHeights[i],
          margin: const EdgeInsets.symmetric(horizontal: 0.5),
          decoration: BoxDecoration(
            color: active ? Colors.white : Colors.white.withAlpha(60),
            borderRadius: BorderRadius.circular(1.5),
          ),
        );
      }),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  ASSISTANT AUDIO BUBBLE — Left-aligned with Sara's avatar
// ═══════════════════════════════════════════════════════════════

class _AssistantAudioBubble extends StatefulWidget {
  final String? audioPath;
  final int duration;
  final DateTime time;
  final bool isGrouped;
  const _AssistantAudioBubble({
    this.audioPath, required this.duration,
    required this.time, this.isGrouped = false,
  });

  @override
  State<_AssistantAudioBubble> createState() => _AssistantAudioBubbleState();
}

class _AssistantAudioBubbleState extends State<_AssistantAudioBubble> {
  final _player = AudioPlayer();
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _total = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onPositionChanged.listen((p) { if (mounted) setState(() => _position = p); });
    _player.onDurationChanged.listen((d) { if (mounted) setState(() => _total = d); });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() { _playing = false; _position = Duration.zero; });
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (widget.audioPath == null) return;
    if (_playing) {
      await _player.pause();
      if (mounted) setState(() => _playing = false);
    } else {
      try {
        await _player.play(DeviceFileSource(widget.audioPath!));
        if (mounted) setState(() => _playing = true);
      } catch (_) {}
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final totalSec = _total.inSeconds > 0 ? _total.inSeconds : widget.duration;
    final progress = totalSec > 0 ? _position.inSeconds / totalSec : 0.0;

    // Message bubbles copy on press — quiet for the Information Clicker.
    return ClickerQuiet(
      child: Padding(
      padding: EdgeInsets.only(top: widget.isGrouped ? 1 : 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        textDirection: ui.TextDirection.ltr,
        children: [
          const _SaraAvatar(size: 30),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _saraCard(context),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: _togglePlay,
                        child: Container(
                          width: 32, height: 32,
                          decoration: BoxDecoration(color: AppColors.primary.withAlpha(30), shape: BoxShape.circle),
                          child: Icon(_playing ? Icons.pause : Icons.play_arrow, color: AppColors.primary, size: 18),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: List.generate(24, (i) {
                            const barHeights = [0.3, 0.5, 0.7, 0.9, 1.0, 0.8, 0.6, 0.9, 1.0, 0.7, 0.5, 0.8,
                                                1.0, 0.6, 0.4, 0.7, 0.9, 1.0, 0.8, 0.5, 0.7, 0.9, 0.6, 0.4];
                            final barProgress = i / 24;
                            final active = barProgress <= progress;
                            return Container(
                              width: 3, height: 16 * barHeights[i],
                              margin: const EdgeInsets.symmetric(horizontal: 0.5),
                              decoration: BoxDecoration(
                                color: active ? AppColors.primary : AppColors.primary.withAlpha(40),
                                borderRadius: BorderRadius.circular(1.5),
                              ),
                            );
                          }),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _playing ? _fmt(_position) : _fmt(_total),
                        style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ],
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
//  CONFIRMATION CARD — In-chat confirmation for sensitive operations
// ═══════════════════════════════════════════════════════════════

class _ConfirmationCard extends ConsumerWidget {
  final String title;
  final Map<String, dynamic> params;
  final String toolName;
  final RiskLevel riskLevel;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const _ConfirmationCard({
    required this.title,
    required this.params,
    required this.toolName,
    required this.riskLevel,
    required this.onConfirm,
    required this.onCancel,
  });

  Color _riskColor() {
    switch (riskLevel) {
      case RiskLevel.critical: return Color(0xFFD32F2F);
      case RiskLevel.high: return Color(0xFFFF6B35);
      case RiskLevel.medium: return AppColors.primary;
      case RiskLevel.low: return AppColors.primary;
    }
  }

  IconData _riskIcon() {
    switch (riskLevel) {
      case RiskLevel.critical: return Icons.error_outline;
      case RiskLevel.high: return Icons.warning_amber_rounded;
      case RiskLevel.medium: return Icons.info_outline;
      case RiskLevel.low: return Icons.check_circle_outline;
    }
  }

  String _toolDisplayName(BuildContext context) {
    final isEn = AppLocalizations.of(context).locale.languageCode == 'en';
    const namesAr = {
      'delete_bank_account': 'حذف حساب بنكي',
      'update_bank_account': 'تحديث حساب بنكي',
      'create_bank_account': 'إنشاء حساب بنكي',
      'delete_savings_goal': 'حذف هدف ادخار',
      'update_savings_goal': 'تحديث هدف ادخار',
      'contribute_to_goal': 'إضافة مبلغ لهدف',
      'delete_debt': 'حذف دين',
      'update_debt': 'تحديث دين',
      'pay_debt': 'سداد دين',
      'create_debt': 'إنشاء دين',
      'update_budget': 'تحديث ميزانية',
      'delete_budget': 'حذف ميزانية',
      'delete_transaction': 'حذف معاملة',
      'delete_recurring': 'حذف معاملة متكررة',
      'update_recurring': 'تحديث معاملة متكررة',
    };
    const namesEn = {
      'delete_bank_account': 'Delete Bank Account',
      'update_bank_account': 'Update Bank Account',
      'create_bank_account': 'Create Bank Account',
      'delete_savings_goal': 'Delete Savings Goal',
      'update_savings_goal': 'Update Savings Goal',
      'contribute_to_goal': 'Contribute to Goal',
      'delete_debt': 'Delete Debt',
      'update_debt': 'Update Debt',
      'pay_debt': 'Pay Debt',
      'create_debt': 'Create Debt',
      'update_budget': 'Update Budget',
      'delete_budget': 'Delete Budget',
      'delete_transaction': 'Delete Transaction',
      'delete_recurring': 'Delete Recurring Transaction',
      'update_recurring': 'Update Recurring Transaction',
    };
    final names = isEn ? namesEn : namesAr;
    final def = AgentToolRegistry.findByName(toolName);
    return names[toolName] ?? (isEn ? def?.descriptionEn : def?.nameAr) ?? (isEn ? 'Confirm operation' : 'تأكيد العملية');
  }

  String _paramDisplayName(String key, BuildContext context) {
    final isEn = AppLocalizations.of(context).locale.languageCode == 'en';
    const namesAr = {
      'name': 'الاسم', 'amount': 'المبلغ', 'currency': 'العملة',
      'person_name': 'الشخص', 'goal_id': 'الهدف', 'debt_id': 'الدين',
      'target_amount': 'المبلغ المستهدف', 'description': 'الوصف',
      'due_date': 'تاريخ الاستحقاق', 'notes': 'ملاحظات',
      'current_amount': 'المبلغ الحالي',
    };
    const namesEn = {
      'name': 'Name', 'amount': 'Amount', 'currency': 'Currency',
      'person_name': 'Person', 'goal_id': 'Goal', 'debt_id': 'Debt',
      'target_amount': 'Target Amount', 'description': 'Description',
      'due_date': 'Due Date', 'notes': 'Notes',
      'current_amount': 'Current Amount',
    };
    final names = isEn ? namesEn : namesAr;
    return names[key] ?? key;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final riskColor = _riskColor();
    final l10n = AppLocalizations.of(context);
    final isEn = l10n.locale.languageCode == 'en';
    final resolved = Map<String, dynamic>.from(params);
    final accounts = ref.watch(personal_ui.personalFinanceProvider).bankAccounts;
    var missingAccount = false;
    for (final key in const ['account_id', 'bank_account_id', 'from_account_id', 'to_account_id']) {
      if (params[key] == null) continue;
      final account = accounts.where((a) => a.id == '${params[key]}').firstOrNull;
      if (account == null) { missingAccount = true; continue; }
      resolved[key.replaceFirst(RegExp(r'_id$'), '_name')] = account.bankName;
    }
    final displayParams = Map<String, String>.fromEntries(saraDetailRows(resolved, arabic: !isEn));

    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: _saraConfirmBg(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: riskColor.withOpacity(0.3), width: 1.5),
        boxShadow: [
          BoxShadow(color: riskColor.withOpacity(0.1), blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: riskColor.withOpacity(0.12),
              borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
            ),
            child: Row(
              children: [
                Icon(_riskIcon(), color: riskColor, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _toolDisplayName(context),
                    style: TextStyle(
                      fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.bold,
                      color: riskColor,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Params list
          if (missingAccount) Padding(padding: const EdgeInsets.all(12), child: Column(children: [
            Text(isEn ? 'The account is unavailable. Refresh your data and prepare the operation again.'
                : 'الحساب غير متاح حاليًا. حدّث بياناتك وأعد تجهيز العملية.', style: const TextStyle(fontFamily: 'Cairo', height: 1.6)),
            TextButton(onPressed: () => ref.read(personal_ui.personalFinanceProvider.notifier).load(),
                child: Text(isEn ? 'Refresh accounts' : 'تحديث الحسابات')),
          ])),
          if (displayParams.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: displayParams.entries.map((e) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_paramDisplayName(e.key, context)}: ',
                        style: TextStyle(
                          fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w600,
                          color: _saraCardStrong(context),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '${e.value}',
                          style: TextStyle(
                            fontFamily: 'Cairo', fontSize: 12, color: _saraCardSoft(context),
                          ),
                        ),
                      ),
                    ],
                  ),
                )).toList(),
              ),
            ),

          // Critical warning
          if (riskLevel == RiskLevel.critical)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
              child: Text(
                isEn ? '⚠️ This action cannot be undone!' : '⚠️ هذه العملية لا يمكن التراجع عنها!',
                style: TextStyle(
                  fontFamily: 'Cairo', fontSize: 11, color: Color(0xFFEF5350),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

          // Buttons
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: missingAccount ? null : onConfirm,
                    icon: Icon(Icons.check_circle_outline, size: 18),
                    label: Text(isEn ? 'Confirm' : 'تأكيد التنفيذ', style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: riskColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      elevation: 0,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onCancel,
                    icon: Icon(Icons.cancel_outlined, size: 18),
                    label: Text(isEn ? 'Cancel' : 'إلغاء', style: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _saraCardStrong(context),
                      side: BorderSide(color: _saraLine(context)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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

// ═══════════════════════════════════════════════════════════════
//  ASSISTANT BUBBLE — Left-aligned, Dark Gray, with Avatar
// ═══════════════════════════════════════════════════════════════

class _AssistantBubble extends StatelessWidget {
  final String text;
  final DateTime time;
  final bool isGrouped;
  final VoidCallback onCopy;
  final String? routeLink;
  final List<SaraAction> actions;
  final void Function(SaraAction) onAction;
  final bool animate;
  final GlobalKey? anchorKey;
  final VoidCallback? onRevealStart, onRevealProgress, onRevealComplete;
  const _AssistantBubble({super.key, required this.text, required this.time, required this.onCopy, this.isGrouped = false, this.routeLink, this.actions = const [], required this.onAction,
    this.animate = false, this.onRevealStart, this.onRevealProgress, this.onRevealComplete, this.anchorKey});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Sara's message always sits on the LEFT of the screen with her avatar to
    // its left — same as the user's bubble on the RIGHT — in BOTH languages.
    // Forcing LTR here keeps Sara's bubbles on the left even when the app is
    // RTL (Arabic), so user/Sara are never on the same side.
    final isRtl = Localizations.localeOf(context).languageCode == 'ar';
    final msgDir = isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr;
    // Message bubbles copy on press — quiet for the Information Clicker.
    return ClickerQuiet(
      child: Padding(
      padding: EdgeInsets.only(top: isGrouped ? 1 : 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        textDirection: ui.TextDirection.ltr,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: GestureDetector(
              onTap: onCopy,
              child: _SaraAvatar(size: 32),
            ),
          ),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onLongPress: onCopy,
                child: Container(
                  key: anchorKey,
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    decoration: BoxDecoration(
                      color: _saraBubble(context),
                      border: Border.all(color: _saraLine(context), width: 0.6),
                      borderRadius: BorderRadius.only(
                        topLeft: isGrouped ? const Radius.circular(8) : const Radius.circular(20),
                        topRight: const Radius.circular(20),
                        bottomLeft: const Radius.circular(6),
                        bottomRight: const Radius.circular(20),
                      ),
                      boxShadow: [BoxShadow(color: Colors.black.withAlpha(_saraLight(context) ? 10 : 30), blurRadius: 16, offset: const Offset(0, 4))],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SaraWordReveal(text: text, animate: animate, direction: msgDir,
                            onStart: onRevealStart, onProgress: onRevealProgress, onComplete: onRevealComplete,
                            style: TextStyle(fontFamily: 'Cairo', fontSize: 14, color: _saraText(context), height: 1.8)),
                        if (routeLink != null) ...[
                          const SizedBox(height: 10),
                          // A real link: names the screen it opens and goes
                          // straight to its route (with the record's id).
                          Semantics(button: true, link: true, child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => openSaraRoute(context, routeLink!),
                            child: Ink(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(colors: [AppColors.primary.withAlpha(30), AppColors.primary.withAlpha(12)]),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: AppColors.primary.withAlpha(70)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.open_in_new_rounded, size: 14, color: AppColors.primary),
                                  const SizedBox(width: 6),
                                  Flexible(child: Text(saraRouteLinkLabel(routeLink!, arabic: isRtl) ?? l10n.translate('goToSection'),
                                      maxLines: 1, overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.primary))),
                                  const SizedBox(width: 4),
                                  Icon(isRtl ? Icons.chevron_left_rounded : Icons.chevron_right_rounded, size: 16, color: AppColors.primary),
                                ],
                              ),
                            ),
                          )),
                        ],
                        if (actions.where((a) => a.type != SaraActionType.refreshData).isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: actions.where((a) => a.type != SaraActionType.refreshData).map((a) {
                              final label = (a.label?.isNotEmpty ?? false) ? a.label! : _defaultActionLabel(a, l10n);
                              return GestureDetector(
                                onTap: () => onAction(a),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: AppColors.primary.withAlpha(22),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: AppColors.primary.withAlpha(60), width: 0.8),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(_actionIcon(a), size: 13, color: AppColors.primary),
                                      const SizedBox(width: 5),
                                      Text(label, style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.primary)),
                                    ],
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 3, left: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(DateFormat('HH:mm').format(time), style: TextStyle(fontFamily: 'Cairo', fontSize: 10, color: _saraFaint(context))),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: onCopy,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: _saraCard(context),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Icon(Icons.copy_rounded, size: 10, color: _saraFaint(context)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  static String _defaultActionLabel(SaraAction a, AppLocalizations l10n) {
    switch (a.type) {
      case SaraActionType.openScreen: return l10n.translate('actionOpen');
      case SaraActionType.goBack: return l10n.translate('actionGoBack');
      case SaraActionType.createEntity: return l10n.translate('actionCreate');
      case SaraActionType.exportPdf: return l10n.translate('actionExportPdf');
      case SaraActionType.showSnackbar: return l10n.translate('actionExecute');
      case SaraActionType.copyText: return l10n.translate('actionCopy');
      case SaraActionType.refreshData: return l10n.translate('actionRefreshData');
      case SaraActionType.navigateToTab: return l10n.translate('actionNavigate');
      case SaraActionType.openUrl: return l10n.translate('actionOpenLink');
      case SaraActionType.showDialog: return l10n.translate('actionShow');
      case SaraActionType.openEntity: return l10n.translate('actionOpen');
    }
  }

  static IconData _actionIcon(SaraAction a) {
    switch (a.type) {
      case SaraActionType.openScreen: return Icons.open_in_new_rounded;
      case SaraActionType.goBack: return Icons.arrow_back_rounded;
      case SaraActionType.createEntity: return Icons.add_circle_outline_rounded;
      case SaraActionType.exportPdf: return Icons.picture_as_pdf_rounded;
      case SaraActionType.showSnackbar: return Icons.notifications_none_rounded;
      case SaraActionType.copyText: return Icons.copy_rounded;
      case SaraActionType.refreshData: return Icons.refresh_rounded;
      case SaraActionType.navigateToTab: return Icons.tab_rounded;
      case SaraActionType.openUrl: return Icons.link_rounded;
      case SaraActionType.showDialog: return Icons.info_outline_rounded;
      case SaraActionType.openEntity: return Icons.open_in_new_rounded;
    }
  }
}

// ═══════════════════════════════════════════════════════════════
//  TYPING INDICATOR
// ═══════════════════════════════════════════════════════════════

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();
  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Shown only while Sara is really working; still for reduced motion.
    if (MediaQuery.of(context).disableAnimations) { _ctrl.value = .5; _ctrl.stop(); }
    else if (!_ctrl.isAnimating) { _ctrl.repeat(); }
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final light = _saraLight(context);
    final base = light ? const Color(0xFFF0E6E9) : const Color(0xFF2A2B31);
    // Gemini-like: soft lines of colour light sweep across while she thinks.
    Widget line(double width, double delay) => AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final t = ((_ctrl.value + delay) % 1.0) * 2.4 - 1.2;
        return Container(
          width: width, height: 9,
          margin: const EdgeInsets.only(bottom: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            gradient: LinearGradient(
              begin: Alignment(t - 1, 0), end: Alignment(t + 1, 0),
              colors: [base, const Color(0xFFE05470).withAlpha(light ? 150 : 170), const Color(0xFFF2A65A).withAlpha(light ? 120 : 140),
                const Color(0xFF7B5CD6).withAlpha(light ? 110 : 150), base],
              stops: const [0, .35, .5, .65, 1],
            ),
          ),
        );
      },
    );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        textDirection: ui.TextDirection.ltr,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: _SaraAvatar(size: 32),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 7),
            decoration: BoxDecoration(
              color: _saraBubble(context),
              border: Border.all(color: _saraLine(context), width: 0.6),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [line(170, 0), line(128, .12), line(84, .24)],
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  ERROR BUBBLE
// ═══════════════════════════════════════════════════════════════

class _ErrorBubble extends StatelessWidget {
  final String text;
  final String query;
  final ValueChanged<String> onRetry;
  const _ErrorBubble({required this.text, required this.query, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Message bubbles copy on press — quiet for the Information Clicker.
    return ClickerQuiet(
      child: Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.danger.withAlpha(20),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.danger.withAlpha(40)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: AppColors.danger, size: 16),
                const SizedBox(width: 8),
                Flexible(child: Text(text, style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, color: AppColors.danger))),
              ],
            ),
          ),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: () => onRetry(query),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: _saraCard(context),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _saraLine(context)),
              ),
              child: Text(l10n.translate('retry'), style: TextStyle(fontFamily: 'Cairo', fontSize: 11, color: _saraSub(context))),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  REPORT CARD
// ═══════════════════════════════════════════════════════════════

class _ReportCard extends StatelessWidget {
  final String text;
  const _ReportCard({required this.text});
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Pending account/currency mismatch choice: the refused tool + params plus
/// the real numbered options. The next user message only selects or cancels.
class _MismatchPending {
  final String toolName;
  final Map<String, dynamic> params;
  final MismatchOptions options;
  const _MismatchPending({
    required this.toolName,
    required this.params,
    required this.options,
  });
}
