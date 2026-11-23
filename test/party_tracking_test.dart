import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/core_business/presentation/widgets/party_tracking.dart';
import 'package:fyona_flutter/features/personal/data/merchant_api.dart';

class _FakeMerchant extends MerchantApi {
  _FakeMerchant() : super(ApiClient(dio: Dio()));
  final lookups = <Map<String, String?>>[];
  @override
  Future<Map<String, dynamic>> lookup({
    String? phone,
    String? code,
    String? country,
  }) async {
    lookups.add({'phone': phone, 'code': code, 'country': country});
    return {'found': false};
  }
}

void main() {
  testWidgets('code and phone modes keep not-found errors inline', (
    tester,
  ) async {
    final api = _FakeMerchant();
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [merchantApiProvider.overrideWithValue(api)],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: Consumer(
              builder: (ctx, ref, _) {
                return Center(
                  child: ElevatedButton(
                    onPressed: () => showPartyTrackingDialog(
                      ctx,
                      ref,
                      partyKind: 'customer',
                      partyId: 'C1',
                    ),
                    child: const Text('open'),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final code = find.byKey(const ValueKey('tracking-code-input'));
    final phone = find.byKey(const ValueKey('tracking-phone-input'));
    final country = find.byKey(const ValueKey('tracking-country'));
    expect(find.byKey(const ValueKey('tracking-mode-code')), findsOneWidget);
    expect(find.byKey(const ValueKey('tracking-mode-phone')), findsOneWidget);
    expect(
      tester
          .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
          .selected,
      {false},
    );
    expect(tester.widget<TextField>(code).maxLength, 6);
    expect(phone, findsNothing);
    expect(country, findsNothing);

    await tester.enterText(code, '123');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(api.lookups, isEmpty);
    expect(find.text('الرقم المميز لازم يكون ستة أرقام فقط'), findsOneWidget);

    await tester.enterText(code, '000000');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(api.lookups.single, {
      'phone': '',
      'code': '000000',
      'country': null,
    });
    expect(
      find.text('لم نعثر على حساب بهذا الرقم المميز، تأكد من صحة الرقم.'),
      findsOneWidget,
    );
    expect(code, findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('هذا هو الحساب اللي تقصده؟'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tracking-mode-phone')));
    await tester.pumpAndSettle();
    expect(code, findsNothing);
    expect(phone, findsOneWidget);
    expect(country, findsOneWidget);
    expect(tester.widget<TextField>(phone).controller!.text, isEmpty);
    expect(
      find.text('لم نعثر على حساب بهذا الرقم المميز، تأكد من صحة الرقم.'),
      findsNothing,
    );
    await tester.enterText(phone, '123');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(api.lookups, hasLength(1));
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text('اكتب رقم الهاتف بدون رمز الدولة'),
      ),
      findsOneWidget,
    );
    expect(find.byType(SnackBar), findsNothing);
    expect(phone, findsOneWidget);
    expect(country, findsOneWidget);
    expect(tester.getSize(phone).width, greaterThan(100));
    expect(tester.getSize(phone).height, greaterThan(40));
    expect(tester.getTopLeft(country).dx, lessThan(tester.getTopLeft(phone).dx));

    await tester.enterText(phone, '777123456');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(api.lookups.last, {
      'phone': '777123456',
      'code': '',
      'country': 'YE',
    });
    expect(
      find.text('ما لقينا حساب بهذا الرقم تأكد من الرقم والدولة.'),
      findsOneWidget,
    );
    expect(phone, findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tracking-mode-code')));
    await tester.pumpAndSettle();
    expect(code, findsOneWidget);
    expect(country, findsNothing);
    expect(tester.widget<TextField>(code).controller!.text, isEmpty);
  });
}
