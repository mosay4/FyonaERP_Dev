import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../../core/network/dio_provider.dart';
import '../../data/models/suggestion_models.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';

class SuggestionsService {
  final ApiClient apiClient;

  SuggestionsService({required this.apiClient});

  /// Fetch the current user's own suggestions.
  Future<List<Suggestion>> listMine() async {
    final resp = await apiClient.getSafe<List<dynamic>>('/suggestions/mine');
    final list = resp.data ?? const [];
    return list
        .map((j) => Suggestion.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  /// Submit a suggestion with free text + up to 5 images,
  /// up to 2 videos and up to 3 audio recordings.
  Future<Suggestion> submit({
    String title = '',
    String body = '',
    List<Uint8List> images = const [],
    List<String> imageNames = const [],
    List<Uint8List> videos = const [],
    List<String> videoNames = const [],
    List<Uint8List> audios = const [],
    List<String> audioNames = const [],
  }) async {
    final formData = _mediaFormData(
        title: title, body: body, images: images, imageNames: imageNames,
        videos: videos, videoNames: videoNames, audios: audios, audioNames: audioNames);
    final resp = await apiClient.postSafe<Map<String, dynamic>>(
      '/suggestions',
      data: formData,
    );
    if (!resp.success) {
      throw Exception(resp.message ?? AppLocalizations.t('suggestionsFailedToSendSuggestion'));
    }
    return Suggestion.fromJson(resp.data!);
  }

  /// Send a follow-up message (text and/or media) inside an existing
  /// suggestion ticket — keeps every suggestion on its own dedicated chat.
  Future<SuggestionReply> replyToSuggestion({
    required String suggestionId,
    String body = '',
    List<Uint8List> images = const [],
    List<String> imageNames = const [],
    List<Uint8List> videos = const [],
    List<String> videoNames = const [],
    List<Uint8List> audios = const [],
    List<String> audioNames = const [],
  }) async {
    final formData = _mediaFormData(
        title: '', body: body, images: images, imageNames: imageNames,
        videos: videos, videoNames: videoNames, audios: audios, audioNames: audioNames);
    final resp = await apiClient.postSafe<Map<String, dynamic>>(
      '/suggestions/$suggestionId/messages',
      data: formData,
    );
    if (!resp.success) {
      throw Exception(resp.message ?? AppLocalizations.t('suggestionsFailedToSendSuggestion'));
    }
    return SuggestionReply.fromJson(resp.data ?? {});
  }

  FormData _mediaFormData({
    String title = '',
    String body = '',
    List<Uint8List> images = const [],
    List<String> imageNames = const [],
    List<Uint8List> videos = const [],
    List<String> videoNames = const [],
    List<Uint8List> audios = const [],
    List<String> audioNames = const [],
  }) {
    return FormData.fromMap({
      'title': title,
      'body': body,
      'images': [
        for (var i = 0; i < images.length; i++)
          MultipartFile.fromBytes(
            images[i],
            filename: i < imageNames.length ? imageNames[i] : 'image_$i.jpg',
          ),
      ],
      'videos': [
        for (var i = 0; i < videos.length; i++)
          MultipartFile.fromBytes(
            videos[i],
            filename: i < videoNames.length ? videoNames[i] : 'video_$i.mp4',
          ),
      ],
      'audios': [
        for (var i = 0; i < audios.length; i++)
          MultipartFile.fromBytes(
            audios[i],
            filename: i < audioNames.length ? audioNames[i] : 'audio_$i.m4a',
          ),
      ],
    });
  }

  /// Admin: paginated list with optional status filter + search.
  Future<SuggestionList> adminList({
    String? status,
    String? search,
    int page = 1,
    int perPage = 20,
  }) async {
    final resp = await apiClient.getSafe<Map<String, dynamic>>(
      '/suggestions',
      queryParameters: {
        if (status != null && status.isNotEmpty) 'status': status,
        if (search != null && search.isNotEmpty) 'search': search,
        'page': page,
        'per_page': perPage,
      },
    );
    return SuggestionList.fromJson(resp.data ?? {});
  }

  /// Admin: review (approve / reject) with an optional note.
  Future<Suggestion> adminUpdate(
    String id, {
    required String status,
    String? adminNote,
  }) async {
    final resp = await apiClient.patchSafe<Map<String, dynamic>>(
      '/suggestions/$id',
      data: {
        'status': status,
        if (adminNote != null && adminNote.isNotEmpty) 'admin_note': adminNote,
      },
    );
    if (!resp.success) {
      throw Exception(resp.message ?? AppLocalizations.t('suggestionsSuggestionUpdateFailed'));
    }
    return Suggestion.fromJson(resp.data!);
  }

  /// Admin: reply to a suggestion (goes to the suggestion owner).
  Future<SuggestionReply> reply(String suggestionId, String body) async {
    final resp = await apiClient.postSafe<Map<String, dynamic>>(
      '/suggestions/$suggestionId/reply',
      data: {'body': body},
    );
    if (!resp.success) {
      throw Exception(resp.message ?? AppLocalizations.t('suggestionsFailedToSendReply'));
    }
    return SuggestionReply.fromJson(resp.data!);
  }

  /// Admin: paginated conversation list (grouped per user).
  Future<SuggestionConversationList> adminConversations({
    String? search,
    int page = 1,
    int perPage = 20,
  }) async {
    final resp = await apiClient.getSafe<Map<String, dynamic>>(
      '/suggestions/conversations',
      queryParameters: {
        if (search != null && search.isNotEmpty) 'search': search,
        'page': page,
        'per_page': perPage,
      },
    );
    return SuggestionConversationList.fromJson(resp.data ?? {});
  }

  /// Admin: one page of the conversation stream for a user (newest first).
  Future<SuggestionConversationMessages> conversationMessages({
    required String userId,
    int page = 1,
    int perPage = 30,
  }) async {
    final resp = await apiClient.getSafe<Map<String, dynamic>>(
      '/suggestions/conversations/$userId/messages',
      queryParameters: {'page': page, 'per_page': perPage},
    );
    return SuggestionConversationMessages.fromJson(resp.data ?? {});
  }

  /// Admin: reply inside a conversation (attaches to the latest suggestion).
  Future<SuggestionReply> conversationReply(String userId, String body) async {
    final resp = await apiClient.postSafe<Map<String, dynamic>>(
      '/suggestions/conversations/$userId/reply',
      data: {'body': body},
    );
    if (!resp.success) {
      throw Exception(resp.message ?? AppLocalizations.t('suggestionsFailedToSendReply'));
    }
    return SuggestionReply.fromJson(resp.data!);
  }

  /// Admin: mark a conversation as read.
  Future<void> markConversationRead(String userId) async {
    await apiClient.postSafe<Map<String, dynamic>>(
      '/suggestions/conversations/$userId/read',
    );
  }

  /// Fetch replies for a suggestion (owner or admin).
  Future<List<SuggestionReply>> getReplies(String suggestionId) async {
    final resp = await apiClient.getSafe<List<dynamic>>(
      '/suggestions/$suggestionId/replies',
    );
    final list = resp.data ?? const [];
    return list
        .map((j) => SuggestionReply.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  /// Edit an own message's text (server allows owners within 24h).
  Future<SuggestionReply> editMessage({
    required String messageId,
    required String body,
  }) async {
    final resp = await apiClient.putSafe<Map<String, dynamic>>(
      '/suggestions/messages/$messageId',
      data: {'body': body},
    );
    if (!resp.success) {
      throw Exception(resp.message ?? 'تعذر تعديل الرسالة');
    }
    return SuggestionReply.fromJson(resp.data ?? {});
  }

  /// Delete an own message (server allows owners within 24h).
  Future<void> deleteMessage(String messageId) async {
    final resp = await apiClient.postSafe<Map<String, dynamic>>(
      '/suggestions/messages/$messageId',
      data: {'_method': 'DELETE'},
    );
    if (!resp.success) {
      throw Exception(resp.message ?? 'تعذر حذف الرسالة');
    }
  }

  /// Download an uploaded suggestion image (authed by the interceptor).
  Future<Uint8List> fetchImage(String filename) async {
    return _fetchBytes('/suggestions/image/$filename');
  }

  /// Download an uploaded suggestion media file (video/audio/image).
  Future<Uint8List> fetchFile(String kind, String filename) async {
    return _fetchBytes('/suggestions/file/$kind/$filename');
  }

  /// Report the current user as "online" to the suggestions presence system.
  Future<void> reportPresence() async {
    try {
      await apiClient.postSafe<Map<String, dynamic>>(
        '/suggestions/presence',
        data: {'action': 'heartbeat'},
      );
    } catch (_) {
      // Presence is best-effort; swallow errors silently.
    }
  }

  Future<Uint8List> _fetchBytes(String url) async {
    final r = await apiClient.dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(r.data ?? const []);
  }
}
