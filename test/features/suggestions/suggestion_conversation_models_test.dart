import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/suggestions/data/models/suggestion_models.dart';

void main() {
  group('SuggestionConversation', () {
    test('parses json and flags unread', () {
      final c = SuggestionConversation.fromJson({
        'user_id': 'u1',
        'user_name': 'أحمد',
        'user_email': 'a@test.com',
        'organization_name': 'شركة النور',
        'last_message': 'مرحباً',
        'last_is_from_admin': false,
        'last_message_at': '2026-08-14T10:00:00Z',
        'unread_count': 3,
        'has_reply': true,
        'suggestions_count': 2,
        'last_status': 'pending',
      });
      expect(c.userId, 'u1');
      expect(c.userName, 'أحمد');
      expect(c.hasUnread, isTrue);
      expect(c.unreadCount, 3);
      expect(c.hasReply, isTrue);
      expect(c.suggestionsCount, 2);
      expect(c.lastIsFromAdmin, isFalse);
    });

    test('defaults are empty/safe', () {
      final c = SuggestionConversation.fromJson({'user_id': 'u1'});
      expect(c.hasUnread, isFalse);
      expect(c.lastMessage, '');
      expect(c.lastStatus, 'pending');
    });
  });

  group('SuggestionConversationList', () {
    test('parses items and pagination', () {
      final l = SuggestionConversationList.fromJson({
        'items': [
          {'user_id': 'u1', 'unread_count': 1},
          {'user_id': 'u2', 'unread_count': 0},
        ],
        'total': 25,
        'page': 1,
        'per_page': 20,
        'total_pages': 2,
      });
      expect(l.items.length, 2);
      expect(l.total, 25);
      expect(l.hasMore, isTrue);
    });

    test('hasMore false on last page', () {
      final l = SuggestionConversationList.fromJson({
        'items': [],
        'total': 20,
        'page': 1,
        'per_page': 20,
        'total_pages': 1,
      });
      expect(l.hasMore, isFalse);
    });
  });

  group('SuggestionConversationMessage', () {
    test('parses a suggestion message', () {
      final m = SuggestionConversationMessage.fromJson({
        'id': 's1',
        'kind': 'suggestion',
        'user_id': 'u1',
        'suggestion_id': 's1',
        'title': 'عنوان',
        'body': 'نص الاقتراح',
        'images': ['a.png'],
        'videos': ['b.mp4'],
        'audios': ['c.m4a'],
        'status': 'approved',
        'admin_note': 'تمت الموافقة',
        'is_from_admin': false,
        'created_at': '2026-08-14T10:00:00Z',
      });
      expect(m.isSuggestion, isTrue);
      expect(m.isReply, isFalse);
      expect(m.status, 'approved');
      expect(m.adminNote, 'تمت الموافقة');
      expect(m.images, ['a.png']);
      expect(m.isFromAdmin, isFalse);
    });

    test('parses an admin reply message', () {
      final m = SuggestionConversationMessage.fromJson({
        'id': 'r1',
        'kind': 'reply',
        'user_id': 'u1',
        'suggestion_id': 's1',
        'body': 'رد الإدارة',
        'is_from_admin': true,
      });
      expect(m.isReply, isTrue);
      expect(m.isFromAdmin, isTrue);
      expect(m.body, 'رد الإدارة');
      expect(m.images, isEmpty);
    });
  });

  group('SuggestionConversationMessages', () {
    test('parses items and pagination', () {
      final l = SuggestionConversationMessages.fromJson({
        'items': [
          {'id': 'r1', 'kind': 'reply', 'user_id': 'u1', 'suggestion_id': 's1'},
          {'id': 's1', 'kind': 'suggestion', 'user_id': 'u1', 'suggestion_id': 's1'},
        ],
        'total': 2,
        'page': 1,
        'per_page': 30,
        'total_pages': 1,
      });
      expect(l.items.length, 2);
      expect(l.items.first.id, 'r1');
      expect(l.hasMore, isFalse);
    });
  });
}
