import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/merchant_api.dart';

/// Red-dot source for «حساباتي مع التجار» (personal) and «الديون» (business).
/// Polls the cheap unread count; the notification center invalidates it the
/// moment it marks rows read, so the dot disappears immediately after viewing.
final debtUnreadProvider = StreamProvider.family<int, String>((ref, side) {
  final api = ref.watch(merchantApiProvider);
  final controller = StreamController<int>();
  Timer? timer;
  var closed = false;

  Future<void> load() async {
    if (closed) return;
    try {
      final n = await api.unreadNotifications(side: side);
      if (!closed) controller.add(n);
    } catch (_) {
      if (!closed) controller.add(0);
    }
  }

  load();
  timer = Timer.periodic(const Duration(seconds: 15), (_) => load());
  ref.onDispose(() {
    closed = true;
    timer?.cancel();
    controller.close();
  });
  return controller.stream;
});

/// Unread chat counts per link for the red dot on the chat icon.
final chatUnreadProvider =
    StreamProvider.family<Map<String, int>, String>((ref, side) {
  final api = ref.watch(merchantApiProvider);
  final controller = StreamController<Map<String, int>>();
  Timer? timer;
  var closed = false;

  Future<void> load() async {
    if (closed) return;
    try {
      final m = await api.chatUnreadByLink(side: side);
      if (!closed) controller.add(m);
    } catch (_) {
      if (!closed) controller.add(const {});
    }
  }

  load();
  timer = Timer.periodic(const Duration(seconds: 15), (_) => load());
  ref.onDispose(() {
    closed = true;
    timer?.cancel();
    controller.close();
  });
  return controller.stream;
});
