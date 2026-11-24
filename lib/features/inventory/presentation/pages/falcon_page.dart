import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:go_router/go_router.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/localization/app_localizations.dart';
import '../../../../core/responsive/r_api.dart';
import '../../../../core/services/currency/enabled_currencies_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/providers/current_user_provider.dart';
import '../../../../shared/widgets/styled_snack.dart';
import '../../domain/services/falcon_memory_store.dart';
import '../../../branches/data/branch_scope.dart';
import '../providers/inventory_providers.dart';
import '../widgets/falcon_ambient.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';
import 'package:fyona_flutter/shared/widgets/fyona_refresh.dart';

/// «تحليل الصقر» — premium visual analyst for Business. The backend computes
/// every number (and converts them to the chosen report currency); the model
/// only writes short merchant-language decisions. The chat bar stays pinned
/// at the bottom through loading / report / currency changes.
class FalconPage extends ConsumerStatefulWidget {
  final String scope; // product | category | inventory
  final String? refId;
  final String title;
  const FalconPage(
      {super.key, required this.scope, this.refId, required this.title});
  @override
  ConsumerState<FalconPage> createState() => _FalconPageState();
}

enum FalconStage { intro, flight, live }

/// The reply lifecycle — ONE controller drives the whole cycle:
/// idle → thinking → handoff → streaming → docking → completed.
enum FalconReplyPhase { idle, thinking, handoff, streaming, docking, completed }

class _FalconPageState extends ConsumerState<FalconPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  bool _loading = true;
  late final String _memoryWorkspace = BranchScope.token ??
    '${ref.read(currentUserProvider)?.organizationId}|${BranchScope.branchId}|${BranchScope.allMode}';
  bool _refreshing = false;

  /// Frame-driven 4s intro clock (never a Timer: no pending-timer leaks,
  /// advances with pumped frames, cheap on GPU).
  late final AnimationController _introCtrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );
  Future<void>? _introGateFuture;
  int _dataVersion = 0; // bumps on every dataset change → re-reveal/count-up
  Map<String, dynamic> _report = {};
  String? _reportCurrency;
  final List<Map<String, dynamic>> _chat = [];
  final _q = TextEditingController();
  final _scroll = ScrollController();
  bool _asking = false;
  FalconReplyPhase _replyPhase = FalconReplyPhase.idle;
  String _bufferedFullResponse = '';
  String _displayedResponse = '';
  final GlobalKey _thinkingFalconAnchorKey = GlobalKey();
  final GlobalKey _messageTextKey = GlobalKey();
  final GlobalKey _finalAvatarAnchorKey = GlobalKey();
  Offset _falconPos = Offset.zero;
  Offset _falconTarget = Offset.zero;

  static const _prefKey = 'falcon_report_currency';

  /// Override for test environments to speed up the 4s minimum thinking time.
  static Duration get _thinkingMinDelay {
    // In test environments, use a shorter delay to avoid pending timers.
    final binding = WidgetsBinding.instance;
    if (binding.runtimeType.toString().contains('Test')) {
      return const Duration(milliseconds: 100);
    }
    return const Duration(seconds: 4);
  }

  /// Handoff choreography timings (production): wait for the bubble morph
  /// to fully settle BEFORE measuring the avatar anchor, then glide.
  /// Test environments use near-zero values to keep timers drained.
  static Duration get _morphSettleDelay =>
      _isTestEnv ? const Duration(milliseconds: 60) : const Duration(milliseconds: 420);
  static Duration get _glideDelay =>
      _isTestEnv ? const Duration(milliseconds: 80) : const Duration(milliseconds: 380);

  static bool get _isTestEnv =>
      WidgetsBinding.instance.runtimeType.toString().contains('Test');

  /// In-process session identity (isolation per user+scope).
  late final String _userId = ref.read(currentUserIdProvider);
  FalconStage _stage = FalconStage.intro;

  /// Motion-system intensity (Gemini-style state curve): idle .15 →
  /// typing .5 → thinking 1 → streaming .85 → settle back over 900ms.
  /// Paint-only; the energy field reads it without rebuilds.
  final ValueNotifier<double> _motion = ValueNotifier<double>(.15);
  late final AnimationController _flightCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 850));
  late final AnimationController _sendPulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 650));
  late final AnimationController _replyGlow = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900));
  late final AnimationController _thinkClock = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 4000));
  final GlobalKey _heroKey = GlobalKey();
  final GlobalKey _headerSlotKey = GlobalKey();
  final GlobalKey _stackKey = GlobalKey();
  Rect? _flightFrom;
  Rect? _flightTo;
  int? _streamingIndex;
  String _streamingText = '';
  bool _landing = false;
  Timer? _streamTimer;
  bool _streamingCancelled = false;

  /// The ONE falcon journey: a single overlay element glides from the
  /// thinking logo to the reply's first word, rides the reveal line while
  /// the answer writes, then docks onto the message's avatar.
  late final AnimationController _journeyCtrl = AnimationController(
      vsync: this, duration: const Duration(seconds: 1));
  Offset _falconUiPos = Offset.zero;
  double _glideStartDist = 1;
  bool _journeyActive = false;
  late final AnimationController _toastCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1500));
  late final AnimationController _settleCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900));
  late final AnimationController _typingActivity = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 700));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The intro clock starts SYNCHRONOUSLY on the first frame — never after
    // an await — so platform-channel session loads (which resolve on the
    // real event loop) can never delay or desync it.
    _startIntro();
    _restoreSessionOrStart();
  }

  void _startIntro() {
    _stage = FalconStage.intro;
    _introGateFuture = _introCtrl.forward(from: 0);
    _introGateFuture?.whenComplete(() {
      if (mounted) _beginFlight();
    });
  }

  /// CENTER → HEADER: the same visual logo flies DIRECTLY to its header
  /// slot. All coordinates are converted into the page-Stack's local space
  /// (Positioned coordinates) so the landing is pixel-exact — global rects
  /// would be offset by the status bar. Re-measured at flight start, and
  /// the target is re-read each landing so scroll never breaks it.
  void _beginFlight() {
    if (!mounted || _stage != FalconStage.intro) return;
    final stackBox =
        _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final fromCtx = _heroKey.currentContext;
    final toCtx = _headerSlotKey.currentContext;
    if (stackBox == null || !stackBox.hasSize) {
      _finishFlight();
      return;
    }
    final stackTopLeft =
        stackBox.localToGlobal(Offset.zero);
    RenderBox? fromBox = fromCtx?.findRenderObject() as RenderBox?;
    // Re-measure the TARGET right before takeoff (scroll-safe).
    RenderBox? toBox = toCtx?.findRenderObject() as RenderBox?;
    if (fromBox == null || !fromBox.hasSize) {
      _finishFlight();
      return;
    }
    if (toBox == null || !toBox.hasSize) {
      _finishFlight();
      return;
    }
    final from = (fromBox.localToGlobal(Offset.zero) - stackTopLeft) &
        fromBox.size;
    final to = (toBox.localToGlobal(Offset.zero) - stackTopLeft) & toBox.size;
    if (from.isEmpty || to.isEmpty) {
      _finishFlight();
      return;
    }
    setState(() {
      _flightFrom = from;
      _flightTo = to;
      _stage = FalconStage.flight;
      _motion.value = .5;
    });
    _flightCtrl.forward(from: 0).whenComplete(() {
      if (mounted) _finishFlight();
    });
  }

  void _finishFlight() {
    if (!mounted) return;
    setState(() {
      _stage = FalconStage.live;
      _dataVersion++; // staggered report reveal + count-up
      _motion.value = .15;
    });
    // Frame-driven settle (no Timer leaks): intensity decays when done.
    _settleCtrl.forward(from: 0).whenComplete(() {
      if (mounted && !_asking) _motion.value = .15;
    });
  }

  /// Session-first startup: restore from the PROCESS-WIDE memory store
  /// (survives navigation/background — dies only with the app process).
  /// Otherwise brand-new intro (full 4 seconds) + analysis.
  void _restoreSessionOrStart() {
    final s = FalconMemoryStore.instance
        .get(_userId, widget.scope, widget.refId, workspace: _memoryWorkspace);
    if (s != null && (s.chat.isNotEmpty || s.report != null)) {
      _introCtrl.value = 1; // skip intro+flight on a resumed session
      setState(() {
        _stage = FalconStage.live;
        _chat
          ..clear()
          ..addAll(s.chat);
        if (s.report != null) {
          _report = s.report!;
          _dataVersion++;
        }
        _reportCurrency = s.reportCurrency ?? _reportCurrency;
        _loading = false;
      });
      _scrollToChatEnd(false);
      // The kept report may predate edits/sales: re-read the figures in
      // place (old report stays visible, no intro replay).
      if (s.report != null && _reportCurrency != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _analyze(keepOld: true);
        });
      }
      return;
    }
    // Fresh session: the intro clock is ALREADY running from initState —
    // never reset it here (a value=0 would re-anchor its start time to the
    // next rendered frame and silently stretch the intro).
    _initCurrencyAndAnalyze();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // In-memory session lives as long as the PROCESS: pause/resume/lock
    // keep everything; nothing to persist, nothing to expire.
  }

  void _persistSession() {
    if (_report.isEmpty && _chat.isEmpty) return;
    FalconMemoryStore.instance.put(
        _userId,
        widget.scope,
        widget.refId,
        FalconSession(
            chat: List.of(_chat),
            report: _report.isEmpty ? null : _report,
            reportCurrency: _reportCurrency,
            lastActivity: DateTime.now()), workspace: _memoryWorkspace);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _persistSession();
    _introCtrl.dispose();
    _flightCtrl.dispose();
    _sendPulse.dispose();
    _replyGlow.dispose();
    _thinkClock.dispose();
    _toastCtrl.dispose();
    _settleCtrl.dispose();
    _typingActivity.dispose();
    _streamingCancelled = true;
    _streamTimer?.cancel();
    _journeyCtrl.stop();
    _journeyCtrl.dispose();
    _motion.dispose();
    _q.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Default = last saved choice; else USD when enabled; else the first
  /// enabled currency from Business → تخصيص العملات. «تلقائي» is gone.
  Future<void> _initCurrencyAndAnalyze() async {
    final enabled = ref.read(enabledCurrenciesProvider).valueOrNull ??
        await loadEnabledCurrencies(ref.read(currentUserIdProvider));
    String pick;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(
          '${_prefKey}_${ref.read(currentUserIdProvider)}');
      pick = (saved != null && enabled.contains(saved))
          ? saved
          : (enabled.contains('USD')
              ? 'USD'
              : (enabled.isNotEmpty ? enabled.first : 'USD'));
    } catch (_) {
      pick = enabled.contains('USD') ? 'USD' : 'USD';
    }
    if (!mounted) return;
    setState(() => _reportCurrency = pick);
    _analyze();
  }

  Future<void> _saveChoice(String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          '${_prefKey}_${ref.read(currentUserIdProvider)}', code);
    } catch (_) {}
  }

  Future<void> _analyze({bool keepOld = false}) async {
    final requestScope = BranchScope.token;
    if (keepOld) {
      setState(() => _refreshing = true);
    } else {
      setState(() => _loading = true);
    }
    try {
      final r = await ref
          .read(inventoryApiProvider)
          .falconAnalyze(widget.scope, widget.refId,
              reportCurrency: _reportCurrency);
      // An empty answer never wipes a report already on screen.
      if (mounted &&
          requestScope == BranchScope.token &&
          (r.isNotEmpty || !keepOld)) {
        setState(() {
          _report = r;
          _dataVersion++;
        });
      }
    } catch (_) {
      if (mounted && !keepOld) {
        showFyonaSnack(context, 'تعذّر تشغيل التحليل، حاول مجددًا',
            success: false);
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _refreshing = false;
        });
      }
    }
  }

  Future<void> _send([String? preset]) async {
    final requestScope = BranchScope.token;
    final q = (preset ?? _q.text).trim();
    if (q.isEmpty || _asking) return;
    // ── THINKING: the dedicated experience (4s minimum, wall-clock via
    // Future.wait so a fast reply waits and a slow one never adds extra).
    setState(() {
      _chat.add({'role': 'user', 'content': q});
      // The falcon's thinking occupies the reply's own slot, directly
      // below the user's message — it morphs into the reply in place.
      _chat.add({'role': 'assistant', 'content': '', 'status': 'thinking'});
      _asking = true;
      _replyPhase = FalconReplyPhase.thinking;
      _landing = false;
      _q.clear();
    });
    _sendPulse.forward(from: 0);
    _thinkClock.repeat();
    _motion.value = 1; // flame at full energy while the Falcon thinks
    _scrollToChatEnd(true);

    // Capture the thinking-falcon anchor position (global) NOW — the
    // journey falcon starts exactly there and eases from it at handoff.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _thinkingFalconAnchorKey.currentContext;
      final box = ctx?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        _falconPos = box.localToGlobal(box.size.center(Offset.zero));
        _falconTarget = _falconPos;
        _falconUiPos = _falconPos;
      }
    });

    Future<Map<String, dynamic>?> responseFuture;
    try {
      // History for the API never includes the local thinking slot.
      final history =
          _chat.where((m) => m['status'] != 'thinking').toList();
      responseFuture = ref.read(inventoryApiProvider).falconChat(
          widget.scope, widget.refId, q, history,
          reportCurrency: _reportCurrency);
    } catch (_) {
      responseFuture = Future.value(null);
    }
    final results = await Future.wait([
      responseFuture,
      Future.delayed(_thinkingMinDelay),
    ]);
    if (!mounted || requestScope != BranchScope.token) return;
    _bufferedFullResponse =
        ((results[0] as Map?)?['answer'] ?? 'تعذّر الرد.').toString();

    // ── HANDOFF: the SAME inline thinking slot morphs into the reply.
    // The journey falcon takes over FIRST (measured while the thinking
    // logo is still mounted) so there is never an empty frame.
    final bubbleIndex = _chat.length - 1;
    final thinkCtx = _thinkingFalconAnchorKey.currentContext;
    final thinkBox = thinkCtx?.findRenderObject() as RenderBox?;
    if (thinkBox != null && thinkBox.hasSize) {
      _falconPos = thinkBox.localToGlobal(thinkBox.size.center(Offset.zero));
      _falconTarget = _falconPos;
      _falconUiPos = _falconPos;
    }
    setState(() {
      _journeyActive = true;
      _streamingIndex = bubbleIndex;
      _chat[bubbleIndex] = {
        'role': 'assistant',
        'content': '',
        'status': 'streaming',
      };
      _replyPhase = FalconReplyPhase.handoff;
    });
    _journeyCtrl.repeat();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    // 1) LET THE MORPH SETTLE: the thinking row cross-fades into the empty
    // bubble and the layout reflows — measuring DURING that reflow is what
    // made the falcon drift to the wrong spot. Hold the falcon exactly on
    // the (faded) thinking-logo spot until the tree is stable.
    await Future.delayed(_morphSettleDelay);
    if (!mounted) return;
    // 2) Measure the reply's OWN avatar anchor on the SETTLED tree
    // (true post-layout coordinates — never stale ones).
    final avatarBox = _boxOf(_finalAvatarAnchorKey);
    if (avatarBox != null && avatarBox.hasSize) {
      final avatarGlobal =
          avatarBox.localToGlobal(avatarBox.size.center(Offset.zero));
      _glideStartDist =
          (_falconUiPos - avatarGlobal).distance.abs().clamp(1.0, 1e9);
      setState(() => _falconTarget = avatarGlobal);
    }
    // 3) ONE smooth glide: current spot → avatar anchor. While gliding, the
    // overlay re-measures the anchor EVERY frame (scroll-proof).
    await Future.delayed(_glideDelay);
    if (!mounted) return;
    // 4) ARRIVAL = LANDING: the falcon has settled exactly on the avatar's
    // center; the static avatar mounts in the same frame the overlay
    // unmounts (same anchor, badge already scaled to the avatar size) —
    // no second logo, no flash, no gap. The reply starts IMMEDIATELY.
    setState(() {
      _landing = true;
      _journeyActive = false;
      _replyPhase = FalconReplyPhase.streaming;
    });
    _journeyCtrl.stop();
    // Slightly calmer than thinking — the field stays alive while writing.
    _motion.value = .85;
    // One soft pulse rises from the composer the moment the reply begins.
    _replyGlow.forward(from: 0);
    // The falcon stays home (static avatar); the answer writes itself.

    // ── STREAMING: tokens preserving whitespace/lines; the SAME message
    // object grows — never a second commit, never full-text setState.
    final tokens = _tokenizePreservingWhitespace(_bufferedFullResponse);
    var tokenIndex = 0;
    _streamingCancelled = false;
    void streamNext() {
      if (_streamingCancelled ||
          !mounted ||
          _replyPhase == FalconReplyPhase.idle ||
          tokenIndex >= tokens.length) {
        _streamTimer = null;
        _proceedToDocking(bubbleIndex);
        return;
      }
      final token = tokens[tokenIndex++];
      _displayedResponse += token;
      setState(() {
        _chat[bubbleIndex] = {
          'role': 'assistant',
          'content': _displayedResponse,
          'status': 'streaming',
        };
      });
      // The falcon stays FIXED on the avatar while the words surface —
      // it never rides the text (no pen behavior).
      _scrollToChatEnd(false);
      _streamTimer = Timer(_tokenDelay(token), streamNext);
    }
    streamNext();
  }

  void _proceedToDocking(int bubbleIndex) {
    if (!mounted) return;
    // Runs ONLY after the last token. The falcon already landed on the
    // avatar BEFORE streaming — nothing to move; finalize the cycle calmly.
    Future.delayed(const Duration(milliseconds: 50), () {
      if (!mounted) return;
      setState(() {
        _replyPhase = FalconReplyPhase.completed;
        _chat[bubbleIndex] = {
          'role': 'assistant',
          'content': _bufferedFullResponse,
          'status': 'completed',
        };
        _asking = false;
        _displayedResponse = '';
        _streamingIndex = null;
        _landing = false;
        _journeyActive = false;
      });
      _journeyCtrl.stop();
      _motion.value = .45;
      _settleCtrl.forward(from: 0).whenComplete(() {
        if (mounted && !_asking) _motion.value = .15;
      });
      _persistSession();
      _scrollToChatEnd(false);
    });
  }

  /// Bulletproof render-box measure: returns null for ANY inactive/
  /// defunct element state (mounted alone is not enough — 'inactive'
  /// elements still report true in recent frameworks).
  RenderBox? _boxOf(GlobalKey key) {
    try {
      final ctx = key.currentContext;
      if (ctx == null) return null;
      final box = ctx.findRenderObject();
      return box is RenderBox ? box : null;
    } catch (_) {
      return null;
    }
  }

  /// TextPainter with the EXACT bubble text metrics (font/size/weight/
  /// height/direction) for true caret positions (RTL aware).
  TextPainter _caretPainterFor(String text) {
    return TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 14,
              fontWeight: FontWeight.w400,
              height: 1.7,
              color: AppColors.textPrimary)),
      textDirection: Directionality.of(context),
      textAlign: Directionality.of(context) == TextDirection.rtl
          ? TextAlign.right
          : TextAlign.left,
    );
  }

  /// Word-aware tokenizer that PRESERVES whitespace/line breaks (Arabic
  /// words are never broken; '\n' travels with the next word).
  static List<String> _tokenizePreservingWhitespace(String text) {
    final out = <String>[];
    final buf = StringBuffer();
    var wasSpace = false;
    for (final ch in text.runes.map(String.fromCharCode)) {
      final isSpace = ch == ' ' || ch == '\n' || ch == '\t';
      if (isSpace) {
        buf.write(ch);
        wasSpace = true;
      } else {
        if (wasSpace && buf.isNotEmpty) {
          out.add(buf.toString());
          buf.clear();
        }
        buf.write(ch);
        wasSpace = false;
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  /// Dynamic delay per token: normal flow, comma pause, sentence pause,
  /// newline pause (reading rhythm, never annoying).
  Duration _tokenDelay(String token) {
    final t = token.trimRight();
    if (t.endsWith('\n') || token.contains('\n')) {
      return const Duration(milliseconds: 50);
    }
    if (t.endsWith('.') || t.endsWith('!') || t.endsWith('؟')) {
      return const Duration(milliseconds: 100);
    }
    if (t.endsWith(',') || t.endsWith('،') || t.endsWith(':')) {
      return const Duration(milliseconds: 50);
    }
    return const Duration(milliseconds: 30);
  }



  /// [force] = true only for send (jump to the new exchange); during
  /// streaming it FOLLOW-the-writing only when the user is already near
  /// the bottom — manual scroll-up is never yanked back. Throttled.
  DateTime _lastFollow = DateTime.fromMillisecondsSinceEpoch(0);
  void _scrollToChatEnd(bool force) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      final nearBottom = (pos.maxScrollExtent - pos.pixels) < 140;
      if (!force && !nearBottom) return;
      if (!force && DateTime.now().difference(_lastFollow).inMilliseconds < 180) {
        return; // throttle: no jump per word
      }
      _lastFollow = DateTime.now();
      pos.animateTo(
        pos.maxScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  // ── helpers ──
  List<String> _ls(String k) => ((_report[k] as List?) ?? const [])
      .map((e) => _plainLine(e.toString()))
      .where((e) => e.trim().isNotEmpty)
      .take(3)
      .toList();

  /// Arabic text never shows data field names (qty_sold, reorder…) even
  /// from an older server answer.
  String _plainLine(String text) {
    if (_locale == 'en') return text.replaceAll('_', ' ');
    var out = text;
    _falconFieldWords.forEach((key, word) {
      out = out.replaceAllMapped(
        RegExp('(?<![A-Za-z0-9])$key(?![A-Za-z0-9])', caseSensitive: false),
        (_) => word,
      );
    });
    out = out.replaceAll(
      RegExp(r'(?<![A-Za-z0-9])[a-z]+(?:_[a-z0-9]+)+(?![A-Za-z0-9])'),
      '',
    );
    return out.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
  }

  String get _cur =>
      ((_report['stats'] is Map
                  ? (_report['stats'] as Map)['report_currency']
                  : _report['report_currency']) ??
              _reportCurrency ??
              'USD')
          .toString()
          .toUpperCase();

  List<Map<String, dynamic>> get _topSellers {
    final s = _report['stats'];
    if (s is! Map) return const [];
    final list = s['top_sellers'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .take(6)
        .toList();
  }

  String _money(dynamic v) {
    final d = (v is num) ? v.toDouble() : (double.tryParse('$v') ?? 0);
    return '${fmtNum(d)} ${currencyName(_cur, locale: _locale)}';
  }

  /// Explicit widget locale — currency names must follow the actual UI
  /// language, not the process-wide static (which lags behind in tests and
  /// on first frame).
  String? get _locale {
    try {
      return Localizations.localeOf(context).languageCode;
    } catch (_) {
      return null;
    }
  }

  Color _statusColor(String? s) {
    switch (s) {
      case 'excellent':
        return AppColors.success;
      case 'good':
        return AppColors.primary;
      case 'weak':
        return AppColors.danger;
      default:
        return AppColors.warning;
    }
  }

  String _statusWord(AppLocalizations l10n, String? s) {
    switch (s) {
      case 'excellent':
        return l10n.translate('falconStatusExcellent');
      case 'good':
        return l10n.translate('falconStatusGood');
      case 'weak':
        return l10n.translate('falconStatusWeak');
      default:
        return l10n.translate('falconStatusWatch');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final enabled = ref.watch(enabledCurrenciesProvider).valueOrNull ??
        defaultEnabledCurrencies.toSet();
    return Scaffold(
      backgroundColor: AppColors.background,
      // The chat input stays pinned; content scrolls above it. Everything
      // lives inside one Stack: ambient waves, header (logo flies here),
      // scrollable content, composer, bursts and the copy mini-toast.
      body: FalconAmbientEnergy(
        intensity: _motion,
        child: SafeArea(
          bottom: false,
          child: Stack(key: _stackKey, children: [
            Column(
              children: [
                _header(context, l10n),
                Expanded(
                  child: FyonaRefresh(
                    onRefresh: () => _analyze(keepOld: _report.isNotEmpty),
                    child: ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      children: _content(context, l10n, enabled),
                    ),
                  ),
                ),
                _chatBar(context, l10n),
              ],
            ),
            // The SAME center logo flying to its header slot.
            if (_stage == FalconStage.flight &&
                _flightFrom != null &&
                _flightTo != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: FalconFlight(
                    clock: _flightCtrl,
                    from: _flightFrom!,
                    to: _flightTo!,
                  ),
                ),
              ),
            // Energy burst rising from the composer on send.
            if (_sendPulse.isAnimating)
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _sendPulse,
                      builder: (context, _) => CustomPaint(
                        painter: _BurstPainter(t: _sendPulse.value),
                      ),
                    ),
                  ),
                ),
              ),
            // One soft rounded surge when the reply starts writing.
            if (_replyGlow.isAnimating)
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _replyGlow,
                      builder: (context, _) => CustomPaint(
                        painter: _BurstPainter(t: _replyGlow.value * .8),
                      ),
                    ),
                  ),
                ),
              ),
            // THE ONE JOURNEY FALCON: a single overlay logo (no second
            // logo anywhere) glides thinking → first word → caret → avatar.
            if (_journeyActive)
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _journeyCtrl,
                      builder: (context, _) {
                        final stackBox = _boxOf(_stackKey);
                        if (stackBox == null || !stackBox.hasSize) {
                          return const SizedBox.shrink();
                        }
                        final stackOrigin =
                            stackBox.localToGlobal(Offset.zero);
                        // Riding the glide: exponential ease toward the
                        // avatar anchor — re-measured EVERY frame from the
                        // real tree (scroll can never mislead it).
                        if (_replyPhase == FalconReplyPhase.handoff) {
                          final ab = _boxOf(_finalAvatarAnchorKey);
                          if (ab != null && ab.hasSize) {
                            _falconTarget = ab
                                .localToGlobal(ab.size.center(Offset.zero));
                          }
                        }
                        _falconUiPos = Offset.lerp(
                            _falconUiPos, _falconTarget, 0.18)!;
                        // Badge eases from 34px down to the avatar's 26px
                        // with the closing distance → at arrival it IS the
                        // avatar's size → the swap is invisible.
                        final remain =
                            (_falconUiPos - _falconTarget).distance /
                                _glideStartDist;
                        final badge = 26.0 + 8.0 * remain.clamp(0.0, 1.0);
                        final mark = 16.0 + 6.0 * remain.clamp(0.0, 1.0);
                        final pGlobal = _falconUiPos;
                        final p = pGlobal - stackOrigin;
                        return Transform.translate(
                          offset: p - Offset(badge / 2, badge / 2),
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: TweenAnimationBuilder<double>(
                              // Entry fade-in; the exit fade runs ONLY at
                              // dock arrival — never before.
                              tween: Tween(begin: 0, end: _landing ? 0 : 1),
                              duration: _landing
                                  ? const Duration(milliseconds: 110)
                                  : const Duration(milliseconds: 260),
                              curve: Curves.easeOutCubic,
                              onEnd: () {
                                if (_landing && mounted) {
                                  setState(() => _journeyActive = false);
                                  _journeyCtrl.stop();
                                }
                              },
                              builder: (c, v, child) =>
                                  Opacity(opacity: v, child: child),
                              child: Container(
                              width: badge,
                              height: badge,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.surface,
                                boxShadow: [
                                  BoxShadow(
                                      // Glow holds until the last 30% of the
                                      // glide, then eases to nothing at the
                                      // avatar — arrival is seamless.
                                      color: AppColors.primary.withAlpha(
                                          (60 * (remain / .3).clamp(0.0, 1.0))
                                              .round()),
                                      blurRadius: 10),
                                ],
                              ),
                              child: Center(child: FalconMark(mark)),
                            ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            // Tiny green «تم النسخ» pill.
            PositionedDirectional(
              bottom: 96,
              start: 0,
              end: 0,
              child: Center(
                child: AnimatedBuilder(
                  animation: _toastCtrl,
                  builder: (context, _) {
                    final v = _toastCtrl.value;
                    final opacity = v < .12
                        ? (v / .12)
                        : (v > .8 ? ((1 - v) / .2) : 1.0);
                    return Opacity(
                      opacity: opacity.clamp(0, 1),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: AppColors.success,
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(
                              color: Colors.white.withAlpha(90)),
                          boxShadow: [
                            BoxShadow(
                                color: AppColors.success.withAlpha(70),
                                blurRadius: 10),
                          ],
                        ),
                        child: Text(l10nKey('copied'),
                            style: const TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                      ),
                    );
                  },
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// Custom header: back + ONE logo slot (empty during intro/flight until
  /// the center logo lands here) + title. No box behind the transparent
  /// logo, only a very subtle ambient pulse once live.
  Widget _header(BuildContext context, AppLocalizations l10n) {
    final showLogo = _stage == FalconStage.live;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 16, 0),
      child: SizedBox(
        height: 46,
        child: Row(children: [
          IconButton(
            tooltip: l10n.translate('back'),
            onPressed: () => context.pop(),
            icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          ),
          SizedBox(
            width: 30,
            height: 30,
            child: Center(
              // The landing slot: measured for the flight, then holds the
              // logo with a tiny settle pulse. Empty (not hidden) before.
              key: _headerSlotKey,
              child: showLogo
                  ? TweenAnimationBuilder<double>(
                      tween: Tween(begin: 1.3, end: 1),
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutBack,
                      builder: (c, v, child) => Transform.scale(
                          scale: v, child: child),
                      // Keyed by brightness so a mid-page theme switch
                      // rebuilds the artwork instantly (no const caching).
                      child: FalconMark(
                          30,
                          key: ValueKey(Theme.of(context).brightness)),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(l10n.translate('invFalcon'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.w800,
                    fontSize: 16)),
          ),
        ]),
      ),
    );
  }

  List<Widget> _content(BuildContext context, AppLocalizations l10n,
      Set<String> enabled) {
    final stats = _report['stats'] is Map
        ? Map<String, dynamic>.from(_report['stats'] as Map)
        : <String, dynamic>{};
    return [
      // ── Scope title (the logo lives ONLY in the header slot) ──
      Text(_scopeTitle(stats),
          textAlign: TextAlign.center,
          style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: R.fontSize(context, 14),
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary)),
      const SizedBox(height: 8),

      // ── Report currency: only Business-enabled currencies (no auto) ──
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          Text('${l10n.translate('falconReportCurrency')}: ',
              style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)),
          for (final c in enabled)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 6),
              child: ChoiceChip(
                label: Text(currencyName(c, locale: _locale),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 11,
                        color: _reportCurrency == c
                            ? Colors.white
                            : AppColors.textPrimary)),
                selected: _reportCurrency == c,
                selectedColor: AppColors.primary,
                backgroundColor: AppColors.surface,
                side: BorderSide(color: AppColors.border),
                showCheckmark: false,
                onSelected: (_) {
                  if (_reportCurrency == c) return;
                  setState(() => _reportCurrency = c);
                  _saveChoice(c);
                  // In-place refresh: the old report stays visible and the
                  // ambient hero keeps moving — no intro replay.
                  _analyze(keepOld: _report.isNotEmpty);
                },
              ),
            ),
        ]),
      ),
      const SizedBox(height: 10),

      // ── Intro (fresh sessions only) / flight (kept blank; the logo is
      // flying to the header) / loading / report ──
      if (_stage == FalconStage.intro) ...[
        SizedBox(
          height: MediaQuery.of(context).size.height * .52,
          child: Center(
            child: FalconIntroScene(
              clock: _introCtrl,
              logoKey: _heroKey,
            ),
          ),
        ),
      ] else if (_stage == FalconStage.flight) ...[
        const SizedBox(height: 180),
      ] else if (_loading && _report.isEmpty) ...[
        const FalconLoader(),
      ] else ...[
        if (_refreshing)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
              Text(l10n.translate('falconRefreshing'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 12,
                      color: AppColors.textSecondary)),
            ]),
          ),
        AnimatedOpacity(
          opacity: _refreshing ? 0.55 : 1,
          duration: const Duration(milliseconds: 250),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (stats.isEmpty) _emptyState(context, l10n) else ...[
                _statusCard(context, l10n),
                const SizedBox(height: 10),
                _keyNumbersCard(context, l10n, stats),
                if ((stats['branch_summaries'] as List? ?? const []).length > 1) ...[
                  const SizedBox(height: 10), _branchBreakdown(context, l10n, stats)],
                if ((stats['unified'] == true)) ...[
                  const SizedBox(height: 8),
                  _unifiedNote(context, l10n),
                ],
                if (_report['type_guide'] is Map) ...[
                  const SizedBox(height: 10),
                  _typeGuideCard(context, l10n),
                ],
                if (_topSellers.length >= 2) ...[
                  const SizedBox(height: 10),
                  _chartCard(context, l10n),
                ],
                if (_ls('attention').isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _bulletsCard(context, l10n.translate('falconAttention'),
                      _ls('attention'), AppColors.warning, Icons.error_outline),
                ],
                if (_ls('recommendations').isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _bulletsCard(context, l10n.translate('falconActions'),
                      _ls('recommendations'), AppColors.primary, Icons.check_circle_outline),
                ],
                if ((_report['opportunity'] ?? '').toString().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _bulletsCard(context, l10n.translate('falconOpportunity'),
                      [(_report['opportunity'] ?? '').toString()],
                      AppColors.success, Icons.trending_up),
                ],
              ],
              // ── Chat history lives in the same scrollable area ──
              // The falcon's thinking row renders INLINE below the user's
              // message (see _bubble) — no separate section, no label.
              if (_chat.isNotEmpty) ...[
                const SizedBox(height: 10),
                for (var i = 0; i < _chat.length; i++)
                  _bubble(_chat[i], i,
                      streaming: i == _streamingIndex),
              ],
            ],
          ),
        ),
      ],
    ];
  }

  /// The page title, or the product / category name the analysis carries
  /// (a category or product opened without a title).
  String _scopeTitle(Map<String, dynamic> stats) {
    if (widget.title.trim().isNotEmpty) return widget.title;
    final name = switch (widget.scope) {
      'product' => stats['name'],
      'category' => stats['category_name'],
      _ => null,
    };
    return (name ?? '').toString();
  }

  Widget _branchBreakdown(BuildContext context, AppLocalizations l10n, Map stats) {
    final ar = l10n.locale.languageCode == 'ar';
    final rows = (stats['branch_summaries'] as List? ?? []).whereType<Map>();
    return Material(color: AppColors.surface, borderRadius: BorderRadius.circular(16),
      child: ExpansionTile(leading: const Icon(Icons.storefront_rounded, color: AppColors.primary),
        title: Text(ar ? 'تفاصيل الفروع المسموحة' : 'Permitted branch details',
          style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800, fontSize: 13)),
        children: [for (final row in rows) Padding(padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${row['branch_name']}', style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800)),
            Row(children: [Expanded(child: Text(ar ? 'المبيعات' : 'Sales', style: const TextStyle(fontFamily: 'Cairo', fontSize: 11))),
              Text('${fmtNum(num.tryParse('${row['total_sales']}') ?? 0)} ${stats['report_currency']}',
                textDirection: TextDirection.ltr, style: const TextStyle(fontFamily: 'Cairo', fontSize: 11))]),
            Row(children: [Expanded(child: Text(ar ? 'الكمية بالمخزون' : 'Stock quantity', style: const TextStyle(fontFamily: 'Cairo', fontSize: 11))),
              Text(fmtNum(num.tryParse('${row['stock']}') ?? 0), textDirection: TextDirection.ltr,
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 11))]),
          ]))],
      ));
  }

  Widget _statusCard(BuildContext context, AppLocalizations l10n) {
    final color = _statusColor(_report['status']?.toString());
    return _Reveal(
      key: const ValueKey('status'),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withAlpha(90), width: 1.2),
          boxShadow: [
            BoxShadow(
                color: color.withAlpha(26),
                blurRadius: 14,
                offset: const Offset(0, 4)),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withAlpha(26),
              ),
              child: Icon(Icons.insights, color: color, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_statusWord(l10n, _report['status']?.toString()),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: color)),
                  const SizedBox(height: 6),
                  _statusMeter(_report['status']?.toString(), color),
                  if ((_report['status_line'] ?? '').toString().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _richLine(
                          _plainLine((_report['status_line'] ?? '').toString()),
                          color,
                          size: 13),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Four steps: weak → watch → good → excellent (filled up to the status).
  Widget _statusMeter(String? status, Color color) {
    const order = ['weak', 'watch', 'good', 'excellent'];
    final level = order.indexOf(status ?? 'watch').clamp(0, 3);
    return Row(children: [
      for (var i = 0; i < 4; i++) ...[
        Expanded(
          child: AnimatedContainer(
            duration: Duration(milliseconds: 300 + i * 120),
            height: 6,
            decoration: BoxDecoration(
              color: i <= level ? color : color.withAlpha(30),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
        if (i < 3) const SizedBox(width: 4),
      ],
    ]);
  }

  /// A line whose numbers stand out (bold, in the card's color).
  Widget _richLine(String line, Color color, {double size = 13}) {
    final base = TextStyle(
        fontFamily: 'Cairo',
        fontSize: size,
        height: 1.6,
        color: AppColors.textPrimary);
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in RegExp(r'[0-9][0-9,.٫]*%?').allMatches(line)) {
      if (m.start > last) spans.add(TextSpan(text: line.substring(last, m.start)));
      spans.add(TextSpan(
          text: m.group(0),
          style: TextStyle(fontWeight: FontWeight.w800, color: color)));
      last = m.end;
    }
    if (last < line.length) spans.add(TextSpan(text: line.substring(last)));
    return Text.rich(TextSpan(style: base, children: spans));
  }

  Widget _keyNumbersCard(
      BuildContext context, AppLocalizations l10n, Map<String, dynamic> stats) {
    double numOf(dynamic v) =>
        (v is num) ? v.toDouble() : (double.tryParse('$v') ?? 0);
    final profit = numOf(stats['total_profit']);
    final product = widget.scope == 'product';
    final unit = (stats['unit'] ?? '').toString();
    final stock = numOf(stats['stock']);
    // (label, value, icon, color, unit suffix — null = money)
    final tiles = <(String, double, IconData, Color, String?)>[
      (l10n.translate('falconKSales'), numOf(stats['total_sales']),
          Icons.point_of_sale_rounded, AppColors.primary, null),
      (l10n.translate('falconKProfit'), profit, Icons.trending_up_rounded,
          profit < 0 ? AppColors.danger : AppColors.success, null),
      if (product) ...[
        // One product: how much is left and how much was sold read better
        // than a cost-of-goods total.
        (l10n.translate('falconKStock'), stock, Icons.warehouse_rounded,
            stock <= 0 ? AppColors.danger : AppColors.warning, unit),
        (l10n.translate('falconKSoldQty'), numOf(stats['sales_quantity']),
            Icons.shopping_bag_rounded, AppColors.info, unit),
      ] else ...[
        (l10n.translate('falconKInventory'), numOf(stats['inventory_value']),
            Icons.inventory_2_rounded, AppColors.warning, null),
        (l10n.translate('falconKCogs'), numOf(stats['total_cogs']),
            Icons.shopping_bag_rounded, AppColors.textSecondary, null),
      ],
    ];
    return _Reveal(
      key: const ValueKey('numbers'),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.translate('falconKeyNumbers'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 2.1,
              children: [
                for (final t in tiles)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: t.$4.withAlpha(14),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: t.$4.withAlpha(40)),
                    ),
                    child: Row(children: [
                     Container(
                       width: 30,
                       height: 30,
                       decoration: BoxDecoration(
                         color: t.$4.withAlpha(30),
                         shape: BoxShape.circle,
                       ),
                       child: Icon(t.$3, size: 16, color: t.$4),
                     ),
                     const SizedBox(width: 8),
                     Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(t.$1,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 10.5,
                                color: AppColors.textSecondary)),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          // Light count-up after the logo lands (700ms);
                          // replays when the dataset changes (currency...).
                          child: TweenAnimationBuilder<double>(
                            key: ValueKey('cnt-$_dataVersion'),
                            tween: Tween(begin: 0, end: t.$2),
                            duration: const Duration(milliseconds: 700),
                            curve: Curves.easeOut,
                            builder: (c, v, _) => Text(
                                t.$5 == null
                                    ? _money(v)
                                    : '${fmtNum(v)} ${t.$5}'.trim(),
                                style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.textPrimary)),
                          ),
                        ),
                      ],
                    )),
                    ]),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _unifiedNote(BuildContext context, AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(16),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
          l10n.translate('falconUnifiedNote2',
              params: {'cur': currencyName(_cur, locale: _locale)}),
          style: const TextStyle(fontFamily: 'Cairo', fontSize: 12, height: 1.4)),
    );
  }

  /// Deterministic type-expertise card (pricing / turnover / marketing /
  /// risks detected from the product's merchant domain).
  Widget _typeGuideCard(BuildContext context, AppLocalizations l10n) {
    final guide = Map<String, dynamic>.from(_report['type_guide'] as Map);
    final rows = [
      (l10n.translate('falconTypePricing'), guide['pricing']),
      (l10n.translate('falconTypeTurnover'), guide['turnover']),
      (l10n.translate('falconTypeMarketing'), guide['marketing']),
      (l10n.translate('falconTypeRisks'), guide['risks']),
    ];
    final unit = (stats?['products_count'] != null && widget.scope == 'product')
        ? ((_report['stats']?['unit'] ?? '') ?? '') ?? ''
        : '';
    return _Reveal(
      key: const ValueKey('typeguide'),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.primary.withAlpha(70)),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const FalconMark(18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    '${l10n.translate('falconTypeGuide')}: ${(_report['product_type'] ?? '').toString()}',
                    style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary)),
              ),
            ]),
            const SizedBox(height: 6),
            for (final r in rows)
              if ((r.$2 ?? '').toString().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text.rich(
                      TextSpan(style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 12.5,
                          height: 1.5,
                          color: AppColors.textPrimary), children: [
                    TextSpan(
                        text: '• ${r.$1}: ',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    TextSpan(text: (r.$2 ?? '').toString()),
                  ])),
                ),
            if (widget.scope == 'product' &&
                _report['suggested_order_qty'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                    l10n.translate('falconSuggestedOrder', params: {
                      'n': '${_report['suggested_order_qty']}',
                      'unit': unit,
                    }),
                    style: const TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.success)),
              ),
          ],
        ),
      ),
    );
  }

  Map<String, dynamic>? get stats =>
      _report['stats'] is Map ? Map<String, dynamic>.from(_report['stats'] as Map) : null;

  Widget _chartCard(BuildContext context, AppLocalizations l10n) {
    return _Reveal(
      key: const ValueKey('chart'),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.translate('invFalconChart'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            _TopSellersChart(items: _topSellers),
          ],
        ),
      ),
    );
  }

  Widget _bulletsCard(
      BuildContext context, String title, List<String> lines, Color color, IconData icon) {
    return _Reveal(
      key: ValueKey('bullets_$title'),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: color.withAlpha(70)),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
                color: color.withAlpha(18),
                blurRadius: 12,
                offset: const Offset(0, 3)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withAlpha(26),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 16, color: color),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: color)),
              ),
            ]),
            const SizedBox(height: 6),
            const SizedBox(height: 4),
            for (var i = 0; i < lines.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      margin: const EdgeInsets.only(top: 2),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: color.withAlpha(28),
                        shape: BoxShape.circle,
                      ),
                      child: Text('${i + 1}',
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              color: color)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: _richLine(_plainLine(lines[i]), color)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _bubble(Map<String, dynamic> m, int index,
      {bool streaming = false}) {
    final isUser = m['role'] == 'user';
    final content = (m['content'] ?? '').toString();
    final status = (m['status'] ?? '').toString();
    final thinking = status == 'thinking';
    final dark = Theme.of(context).brightness == Brightness.dark;
    // ONE widget per message, forever. When the falcon finishes thinking,
    // the SAME tree position cross-fades from the thinking row into the
    // reply bubble — no new bubble, no jump, no disappearing text.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [
          ...previousChildren,
          if (currentChild != null) currentChild,
        ],
      ),
      child: thinking
          ? Align(
              key: const ValueKey('think'),
              alignment: AlignmentDirectional.centerStart,
              child: TweenAnimationBuilder<double>(
                // Smooth entrance: fade + gentle slide-up (never a pop).
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                builder: (c, v, child) => Opacity(
                  opacity: v,
                  child: Transform.translate(
                      offset: Offset(0, 10 * (1 - v)), child: child),
                ),
                child: SizedBox(
                  key: _thinkingFalconAnchorKey,
                  child: FalconThinkingPhrases(
                    clock: _thinkClock,
                    phrases: [
                      l10nKey('falconThink1'),
                      l10nKey('falconThink2'),
                      l10nKey('falconThink3'),
                      l10nKey('falconThink4'),
                    ],
                  ),
                ),
              ),
            )
          : Align(
              key: ValueKey('msg\$index'),
              alignment: isUser
                  ? AlignmentDirectional.centerEnd
                  : AlignmentDirectional.centerStart,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (!isUser)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 6),
                      // The avatar slot: during the journey the ONE falcon
                      // glides over this anchor (slot empty); when it lands,
                      // the static avatar mounts here and carries the final
                      // anchor key the falcon eases onto.
                      child: SizedBox(
                        key: streaming ? _finalAvatarAnchorKey : null,
                        width: 26,
                        height: 26,
                        child: streaming && !_landing
                            ? const SizedBox.shrink()
                            : Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppColors.primary.withAlpha(24),
                                ),
                                child: const Center(child: FalconMark(16)),
                              ),
                      ),
                    ),
                  Flexible(
                    child: InkWell(
                      // Copy on LONG-PRESS only (single tap does nothing).
                      onLongPress: () async {
                        await Clipboard.setData(ClipboardData(text: content));
                        if (mounted) _showCopiedToast();
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        padding: const EdgeInsets.all(14),
                        constraints: BoxConstraints(
                            maxWidth:
                                MediaQuery.of(context).size.width * 0.74),
                        decoration: BoxDecoration(
                          color: isUser
                              ? AppColors.primary.withAlpha(20)
                              : AppColors.surfaceVariant.withAlpha(90),
                          // Dark theme: bright burgundy edges + a subtle
                          // white neon rim-glow so messages pop on black.
                          // Light theme: unchanged.
                          border: Border.all(
                              color: dark
                                  ? (isUser
                                      ? AppColors.primaryLight.withAlpha(165)
                                      : AppColors.primaryLight.withAlpha(135))
                                  : (isUser
                                      ? AppColors.primary.withAlpha(60)
                                      : AppColors.border),
                              width: dark ? 1.2 : 1),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: dark
                              ? [
                                  BoxShadow(
                                      color: Colors.white.withAlpha(14),
                                      blurRadius: 7,
                                      spreadRadius: -1),
                                ]
                              : null,
                        ),
                        child: Text(content,
                            key: streaming ? _messageTextKey : null,
                            style: const TextStyle(
                                fontFamily: 'Cairo', height: 1.7)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// Tiny helper so the bubble can use l10n without threading it around.
  String l10nKey(String key) =>
      AppLocalizations.of(context).translate(key);

  Widget _emptyState(BuildContext context, AppLocalizations l10n) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(children: [
        const FalconMark(50),
        const SizedBox(height: 12),
        Text(l10n.translate('falconNoDataTitle'),
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 15,
                fontWeight: FontWeight.w700,
                height: 1.5)),
        const SizedBox(height: 10),
        for (final k in [
          'falconNoDataSales',
          'falconNoDataPurchases',
          'falconNoDataPeriod',
          'falconNoDataCategory',
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Icon(Icons.circle, size: 6, color: AppColors.textSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(l10n.translate(k),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12,
                        color: AppColors.textSecondary)),
              ),
            ]),
          ),
        const SizedBox(height: 12),
        Text(
            '${l10n.translate('falconTryLonger')} • ${l10n.translate('falconStartOps')}',
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                color: AppColors.primary,
                fontWeight: FontWeight.w700)),
      ]),
    );
  }

  /// Tiny green copy toast (never a big snackbar).
  void _showCopiedToast() {
    _toastCtrl.forward(from: 0);
  }

  /// Pinned chat bar: suggestions (dynamic per scope+metrics) + input.
  /// Never hidden or moved by loading / report / keyboard.
  Widget _chatBar(BuildContext context, AppLocalizations l10n) {
    final suggestions = _ls('suggested_questions').take(4).toList();
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
        boxShadow: [
          BoxShadow(
              color: AppColors.primary.withAlpha(14),
              blurRadius: 10,
              offset: const Offset(0, -3)),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (suggestions.isNotEmpty &&
                _replyPhase != FalconReplyPhase.thinking)
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  children: [
                    for (final s in suggestions)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 6),
                        child: _FlameChip(label: s, onTap: () => _send(s)),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              child: Row(children: [
                Expanded(
                  child: Focus(
                    onFocusChange: (f) {
                      _motion.value = f ? .5 : (_asking ? 1 : .15);
                      if (mounted) setState(() {});
                    },
                    child: Builder(builder: (context) {
                      final hasFocus = Focus.of(context).hasFocus;
                      return _PulsingComposerBorder(
                        active: hasFocus || _asking,
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            color: AppColors.surface.withAlpha(215),
                          ),
                          child: FyonaTextField(
                            controller: _q,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _send(),
                            onChanged: (_) {
                              // Typing: energy leans toward the composer
                              // + the send button's flame pulses.
                              if (!_asking) {
                                _motion.value = .5;
                                _typingActivity.forward(from: 0);
                                _settleCtrl.forward(from: 0).whenComplete(() {
                                  if (mounted && !_asking) _motion.value = .15;
                                });
                              }
                            },
                            decoration: InputDecoration(
                                hintText: l10n.translate('falconAskHint'),
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 13)),
                            style: const TextStyle(fontFamily: 'Cairo'),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                // Send button: circular flame-glow ring + gradient disc.
                // Typing → soft pulse; send → an elegant flash.
                GestureDetector(
                  onTap: _asking ? null : () => _send(),
                  child: _FlameSendButton(
                      pulse: _sendPulse,
                      typing: _typingActivity,
                      asking: _asking),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

/// One-shot staggered reveal (fade + slide) used by report cards. Replays
/// only when the dataset changes (key includes the data version), never on
/// scroll or chat — GPU-cheap (single tween, no filters).
class _Reveal extends StatelessWidget {
  final Widget child;
  const _Reveal({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      builder: (c, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, (1 - v) * 10), child: child),
      ),
      child: child,
    );
  }
}

class _TopSellersChart extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  const _TopSellersChart({required this.items});

  static const double _fontSize = 10.5;

  /// Column width sized by the NAME so every label owns enough horizontal
  /// space to wrap cleanly (long names get wider columns, never squeezed
  /// into overlap). Caps at 120px; longer names just wrap to more lines.
  double _colWidth(String name) {
    final natural = name.length * _fontSize * 0.62;
    return natural.clamp(64.0, 120.0);
  }

  int _lines(String name, double col) {
    final full = name.length * _fontSize * 0.62;
    return (full / col).ceil().clamp(1, 3);
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    double qtyOf(Map m) => (m['qty_sold'] as num?)?.toDouble() ?? 0;
    final maxY = items.map(qtyOf).fold<double>(0, (a, b) => a > b ? a : b);
    final isAr = Localizations.localeOf(context).languageCode != 'en';

    // Per-column widths + the tallest label's line count.
    final cols = [
      for (final e in items) _colWidth((e['name'] ?? '').toString())
    ];
    final maxLines = [
      for (var i = 0; i < items.length; i++)
        _lines((items[i]['name'] ?? '').toString(), cols[i])
    ].fold(1, math.max);
    final barArea = 48.0;
    // Dynamic bottom reservation: tallest wrapped label + breathing gap.
    final bottomReserved = 12.0 + maxLines * (_fontSize * 1.45);
    final chartHeight = 150.0 + (maxLines - 1) * (_fontSize * 1.45);
    final totalW = cols.fold<double>(0, (a, b) => a + b);

    final needScroll = totalW > MediaQuery.of(context).size.width - 64;
    final chart = SizedBox(
      height: chartHeight,
      width: totalW,
      child: Directionality(
        textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
        child: BarChart(
          BarChartData(
            borderData: FlBorderData(show: false),
            gridData: const FlGridData(show: false),
            alignment: BarChartAlignment.spaceEvenly,
            titlesData: FlTitlesData(
              leftTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              topTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: bottomReserved,
                  getTitlesWidget: (v, meta) {
                    final i = v.toInt();
                    if (i < 0 || i >= items.length) {
                      return const SizedBox.shrink();
                    }
                    final name = (items[i]['name'] ?? '').toString();
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        name,
                        textAlign: TextAlign.center,
                        maxLines: maxLines,
                        softWrap: true,
                        overflow: TextOverflow.visible,
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: _fontSize,
                            height: 1.3,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary),
                      ),
                    );
                  },
                ),
              ),
            ),
            barGroups: [
              for (var i = 0; i < items.length; i++)
                BarChartGroupData(x: i, barRods: [
                  BarChartRodData(
                    toY: qtyOf(items[i]),
                    color: AppColors.primary,
                    width: barArea,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ]),
            ],
            maxY: maxY <= 0 ? 1 : maxY * 1.2,
          ),
        ),
      ),
    );

    if (needScroll) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        reverse: isAr, // RTL: start at the right edge
        child: chart,
      );
    }
    return chart;
  }
}

/// Energy burst rising from the composer toward the content on send.
class _BurstPainter extends CustomPainter {
  final double t;
  _BurstPainter({required this.t});
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // ONE clear pulse from the composer: spreads horizontally first
    // (fast easeOutQuart), then lifts gently — never an explosion.
    final spread = Curves.easeOutQuart.transform(t.clamp(0.0, 1.0));
    final lift = Curves.easeOutCubic.transform(t.clamp(0.0, 1.0));
    final fade = math.sin(math.pi * t.clamp(0.0, 1.0));
    final c = Offset(w * .5, h - h * .20 * lift);
    final rx = w * (.18 + .40 * spread);
    final ry = rx * .70;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.scale(1.0, ry / rx);
    canvas.drawCircle(
        Offset.zero,
        rx,
        Paint()
          ..shader = RadialGradient(colors: [
            AppColors.primary.withAlpha((42 * fade).round()),
            AppColors.primary.withAlpha((18 * fade).round()),
            Colors.transparent,
          ]).createShader(Rect.fromCircle(center: Offset.zero, radius: rx)));
    canvas.restore();
    // Warm heart at the root while the pulse passes.
    canvas.drawCircle(
        c,
        w * .16 * (.7 + .5 * spread),
        Paint()
          ..shader = RadialGradient(colors: [
            const Color(0xFFEF4444).withAlpha((30 * fade).round()),
            Colors.transparent,
          ]).createShader(Rect.fromCircle(
              center: c, radius: w * .16 * (.7 + .5 * spread))));
  }

  @override
  bool shouldRepaint(covariant _BurstPainter old) => old.t != t;
}



/// Breathing composer frame: rotating burgundy sweep + inner glow.
class _PulsingComposerBorder extends StatefulWidget {
  final bool active;
  final Widget? child;
  const _PulsingComposerBorder({required this.active, this.child});
  @override
  State<_PulsingComposerBorder> createState() =>
      _PulsingComposerBorderState();
}

class _PulsingComposerBorderState extends State<_PulsingComposerBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 4200));

  @override
  void initState() {
    super.initState();
    if (!_c.isAnimating) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _ComposerBorderPainter(
            active: widget.active,
            dark: Theme.of(context).brightness == Brightness.dark,
            clock: _c),
        child: widget.child,
      ),
    );
  }
}

class _ComposerBorderPainter extends CustomPainter {
  final bool active;
  final bool dark;
  final Animation<double> clock;
  _ComposerBorderPainter(
      {required this.active, required this.dark, required this.clock})
      : super(repaint: clock);
  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(16));
    final rect = Offset.zero & size;
    final t = clock.value * 6.2832;

    // ── Living border ──
    // Two moving "flame heads" travel around the perimeter: the leading
    // one burgundy (strong), the trailing one silver/white (dark) or
    // soft black (light). Idle = slow drift; active = brighter + faster.
    final speed = active ? t * 1.6 : t * 0.55;
    final paint2 = (dark ? Colors.white : Colors.black);
    final a1 = speed % 6.2832;
    final a2 = (speed + math.pi) % 6.2832;

    // Perimeter sweep base.
    canvas.drawRRect(
        rrect.deflate(.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = active ? 2.0 : 1.2
          ..shader = SweepGradient(colors: [
            AppColors.primary.withAlpha(active ? 110 : 60),
            AppColors.primary.withAlpha(active ? 220 : 150),
            (active ? const Color(0xffc9a6d8) : paint2)
                .withAlpha(active ? 150 : 70),
            AppColors.primary.withAlpha(active ? 110 : 60),
          ], transform: GradientRotation(speed))
              .createShader(rect));

    // Flame heads: small glow blobs riding the ring corners.
    void head(double angle, Color color, int alphaBoost) {
      final c = rect.center +
          Offset(math.cos(angle) * rect.width / 2,
              math.sin(angle) * rect.height / 2);
      canvas.drawCircle(
          c,
          10 + 4 * math.sin(t),
          Paint()
            ..shader = RadialGradient(colors: [
              color.withAlpha(alphaBoost),
              color.withAlpha(alphaBoost ~/ 3),
              Colors.transparent,
            ]).createShader(Rect.fromCircle(center: c, radius: 14)));
    }

    head(a1, AppColors.primary, active ? 80 : 48);
    head(a2, paint2, active ? 46 : 26);

    // Soft burgundy glow escaping a few px OUTSIDE the edge.
    canvas.drawRRect(
        rrect.inflate(3),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..shader = SweepGradient(colors: [
            AppColors.primary.withAlpha(0),
            AppColors.primary.withAlpha(active ? 34 : 16),
            AppColors.primary.withAlpha(0),
          ], transform: GradientRotation(-speed))
              .createShader(rect.inflate(6)));

    // Breathing inner glow.
    canvas.drawRect(
        rect.deflate(1),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              AppColors.primary.withAlpha(
                  (active ? 26 : 10 + 8 * math.sin(t)).round().abs()),
              Colors.transparent,
            ],
          ).createShader(rect));
  }

  @override
  bool shouldRepaint(covariant _ComposerBorderPainter old) =>
      old.active != active;
}











/// Suggested-question chip with a living burgundy flame-glow border:
/// a slow rotating gradient ring whose glow breathes from the edges —
/// soft (never neon), theme-aware contrast, paint-only (isolated clock).
class _FlameChip extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _FlameChip({required this.label, required this.onTap});
  @override
  State<_FlameChip> createState() => _FlameChipState();
}

class _FlameChipState extends State<_FlameChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 5200))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _FlameBorderPainter(clock: _c, dark: dark),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Text(widget.label,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 11,
                    color: AppColors.textPrimary)),
          ),
        ),
      ),
    );
  }
}

class _FlameBorderPainter extends CustomPainter {
  final Animation<double> clock;
  final bool dark;
  _FlameBorderPainter({required this.clock, required this.dark})
      : super(repaint: clock);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(20));
    final t = clock.value * 6.2832;
    // The border: thin burgundy sweep — the "flame ring".
    canvas.drawRRect(
        rrect.deflate(.6),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..shader = SweepGradient(colors: [
            AppColors.primary.withAlpha(45),
            AppColors.primary.withAlpha(150),
            const Color(0xffc9a6d8).withAlpha(95),
            AppColors.primary.withAlpha(45),
          ], transform: GradientRotation(t))
              .createShader(rect));
    // The glow: soft bloom breathing from the edge inward/outward.
    final breath = 0.5 + 0.5 * math.sin(t * .9);
    canvas.drawRRect(
        rrect.inflate(2 + breath * 2.5),
        Paint()
          ..shader = RadialGradient(
              center: Alignment.center,
              radius: 1.1,
              colors: [
                AppColors.primary.withAlpha(0),
                AppColors.primary
                    .withAlpha(((dark ? 16 : 9) + breath * 12).round()),
                AppColors.primary.withAlpha(0),
              ])
              .createShader(rect.inflate(8)));
  }

  @override
  bool shouldRepaint(covariant _FlameBorderPainter old) =>
      old.dark != dark;
}

/// Send button with a circular burgundy flame-glow: slow ambient ring +
/// soft pulse while typing + elegant flash at send. Paint-only layers.
class _FlameSendButton extends StatelessWidget {
  final AnimationController pulse;
  final AnimationController typing;
  final bool asking;
  const _FlameSendButton(
      {required this.pulse, required this.typing, required this.asking});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: Listenable.merge([pulse, typing]),
        builder: (context, _) {
          final t = pulse.value;
          final scale =
              asking ? 1.0 : 1 + .16 * math.sin(t * math.pi);
          final flash = (1 - t).clamp(0.0, 1.0);
          // Typing feeds the breathe: decay toward a slow base glow.
          final typingEnergy = (1 - typing.value).toDouble(); // 1 after keystroke
          return Transform.scale(
            scale: scale,
            child: SizedBox(
              width: 52,
              height: 52,
              child: Stack(alignment: Alignment.center, children: [
                // Ambient flame ring (always alive, slow rotation).
                CustomPaint(
                  size: const Size.square(52),
                  painter: _SendFlamePainter(
                      t: (DateTime.now().millisecondsSinceEpoch % 100000) / 100000.0,
                      typingEnergy: typingEnergy,
                      flash: flash,
                      dark: dark,
                      asking: asking),
                ),
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [
                      AppColors.primary,
                      AppColors.primary.withAlpha(185),
                    ]),
                    boxShadow: [
                      BoxShadow(
                          color: AppColors.primary
                              .withAlpha(asking ? 22 : (46 + 26 * typingEnergy).round()),
                          blurRadius: asking ? 4 : 9 + 4 * typingEnergy),
                    ],
                  ),
                  child: Icon(asking
                          ? Icons.hourglass_top_rounded
                          : Icons.send_rounded,
                      color: Colors.white,
                      size: 21),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }
}

class _SendFlamePainter extends CustomPainter {
  final double t;
  final double typingEnergy;
  final double flash;
  final bool dark;
  final bool asking;
  _SendFlamePainter(
      {required this.t,
      required this.typingEnergy,
      required this.flash,
      required this.dark,
      required this.asking});
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * .48;
    // Rotating two-tone flame ring (never neon-sharp).
    canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        t * 6.2832,
        math.pi * 1.25,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..shader = SweepGradient(colors: [
            AppColors.primary.withAlpha(0),
            AppColors.primary.withAlpha((70 + 60 * typingEnergy).round()),
            const Color(0xffc9a6d8).withAlpha((36 + 40 * typingEnergy).round()),
            AppColors.primary.withAlpha(0),
          ]).createShader(Offset.zero & size));
    // Send flash: a short expanding wave.
    if (flash > .05) {
      canvas.drawCircle(
          c, r + (1 - flash) * 12,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = AppColors.primary.withAlpha((flash * 90).round()));
    }
  }

  @override
  bool shouldRepaint(covariant _SendFlamePainter old) => true;
}


/// Data field names an older server answer may still contain, in plain words.
const _falconFieldWords = <String, String>{
  'qty_sold': 'الكمية المباعة',
  'quantity_sold': 'الكمية المباعة',
  'total_profit': 'الربح',
  'total_sales': 'المبيعات',
  'total_cogs': 'تكلفة المبيعات',
  'inventory_value': 'قيمة المخزون',
  'suggested_order_qty': 'كمية الطلب',
  'order_qty': 'كمية الطلب',
  'order_cost': 'تكلفة الطلب',
  'min_stock': 'الحد الأدنى',
  'low_stock': 'قرب يخلص',
  'reorder': 'الطلب',
};
