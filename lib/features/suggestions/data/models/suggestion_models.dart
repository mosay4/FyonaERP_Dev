class Suggestion {
  final String id;
  final String? organizationId;
  final String title;
  final String body;
  final List<String> images;
  final List<String> videos;
  final List<String> audios;
  final String status;
  final String? adminNote;
  final String? createdAt;
  final String? userName;
  final String? userEmail;
  final String? organizationName;

  const Suggestion({
    required this.id,
    this.organizationId,
    this.title = '',
    this.body = '',
    this.images = const [],
    this.videos = const [],
    this.audios = const [],
    this.status = 'pending',
    this.adminNote,
    this.createdAt,
    this.userName,
    this.userEmail,
    this.organizationName,
  });

  bool get isRejected => status == 'rejected';

  factory Suggestion.fromJson(Map<String, dynamic> json) {
    return Suggestion(
      id: json['id'] as String? ?? '',
      organizationId: json['organization_id'] as String?,
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      images: (json['images'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      videos: (json['videos'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      audios: (json['audios'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      status: json['status'] as String? ?? 'pending',
      adminNote: json['admin_note'] as String?,
      createdAt: json['created_at'] as String?,
      userName: json['user_name'] as String?,
      userEmail: json['user_email'] as String?,
      organizationName: json['organization_name'] as String?,
    );
  }
}

class SuggestionList {
  final List<Suggestion> items;
  final int total;
  final int page;
  final int perPage;
  final int totalPages;

  const SuggestionList({
    required this.items,
    this.total = 0,
    this.page = 1,
    this.perPage = 20,
    this.totalPages = 1,
  });

  factory SuggestionList.fromJson(Map<String, dynamic> json) {
    return SuggestionList(
      items: (json['items'] as List<dynamic>? ?? const [])
          .map((e) => Suggestion.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
      page: json['page'] as int? ?? 1,
      perPage: json['per_page'] as int? ?? 20,
      totalPages: json['total_pages'] as int? ?? 1,
    );
  }
}

class SuggestionReply {
  final String id;
  final String suggestionId;
  final String userId;
  final String? adminId;
  final String body;
  final bool isFromAdmin;
  final List<String> images;
  final List<String> videos;
  final List<String> audios;
  final String? createdAt;
  final String? updatedAt;
  final bool isEdited;

  const SuggestionReply({
    required this.id,
    required this.suggestionId,
    required this.userId,
    this.adminId,
    required this.body,
    this.isFromAdmin = true,
    this.images = const [],
    this.videos = const [],
    this.audios = const [],
    this.createdAt,
    this.updatedAt,
    this.isEdited = false,
  });

  /// Editable only within 24h of creation (server enforces too).
  bool get isEditable {
    final ts = DateTime.tryParse(createdAt ?? '');
    if (ts == null) return false;
    return DateTime.now().difference(ts).inHours < 24;
  }

  factory SuggestionReply.fromJson(Map<String, dynamic> json) {
    return SuggestionReply(
      id: json['id'] as String? ?? '',
      suggestionId: json['suggestion_id'] as String? ?? '',
      userId: json['user_id'] as String? ?? '',
      adminId: json['admin_id'] as String?,
      body: json['body'] as String? ?? '',
      isFromAdmin: json['is_from_admin'] as bool? ?? true,
      images: (json['images'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      videos: (json['videos'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      audios: (json['audios'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      createdAt: json['created_at'] as String?,
      updatedAt: json['updated_at'] as String?,
      isEdited: json['is_edited'] as bool? ?? false,
    );
  }
}

/// One row in the admin conversations feed: everything the user sent us
/// (their suggestions + admin replies) grouped as a single thread.
class SuggestionConversation {
  final String userId;
  final String userName;
  final String userEmail;
  final String? organizationName;
  final String lastMessage;
  final bool lastIsFromAdmin;
  final String? lastMessageAt;
  final int unreadCount;
  final bool hasReply;
  final int suggestionsCount;
  final String lastStatus;
  final bool isOnline;
  final String? lastSeenAt;

  const SuggestionConversation({
    required this.userId,
    this.userName = '',
    this.userEmail = '',
    this.organizationName,
    this.lastMessage = '',
    this.lastIsFromAdmin = false,
    this.lastMessageAt,
    this.unreadCount = 0,
    this.hasReply = false,
    this.suggestionsCount = 0,
    this.lastStatus = 'pending',
    this.isOnline = false,
    this.lastSeenAt,
  });

  bool get hasUnread => unreadCount > 0;

  factory SuggestionConversation.fromJson(Map<String, dynamic> json) {
    return SuggestionConversation(
      userId: json['user_id'] as String? ?? '',
      userName: json['user_name'] as String? ?? '',
      userEmail: json['user_email'] as String? ?? '',
      organizationName: json['organization_name'] as String?,
      lastMessage: json['last_message'] as String? ?? '',
      lastIsFromAdmin: json['last_is_from_admin'] as bool? ?? false,
      lastMessageAt: json['last_message_at'] as String?,
      unreadCount: json['unread_count'] as int? ?? 0,
      hasReply: json['has_reply'] as bool? ?? false,
      suggestionsCount: json['suggestions_count'] as int? ?? 0,
      lastStatus: json['last_status'] as String? ?? 'pending',
      isOnline: json['is_online'] as bool? ?? false,
      lastSeenAt: json['last_seen_at'] as String?,
    );
  }
}

class SuggestionConversationList {
  final List<SuggestionConversation> items;
  final int total;
  final int page;
  final int perPage;
  final int totalPages;

  const SuggestionConversationList({
    required this.items,
    this.total = 0,
    this.page = 1,
    this.perPage = 20,
    this.totalPages = 1,
  });

  bool get hasMore => page < totalPages;

  factory SuggestionConversationList.fromJson(Map<String, dynamic> json) {
    return SuggestionConversationList(
      items: (json['items'] as List<dynamic>? ?? const [])
          .map((e) => SuggestionConversation.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
      page: json['page'] as int? ?? 1,
      perPage: json['per_page'] as int? ?? 20,
      totalPages: json['total_pages'] as int? ?? 1,
    );
  }
}

/// A single message inside an admin conversation — either the user's own
/// suggestion or an admin reply, merged into one chronological stream.
class SuggestionConversationMessage {
  final String id;
  final String kind; // "suggestion" | "reply"
  final String userId;
  final String suggestionId;
  final String title;
  final String body;
  final List<String> images;
  final List<String> videos;
  final List<String> audios;
  final String status;
  final String? adminNote;
  final bool isFromAdmin;
  final String? createdAt;

  const SuggestionConversationMessage({
    required this.id,
    this.kind = 'suggestion',
    required this.userId,
    required this.suggestionId,
    this.title = '',
    this.body = '',
    this.images = const [],
    this.videos = const [],
    this.audios = const [],
    this.status = 'pending',
    this.adminNote,
    this.isFromAdmin = false,
    this.createdAt,
  });

  bool get isSuggestion => kind == 'suggestion';
  bool get isReply => kind == 'reply';

  factory SuggestionConversationMessage.fromJson(Map<String, dynamic> json) {
    return SuggestionConversationMessage(
      id: json['id'] as String? ?? '',
      kind: json['kind'] as String? ?? 'suggestion',
      userId: json['user_id'] as String? ?? '',
      suggestionId: json['suggestion_id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      images: (json['images'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      videos: (json['videos'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      audios: (json['audios'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      status: json['status'] as String? ?? 'pending',
      adminNote: json['admin_note'] as String?,
      isFromAdmin: json['is_from_admin'] as bool? ?? false,
      createdAt: json['created_at'] as String?,
    );
  }
}

class SuggestionConversationMessages {
  final List<SuggestionConversationMessage> items;
  final int total;
  final int page;
  final int perPage;
  final int totalPages;

  const SuggestionConversationMessages({
    required this.items,
    this.total = 0,
    this.page = 1,
    this.perPage = 20,
    this.totalPages = 1,
  });

  bool get hasMore => page < totalPages;

  factory SuggestionConversationMessages.fromJson(Map<String, dynamic> json) {
    return SuggestionConversationMessages(
      items: (json['items'] as List<dynamic>? ?? const [])
          .map((e) => SuggestionConversationMessage.fromJson(e as Map<String, dynamic>))
          .toList(),
      total: json['total'] as int? ?? 0,
      page: json['page'] as int? ?? 1,
      perPage: json['per_page'] as int? ?? 20,
      totalPages: json['total_pages'] as int? ?? 1,
    );
  }
}
