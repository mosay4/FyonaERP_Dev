import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/network/dio_provider.dart';
import '../data/models/suggestion_models.dart';
import '../domain/services/suggestions_service.dart';

final suggestionsServiceProvider = Provider<SuggestionsService>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return SuggestionsService(apiClient: apiClient);
});

/// The current user's submitted suggestions.
final mySuggestionsProvider = FutureProvider<List<Suggestion>>((ref) async {
  return ref.watch(suggestionsServiceProvider).listMine();
});

class AdminSuggestionsQuery {
  final String? status;
  final String? search;
  final int page;
  const AdminSuggestionsQuery({this.status, this.search, this.page = 1});

  @override
  bool operator ==(Object other) =>
      other is AdminSuggestionsQuery &&
      other.status == status &&
      other.search == search &&
      other.page == page;

  @override
  int get hashCode => Object.hash(status, search, page);
}

/// Admin: paginated suggestions feed.
final adminSuggestionsProvider =
    FutureProvider.family<SuggestionList, AdminSuggestionsQuery>(
  (ref, query) async {
    return ref
        .watch(suggestionsServiceProvider)
        .adminList(status: query.status, search: query.search, page: query.page);
  },
);

class AdminConversationsQuery {
  final String? search;
  final int page;
  const AdminConversationsQuery({this.search, this.page = 1});

  @override
  bool operator ==(Object other) =>
      other is AdminConversationsQuery &&
      other.search == search &&
      other.page == page;

  @override
  int get hashCode => Object.hash(search, page);
}

/// Admin: paginated conversations feed (grouped per user).
final adminConversationsProvider =
    FutureProvider.family<SuggestionConversationList, AdminConversationsQuery>(
  (ref, query) async {
    return ref
        .watch(suggestionsServiceProvider)
        .adminConversations(search: query.search, page: query.page);
  },
);

/// One page of an admin conversation's message stream (newest first).
final conversationMessagesProvider = FutureProvider.family<
    SuggestionConversationMessages,
    ({String userId, int page})>((ref, key) async {
  return ref
      .watch(suggestionsServiceProvider)
      .conversationMessages(userId: key.userId, page: key.page);
});

/// Image bytes cache keyed by filename.
final suggestionImageProvider =
    FutureProvider.family<Uint8List, String>((ref, filename) async {
  return ref.watch(suggestionsServiceProvider).fetchImage(filename);
});

/// Generic media bytes (video/audio/image) cache keyed by kind + filename.
final suggestionFileProvider =
    FutureProvider.family<Uint8List, ({String kind, String filename})>(
        (ref, key) async {
  return ref
      .watch(suggestionsServiceProvider)
      .fetchFile(key.kind, key.filename);
});

/// Replies for a given suggestion (owner or admin).
final suggestionRepliesProvider =
    FutureProvider.family<List<SuggestionReply>, String>((ref, suggestionId) async {
  return ref.watch(suggestionsServiceProvider).getReplies(suggestionId);
});

/// One chat entry in the user's suggestions conversation:
/// either the user's own suggestion or an admin reply.
class SuggestionChatEntry {
  final Suggestion suggestion;
  final SuggestionReply? reply;
  const SuggestionChatEntry(this.suggestion, [this.reply]);

  bool get isReply => reply != null;
}

DateTime _parseTs(String? raw) =>
    DateTime.tryParse(raw ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);

/// One suggestion ticket's dedicated chat: the suggestion itself followed by
/// its replies in chronological order. Newer messages from either side appear
/// here — this is what the per-ticket conversation view renders.
final suggestionTicketProvider =
    FutureProvider.family<List<SuggestionChatEntry>, String>((ref, suggestionId) async {
  final service = ref.watch(suggestionsServiceProvider);
  final items = await service.listMine();
  Suggestion? match;
  for (final s in items) {
    if (s.id == suggestionId) {
      match = s;
      break;
    }
  }
  if (match == null) return <SuggestionChatEntry>[];
  final replies = await service.getReplies(match.id);
  final entries = <SuggestionChatEntry>[SuggestionChatEntry(match)];
  for (final r in replies) {
    entries.add(SuggestionChatEntry(match, r));
  }
  return entries;
});

/// The user's suggestions conversation flattened in chronological order
/// (oldest first): each suggestion followed by its admin replies.
final mySuggestionsConversationProvider =
    FutureProvider<List<SuggestionChatEntry>>((ref) async {
  final service = ref.watch(suggestionsServiceProvider);
  final items = await service.listMine();
  final sorted = [...items]
    ..sort((a, b) => _parseTs(a.createdAt).compareTo(_parseTs(b.createdAt)));
  final replies =
      await Future.wait(sorted.map((s) => service.getReplies(s.id)));
  final entries = <SuggestionChatEntry>[];
  for (var i = 0; i < sorted.length; i++) {
    entries.add(SuggestionChatEntry(sorted[i]));
    for (final r in replies[i]) {
      entries.add(SuggestionChatEntry(sorted[i], r));
    }
  }
  return entries;
});

/// Local preference key holding the last time the user opened the
/// suggestions chat (ISO-8601 UTC). Unread = admin replies after that time.
const String suggestionsLastReadAtKey = 'suggestions_last_read_at';

/// Persist "now" as the moment the user read the suggestions chat.
Future<void> markSuggestionsChatRead() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
      suggestionsLastReadAtKey, DateTime.now().toUtc().toIso8601String());
}

/// Number of unread admin replies in the user's suggestions chat.
final suggestionUnreadCountProvider = FutureProvider<int>((ref) async {
  final entries = await ref.watch(mySuggestionsConversationProvider.future);
  final prefs = await SharedPreferences.getInstance();
  final lastRead = prefs.getString(suggestionsLastReadAtKey);
  final lastTs = DateTime.tryParse(lastRead ?? '');
  if (lastTs == null) return 0;
  var unread = 0;
  for (final e in entries) {
    final r = e.reply;
    if (r == null || !r.isFromAdmin) continue;
    final ts = DateTime.tryParse(r.createdAt ?? '');
    if (ts != null && ts.isAfter(lastTs)) unread++;
  }
  return unread;
});

/// Heartbeat provider: reports the user as online every 30 seconds
/// while the suggestions feature is active.
final suggestionPresenceProvider = Provider<void>((ref) {
  final service = ref.watch(suggestionsServiceProvider);
  service.reportPresence();
  final timer = Timer.periodic(const Duration(seconds: 30), (_) {
    service.reportPresence();
  });
  ref.onDispose(() => timer.cancel());
});
