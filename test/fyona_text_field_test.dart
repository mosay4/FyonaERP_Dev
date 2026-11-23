import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/shared/widgets/fyona_text_field.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child,
      {TextDirection direction = TextDirection.rtl}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Directionality(textDirection: direction, child: child),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('Arabic field: caret is visually left, Backspace deletes text',
      (tester) async {
    final c = TextEditingController(text: 'مرحبا');
    await pump(tester, FyonaTextField(controller: c));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    final display = state.widget.controller;
    display.selection = TextSelection.collapsed(offset: display.text.length);
    final start = state.renderEditable
        .getLocalRectForCaret(const TextPosition(offset: 0));
    final end = state.renderEditable.getLocalRectForCaret(
        TextPosition(offset: display.text.length));
    expect(end.left, lessThan(start.left));
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(c.text, 'مرحب');
    expect(c.text.contains('\u200f'), isFalse);
    expect(display.text, 'مرحب');
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('Latin text in Arabic field deletes from the visual left',
      (tester) async {
    final c = TextEditingController(text: 'abc');
    await pump(tester, FyonaTextField(controller: c));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    final display =
        tester.widget<EditableText>(find.byType(EditableText)).controller;
    display.selection = TextSelection.collapsed(offset: display.text.length);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(c.text, 'ab');
    expect(display.text, 'ab');
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('tapping the visual left of a number moves the caret there',
      (tester) async {
    final c = TextEditingController(text: '125');
    await pump(tester, FyonaTextField(controller: c));
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    final display = state.widget.controller;
    final end = state.renderEditable
        .getLocalRectForCaret(TextPosition(offset: display.text.length));
    await tester.tapAt(
        state.renderEditable.localToGlobal(Offset(end.left + 1, end.center.dy)));
    await tester.pump();
    expect(display.selection.extentOffset, display.text.length);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(c.text, '12');
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('TextFormField validation and save receive clean text',
      (tester) async {
    final key = GlobalKey<FormState>();
    String? validated;
    String? saved;
    await pump(
      tester,
      Form(
        key: key,
        child: FyonaTextFormField(
          validator: (v) {
            validated = v;
            return null;
          },
          onSaved: (v) => saved = v,
        ),
      ),
    );
    await tester.enterText(find.byType(TextFormField), 'علي 12');
    await tester.pump();
    expect(key.currentState!.validate(), isTrue);
    key.currentState!.save();
    expect(validated, 'علي 12');
    expect(saved, 'علي 12');
    expect(validated!.contains('\u200f'), isFalse);
  });

  testWidgets('English direction keeps ordinary LTR editing', (tester) async {
    final c = TextEditingController(text: 'abc');
    await pump(tester, FyonaTextField(controller: c),
        direction: TextDirection.ltr);
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    final display = state.widget.controller;
    expect(display.text, 'abc');
    final start = state.renderEditable
        .getLocalRectForCaret(const TextPosition(offset: 0));
    final end = state.renderEditable
        .getLocalRectForCaret(TextPosition(offset: display.text.length));
    expect(end.left, greaterThan(start.left));
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}
