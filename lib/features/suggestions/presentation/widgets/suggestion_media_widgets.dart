import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../di/suggestions_providers.dart';
import '../../../../core/localization/app_localizations.dart';

/// A tappable video tile that downloads the bytes and plays them full-screen.
class SuggestionVideoTile extends ConsumerWidget {
  final String filename;
  const SuggestionVideoTile({super.key, required this.filename});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref
        .watch(suggestionFileProvider((kind: 'video', filename: filename)));
    return InkWell(
      onTap: () {
        final bytes = data.valueOrNull;
        if (bytes != null) _openVideoDialog(context, bytes, filename);
      },
      borderRadius: AppRadius.smBorder,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: AppRadius.smBorder,
          border: Border.all(color: AppColors.border),
        ),
        child: data.when(
          loading: () => const Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.primary),
            ),
          ),
          error: (_, _) =>  Icon(Icons.videocam_off_outlined,
              color: AppColors.textSecondary),
          data: (_) =>
              const Icon(Icons.play_circle_fill, size: 34, color: AppColors.primary),
        ),
      ),
    );
  }

  Future<void> _openVideoDialog(
      BuildContext context, Uint8List bytes, String filename) async {
    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/sugg_video_${DateTime.now().millisecondsSinceEpoch}_$filename');
    await file.writeAsBytes(bytes);
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => _VideoViewer(file: file)),
    );
  }
}

class _VideoViewer extends StatefulWidget {
  final File file;
  const _VideoViewer({required this.file});

  @override
  State<_VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<_VideoViewer> {
  late final VideoPlayerController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(widget.file);
    _controller.initialize().then((_) {
      if (!mounted) return;
      setState(() => _initialized = true);
      _controller.play();
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _controller.dispose();
    widget.file.delete().catchError((_) => widget.file);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: _initialized
            ? AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: VideoPlayer(_controller),
              )
            : const CircularProgressIndicator(color: Colors.white),
      ),
    );
  }
}

/// A playable audio tile that downloads the bytes and plays them inline.
class SuggestionAudioTile extends ConsumerStatefulWidget {
  final String filename;
  const SuggestionAudioTile({super.key, required this.filename});

  @override
  ConsumerState<SuggestionAudioTile> createState() =>
      _SuggestionAudioTileState();
}

class _SuggestionAudioTileState extends ConsumerState<SuggestionAudioTile> {
  final AudioPlayer _player = AudioPlayer();
  bool _playing = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle(Uint8List bytes) async {
    if (_playing) {
      await _player.stop();
      if (mounted) setState(() => _playing = false);
      return;
    }
    setState(() => _playing = true);
    try {
      await _player.play(BytesSource(bytes));
      _player.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => _playing = false);
      });
    } catch (_) {
      if (mounted) setState(() => _playing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref
        .watch(suggestionFileProvider((kind: 'audio', filename: widget.filename)));
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.primary.withAlpha(12),
        borderRadius: AppRadius.smBorder,
        border: Border.all(color: AppColors.primary.withAlpha(40)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            onPressed: data.valueOrNull == null
                ? null
                : () => _toggle(data.valueOrNull!),
            icon: Icon(
              _playing
                  ? Icons.stop_circle_outlined
                  : Icons.play_circle_fill,
              color: AppColors.primary,
              size: 30,
            ),
          ),
          Text(
            AppLocalizations.of(context).translate('suggestionsAudioRecording'),
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
