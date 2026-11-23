import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../features/personal/presentation/providers/merchant_unread_provider.dart';

/// Chat action icon with a red dot while that conversation has unread
/// messages (side: 'personal' or 'merchant').
class ChatUnreadIcon extends ConsumerWidget {
  final String side;
  final String linkId;
  final VoidCallback onPressed;
  const ChatUnreadIcon(
      {super.key,
      required this.side,
      required this.linkId,
      required this.onPressed});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(chatUnreadProvider(side)).valueOrNull?[linkId] ?? 0;
    return IconButton(
      tooltip: 'chat',
      onPressed: onPressed,
      icon: Stack(clipBehavior: Clip.none, children: [
        const Icon(Icons.chat_bubble_outline),
        if (n > 0)
          Positioned(
            top: -1,
            right: -1,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: AppColors.danger,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.background, width: 1.5),
              ),
            ),
          ),
      ]),
    );
  }
}
