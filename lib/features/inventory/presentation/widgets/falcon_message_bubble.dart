import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../providers/falcon_reply_controller.dart';
import 'falcon_ambient.dart';

/// A single keyed stateful bubble persists through handoff/stream/dock/end.
/// Its RenderParagraph and our TextPainter share ALL layout parameters.
class FalconMessageBubble extends StatefulWidget {
  final FalconResponseMessage message;
  final VoidCallback onGeometry;
  final ValueChanged<String> onCopy;
  const FalconMessageBubble({super.key, required this.message,
    required this.onGeometry, required this.onCopy});
  @override
  State<FalconMessageBubble> createState() => FalconMessageBubbleState();
}

class FalconMessageBubbleState extends State<FalconMessageBubble> {
  final messageTextKey = GlobalKey();
  final finalAvatarAnchorKey = GlobalKey();
  TextStyle? _style;
  TextScaler _scaler = TextScaler.noScaling;
  TextDirection _direction = TextDirection.rtl;
  Locale? _locale;

  Rect? avatarRect() {
    final box = finalAvatarAnchorKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Rect? caretRect() {
    final box = messageTextKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize || _style == null) return null;
    final painter = TextPainter(
      text: TextSpan(text: widget.message.displayedText, style: _style),
      textAlign: _direction == TextDirection.rtl ? TextAlign.right : TextAlign.left,
      textDirection: _direction, textScaler: _scaler, locale: _locale,
      textWidthBasis: TextWidthBasis.parent,
    )..layout(minWidth: box.size.width, maxWidth: box.size.width);
    final caret = painter.getOffsetForCaret(
        TextPosition(offset: widget.message.displayedText.length), Rect.zero);
    final height = painter.preferredLineHeight;
    painter.dispose();
    final origin = box.localToGlobal(caret);
    // A writing cursor sits ahead of the real caret, never over the letters.
    return Rect.fromLTWH(origin.dx + (_direction == TextDirection.rtl ? -28 : 2),
        origin.dy + (height - 26) / 2, 26, 26);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.message,
    builder: (context, _) {
      _style = DefaultTextStyle.of(context).style.copyWith(
          fontFamily: 'Cairo', fontSize: 14, fontWeight: FontWeight.w400,
          height: 1.7, color: AppColors.textPrimary);
      _scaler = MediaQuery.textScalerOf(context);
      _direction = Directionality.of(context);
      _locale = Localizations.maybeLocaleOf(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onGeometry();
      });
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          SizedBox(key: finalAvatarAnchorKey, width: 26, height: 26,
            child: widget.message.phase == FalconReplyPhase.completed
                ? const FalconMark(26) : null),
          const SizedBox(width: 8),
          Expanded(child: GestureDetector(
            onTap: () => widget.onCopy(widget.message.displayedText),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(color: AppColors.primary.withAlpha(65)),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                // Writing-cursor gutter on both sides protects the last word.
                padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 18),
                child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 28),
                  child: SizedBox(width: double.infinity,
                    child: FalconStreamingText(textKey: messageTextKey,
                      text: widget.message.displayedText, style: _style!,
                      direction: _direction, scaler: _scaler, locale: _locale)),
                ),
              ),
            ),
          )),
        ]),
      );
    },
  );
}

/// No internal buffer or animation copy. This renders only displayedText.
/// Raw Markdown delimiters/newlines are preserved byte-for-byte; nothing
/// strips list markers or replaces partial content with the buffered answer.
class FalconStreamingText extends StatelessWidget {
  final GlobalKey textKey;
  final String text;
  final TextStyle style;
  final TextDirection direction;
  final TextScaler scaler;
  final Locale? locale;
  const FalconStreamingText({super.key, required this.textKey, required this.text,
    required this.style, required this.direction, required this.scaler, this.locale});
  @override
  Widget build(BuildContext context) => Text(text, key: textKey, style: style,
    textDirection: direction, textScaler: scaler, locale: locale,
    textAlign: direction == TextDirection.rtl ? TextAlign.right : TextAlign.left,
    textWidthBasis: TextWidthBasis.parent, softWrap: true);
}
