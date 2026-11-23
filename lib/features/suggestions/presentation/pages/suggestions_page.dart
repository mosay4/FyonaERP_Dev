import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart' hide TextDirection;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/services/connectivity_service.dart';
import '../../../../shared/widgets/connectivity_widgets.dart';
import '../../../../shared/widgets/two_tone_icon.dart';
import '../../../../shared/widgets/two_tone_icons.dart';
import '../../data/models/suggestion_models.dart';
import '../../di/suggestions_providers.dart';
import '../widgets/conversation_ui.dart';
import '../widgets/suggestion_media_widgets.dart';
import '../../../../core/localization/app_localizations.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

class SuggestionsPage extends ConsumerStatefulWidget {
  SuggestionsPage({super.key});

  @override
  ConsumerState<SuggestionsPage> createState() => _SuggestionsPageState();
}

class _SuggestionsPageState extends ConsumerState<SuggestionsPage> {
  final _imagePicker = ImagePicker();
  final _audioRecorder = AudioRecorder();
  final _audioPlayer = AudioPlayer();
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<Uint8List> _images = [];
  final List<String> _imageNames = [];
  final List<Uint8List> _videos = [];
  final List<String> _videoNames = [];
  final List<Uint8List> _audios = [];
  final List<String> _audioNames = [];
  String? _openTicketId;
  bool _submitting = false;
  bool _isRecording = false;
  int _recordingSeconds = 0;
  double _waveformValue = 0;
  Timer? _recordingTimer;
  Timer? _incomingPollTimer;
  int? _playingIndex;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      markSuggestionsChatRead();
      ref.invalidate(suggestionUnreadCountProvider);
      // Start presence heartbeat so the admin sees us as online.
      ref.read(suggestionPresenceProvider);
    });
    // Live incoming replies + status changes: poll the open ticket (and the
    // unread counter) so admin answers and status flips appear within
    // seconds without reopening the page. Skipped while submitting/recording
    // and guarded offline-safe.
    _incomingPollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || _submitting || _isRecording) return;
      try {
        if (!ref.read(connectivityServiceProvider).isOnline) return;
        if (_openTicketId != null) {
          ref.invalidate(suggestionTicketProvider(_openTicketId!));
        }
        ref.invalidate(mySuggestionsProvider);
        ref.invalidate(mySuggestionsConversationProvider);
      } catch (_) {}
    });
    // Offline guard: show a polished centered modal instead of the raw
    // "server unavailable" error when the network is down.
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
            ref.invalidate(mySuggestionsProvider);
            if (_openTicketId != null) {
              ref.invalidate(suggestionTicketProvider(_openTicketId!));
            }
          }
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _incomingPollTimer?.cancel();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImages() async {
    final remaining = 5 - _images.length;
    if (remaining <= 0) {
      _showSnack(AppLocalizations.of(context).translate('suggestionsMaximum5Photos'));
      return;
    }
    final picked = await _imagePicker.pickMultiImage();
    if (picked.isEmpty) return;
    for (final file in picked.take(remaining)) {
      try {
        final bytes = await file.readAsBytes();
        if (!mounted) return;
        setState(() {
          _images.add(bytes);
          _imageNames.add(file.name);
        });
      } catch (_) {
        // skip unreadable file
      }
    }
  }

  Future<void> _pickVideos() async {
    final remaining = 2 - _videos.length;
    if (remaining <= 0) {
      _showSnack(AppLocalizations.of(context).translate('suggestionsMaximumTwoVideos'));
      return;
    }
    final file = await _imagePicker.pickVideo(source: ImageSource.gallery);
    if (file == null) return;
    try {
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        _videos.add(bytes);
        _videoNames.add(file.name);
      });
    } catch (_) {
      _showSnack(AppLocalizations.of(context).translate('suggestionsTheVideoCouldNot'));
    }
  }

  void _showMediaPicker() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              SizedBox(height: 6),
              ListTile(
                leading: Icon(Icons.image_outlined,
                    color: AppColors.textPrimary, size: 22),
                title: Text(AppLocalizations.of(context).translate('suggestionsImage'),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                trailing: Icon(Icons.chevron_left,
                    color: AppColors.textDisabled),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImages();
                },
              ),
              ListTile(
                leading: Icon(Icons.videocam_outlined,
                    color: AppColors.textPrimary, size: 22),
                title: Text(AppLocalizations.of(context).translate('suggestionsVideo'),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                trailing: Icon(Icons.chevron_left,
                    color: AppColors.textDisabled),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickVideos();
                },
              ),
              SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }

  Future<void> _startRecording() async {
    final hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) {
      _showSnack(AppLocalizations.of(context).translate('suggestionsYouNeedMicrophonePermission'));
      return;
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/sugg_audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _audioRecorder.start(RecordConfig(encoder: AudioEncoder.aacLc),
        path: path);
    _recordingSeconds = 0;
    _recordingTimer = Timer.periodic(Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() {
        _recordingSeconds++;
        _waveformValue = math.Random().nextDouble();
      });
    });
    setState(() => _isRecording = true);
  }

  Future<void> _stopRecording() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    final path = await _audioRecorder.stop();
    if (!mounted) return;
    if (path != null) {
      try {
        final bytes = await File(path).readAsBytes();
        if (bytes.isEmpty) throw Exception('empty');
        setState(() {
          _audios.add(bytes);
          _audioNames.add(
              'recording_${DateTime.now().millisecondsSinceEpoch}.m4a');
        });
      } catch (_) {
        _showSnack(AppLocalizations.of(context).translate('suggestionsTheAudioRecordingCould'));
      } finally {
        final f = File(path);
        if (f.existsSync()) f.delete();
      }
    }
    setState(() => _isRecording = false);
  }

  Future<void> _togglePlayAudio(int index) async {
    if (_playingIndex == index) {
      await _audioPlayer.stop();
      if (mounted) setState(() => _playingIndex = null);
      return;
    }
    await _audioPlayer.stop();
    setState(() => _playingIndex = index);
    try {
      await _audioPlayer.play(BytesSource(_audios[index]));
      _audioPlayer.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => _playingIndex = null);
      });
    } catch (_) {
      if (mounted) setState(() => _playingIndex = null);
    }
  }

  bool get _hasMedia =>
      _images.isNotEmpty || _videos.isNotEmpty || _audios.isNotEmpty;

  Future<void> _submit() async {
    final body = _inputCtrl.text.trim();
    if (body.isEmpty && !_hasMedia) {
      _showSnack(AppLocalizations.of(context).translate('suggestionsWriteTheProposalDescription'));
      return;
    }
    setState(() => _submitting = true);
    try {
      final service = ref.read(suggestionsServiceProvider);
      if (_openTicketId != null) {
        // Inside a ticket: append a message to that dedicated chat — text
        // and/or media (voice/image alone are both allowed now).
        await service.replyToSuggestion(
          suggestionId: _openTicketId!,
          body: body,
          images: _images,
          imageNames: _imageNames,
          videos: _videos,
          videoNames: _videoNames,
          audios: _audios,
          audioNames: _audioNames,
        );
        ref.invalidate(suggestionTicketProvider(_openTicketId!));
      } else {
        await service.submit(
          body: body,
          images: _images,
          imageNames: _imageNames,
          videos: _videos,
          videoNames: _videoNames,
          audios: _audios,
          audioNames: _audioNames,
        );
        ref.invalidate(mySuggestionsProvider);
      }
      _inputCtrl.clear();
      setState(() {
        _images.clear();
        _imageNames.clear();
        _videos.clear();
        _videoNames.clear();
        _audios.clear();
        _audioNames.clear();
      });
      ref.invalidate(mySuggestionsProvider);
      ref.invalidate(mySuggestionsConversationProvider);
    } catch (e) {
      _showSnack(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _openTicket(Suggestion ticket) {
    setState(() {
      _openTicketId = ticket.id;
      _images.clear();
      _imageNames.clear();
      _videos.clear();
      _videoNames.clear();
      _audios.clear();
      _audioNames.clear();
    });
    _inputCtrl.clear();
    markSuggestionsChatRead();
    ref.invalidate(suggestionUnreadCountProvider);
  }

  void _backToList() {
    setState(() => _openTicketId = null);
    // Refresh the list so a status changed by the admin shows immediately.
    try {
      ref.invalidate(mySuggestionsProvider);
    } catch (_) {}
  }

  Future<Suggestion?> _createSuggestion(String title, String body) async {
    try {
      final created = await ref
          .read(suggestionsServiceProvider)
          .submit(title: title, body: body);
      if (mounted) {
        setState(() => _openTicketId = created.id);
      }
      ref.invalidate(mySuggestionsProvider);
      markSuggestionsChatRead();
      return created;
    } catch (e) {
      _showSnack(e.toString().replaceFirst('Exception: ', ''));
      return null;
    }
  }

  void _showNewSuggestionSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      // Scroll-controlled + keyboard-aware: without these the two text
      // fields overflow by ~41px as soon as the keyboard opens.
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            child: _NewSuggestionSheet(
              onCreate: (title, body) => _createSuggestion(title, body),
            ),
          ),
        ),
      ),
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_openTicketId != null) {
      return _ChatScaffold(
        suggestionId: _openTicketId!,
        controller: _scrollCtrl,
        onBack: () => _backToList(),
        composer: () => Column(
          children: [
            _buildPreviewBar(),
            _buildInputBar(),
          ],
        ),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildListAppBar(),
      body: Column(
        children: [
          Expanded(
            child: _TicketList(
              onOpen: (t) => _openTicket(t),
              onCreate: () => _showNewSuggestionSheet(),
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildListAppBar() {
    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PlatformAvatar(size: 38),
          SizedBox(width: 12),
          Text(AppLocalizations.of(context).translate('appFeedbackSuggestions'),
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
        ],
      ),
      actions: [
        IconButton(
          icon: TwoToneIcon(data: TwoToneIcons.plus, size: 22),
          onPressed: () => _showNewSuggestionSheet(),
        ),
      ],
    );
  }

  Widget _buildPreviewBar() {
    final hasMedia = _hasMedia;
    if (!hasMedia) return SizedBox.shrink();
    return Container(
      padding: EdgeInsets.fromLTRB(10, 8, 10, 0),
      child: SizedBox(
        height: 84,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _images.length + _videos.length + _audios.length,
          separatorBuilder: (_, _) => SizedBox(width: 8),
          itemBuilder: (context, i) {
            if (i < _images.length) return _buildImagePreview(i);
            final vi = i - _images.length;
            if (vi < _videos.length) return _buildVideoPreview(vi);
            return _buildAudioPreview(i - _images.length - _videos.length);
          },
        ),
      ),
    );
  }

  Widget _buildImagePreview(int i) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(_images[i],
              width: 84, height: 84, fit: BoxFit.cover),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: GestureDetector(
            onTap: () => setState(() {
              _images.removeAt(i);
              _imageNames.removeAt(i);
            }),
            child: const _RemoveBadge(),
          ),
        ),
      ],
    );
  }

  Widget _buildVideoPreview(int i) {
    return Stack(
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            color: AppColors.surfaceVariant,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.divider),
          ),
          child: Center(
            child: Icon(Icons.play_circle_fill,
                size: 36, color: AppColors.primary),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: GestureDetector(
            onTap: () => setState(() {
              _videos.removeAt(i);
              _videoNames.removeAt(i);
            }),
            child: const _RemoveBadge(),
          ),
        ),
      ],
    );
  }

  Widget _buildAudioPreview(int i) {
    return Container(
      width: 150,
      height: 84,
      padding: EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Stack(
        children: [
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _togglePlayAudio(i),
                  icon: Icon(
                    _playingIndex == i
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_fill,
                    color: AppColors.primary,
                    size: 30,
                  ),
                ),
                SizedBox(width: 4),
                Text(AppLocalizations.of(context).translate('suggestionsAudioRecording'),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 11,
                        color: AppColors.textDisabled)),
              ],
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: GestureDetector(
              onTap: () => setState(() {
                _audios.removeAt(i);
                _audioNames.removeAt(i);
              }),
              child: const _RemoveBadge(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    final hasText = _inputCtrl.text.trim().isNotEmpty;
    final hasMedia = _hasMedia;
    final canSend = (hasText || hasMedia) && !_submitting;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(top: BorderSide(color: AppColors.surfaceVariant, width: 0.5)),
      ),
      padding: EdgeInsets.only(
        left: 10,
        right: 10,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      child: _isRecording ? _buildRecordingInput() : _buildTextInput(canSend),
    );
  }

  Widget _buildTextInput(bool canSend) {
    const btnSize = 44.0;
    return Row(
      key: ValueKey('text_input'),
      textDirection: ui.TextDirection.ltr,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        GestureDetector(
          onTap: canSend ? _submit : null,
          child: AnimatedContainer(
            duration: Duration(milliseconds: 200),
            width: btnSize,
            height: btnSize,
            margin: EdgeInsets.only(bottom: 2),
            decoration: BoxDecoration(
              color: canSend ? Color(0xFFE53935) : AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Icon(
              Icons.arrow_forward_rounded,
              color: canSend ? Colors.white : AppColors.textDisabled,
              size: 20,
            ),
          ),
        ),
        SizedBox(width: 6),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: AppColors.divider, width: 0.5),
            ),
            child: FyonaTextField(
              controller: _inputCtrl,
              textAlign: TextAlign.right,
              textInputAction: TextInputAction.send,
              maxLines: 4,
              minLines: 1,
              textDirection: ui.TextDirection.rtl,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => canSend ? _submit() : null,
              decoration: InputDecoration(
                hintText: AppLocalizations.of(context).translate('suggestionsWriteYourSuggestionHere'),
                hintTextDirection: ui.TextDirection.rtl,
                hintStyle: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 14,
                    color: AppColors.textPlaceholder),
                border: InputBorder.none,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 14,
                  color: AppColors.textPrimary,
                  height: 1.3),
            ),
          ),
        ),
        SizedBox(width: 6),
        GestureDetector(
          onTap: _submitting ? null : _showMediaPicker,
          child: Container(
            width: btnSize,
            height: btnSize,
            margin: EdgeInsets.only(bottom: 2),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Icon(Icons.add_photo_alternate_outlined,
                color: AppColors.textDisabled, size: 22),
          ),
        ),
        SizedBox(width: 4),
        GestureDetector(
          onTap: _isRecording ? _stopRecording : _startRecording,
          child: Container(
            width: btnSize,
            height: btnSize,
            margin: EdgeInsets.only(bottom: 2),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Icon(
              _isRecording ? Icons.stop_rounded : Icons.mic,
              color: _isRecording ? AppColors.danger : AppColors.textDisabled,
              size: 22,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRecordingInput() {
    final mins = (_recordingSeconds ~/ 60).toString().padLeft(2, '0');
    final secs = (_recordingSeconds % 60).toString().padLeft(2, '0');
    return Container(
      key: ValueKey('recording_input'),
      height: 40,
      margin: EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.danger.withAlpha(80), width: 0.5),
      ),
      child: Row(
        textDirection: ui.TextDirection.ltr,
        children: [
          SizedBox(width: 12),
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
                shape: BoxShape.circle, color: AppColors.danger),
          ),
          SizedBox(width: 8),
          Text('$mins:$secs',
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
          SizedBox(width: 10),
          Expanded(child: _buildLiveWaveform()),
          SizedBox(width: 8),
          GestureDetector(
            onTap: _stopRecording,
            child: Container(
              width: 36,
              height: 36,
              margin: EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: AppColors.danger,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(Icons.stop_rounded,
                  color: Colors.white, size: 18),
            ),
          ),
          SizedBox(width: 6),
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
          final h = base +
              _waveformValue * 18 * (0.5 + 0.5 * ((i * 7 + _recordingSeconds * 3) % 10) / 10);
          return AnimatedContainer(
            duration: Duration(milliseconds: 120),
            width: 3,
            height: h.clamp(4.0, 28.0),
            margin: EdgeInsetsDirectional.only(end: 2),
            decoration: BoxDecoration(
              color: AppColors.danger.withAlpha(180),
              borderRadius: BorderRadius.circular(1.5),
            ),
          );
        }),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  TICKET LIST — every suggestion the user created
// ═══════════════════════════════════════════════════════════════

class _TicketList extends ConsumerStatefulWidget {
  final void Function(Suggestion ticket) onOpen;
  final VoidCallback onCreate;
  const _TicketList({required this.onOpen, required this.onCreate});

  @override
  ConsumerState<_TicketList> createState() => _TicketListState();
}

class _TicketListState extends ConsumerState<_TicketList> {
  @override
  Widget build(BuildContext context) {
    final tickets = ref.watch(mySuggestionsProvider);
    return tickets.when(
      loading: () => Center(
          child: CircularProgressIndicator(color: AppColors.primary)),
      error: (_, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(AppLocalizations.of(context).translate('suggestionsUnableToLoadSuggestions'),
                style: TextStyle(
                    fontFamily: 'Cairo', color: AppColors.textDisabled)),
            SizedBox(height: 10),
            GestureDetector(
              onTap: () => ref.invalidate(mySuggestionsProvider),
              child: Container(
                padding:
                    EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(AppLocalizations.of(context).translate('retry'),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
      data: (items) {
        if (items.isEmpty) return _EmptyTickets(onCreate: widget.onCreate);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(18, 12, 18, 4),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                        AppLocalizations.of(context).translate('suggestionsYourSuggestions'),
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textSecondary)),
                  ),
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha(12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('${items.length}',
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primary)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                itemCount: items.length,
                separatorBuilder: (_, _) => SizedBox(height: 10),
                itemBuilder: (context, i) => _TicketTile(
                  ticket: items[i],
                  onTap: () => widget.onOpen(items[i]),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TicketTile extends StatelessWidget {
  final Suggestion ticket;
  final VoidCallback? onTap;
  const _TicketTile({required this.ticket, this.onTap});

  @override
  Widget build(BuildContext context) {
    final (statusLabelText, statusColor) = statusLabel(ticket.status);
    final bodyPreview = ticket.body.isNotEmpty
        ? ticket.body
        : (ticket.title.isNotEmpty
              ? AppLocalizations.of(context).translate('suggestionsAudioRecording')
              : ticket.title);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.divider, width: 0.5),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _PlatformAvatar(size: 40),
            SizedBox(width: 12),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          ticket.title.isNotEmpty ? ticket.title
                              : AppLocalizations.of(context).translate('suggestionsSuggestion'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary),
                        ),
                      ),
                      SizedBox(width: 8),
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: statusColor.withAlpha(25),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(statusLabelText,
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: statusColor)),
                      ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text(bodyPreview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 12,
                          color: AppColors.textSecondary,
                          height: 1.4)),
                  SizedBox(height: 4),
                  Text(_ticketDate(ticket.createdAt),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 10,
                          color: AppColors.textPlaceholder)),
                ],
              ),
            ),
            SizedBox(width: 6),
            Icon(Icons.chevron_left, size: 18, color: AppColors.textDisabled),
          ],
        ),
      ),
    );
  }

  String _ticketDate(String? raw) {
    final ts = DateTime.tryParse(raw ?? '');
    if (ts == null) return '';
    return timeAgo(raw);
  }
}

class _EmptyTickets extends StatelessWidget {
  final VoidCallback onCreate;
  const _EmptyTickets({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Color(0xFFA01530), Color(0xFF6B0F20)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withAlpha(60),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: HugeIcon(
                icon: HugeIcons.strokeRoundedChatSpark,
                color: Colors.white,
                size: 40,
                strokeWidth: 1.8,
              ),
            ),
            SizedBox(height: 20),
            Text(AppLocalizations.of(context).translate('suggestionsNoTicketsTitle'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            SizedBox(height: 8),
            Text(AppLocalizations.of(context).translate('suggestionsNoTicketsHint'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    color: AppColors.textDisabled,
                    height: 1.6)),
            SizedBox(height: 18),
            GestureDetector(
              onTap: onCreate,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_rounded, color: Colors.white, size: 18),
                    SizedBox(width: 8),
                    Text(AppLocalizations.of(context).translate('suggestionsCreateYourFirst'),
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
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
//  NEW SUGGESTION SHEET — name + short description
// ═══════════════════════════════════════════════════════════════

class _NewSuggestionSheet extends ConsumerStatefulWidget {
  final Future<Suggestion?> Function(String title, String body) onCreate;
  const _NewSuggestionSheet({required this.onCreate});

  @override
  ConsumerState<_NewSuggestionSheet> createState() => _NewSuggestionSheetState();
}

class _NewSuggestionSheetState extends ConsumerState<_NewSuggestionSheet> {
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit(BuildContext context) async {
    final title = _titleCtrl.text.trim();
    final body = _bodyCtrl.text.trim();
    if (title.isEmpty || body.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context).translate('suggestionsNewFieldsRequired'),
            style: TextStyle(fontFamily: 'Cairo')),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    setState(() => _submitting = true);
    final created = await widget.onCreate(title, body);
    if (!mounted) return;
    if (created != null) {
      Navigator.pop(context);
    } else {
      setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: 10),
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
          SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.edit_note_outlined,
                  color: AppColors.primary, size: 22),
              SizedBox(width: 10),
              Text(AppLocalizations.of(context).translate('suggestionsCreateNew'),
                  style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
            ],
          ),
          SizedBox(height: 16),
          FyonaTextField(
            controller: _titleCtrl,
            textDirection: ui.TextDirection.rtl,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: AppLocalizations.of(context).translate('suggestionsNewTitleHint'),
              hintTextDirection: ui.TextDirection.rtl,
              hintStyle: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 13,
                  color: AppColors.textPlaceholder),
              label: Text(AppLocalizations.of(context).translate('suggestionsNewTitle'),
                  style: TextStyle(fontFamily: 'Cairo', fontSize: 12)),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppColors.divider),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppColors.divider),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    BorderSide(color: AppColors.primary, width: 1.5),
              ),
              contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            style: TextStyle(fontFamily: 'Cairo', fontSize: 14),
          ),
          SizedBox(height: 12),
          FyonaTextField(
            controller: _bodyCtrl,
            maxLines: 4,
            minLines: 2,
            textDirection: ui.TextDirection.rtl,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: AppLocalizations.of(context).translate('suggestionsNewDescriptionHint'),
              hintTextDirection: ui.TextDirection.rtl,
              hintStyle: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 13,
                  color: AppColors.textPlaceholder),
              label: Text(AppLocalizations.of(context).translate('suggestionsNewDescription'),
                  style: TextStyle(fontFamily: 'Cairo', fontSize: 12)),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppColors.divider),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppColors.divider),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    BorderSide(color: AppColors.primary, width: 1.5),
              ),
              contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            style: TextStyle(fontFamily: 'Cairo', fontSize: 14),
          ),
          SizedBox(height: 18),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: _submitting ? null : () => Navigator.pop(context),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(AppLocalizations.of(context).translate('cancel'),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary)),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  onTap: _submitting ? null : () => _submit(context),
                  child: AnimatedContainer(
                    duration: Duration(milliseconds: 150),
                    height: 44,
                    decoration: BoxDecoration(
                      color: _submitting ? AppColors.surfaceVariant : AppColors.primary,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: _submitting
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.4, color: AppColors.primary),
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.done_rounded,
                                  color: Colors.white, size: 18),
                              SizedBox(width: 8),
                              Text(AppLocalizations.of(context).translate('suggestionsCreateNew'),
                                  style: TextStyle(
                                      fontFamily: 'Cairo',
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white)),
                            ],
                          ),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  CHAT SCAFFOLD — one ticket's dedicated conversation
// ═══════════════════════════════════════════════════════════════

class _ChatScaffold extends ConsumerStatefulWidget {
  final String suggestionId;
  final ScrollController controller;
  final VoidCallback onBack;
  final Widget Function() composer;
  const _ChatScaffold({
    required this.suggestionId,
    required this.controller,
    required this.onBack,
    required this.composer,
  });

  @override
  ConsumerState<_ChatScaffold> createState() => _ChatScaffoldState();
}

class _ChatScaffoldState extends ConsumerState<_ChatScaffold> {
  @override
  Widget build(BuildContext context) {
    final ticket = ref.watch(suggestionTicketProvider(widget.suggestionId));
    return ticket.when(
      loading: () => Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
      ),
      error: (_, _) => Scaffold(
        backgroundColor: AppColors.background,
        appBar: _buildAppBar(context, '', 'pending'),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(AppLocalizations.of(context).translate('suggestionsUnableToLoadSuggestions'),
                  style: TextStyle(
                      fontFamily: 'Cairo', color: AppColors.textDisabled)),
              SizedBox(height: 10),
              GestureDetector(
                onTap: () =>
                    ref.invalidate(suggestionTicketProvider(widget.suggestionId)),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(AppLocalizations.of(context).translate('retry'),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
      data: (entries) {
        final first = entries.isEmpty ? null : entries[0];
        final sug = first?.suggestion;
        final title = (sug?.title ?? '').isNotEmpty
            ? sug!.title
            : AppLocalizations.of(context).translate('suggestionsSuggestion');
        final status = sug?.status ?? 'pending';
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: _buildAppBar(context, title, status),
          body: Column(
            children: [
              _TicketBanner(title: title, createdAt: sug?.createdAt),
              Expanded(
                  child: _ChatList(
                    suggestionId: widget.suggestionId,
                    controller: widget.controller,
                  )),
              widget.composer(),
            ],
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, String title, String status) {
final (statusLabelText, statusColor) =
    statusLabel(status);
    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      leading: GestureDetector(
        onTap: widget.onBack,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: AppColors.surfaceVariant,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Icon(Icons.arrow_back_ios_new,
                size: 20, color: AppColors.textPrimary),
          ),
        ),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _PlatformAvatar(size: 32),
          SizedBox(width: 10),
          Flexible(
            child: Text(
                AppLocalizations.of(context).translate('appFeedbackSuggestions'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
          ),
        ],
      ),
      actions: [
        GestureDetector(
          onTap: () => _showStatusDialog(context, status),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: statusColor.withAlpha(18),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: statusColor.withAlpha(60), width: 0.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(Icons.info_outlined, size: 15, color: statusColor),
                SizedBox(width: 5),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(AppLocalizations.of(context).translate('suggestionsStatusLabel'),
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 9,
                            color: AppColors.textSecondary)),
                    Text(statusLabelText,
                        maxLines: 1,
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: statusColor)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _showStatusDialog(BuildContext context, String current) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            width: double.infinity,
            height: double.infinity,
            child: SingleChildScrollView(
              padding: EdgeInsets.all(20),
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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.info_outlined,
                            color: AppColors.primary, size: 26),
                        SizedBox(height: 6),
                        Text(AppLocalizations.of(context).translate('suggestionsStatusDialogTitle'),
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary)),
                        SizedBox(height: 2),
                        Text(AppLocalizations.of(context).translate('suggestionsStatusDialogHint'),
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 11,
                                color: AppColors.textDisabled)),
                      ],
                    ),
                  ),
                  SizedBox(height: 14),
                  for (final st in suggestionStatuses) ...[
                    _StatusRow(
                      status: st,
                      isCurrent: st == current,
                      onTap: () => Navigator.pop(ctx),
                    ),
                    SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StatusRow extends StatelessWidget {
  final String status;
  final bool isCurrent;
  final VoidCallback? onTap;
  const _StatusRow({required this.status, this.isCurrent = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final (labelText, color) = statusLabel(status);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isCurrent ? color.withAlpha(18) : AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(14),
          border: isCurrent
              ? Border.all(color: color.withAlpha(90), width: 1)
              : Border.all(color: AppColors.divider, width: 0.5),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: color.withAlpha(20),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: isCurrent
                    ? Icon(Icons.check_rounded,
                        size: 16, color: color)
                    : SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                            strokeWidth: 3, color: color, value: 1)),
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(labelText,
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: color)),
                      if (isCurrent) ...[
                        SizedBox(width: 6),
                        Text(AppLocalizations.of(context).translate('suggestionsCurrentStatus'),
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 10,
                                color: AppColors.textSecondary)),
                      ],
                    ],
                  ),
                  SizedBox(height: 3),
                  Text(statusDescription(status),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 11,
                          color: AppColors.textSecondary,
                          height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TicketBanner extends StatelessWidget {
  final String title;
  final String? createdAt;
  const _TicketBanner({required this.title, this.createdAt});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withAlpha(160),
        border: Border(
          bottom: BorderSide(color: AppColors.divider, width: 0.5),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.edit_note_outlined, size: 16, color: AppColors.primary),
          SizedBox(width: 8),
          Flexible(
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
          ),
          SizedBox(width: 8),
          Text(timeAgo(createdAt),
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 10,
                  color: AppColors.textPlaceholder)),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  CONVERSATION LIST (one ticket)
// ═══════════════════════════════════════════════════════════════

class _ChatList extends ConsumerStatefulWidget {
  final String suggestionId;
  final ScrollController controller;
  const _ChatList({required this.suggestionId, required this.controller});

  @override
  ConsumerState<_ChatList> createState() => _ChatListState();
}

class _ChatListState extends ConsumerState<_ChatList> {
  void _scrollToBottom() {
    final c = widget.controller;
    if (c.hasClients) {
      c.animateTo(c.position.maxScrollExtent,
          duration: Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversation = ref.watch(suggestionTicketProvider(widget.suggestionId));
    return conversation.when(
      loading: () => Center(
          child: CircularProgressIndicator(color: AppColors.primary)),
      error: (_, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(AppLocalizations.of(context).translate('suggestionsUnableToLoadSuggestions'),
                style: TextStyle(
                    fontFamily: 'Cairo', color: AppColors.textDisabled)),
            SizedBox(height: 10),
            GestureDetector(
              onTap: () =>
                  ref.invalidate(suggestionTicketProvider(widget.suggestionId)),
              child: Container(
                padding:
                    EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(AppLocalizations.of(context).translate('retry'),
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
      data: (entries) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollToBottom();
        });
        if (entries.isEmpty) return const _EmptyState();
        return ListView.builder(
          controller: widget.controller,
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: entries.length,
          itemBuilder: (context, i) => _buildEntry(entries, i),
        );
      },
    );
  }

  Widget _buildEntry(List<SuggestionChatEntry> entries, int i) {
    final entry = entries[i];
    final prev = i > 0 ? entries[i - 1] : null;
    final date = _entryDate(entry);
    final showDate = prev == null || !_sameDay(_entryDate(prev), date);
    // Group consecutive bubbles only when they share the same side
    // (admin vs user) — a user reply after an admin reply starts fresh.
    final grouped = prev != null &&
        _sameDay(_entryDate(prev), date) &&
        _entryIsAdmin(prev) == _entryIsAdmin(entry);

    final r = entry.reply;
    if (r != null) {
      if (!r.isFromAdmin) {
        // The user's own message: right side (direction-aware), red border.
        return Column(
          children: [
            if (showDate) ConversationDateSeparator(date: date),
            _UserMessageBubble(
              reply: r,
              time: date,
              isGrouped: grouped,
              onLongPress: () => _showOwnMessageActions(r),
            ),
          ],
        );
      }
      return Column(
        children: [
          if (showDate) ConversationDateSeparator(date: date),
          _AdminBubble(
            reply: r,
            text: r.body,
            images: r.images,
            videos: r.videos,
            audios: r.audios,
            time: date,
            isGrouped: grouped,
            onLongPress: () => _showOwnMessageActions(r),
          ),
        ],
      );
    }

    final note = entry.suggestion.adminNote;
    return Column(
      children: [
        if (showDate) ConversationDateSeparator(date: date),
        _UserSuggestionBubble(
            suggestion: entry.suggestion, time: date, isGrouped: grouped),
        if (note != null && note.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: 6),
            child: _AdminBubble(text: note, time: date),
          ),
      ],
    );
  }

  /// Long-press on a message (user side): copy only. Edit/delete were
  /// removed for users — the admin panel keeps full edit/delete rights
  /// through the backend API.
  Future<void> _showOwnMessageActions(SuggestionReply r) async {
    HapticFeedback.lightImpact();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.copy_rounded, color: AppColors.textSecondary),
              title: Text(AppLocalizations.of(context).translate('actionCopy'),
                  style: TextStyle(fontFamily: 'Cairo')),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: r.body));
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(AppLocalizations.of(context).translate('copied'),
                      style: TextStyle(fontFamily: 'Cairo')),
                  duration: Duration(seconds: 1),
                  backgroundColor: AppColors.surfaceVariant,
                  behavior: SnackBarBehavior.floating,
                ));
              },
            ),
            SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

DateTime _entryDate(SuggestionChatEntry e) {
  final raw = e.reply?.createdAt ?? e.suggestion.createdAt;
  return DateTime.tryParse(raw ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
}

/// Which side of the chat an entry belongs to: admin (left in RTL) or the
/// user themselves (right in RTL). The ticket's opening suggestion is always
/// the user's side; replies follow their `isFromAdmin` flag (user messages
/// sent from the app have adminId null → false).
bool _entryIsAdmin(SuggestionChatEntry e) =>
    e.reply != null && e.reply!.isFromAdmin;

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

// ═══════════════════════════════════════════════════════════════
//  EMPTY STATE
// ═══════════════════════════════════════════════════════════════

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Color(0xFFA01530), Color(0xFF6B0F20)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withAlpha(60),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: HugeIcon(
                icon: HugeIcons.strokeRoundedChatSpark,
                color: Colors.white,
                size: 40,
                strokeWidth: 1.8,
              ),
            ),
            SizedBox(height: 20),
            Text(AppLocalizations.of(context).translate('suggestionsYouHavenTSent'),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            SizedBox(height: 8),
            Text(AppLocalizations.of(context).translate('suggestionsWriteYourSuggestionBelow'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    color: AppColors.textDisabled,
                    height: 1.6)),
            SizedBox(height: 18),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.divider),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.attach_file,
                      color: AppColors.textPlaceholder, size: 14),
                  SizedBox(width: 6),
                  Text(AppLocalizations.of(context).translate('suggestionsImagesVideoAndAudio'),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 11,
                          color: AppColors.textPlaceholder)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  USER SUGGESTION BUBBLE — Right-aligned, Red
// ═══════════════════════════════════════════════════════════════

class _UserSuggestionBubble extends StatelessWidget {
  final Suggestion suggestion;
  final DateTime time;
  final bool isGrouped;
  const _UserSuggestionBubble(
      {required this.suggestion, required this.time, this.isGrouped = false});

  String get _text {
    if (suggestion.title.isNotEmpty && suggestion.title != suggestion.body) {
      return '${suggestion.title}\n\n${suggestion.body}';
    }
    return suggestion.body;
  }

  @override
  Widget build(BuildContext context) {
    final hasMedia = suggestion.images.isNotEmpty ||
        suggestion.videos.isNotEmpty ||
        suggestion.audios.isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(top: isGrouped ? 1 : 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const _UserAvatar(size: 28),
              SizedBox(width: 8),
              Flexible(
                child: GestureDetector(
                  onLongPress: () {
                    HapticFeedback.lightImpact();
                    Clipboard.setData(ClipboardData(text: _text));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(AppLocalizations.of(context).translate('copied'), style: TextStyle(fontFamily: 'Cairo')),
                      duration: Duration(seconds: 1),
                      backgroundColor: AppColors.surfaceVariant,
                      behavior: SnackBarBehavior.floating,
                    ));
                  },
                  child: Container(
                    constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.7),
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Color(0xFFA01530),
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(18),
                        topRight: isGrouped
                            ? Radius.circular(6)
                            : Radius.circular(18),
                        bottomLeft: Radius.circular(18),
                        bottomRight: Radius.circular(6),
                      ),
                    ),
                    child: Text(_text,
                        style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 14,
                            color: Colors.white,
                            height: 1.5)),
                  ),
                ),
              ),
            ],
          ),
          if (hasMedia)
            Padding(
              padding: EdgeInsets.only(top: 6),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: _MessageMedia(
                  images: suggestion.images,
                  videos: suggestion.videos,
                  audios: suggestion.audios,
                ),
              ),
            ),
          Padding(
            padding: EdgeInsetsDirectional.only(top: 3, start: 36),
            child: Text(clockTime(time.toIso8601String()),
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 10,
                    color: AppColors.textPlaceholder)),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  MEDIA INSIDE USER BUBBLE
// ═══════════════════════════════════════════════════════════════

class _MessageMedia extends StatelessWidget {
  final List<String> images;
  final List<String> videos;
  final List<String> audios;
  const _MessageMedia({
    this.images = const [],
    this.videos = const [],
    this.audios = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (images.isNotEmpty) ...[
          for (final img in images) ...[
            Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: _SuggestionImageThumb(filename: img),
            ),
          ],
          SizedBox(height: 2),
        ],
        if (videos.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final v in videos) SuggestionVideoTile(filename: v),
            ],
          ),
          SizedBox(height: 8),
        ],
        if (audios.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in audios) SuggestionAudioTile(filename: a),
            ],
          ),
      ],
    );
  }
}

class _SuggestionImageThumb extends ConsumerWidget {
  final String filename;
  const _SuggestionImageThumb({required this.filename});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = ref.watch(suggestionImageProvider(filename));
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: image.when(
        loading: () => Container(
          width: 72,
          height: 72,
          color: AppColors.surfaceVariant,
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.primary),
            ),
          ),
        ),
        error: (_, _) => Container(
          width: 72,
          height: 72,
          color: AppColors.surfaceVariant,
          child: Icon(Icons.broken_image_outlined,
              color: AppColors.textPlaceholder),
        ),
        data: (bytes) => GestureDetector(
          onTap: () => showSuggestionImageFullScreen(context, bytes),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.7,
            ),
            child: Image.memory(bytes),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  ADMIN BUBBLE — Left-aligned, Dark (text + media)
// ═══════════════════════════════════════════════════════════════

class _AdminBubble extends StatelessWidget {
  final SuggestionReply? reply;
  final String text;
  final List<String> images;
  final List<String> videos;
  final List<String> audios;
  final DateTime time;
  final bool isGrouped;
  final VoidCallback? onLongPress;
  const _AdminBubble({
    this.reply,
    required this.text,
    this.images = const [],
    this.videos = const [],
    this.audios = const [],
    required this.time,
    this.isGrouped = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final hasMedia =
        images.isNotEmpty || videos.isNotEmpty || audios.isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(top: isGrouped ? 1 : 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                GestureDetector(
                  onLongPress: onLongPress,
                  child: Container(
                    constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.65),
                    padding: EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceVariant,
                      borderRadius: BorderRadius.only(
                        topLeft: isGrouped
                            ? Radius.circular(6)
                            : Radius.circular(18),
                        topRight: Radius.circular(18),
                        bottomLeft: Radius.circular(6),
                        bottomRight: Radius.circular(18),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (text.isNotEmpty)
                          Text(text,
                              style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 14,
                                  color: AppColors.textPrimary,
                                  height: 1.5)),
                        if (hasMedia) ...[
                          if (text.isNotEmpty) SizedBox(height: 8),
                          _MessageMedia(
                            images: images,
                            videos: videos,
                            audios: audios,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsetsDirectional.only(top: 3, end: 4),
                  child: Text(clockTime(time.toIso8601String()),
                      style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 10,
                          color: AppColors.textPlaceholder)),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsetsDirectional.only(end: 8),
            child: _PlatformAvatar(size: 30),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  USER MESSAGE BUBBLE — user side (right in RTL), red border
// ═══════════════════════════════════════════════════════════════

class _UserMessageBubble extends StatelessWidget {
  final SuggestionReply reply;
  final DateTime time;
  final bool isGrouped;
  final VoidCallback? onLongPress;
  const _UserMessageBubble({
    required this.reply,
    required this.time,
    this.isGrouped = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final hasMedia = reply.images.isNotEmpty ||
        reply.videos.isNotEmpty ||
        reply.audios.isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(top: isGrouped ? 1 : 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const _UserAvatar(size: 28),
          SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onLongPress: onLongPress,
                  child: Container(
                    constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.7),
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(18),
                        topRight: isGrouped
                            ? Radius.circular(6)
                            : Radius.circular(18),
                        bottomLeft: Radius.circular(18),
                        bottomRight: Radius.circular(6),
                      ),
                      border: Border.all(
                          color: AppColors.primary, width: 1),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (reply.body.isNotEmpty)
                          Text(reply.body,
                              style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 14,
                                  color: AppColors.textPrimary,
                                  height: 1.5)),
                        if (hasMedia) ...[
                          if (reply.body.isNotEmpty) SizedBox(height: 8),
                          _MessageMedia(
                            images: reply.images,
                            videos: reply.videos,
                            audios: reply.audios,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsetsDirectional.only(top: 3, start: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(clockTime(time.toIso8601String()),
                          style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 10,
                              color: AppColors.textPlaceholder)),
                      if (reply.isEdited) ...[
                        SizedBox(width: 4),
                        Text(
                            AppLocalizations.of(context)
                                .translate('suggestionsEditedLabel'),
                            style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 10,
                                fontStyle: FontStyle.italic,
                                color: AppColors.textPlaceholder)),
                      ],
                    ],
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
//  AVATARS
// ═══════════════════════════════════════════════════════════════

class _PlatformAvatar extends StatelessWidget {
  final double size;
  const _PlatformAvatar({this.size = 38});

  @override
  Widget build(BuildContext context) {
    // Company logo: white logo on dark theme, black logo on light theme.
    final logoAsset =
        Theme.of(context).brightness == Brightness.dark
            ? 'assets/images/fyona_logo_light.png'
            : 'assets/images/fyona_logo_dark.png';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
              color: AppColors.primary.withAlpha(80),
              blurRadius: 6,
              offset: Offset(0, 2)),
        ],
      ),
      child: ClipOval(
        child: Image.asset(
          logoAsset,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Image.asset(
            'assets/images/fyona_logo_light.png',
            width: size,
            height: size,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }
}

class _UserAvatar extends StatelessWidget {
  final double size;
  const _UserAvatar({this.size = 28});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
          shape: BoxShape.circle, color: AppColors.surfaceVariant),
      // User slots show only the user photo (or a person icon) — never
      // the company logo.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: Icon(Icons.person,
            color: AppColors.textDisabled, size: size * 0.6),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  REMOVE BADGE (attachments preview)
// ═══════════════════════════════════════════════════════════════

class _RemoveBadge extends StatelessWidget {
  const _RemoveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(2),
      decoration: BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
      child: Icon(Icons.close, size: 14, color: Colors.white),
    );
  }
}