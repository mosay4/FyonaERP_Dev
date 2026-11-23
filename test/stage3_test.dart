import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/section_scope.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/personal/data/merchant_api.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/merchant_debt_pages.dart';
import 'package:fyona_flutter/features/personal/presentation/widgets/chat_video_surface.dart';
import 'package:fyona_flutter/shared/widgets/invoice_amount.dart';
import 'package:fyona_flutter/shared/widgets/secure_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

class FakeBranches extends BranchApi {
  FakeBranches() : super(ApiClient(dio: Dio()));
  List<Map<String, dynamic>> rows = [
    {'organization_id': 'org', 'role': 'member', 'avatar': '/uploads/logo?v=1',
      'permissions': {'customers': true}},
  ];
  @override
  Future<List<Map<String, dynamic>>> access() async => rows;
}

class HugeDebtApi extends MerchantApi {
  HugeDebtApi() : super(ApiClient(dio: Dio()));
  @override
  Future<Map<String, dynamic>> businessOperationDetail({required String partyKind,
      required String partyId, required String invoiceId}) async => {
    'number': 'INV-HUGE', 'total': 999999999999.99,
    'paid': 999999999999.99, 'remaining': 999999999999.99, 'currency': 'SAR',
    'items': [{'name': 'منتج', 'qty': 999999999999.99,
      'price': 999999999999.99, 'total': 999999999999.99}],
  };
}

class FakeVideoController extends VideoPlayerController {
  FakeVideoController() : super.networkUrl(Uri.parse('https://example.invalid/video'), httpHeaders: {});
  Map<String, String>? initializedHeaders;
  @override
  Future<void> initialize() async { initializedHeaders = {...httpHeaders}; }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final section in ['personal', 'business']) {
    test('$section survives restart; history is account scoped and access gated', () async {
      await SectionHistory.save('owner', section);
      final stored = (await SharedPreferences.getInstance()).getKeys();
      expect(stored, contains('last_section_owner'));
      SharedPreferences.resetStatic();
      expect(await SectionHistory.restore('owner', business: true, personal: true), section);
      expect(await SectionHistory.restore('other', business: true, personal: true), 'business');
      expect(await SectionHistory.restore('owner', business: false, personal: true), 'personal');
      expect(await SectionHistory.restore('owner', business: true, personal: false), 'business');
    });
  }
  test('buffer percentage tracks playhead ranges, seek, pause, complete and error', () {
    final value = VideoPlayerValue(duration: const Duration(seconds: 100),
      isInitialized: true, isPlaying: true, isBuffering: true,
      position: const Duration(seconds: 20), buffered: [
        DurationRange(Duration.zero, const Duration(seconds: 60)),
        DurationRange(const Duration(seconds: 80), const Duration(seconds: 90)),
      ]);
    expect(videoBufferedFraction(value), .5);
    expect(showVideoBufferOverlay(value), isTrue);
    expect(videoBufferedFraction(value.copyWith(position: const Duration(seconds: 70))), 0);
    expect(showVideoBufferOverlay(value.copyWith(isPlaying: false)), isFalse);
    expect(showVideoBufferOverlay(value.copyWith(isCompleted: true)), isFalse);
    expect(showVideoBufferOverlay(value.copyWith(errorDescription: 'error')), isFalse);
    expect(showVideoBufferOverlay(value.copyWith(buffered: [
      DurationRange(Duration.zero, const Duration(seconds: 100))])), isFalse);
    expect(videoBufferedFraction(const VideoPlayerValue.uninitialized()), 0);
  });
  test('native video receives interceptor-equivalent auth before initialization', () async {
    final token = Completer<String?>();
    final controller = FakeVideoController();
    final pending = initializeChatVideoController(controller,
      accessToken: token.future, isActive: () => true);
    expect(controller.initializedHeaders, isNull);
    token.complete('test-access');
    await pending;
    expect(controller.initializedHeaders, {'Authorization': 'Bearer test-access'});
    final disposed = FakeVideoController();
    await initializeChatVideoController(disposed,
      accessToken: Future.value('test-access'), isActive: () => false);
    expect(disposed.initializedHeaders, isNull);
  });
  testWidgets('huge RTL amount is centered in its allocated box and scales down', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Directionality(
      textDirection: TextDirection.rtl,
      child: Center(child: SizedBox(width: 60, height: 30,
        child: InvoiceAmount('999,999,999,999.99'))))));
    final text = tester.widget<Text>(find.text('999,999,999,999.99'));
    expect(text.textDirection, TextDirection.ltr);
    expect(text.textAlign, TextAlign.center);
    final fit = tester.widget<FittedBox>(find.byType(FittedBox));
    expect(fit.fit, BoxFit.scaleDown);
    expect(fit.alignment, Alignment.center);
    expect(tester.takeException(), isNull);
  });
  testWidgets('actual debt invoice preview fits and centers every RTL amount', (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    tester.view.physicalSize = const Size(360, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(overrides: [
      merchantApiProvider.overrideWithValue(HugeDebtApi()),
    ], child: MaterialApp(locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: const DebtOperationDetailPage(linkId: 'L', invoiceId: 'I',
        name: 'عميل', partyId: 'P', partyKind: 'customer', isBusiness: true))));
    await tester.pumpAndSettle();
    expect(find.byType(InvoiceAmount), findsNWidgets(3));
    for (final amount in tester.widgetList<InvoiceAmount>(find.byType(InvoiceAmount))) {
      expect(amount.alignment, Alignment.center);
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets('video surface appears before initialize and retry remains usable', (tester) async {
    final controller = VideoPlayerController.networkUrl(Uri.parse('https://example.invalid/a.mp4'));
    var retries = 0;
    await tester.pumpWidget(MaterialApp(home: Center(child: ChatVideoSurface(
      controller: controller, onRetry: () => retries++))));
    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    controller.value = VideoPlayerValue.erroneous('failed');
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tap(find.byType(FilledButton));
    expect(retries, 1);
    await tester.pumpWidget(const SizedBox());
    await controller.dispose();
  });
  test('image cache keys stay stable and server versions remain distinct', () {
    expect(secureImageCacheKey('/uploads/a?v=1'), secureImageCacheKey('/uploads/a?v=1'));
    expect(secureImageCacheKey('/uploads/a?v=1'), isNot(secureImageCacheKey('/uploads/a?v=2')));
    expect(workspaceDataEqual({'permissions': {'x': true}}, {'permissions': {'x': true}}), isTrue);
  });
  testWidgets('unchanged workspace poll causes no provider churn; edits refresh', (tester) async {
    final api = FakeBranches();
    late WidgetRef captured;
    var loads = 0;
    await tester.pumpWidget(ProviderScope(overrides: [
      branchApiProvider.overrideWithValue(api),
      branchAccessProvider.overrideWith((ref) async { loads++; return api.access(); }),
    ], child: Consumer(builder: (context, ref, child) {
      captured = ref;
      ref.watch(branchAccessProvider);
      return const SizedBox();
    })));
    await tester.pump();
    await captured.read(branchAccessProvider.future);
    expect(loads, 1);
    await refreshBranchAccessIfChanged(captured);
    await tester.pump();
    expect(loads, 1);
    api.rows = [{...api.rows.first, 'avatar': '/uploads/logo?v=2'}];
    await refreshBranchAccessIfChanged(captured);
    await captured.read(branchAccessProvider.future);
    await tester.pump();
    expect(loads, 2);
  });
}
