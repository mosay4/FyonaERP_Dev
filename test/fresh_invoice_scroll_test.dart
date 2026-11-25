import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/shared/widgets/fresh_invoice_scroll.dart';

/// Mirrors the sale / purchase invoice page: customer section on top, a long
/// form, the paid-amount field at the BOTTOM, issue → success dialog →
/// «بيع جديد» resets the form and must return to the top.
class _InvoicePage extends StatefulWidget {
  const _InvoicePage({required this.guarded});
  final bool guarded;
  @override
  State<_InvoicePage> createState() => _InvoicePageState();
}

class _InvoicePageState extends State<_InvoicePage> {
  final scroll = ScrollController();
  final paid = TextEditingController();
  int items = 30;

  @override
  void dispose() {
    scroll.dispose();
    paid.dispose();
    super.dispose();
  }

  Widget _dialog(BuildContext ctx) => AlertDialog(
        content: FilledButton(
          onPressed: () {
            setState(() => items = 30); // draft reset
            paid.clear();
            Navigator.pop(ctx, 'new');
          },
          child: const Text('بيع جديد'),
        ),
      );

  Future<void> issue() async {
    final String? next;
    if (widget.guarded) {
      next = await showIssueResultDialog<String>(
          context: context, builder: _dialog);
    } else {
      // Round-14 behaviour.
      next = await showDialog<String>(
          context: context, barrierDismissible: false, builder: _dialog);
    }
    if (next != 'new' || !mounted) return;
    if (widget.guarded) {
      glideFreshInvoiceToTop(scroll, isMounted: () => mounted);
    } else if (scroll.hasClients && scroll.offset > 0) {
      scroll.animateTo(0,
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          Expanded(
            child: ListView(controller: scroll, children: [
              const SizedBox(height: 60, child: Text('customer')),
              for (var i = 0; i < items; i++)
                SizedBox(height: 50, child: Text('row $i')),
              TextField(key: const ValueKey('paid'), controller: paid),
            ]),
          ),
          TextButton(onPressed: issue, child: const Text('issue')),
        ]),
      );
}

Future<ScrollController> _runFlow(WidgetTester tester, {required bool guarded}) async {
  await tester.pumpWidget(MaterialApp(home: _InvoicePage(guarded: guarded)));
  final state = tester.state<_InvoicePageState>(find.byType(_InvoicePage));
  state.scroll.jumpTo(state.scroll.position.maxScrollExtent);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('paid')));
  await tester.enterText(find.byKey(const ValueKey('paid')), '100');
  await tester.pumpAndSettle();
  expect(state.scroll.offset, greaterThan(0));
  await tester.tap(find.text('issue'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('بيع جديد'));
  await tester.pumpAndSettle();
  return state.scroll;
}

void main() {
  testWidgets('without the guard the restored bottom field drags it back down',
      (tester) async {
    final scroll = await _runFlow(tester, guarded: false);
    expect(scroll.offset, greaterThan(0),
        reason: 'reproduces the bug: fresh invoice left at the end');
  });

  testWidgets('«بيع جديد» returns the fresh invoice smoothly to the TOP',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _InvoicePage(guarded: true)));
    final state = tester.state<_InvoicePageState>(find.byType(_InvoicePage));
    state.scroll.jumpTo(state.scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('paid')));
    await tester.enterText(find.byKey(const ValueKey('paid')), '100');
    await tester.pumpAndSettle();
    final bottom = state.scroll.offset;
    expect(bottom, greaterThan(0));
    await tester.tap(find.text('issue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('بيع جديد'));
    // Smooth: mid-way it is between the end and the top (not a jump).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(state.scroll.offset, lessThan(bottom));
    await tester.pumpAndSettle();
    expect(state.scroll.offset, 0);
    expect(find.text('customer'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.context?.widget,
        isNot(isA<EditableText>()));
  });
}
