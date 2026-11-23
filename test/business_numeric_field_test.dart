import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/presentation/widgets/business_number_field.dart';

void main() {
  Future<void> pumpField(WidgetTester tester, TextEditingController c,
      {bool arabic = true, ValueChanged<String>? onChanged}) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Directionality(
      textDirection: arabic ? TextDirection.rtl : TextDirection.ltr,
      child: BusinessNumberField(controller: c, onChanged: onChanged),
    ))));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
  }

  testWidgets('Arabic end caret is visually left and IME Backspace deletes every digit',
      (tester) async {
    final c = TextEditingController(text: '123.45');
    final changed = <String>[];
    await pumpField(tester, c, onChanged: changed.add);
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    final display = state.widget.controller;
    display.selection = TextSelection.collapsed(offset: display.text.length);
    final start = state.renderEditable.getLocalRectForCaret(const TextPosition(offset: 0));
    final end = state.renderEditable.getLocalRectForCaret(TextPosition(offset: display.text.length));
    expect(end.left, lessThan(start.left));
    // Digit order remains LTR within the number, never reversed to satisfy RTL.
    final nextDigit = state.renderEditable.getLocalRectForCaret(const TextPosition(offset: 1));
    expect(nextDigit.left, greaterThan(start.left));
    await tester.tapAt(state.renderEditable.localToGlobal(
        Offset(end.left - 1, end.center.dy)));
    await tester.pump();
    expect(display.selection.extentOffset, display.text.length);
    for (final expected in ['123.4', '123.', '123', '12', '1', '']) {
      final before = display.text;
      tester.testTextInput.updateEditingValue(TextEditingValue(
        text: before.substring(0, before.length - 1),
        selection: TextSelection.collapsed(offset: before.length - 1),
      ));
      await tester.pump();
      expect(c.text, expected);
      expect(c.text.contains('\u200f'), isFalse);
      expect(c.selection.extentOffset, expected.length);
    }
    expect(changed, ['123.4', '123.', '123', '12', '1', '']);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('English typing and deletion keep ordinary LTR selection', (tester) async {
    final c = TextEditingController(text: '123.45');
    await pumpField(tester, c, arabic: false);
    final display = tester.widget<EditableText>(find.byType(EditableText)).controller;
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '123.4', selection: TextSelection.collapsed(offset: 5)));
    await tester.pump();
    expect(c.text, '123.4');
    expect(display.text, '123.4');
    expect(c.selection.extentOffset, 5);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('hardware Backspace from the visual left deletes instead of stalling',
      (tester) async {
    final c = TextEditingController(text: '125');
    await pumpField(tester, c);
    final display = tester.widget<EditableText>(find.byType(EditableText)).controller;
    display.selection = TextSelection.collapsed(offset: display.text.length);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(c.text, '12');
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('Arabic middle and selected-range edits do not jump to the end', (tester) async {
    final c = TextEditingController(text: '12345');
    await pumpField(tester, c);
    final display = tester.widget<EditableText>(find.byType(EditableText)).controller;
    display.selection = const TextSelection.collapsed(offset: 2);
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '1345\u200f', selection: TextSelection.collapsed(offset: 1)));
    await tester.pump();
    expect(c.text, '1345');
    expect(display.selection.extentOffset, 1);
    display.selection = const TextSelection(baseOffset: 1, extentOffset: 3);
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '195\u200f', selection: TextSelection.collapsed(offset: 2)));
    await tester.pump();
    expect(c.text, '195');
    expect(display.selection.extentOffset, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('Arabic digit paste is normalized and never persists direction markers', (tester) async {
    final c = TextEditingController();
    await pumpField(tester, c);
    await tester.enterText(find.byType(TextField), '١٢٣٫٤٥');
    await tester.pump();
    expect(c.text, '123.45');
    expect(double.parse(c.text), 123.45);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('invoice model rebuild preserves trailing decimal and cursor', (tester) async {
    double model = 12;
    final controllers = <TextEditingController>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Directionality(
      textDirection: TextDirection.rtl,
      child: StatefulBuilder(builder: (context, update) {
        final c = TextEditingController(text: '$model');
        controllers.add(c);
        return BusinessNumberField(controller: c,
          onChanged: (value) => update(() => model = double.tryParse(value) ?? model));
      }),
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '12.');
    await tester.pump();
    final display = tester.widget<EditableText>(find.byType(EditableText)).controller;
    expect(display.text, '12.\u200f');
    expect(controllers.last.text, '12.');
    await tester.enterText(find.byType(TextField), '12.5');
    await tester.pump();
    expect(model, 12.5);
    expect(controllers.last.text, '12.5');
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(controllers.last.text, '');
    expect(display.text, '');
    await tester.pumpWidget(const SizedBox.shrink());
    for (final c in controllers) { c.dispose(); }
  });

  test('active IME composing ranges are not rewritten', () {
    final formatter = BusinessNumberFormatter(arabic: true);
    const composing = TextEditingValue(text: '12',
        selection: TextSelection.collapsed(offset: 2), composing: TextRange(start: 0, end: 2));
    expect(formatter.formatEditUpdate(TextEditingValue.empty, composing), composing);
  });

  testWidgets('form validation and saving receive clean values with existing formatters',
      (tester) async {
    final key = GlobalKey<FormState>();
    String? validated, saved;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Directionality(
      textDirection: TextDirection.rtl,
      child: Form(key: key, child: BusinessNumberField(
        formField: true,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        validator: (value) { validated = value; return null; },
        onSaved: (value) => saved = value,
      )),
    ))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '١٢٣');
    await tester.pump();
    expect(key.currentState!.validate(), isTrue);
    key.currentState!.save();
    expect(validated, '123');
    expect(saved, '123');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
