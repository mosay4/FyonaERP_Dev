import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Persistent chat message model for storage.
///
/// Root fix: single source of truth for Sara's full conversation memory.
/// One file per user+account (conversation_id = "${userId}_${accountType}").
/// Stores every user turn and every Sara turn (text, voice transcript,
/// image/file metadata, analysis) with stable ids, timestamps and ordering.
/// Old JSON files are read tolerantly — new optional fields default safely.
class ChatPersistMessage {
  final String id;
  final String text;
  final String role;
  final DateTime time;
  final String? routeLink;
  final List<Map<String, dynamic>> actions;
  final String? imagePath;
  final String? audioPath;
  final int audioDuration;
  final bool isWelcome;

  // --- P2: full memory fields (all optional for backward compat) ---
  final String? conversationId;
  final String? userId;
  final String? accountType;
  final String? messageType; // text | voice | image | file | assistant_voice
  final String? transcript; // voice transcript (user) or spoken text (Sara)
  final String? fileName;
  final String? mimeType;
  final int? fileSize;
  final String? analysis; // image vision / file extracted text (real, not invented)

  const ChatPersistMessage({
    required this.id,
    required this.text,
    required this.role,
    required this.time,
    this.routeLink,
    this.actions = const [],
    this.imagePath,
    this.audioPath,
    this.audioDuration = 0,
    this.isWelcome = false,
    this.conversationId,
    this.userId,
    this.accountType,
    this.messageType,
    this.transcript,
    this.fileName,
    this.mimeType,
    this.fileSize,
    this.analysis,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'role': role,
    'time': time.toIso8601String(),
    'routeLink': routeLink,
    'actions': actions,
    'imagePath': imagePath,
    'audioPath': audioPath,
    'audioDuration': audioDuration,
    'isWelcome': isWelcome,
    if (conversationId != null) 'conversationId': conversationId,
    if (userId != null) 'userId': userId,
    if (accountType != null) 'accountType': accountType,
    if (messageType != null) 'messageType': messageType,
    if (transcript != null) 'transcript': transcript,
    if (fileName != null) 'fileName': fileName,
    if (mimeType != null) 'mimeType': mimeType,
    if (fileSize != null) 'fileSize': fileSize,
    if (analysis != null) 'analysis': analysis,
  };

  factory ChatPersistMessage.fromJson(Map<String, dynamic> json) {
    return ChatPersistMessage(
      id: json['id'] as String? ?? '',
      text: json['text'] as String? ?? '',
      role: json['role'] as String? ?? 'assistant',
      time: DateTime.tryParse(json['time'] as String? ?? '') ?? DateTime.now(),
      routeLink: json['routeLink'] as String?,
      actions: (json['actions'] as List<dynamic>?)
          ?.map((e) => Map<String, dynamic>.from(e as Map))
          .toList() ?? [],
      imagePath: json['imagePath'] as String?,
      audioPath: json['audioPath'] as String?,
      audioDuration: json['audioDuration'] as int? ?? 0,
      isWelcome: json['isWelcome'] as bool? ?? false,
      conversationId: json['conversationId'] as String?,
      userId: json['userId'] as String?,
      accountType: json['accountType'] as String?,
      messageType: json['messageType'] as String?,
      transcript: json['transcript'] as String?,
      fileName: json['fileName'] as String?,
      mimeType: json['mimeType'] as String?,
      fileSize: json['fileSize'] as int?,
      analysis: json['analysis'] as String?,
    );
  }
}

/// Persistent conversation storage using JSON files.
///
/// Each conversation is stored as a JSON file keyed by conversationId
/// (= "${userId}_${accountType}"). One file = one full history for that
/// user+account. Messages survive restarts and logout/login (the file is
/// NOT deleted on logout — that was the root cause for lost history).
/// Storage keeps the full history (no trimming for context window); the
/// LLM window is bounded at retrieval time, not by deleting storage.
class ChatPersistence {
  static const String _folderName = 'sara_chat';
  static const int _maxMessages = 5000;

  ChatPersistence._();
  static final ChatPersistence instance = ChatPersistence._();

  // Per-user mutex for concurrent append/save (prevents lost updates)
  static final Map<String, Completer<void>> _locks = {};

  /// Get the storage directory.
  Future<Directory> _getDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/$_folderName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Get the file path for a user's conversation.
  Future<File> _getFile(String userId) async {
    final dir = await _getDir();
    return File('${dir.path}/chat_$userId.json');
  }

  /// Load all messages for a user.
  Future<List<ChatPersistMessage>> loadMessages(String userId) async {
    try {
      final file = await _getFile(userId);
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      if (content.isEmpty) return [];
      final List<dynamic> jsonList = jsonDecode(content);
      return jsonList
          .map((e) => ChatPersistMessage.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (e) {
      debugPrint('ChatPersistence.loadMessages error: $e');
      return [];
    }
  }

  Future<void> _withLock(String userId, Future<void> Function() fn) async {
    while (_locks.containsKey(userId)) {
      try { await _locks[userId]!.future; } catch (_) {}
    }
    final c = Completer<void>();
    _locks[userId] = c;
    try {
      await fn();
    } finally {
      _locks.remove(userId);
      if (!c.isCompleted) c.complete();
    }
  }

  /// Save all messages for a user (replaces existing).
  /// Dedups by id, sorts by time+id, and keeps full history (up to _maxMessages).
  Future<bool> saveMessages(String userId, List<ChatPersistMessage> messages) async {
    bool ok = false;
    await _withLock(userId, () async {
      try {
        final file = await _getFile(userId);
        final seen = <String>{};
        final deduped = <ChatPersistMessage>[];
        for (final m in messages) {
          if (m.id.isEmpty || seen.add(m.id)) deduped.add(m);
        }
        deduped.sort((a, b) {
          final c = a.time.compareTo(b.time);
          if (c != 0) return c;
          return a.id.compareTo(b.id);
        });
        final trimmed = deduped.length > _maxMessages
            ? deduped.sublist(deduped.length - _maxMessages)
            : deduped;
        final jsonList = trimmed.map((m) => m.toJson()).toList();
        await file.writeAsString(jsonEncode(jsonList));
        ok = true;
      } catch (e) {
        debugPrint('ChatPersistence.saveMessages error: $e');
        ok = false;
      }
    });
    return ok;
  }

  /// Append a single message to the conversation (idempotent).
  Future<bool> appendMessage(String userId, ChatPersistMessage message) async {
    bool ok = false;
    await _withLock(userId, () async {
      try {
        final file = await _getFile(userId);
        List<ChatPersistMessage> messages = [];
        if (await file.exists()) {
          final content = await file.readAsString();
          if (content.isNotEmpty) {
            final List<dynamic> jsonList = jsonDecode(content);
            messages = jsonList.map((e) => ChatPersistMessage.fromJson(Map<String, dynamic>.from(e))).toList();
          }
        }
        if (messages.any((m) => m.id == message.id)) {
          ok = true;
          return;
        }
        messages.add(message);
        // Dedup + sort inside save logic (re-use)
        final seen = <String>{};
        final deduped = <ChatPersistMessage>[];
        for (final m in messages) {
          if (m.id.isEmpty || seen.add(m.id)) deduped.add(m);
        }
        deduped.sort((a, b) {
          final c = a.time.compareTo(b.time);
          if (c != 0) return c;
          return a.id.compareTo(b.id);
        });
        final trimmed = deduped.length > _maxMessages ? deduped.sublist(deduped.length - _maxMessages) : deduped;
        await file.writeAsString(jsonEncode(trimmed.map((m) => m.toJson()).toList()));
        ok = true;
      } catch (e) {
        debugPrint('ChatPersistence.appendMessage error: $e');
        ok = false;
      }
    });
    return ok;
  }

  /// Retrieve relevant history for a query (bounded, never rewrites originals).
  /// Returns up to [recentCount] most recent messages plus up to
  /// [relevantCount] older messages that contain query keywords or attachment
  /// references. Caller decides how to merge them into the LLM window.
  Future<List<ChatPersistMessage>> retrieveRelevant(
    String userId, String query, {int recentCount = 6, int relevantCount = 4}) async {
    final all = await loadMessages(userId);
    if (all.isEmpty) return [];
    // Recent slice (most recent, in order)
    final recent = all.length > recentCount ? all.sublist(all.length - recentCount) : List.of(all);
    if (query.trim().isEmpty) return recent;
    final q = query.toLowerCase();
    final keywords = q.split(RegExp(r'\s+')).where((w) => w.length > 2).toSet();
    final older = all.length > recentCount ? all.sublist(0, all.length - recentCount) : <ChatPersistMessage>[];
    final scored = <ChatPersistMessage, int>{};
    for (final m in older) {
      int score = 0;
      final hay = '${m.text} ${m.transcript ?? ''} ${m.fileName ?? ''} ${m.analysis ?? ''}'.toLowerCase();
      for (final kw in keywords) {
        if (hay.contains(kw)) score++;
      }
      // Attachment/image/file messages are relevant when query mentions them
      if (q.contains('صورة') || q.contains('image') || q.contains('ملف') || q.contains('file')) {
        if ((m.imagePath ?? '').isNotEmpty || (m.fileName ?? '').isNotEmpty) score += 2;
      }
      // Amount/money keywords
      if (q.contains('مبلغ') || q.contains('amount') || q.contains('راتب') || q.contains('ميزانية') || q.contains('budget')) {
        if (RegExp(r'\d').hasMatch(hay)) score += 1;
      }
      if (score > 0) scored[m] = score;
    }
    final sorted = scored.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final relevant = sorted.take(relevantCount).map((e) => e.key).toList()
      ..sort((a, b) {
        final c = a.time.compareTo(b.time);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    // Merge relevant (older) + recent, dedup and keep chronological
    final merged = <ChatPersistMessage>[...relevant, ...recent];
    final seen = <String>{};
    final out = <ChatPersistMessage>[];
    for (final m in merged) {
      if (seen.add(m.id)) out.add(m);
    }
    out.sort((a, b) {
      final c = a.time.compareTo(b.time);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    return out;
  }

  /// Clear all messages for a user.
  Future<bool> clearMessages(String userId) async {
    try {
      final file = await _getFile(userId);
      if (await file.exists()) {
        await file.delete();
      }
      return true;
    } catch (e) {
      debugPrint('ChatPersistence.clearMessages error: $e');
      return false;
    }
  }

  /// Check if a user has saved messages.
  Future<bool> hasMessages(String userId) async {
    try {
      final file = await _getFile(userId);
      return await file.exists();
    } catch (e) {
      return false;
    }
  }
}
