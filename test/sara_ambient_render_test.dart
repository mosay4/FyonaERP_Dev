import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/features/ai/presentation/widgets/sara_ambient_controller.dart';
import 'package:fyona_flutter/features/ai/presentation/widgets/sara_ambient_scene.dart';

const size = Size(390, 760);
const input = Rect.fromLTWH(66, 680, 240, 44);
const reply = Rect.fromLTWH(22, 330, 252, 124);
final _themes = <bool, ThemeData>{};

void step(SaraAmbientController c, int ms) {
  for (var i = 0; i < ms; i += 16) { c.advance(const Duration(milliseconds: 16)); }
}

SaraAmbientController scene(SaraAmbientPhase phase) {
  final c = SaraAmbientController();
  c.setGeometry(const SaraAmbientGeometry(input: input, reply: reply,
      avatar: Rect.fromLTWH(316, -60, 40, 40), user: Rect.fromLTWH(140, 210, 225, 60)));
  step(c, 320);
  switch (phase) {
    case SaraAmbientPhase.focus: c.focus(true); step(c, 320); break;
    case SaraAmbientPhase.typing:
      c.focus(true);
      for (var i = 1; i < 8; i++) { c.edit('س' * i); step(c, 30); }
      break;
    case SaraAmbientPhase.sending: c.send(); step(c, 180); break;
    case SaraAmbientPhase.waiting: c.send(); c.setActivity(SaraAmbientActivity.waiting); step(c, 500); break;
    case SaraAmbientPhase.thinking: c.send(); c.setActivity(SaraAmbientActivity.thinking); step(c, 1200); break;
    case SaraAmbientPhase.responding:
      c.send(); c.registerReply('reply'); c.replyStarted('reply'); c.setActivity(SaraAmbientActivity.responding);
      for (var i = 0; i < 6; i++) { c.word('reply'); step(c, 70); }
      break;
    case SaraAmbientPhase.completed:
      c.send(); c.registerReply('reply'); c.replyStarted('reply'); c.word('reply'); c.replyFinished('reply'); step(c, 180); break;
    case SaraAmbientPhase.executing: c.beginOperation(); step(c, 420); break;
    case SaraAmbientPhase.success: c.beginOperation(); c.finishOperation(confirmed: true); step(c, 180); break;
    case SaraAmbientPhase.error: c.send(); c.error(); step(c, 120); break;
    case SaraAmbientPhase.cancelling: c.send(); c.cancel(); step(c, 120); break;
    case SaraAmbientPhase.hidden: c.setVisible(false); break;
    case SaraAmbientPhase.idle: step(c, 300); break;
  }
  return c;
}

ui.Picture record(SaraAmbientController c, bool dark, {bool accents = true}) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final theme = _themes.putIfAbsent(dark, () => ThemeData(brightness: dark ? Brightness.dark : Brightness.light, colorSchemeSeed: AppColors.primary));
  canvas.drawRect(Offset.zero & size, Paint()..color = dark ? const Color(0xFF0D0D0D) : const Color(0xFFF4F6F8));
  SaraAmbientPainter(controller: c, primary: theme.colorScheme.primary, ink: theme.colorScheme.onSurface, dark: dark).paint(canvas, size);
  for (final rect in [reply, input]) {
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(22)),
        Paint()..color = dark ? const Color(0xFF1E1E1E) : Colors.white);
  }
  final text = TextPainter(text: TextSpan(text: 'حساب الكاش\nالرصيد: ١٬٥٠٠ ريال سعودي',
      style: TextStyle(fontFamily: 'Cairo', fontSize: 15, height: 1.8, color: dark ? Colors.white : Colors.black87)),
      textDirection: TextDirection.rtl)..layout(maxWidth: reply.width - 28);
  text.paint(canvas, Offset(reply.right - 14 - text.width, reply.top + 14));
  final note = TextPainter(text: TextSpan(text: 'اكتب رسالتك…', style: TextStyle(fontFamily: 'Cairo', fontSize: 13,
      color: dark ? Colors.white70 : Colors.black54)), textDirection: TextDirection.rtl)..layout(maxWidth: input.width - 28);
  note.paint(canvas, Offset(input.right - 14 - note.width, input.top + 10));
  if (accents) {
    SaraAmbientPainter(controller: c, primary: theme.colorScheme.primary,
        ink: theme.colorScheme.onSurface, dark: dark, accents: true).paint(canvas, size);
  }
  text.dispose(); note.dispose();
  return recorder.endRecording();
}

void main() {
  testWidgets('raster all phases and review themed smoke without covering message interiors', (tester) async {
    final font = FontLoader('Cairo')..addFont(rootBundle.load('assets/fonts/Cairo-400.ttf'));
    await font.load();
    await tester.runAsync(() async {
      for (final dark in [false, true]) {
        for (final phase in SaraAmbientPhase.values) {
          final c = scene(phase);
          final picture = record(c, dark);
          final image = await picture.toImage(size.width.toInt(), size.height.toInt());
          expect(image.width, 390);
          if (const {SaraAmbientPhase.idle, SaraAmbientPhase.typing, SaraAmbientPhase.thinking, SaraAmbientPhase.executing}.contains(phase)) {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await File('/home/abdulrhman2/fyona-build-logs/sara-ambient-${dark ? 'dark' : 'light'}-${phase.name}.png')
                .writeAsBytes(png!.buffer.asUint8List());
          }
          final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          final plainPicture = record(c, dark, accents: false);
          final plain = await plainPicture.toImage(390, 760);
          final plainRaw = await plain.toByteData(format: ui.ImageByteFormat.rawRgba);
          // Pixel-for-pixel: edge glows cannot tint text or the central input.
          for (final rect in [reply.deflate(25), input.deflate(16)]) {
            for (var y = rect.top.toInt(); y < rect.bottom.toInt(); y += 7) {
              for (var x = rect.left.toInt(); x < rect.right.toInt(); x += 7) {
                final offset = (y * 390 + x) * 4;
                expect(raw!.getUint32(offset), plainRaw!.getUint32(offset), reason: '$phase dark=$dark at $x,$y');
              }
            }
          }
          image.dispose(); plain.dispose(); picture.dispose(); plainPicture.dispose(); c.dispose();
        }
      }
    });
  });

  testWidgets('bounded CPU paint-recording benchmark (not an on-device FPS assertion)', (tester) async {
    final timings = <int>[];
    final c = scene(SaraAmbientPhase.thinking);
    for (var frame = 0; frame < 160; frame++) {
      c.advance(const Duration(microseconds: 16667));
      final watch = Stopwatch()..start();
      final picture = record(c, frame.isEven);
      watch.stop(); timings.add(watch.elapsedMicroseconds); picture.dispose();
    }
    timings.sort();
    final p95 = timings[(timings.length * .95).floor()] / 1000;
    final metrics = {'frames': timings.length, 'p95_cpu_record_ms': p95,
      'mean_cpu_record_ms': timings.reduce((a, b) => a + b) / timings.length / 1000,
      'scope': 'Headless Linux CPU paint recording only; no device/GPU FPS claim',
      'size': '390x760', 'ribbons': 3, 'max_samples_per_ribbon': 32};
    await tester.runAsync(() => File('/home/abdulrhman2/fyona-build-logs/sara-ambient-paint-metrics.json').writeAsString(jsonEncode(metrics)));
    expect(p95, lessThan(16.67));
    c.dispose();
  });
}
