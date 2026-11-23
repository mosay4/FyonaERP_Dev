import 'package:flutter_riverpod/flutter_riverpod.dart';

class ActiveChatView {
  const ActiveChatView(this.linkId, this.side);
  final String linkId;
  final String side;
}

final activeChatViewProvider = StateProvider<ActiveChatView?>((ref) => null);

bool suppressChatTray(String? payload, ActiveChatView? active) {
  if (payload == null || active == null) return false;
  final uri = Uri.tryParse(payload);
  if (uri == null ||
      !const ['/personal/chat', '/debts/chat'].contains(uri.path))
    return false;
  final side = uri.path.startsWith('/personal') ? 'personal' : 'merchant';
  return uri.queryParameters['link'] == active.linkId && side == active.side;
}
