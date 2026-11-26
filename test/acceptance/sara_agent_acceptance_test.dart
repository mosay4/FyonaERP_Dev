// Acceptance tests for the Sara AI Agent Flutter layer.
//
// Covers: action parsing, deep-navigation route resolution, app-awareness state
// serialization, and the TTS speak() request contract.

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fyona_flutter/core/network/api_endpoints.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/features/ai/domain/services/ai_service.dart';
import 'package:fyona_flutter/shared/widgets/sara_action_dispatcher.dart';

void main() {
  group('SaraAction parsing', () {
    test('maps every action string to its type', () {
      expect(SaraAction.fromJson({'action': 'open_screen'}).type, SaraActionType.openScreen);
      expect(SaraAction.fromJson({'action': 'go_back'}).type, SaraActionType.goBack);
      expect(SaraAction.fromJson({'action': 'create_entity'}).type, SaraActionType.createEntity);
      expect(SaraAction.fromJson({'action': 'export_pdf'}).type, SaraActionType.exportPdf);
      expect(SaraAction.fromJson({'action': 'refresh_data'}).type, SaraActionType.refreshData);
      expect(SaraAction.fromJson({'action': 'open_url'}).type, SaraActionType.openUrl);
      expect(SaraAction.fromJson({'action': 'open_entity'}).type, SaraActionType.openEntity);
    });

    test('parses open_entity params and label', () {
      final action = SaraAction.fromJson({
        'action': 'open_entity',
        'params': {'entity_type': 'bank', 'name': 'الراجحي'},
        'label': 'فتح الراجحي',
      });
      expect(action.type, SaraActionType.openEntity);
      expect(action.params['entity_type'], 'bank');
      expect(action.params['name'], 'الراجحي');
      expect(action.label, 'فتح الراجحي');
    });
  });

  group('AiAgentResponse.fromJson', () {
    test('parses text, actions, suggestions and confidence', () {
      final resp = AiAgentResponse.fromJson({
        'text': 'رصيدك 1000 ريال.',
        'confidence': 0.9,
        'suggestions': ['افتح البنوك', 'أنشئ هدف'],
        'actions': [
          {'action': 'open_entity', 'params': {'entity_type': 'bank', 'name': 'الراجحي'}},
          {'action': 'open_screen', 'params': {'screen': 'التقارير'}},
        ],
      });
      expect(resp.text, 'رصيدك 1000 ريال.');
      expect(resp.confidence, 0.9);
      expect(resp.suggestions, hasLength(2));
      expect(resp.actions, hasLength(2));
      expect(resp.actions.first.type, SaraActionType.openEntity);
    });

    test('falls back to "answer" key for legacy responses', () {
      final resp = AiAgentResponse.fromJson({
        'answer': 'الجواب القديم',
        'confidence': 0.5,
        'actions': [],
        'suggestions': [],
      });
      expect(resp.text, 'الجواب القديم');
    });
  });

  group('SaraAppState', () {
    test('serializes all app-awareness fields', () {
      const state = SaraAppState(
        subscriptionPlan: 'Pro',
        subscriptionStatus: 'active',
        networkStatus: 'offline',
        currentTab: 'wallet',
        lastScreen: 'البنوك',
        lastOperation: 'إيداع 500',
        pendingOperations: ['إنشاء ميزانية'],
      );
      final json = state.toJson();
      expect(json['subscription_plan'], 'Pro');
      expect(json['subscription_status'], 'active');
      expect(json['network_status'], 'offline');
      expect(json['current_tab'], 'wallet');
      expect(json['last_screen'], 'البنوك');
      expect(json['last_operation'], 'إيداع 500');
      expect(json['pending_operations'], ['إنشاء ميزانية']);
    });

    test('omits null fields and defaults network to online', () {
      const state = SaraAppState();
      final json = state.toJson();
      expect(json['network_status'], 'online');
      expect(json.containsKey('subscription_plan'), isFalse);
      expect(json.containsKey('last_screen'), isFalse);
    });
  });

  group('Deep navigation route resolution', () {
    SaraAction action(String type, {String? name, String? id}) => SaraAction(
          type: SaraActionType.openEntity,
          params: {
            'entity_type': type,
            'name': ?name,
            'id': ?id,
          },
        );

    test('bank with name -> bank detail route (encoded)', () {
      final route = SaraActionDispatcher.resolveRouteFromActions([
        action('bank', name: 'الراجحي'),
      ]);
      expect(route, RouteNames.personalBankDetail.replaceFirst(':bankName', Uri.encodeComponent('الراجحي')));
    });

    test('bank without name -> banks list', () {
      expect(
        SaraActionDispatcher.resolveRouteFromActions([action('bank')]),
        RouteNames.personalBanks,
      );
    });

    test('goal with id -> savings detail', () {
      expect(
        SaraActionDispatcher.resolveRouteFromActions([action('goal', id: 'goal-1')]),
        RouteNames.personalSavingsDetail.replaceFirst(':goalId', 'goal-1'),
      );
    });

    test('customer -> the customers screen (no detail route by id)', () {
      expect(
        SaraActionDispatcher.resolveRouteFromActions([action('customer', id: 'c-9')]),
        RouteNames.customers,
      );
      expect(SaraActionDispatcher.resolveRouteFromActions([action('supplier')]), RouteNames.suppliers);
    });

    test('invoice -> the sales invoices list (the view needs the record)', () {
      expect(
        SaraActionDispatcher.resolveRouteFromActions([action('invoice', id: 'inv-7')]),
        RouteNames.sales,
      );
      expect(
        SaraActionDispatcher.resolveRouteFromActions([action('invoice')]),
        RouteNames.sales,
      );
    });

    test('product -> inventory, expense -> expenses, recurring -> recurring tab', () {
      expect(SaraActionDispatcher.resolveRouteFromActions([action('product')]), RouteNames.inventory);
      expect(SaraActionDispatcher.resolveRouteFromActions([action('expense')]), RouteNames.businessIncomeExpense);
      // Recurring entities have their own page.
      expect(SaraActionDispatcher.resolveRouteFromActions([action('recurring')]), RouteNames.personalRecurring);
      expect(SaraActionDispatcher.resolveRouteFromActions([action('budget')]), RouteNames.personalBudget);
    });

    test('transaction with id -> account detail, without -> transactions', () {
      expect(
        SaraActionDispatcher.resolveRouteFromActions([action('transaction', id: 'tx-2')]),
        RouteNames.personalAccountDetail.replaceFirst(':id', 'tx-2'),
      );
      expect(
        SaraActionDispatcher.resolveRouteFromActions([action('transaction')]),
        RouteNames.personalTransactions,
      );
    });

    test('open_screen actions resolve via route map', () {
      final actions = [
        const SaraAction(type: SaraActionType.openScreen, params: {'screen': 'التقارير'}),
      ];
      expect(SaraActionDispatcher.resolveRouteFromActions(actions), RouteNames.personalReports);
    });

    test('unknown entity -> null (no wrong navigation)', () {
      expect(SaraActionDispatcher.resolveRouteFromActions([action('unknown')]), isNull);
    });
  });

  group('AiService.speak (TTS)', () {
    test('posts FormData to aiSpeak with bytes response and returns audio', () async {
      final dio = Dio()..httpClientAdapter = _FakeAdapter();
      final service = AiService(apiClient: ApiClient(dio: dio));

      final bytes = await service.speak('مرحباً بك', voice: 'nova', speed: 1.5);

      expect(bytes, isNotNull);
      expect(bytes, [0x4D, 0x50, 0x33]); // MP3

      final req = _FakeAdapter.lastRequest!;
      expect(req.method, 'POST');
      expect(req.path, ApiEndpoints.aiSpeak);
      expect(req.responseType, ResponseType.bytes);

      final form = req.data as FormData;
      final fields = {for (final e in form.fields) e.key: e.value};
      expect(fields['text'], 'مرحباً بك');
      expect(fields['voice'], 'nova');
      expect(fields['speed'], '1.5');
    });

    test('returns null on network failure (never throws)', () async {
      final dio = Dio()..httpClientAdapter = _ThrowAdapter();
      final service = AiService(apiClient: ApiClient(dio: dio));
      final bytes = await service.speak('مرحباً');
      expect(bytes, isNull);
    });
  });
}

class _FakeAdapter implements HttpClientAdapter {
  static RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromBytes(
      [0x4D, 0x50, 0x33],
      200,
      headers: {'content-type': ['audio/mpeg']},
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ThrowAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(requestOptions: options, type: DioExceptionType.connectionError);
  }

  @override
  void close({bool force = false}) {}
}
