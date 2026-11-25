import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/network/dio_provider.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/offline/offline_sara.dart';
import '../../../../core/offline/offline_guard.dart';
import '../../presentation/widgets/sara_offline_notice.dart';
import '../../../../shared/widgets/sara_action_dispatcher.dart';

/// App state snapshot sent to Sara for full app awareness.
class SaraAppState {
  final String? subscriptionPlan;
  final String? subscriptionStatus;
  final String? networkStatus;
  final String? currentTab;
  final String? lastScreen;
  final String? lastOperation;
  final List<String> pendingOperations;

  const SaraAppState({
    this.subscriptionPlan,
    this.subscriptionStatus,
    this.networkStatus = 'online',
    this.currentTab,
    this.lastScreen,
    this.lastOperation,
    this.pendingOperations = const [],
  });

  Map<String, dynamic> toJson() => {
        if (subscriptionPlan != null) 'subscription_plan': subscriptionPlan,
        if (subscriptionStatus != null) 'subscription_status': subscriptionStatus,
        'network_status': networkStatus ?? 'online',
        if (currentTab != null) 'current_tab': currentTab,
        if (lastScreen != null) 'last_screen': lastScreen,
        if (lastOperation != null) 'last_operation': lastOperation,
        if (pendingOperations.isNotEmpty) 'pending_operations': pendingOperations,
      };
}

class Suggestion {
  final int id;
  final String type;
  final String title;
  final String description;
  final bool isRead;
  final String createdAt;

  const Suggestion({
    required this.id,
    required this.type,
    required this.title,
    required this.description,
    this.isRead = false,
    this.createdAt = '',
  });

  Suggestion copyWith({bool? isRead}) {
    return Suggestion(
      id: id,
      type: type,
      title: title,
      description: description,
      isRead: isRead ?? this.isRead,
      createdAt: createdAt,
    );
  }

  factory Suggestion.fromJson(Map<String, dynamic> json) => Suggestion(
    id: json['id'] as int? ?? 0,
    type: json['type'] as String? ?? 'sales_trend',
    title: json['title'] as String? ?? '',
    description: json['description'] as String? ?? '',
    isRead: json['is_read'] as bool? ?? false,
    createdAt: json['created_at'] as String? ?? '',
  );
}

class AiInsights {
  final String summary;
  final List<String> highlights;
  final String recommendation;

  const AiInsights({
    this.summary = '',
    this.highlights = const [],
    this.recommendation = '',
  });

  factory AiInsights.fromJson(Map<String, dynamic> json) => AiInsights(
    summary: json['summary'] as String? ?? '',
    highlights: (json['highlights'] as List?)?.whereType<String>().toList() ?? [],
    recommendation: json['recommendation'] as String? ?? '',
  );
}

/// Structured response from Sara AI Agent.
class AiAgentResponse {
  final String text;
  final List<SaraAction> actions;
  final List<String> suggestions;
  final double confidence;
  final List<Map<String, dynamic>> pendingTools;
  final String? userQuery; // final query after transcript/image/file merge (for memory)
  /// Business Sara on a device-ledger branch: requests this phone answers
  /// from its own ledger before the conversation continues ([state]).
  final List<Map<String, dynamic>> deviceCalls;
  final Map<String, dynamic>? state;

  const AiAgentResponse({
    required this.text,
    this.actions = const [],
    this.suggestions = const [],
    this.confidence = 0.0,
    this.pendingTools = const [],
    this.userQuery,
    this.deviceCalls = const [],
    this.state,
  });

  factory AiAgentResponse.fromJson(Map<String, dynamic> json) {
    final actionsList = <SaraAction>[];
    if (json['actions'] is List) {
      for (final a in json['actions'] as List) {
        if (a is Map<String, dynamic>) {
          actionsList.add(SaraAction.fromJson(a));
        }
      }
    }
    final pendingToolsList = <Map<String, dynamic>>[];
    if (json['pending_tools'] is List) {
      for (final t in json['pending_tools'] as List) {
        if (t is Map<String, dynamic>) {
          pendingToolsList.add(Map<String, dynamic>.from(t));
        }
      }
    }
    return AiAgentResponse(
      text: json['text'] as String? ?? json['answer'] as String? ?? '',
      actions: actionsList,
      suggestions: (json['suggestions'] as List?)?.whereType<String>().toList() ?? [],
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.9,
      pendingTools: pendingToolsList,
      userQuery: json['user_query'] as String?,
      deviceCalls: [
        for (final c in (json['device_calls'] as List?) ?? const [])
          if (c is Map) Map<String, dynamic>.from(c),
      ],
      state: json['state'] is Map ? Map<String, dynamic>.from(json['state'] as Map) : null,
    );
  }
}

class AiService {
  final ApiClient apiClient;
  final Ref? _ref;

  AiService({required this.apiClient, Ref? ref}) : _ref = ref;

  Future<List<Suggestion>> getSuggestions() async {
    final resp = await apiClient.getSafe<List<dynamic>>(ApiEndpoints.aiInsights);
    if (resp.data == null) return [];
    return (resp.data as List).map((j) => Suggestion.fromJson(j as Map<String, dynamic>)).toList();
  }

  Future<AiInsights> getInsights({DateTime? from, DateTime? to}) async {
    final resp = await apiClient.getSafe<Map<String, dynamic>>(ApiEndpoints.aiInsights, queryParameters: {
      if (from != null) 'from': from.toIso8601String(),
      if (to != null) 'to': to.toIso8601String(),
    });
    if (resp.data == null) return const AiInsights();
    return AiInsights.fromJson(resp.data!);
  }

  /// Send a question to Sara AI Agent and get structured response.
  Future<AiAgentResponse> askQuestion(
    String query, {
    String? userName,
    String accountType = 'personal',
    String? companyName,
    String currentScreen = '',
    List<Map<String, String>>? screenCatalog,
    String? language,
    List<Map<String, String>>? history,
    SaraAppState? appState,
    Ref? ref,
    List<String>? deviceRoutes,
  }) async {
    try {
      final resp = await apiClient.postSafe<Map<String, dynamic>>(
        accountType == 'business' ? '/business-sara/query' : ApiEndpoints.aiQuery,
        options: Options(
          receiveTimeout: const Duration(minutes: 3),
          headers: {if (deviceRoutes != null) 'x-fyona-device-sara': '1'},
        ),
        data: {
          if (deviceRoutes != null) 'device_routes': deviceRoutes,
          'query': query,
          'user_name': userName ?? '',
          'account_type': accountType,
          'company_name': companyName,
          'current_screen': currentScreen,
          if (screenCatalog != null && screenCatalog.isNotEmpty)
            'screen_catalog': screenCatalog,
          if (language != null) 'language': language,
          if (history != null) 'history': history,
          if (appState != null) ...appState.toJson(),
        },
      );
      return AiAgentResponse.fromJson(resp.data ?? {});
    } catch (e) {
      // Offline fallback: answer locally from the same services the UI uses
      // (never fake success — local writers still go through the outbox).
      // Personal Sara is online-only: no local answers from device data.
      final r = ref ?? _ref;
      if (r != null &&
          SaraOnlinePolicy.allowsOfflineFallback(accountType) &&
          isConnectivityError(e)) {
        final text = await OfflineSara.answer(
          ref: r,
          query: query,
          accountType: accountType,
        );
        if (text != null) {
          return AiAgentResponse(
            text: text,
            confidence: 0.6,
            suggestions: [_fallbackNote()],
          );
        }
      }
      rethrow;
    }
  }

  String _fallbackNote() =>
      'أنا أعمل الآن بدون إنترنت، لكنني قرأت بياناتك المحلية وأجبتك منها. عند عودة الاتصال سأجيبك بشكل أكمل.';

  /// Text-to-Speech: convert text to MP3 bytes using Sara's voice.
  Future<Uint8List?> speak(String text, {String voice = 'alloy', double speed = 1.0}) async {
    try {
      final resp = await apiClient.dio.post(
        ApiEndpoints.aiSpeak,
        data: FormData.fromMap({
          'text': text,
          'voice': voice,
          'speed': speed.toString(),
        }),
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = resp.data;
      if (bytes is List<int>) return Uint8List.fromList(bytes);
      if (bytes is Uint8List) return bytes;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Resume a device-ledger Business conversation with the phone's answers.
  Future<AiAgentResponse> continueBusiness({
    required Map<String, dynamic> state,
    required List<Map<String, dynamic>> results,
    required List<String> deviceRoutes,
    String? language,
    List<Map<String, String>>? screenCatalog,
  }) async {
    final resp = await apiClient.postSafe<Map<String, dynamic>>(
      '/business-sara/continue',
      options: Options(
        receiveTimeout: const Duration(minutes: 3),
        headers: {'x-fyona-device-sara': '1'},
      ),
      data: {
        'state': state,
        'results': results,
        'device_routes': deviceRoutes,
        'language': language ?? 'ar',
        if (screenCatalog != null) 'screen_catalog': screenCatalog,
      },
    );
    return AiAgentResponse.fromJson(resp.data ?? {});
  }

  Future<AiAgentResponse> askQuestionWithAudio(
    String query, {
    String? audioFile,
    String? imagePath,
    String? attachmentPath,
    String? userName,
    String accountType = 'personal',
    String? language,
    List<Map<String, String>>? screenCatalog,
    List<Map<String, String>>? history,
    SaraAppState? appState,
    Ref? ref,
    List<String>? deviceRoutes,
  }) async {
    final formData = FormData.fromMap({
      'query': query,
      if (deviceRoutes != null) 'device_routes': jsonEncode(deviceRoutes),
      'user_name': userName ?? '',
      'account_type': accountType,
      if (screenCatalog != null && screenCatalog.isNotEmpty)
        'screen_catalog': jsonEncode(screenCatalog),
      if (language != null) 'language': language,
      if (audioFile != null)
        'audio_file': await MultipartFile.fromFile(
          audioFile,
          filename: audioFile.split('/').last,
          contentType: DioMediaType('audio', 'm4a'),
        ),
      if (imagePath != null)
        'image_file': await MultipartFile.fromFile(
          imagePath,
          filename: imagePath.split('/').last,
        ),
      if (attachmentPath != null)
        'attachment_file': await MultipartFile.fromFile(
          attachmentPath,
          filename: attachmentPath.split('/').last,
        ),
      if (history != null) 'history': jsonEncode(history),
      if (appState != null) ...appState.toJson(),
    });
    try {
      final resp = await apiClient.postSafe<Map<String, dynamic>>(
        accountType == 'business' ? '/business-sara/query-attachment' : ApiEndpoints.aiQueryAttachment,
        options: Options(
          receiveTimeout: const Duration(minutes: 15),
          sendTimeout: const Duration(minutes: 3),
          headers: {if (deviceRoutes != null) 'x-fyona-device-sara': '1'},
        ),
        data: formData,
      );
      return AiAgentResponse.fromJson(resp.data ?? {});
    } catch (e) {
      // Offline fallback: same local assistant path as askQuestion.
      // Personal Sara is online-only: no local answers from device data.
      final r = ref ?? _ref;
      if (r != null &&
          SaraOnlinePolicy.allowsOfflineFallback(accountType) &&
          isConnectivityError(e)) {
        final text = await OfflineSara.answer(
          ref: r,
          query: query,
          accountType: accountType,
        );
        if (text != null) {
          return AiAgentResponse(
            text: text,
            confidence: 0.6,
            suggestions: [_fallbackNote()],
          );
        }
      }
      rethrow;
    }
  }
}
