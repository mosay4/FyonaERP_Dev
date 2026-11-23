import 'package:collection/collection.dart';

/// Bounded sliding window. History/refresh merges never create sound events.
class ChatTimeline {
  static const pageSize = 40;
  static const capacity = 500;
  final List<Map<String, dynamic>> messages = [];
  final Set<String> _receive = {};
  final Set<String> _sent = {};

  static String? clientId(Map message) {
    for (final key in ['client_message_id', 'client_id', 'idempotency_key']) {
      final value = message[key]?.toString();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  bool merge(
    List<Map<String, dynamic>> page, {
    bool live = false,
    bool older = false,
  }) {
    var changed = false;
    for (final raw in page) {
      var message = Map<String, dynamic>.from(raw);
      final id = '${message['id']}';
      var key = clientId(message);
      // A legacy refresh may omit the client key; retain the binding learned
      // from the send response so a late retry cannot recreate a pending row.
      final byId = messages.indexWhere(
        (m) => message['id'] != null && '${m['id']}' == id,
      );
      key ??= byId < 0 ? null : clientId(messages[byId]);
      if (key != null) {
        message['client_id'] = key;
        message['client_message_id'] = key;
      }
      bool sameMessage(Map<String, dynamic> m) =>
          (message['id'] != null && '${m['id']}' == id) ||
          (key != null && clientId(m) == key && m['mine'] == message['mine']);
      final index = messages.indexWhere(sameMessage);
      if (index >= 0 &&
          message['busy'] != null &&
          messages[index]['busy'] == null) {
        message = messages[index]; // Never regress an acknowledged row.
      }
      if (index < 0) {
        messages.add(message);
        if (live && message['mine'] != true && message['deleted'] != true) {
          _receive.add(id);
        }
        changed = true;
      } else if (!const DeepCollectionEquality().equals(
        messages[index],
        message,
      )) {
        messages[index] = message;
        changed = true;
      }
      // Collapse a pending/server pair even if both existed before this merge.
      if (index >= 0) {
        for (var i = messages.length - 1; i > index; i--) {
          if (sameMessage(messages[i])) {
            messages.removeAt(i);
            changed = true;
          }
        }
      }
    }
    if (!changed) return false;
    messages.sort((a, b) {
      final time = '${a['created_at']}'.compareTo('${b['created_at']}');
      return time != 0 ? time : '${a['id']}'.compareTo('${b['id']}');
    });
    if (messages.length > capacity) {
      if (older) {
        messages.removeRange(capacity, messages.length);
      } else {
        messages.removeRange(0, messages.length - capacity);
      }
    }
    final ids = messages.map((m) => '${m['id']}').toSet();
    _receive.retainAll(ids);
    return true;
  }

  bool rendered(String id) => _receive.remove(id);

  bool accepted(String id) {
    if (!_sent.add(id)) return false;
    if (_sent.length > capacity) _sent.remove(_sent.first);
    return true;
  }
}
