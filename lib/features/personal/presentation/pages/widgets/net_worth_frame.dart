import 'package:flutter/material.dart';

import '../../../../../core/theme/app_colors.dart';

/// Reserved physical-left gutter (in logical pixels) the card / pill keep
/// free for the pinned collapse arrow.
const double kNetWorthArrowGutter = 48;

/// Size and inset of the pinned arrow.
const double kNetWorthArrowSize = 32;
const double kNetWorthArrowInset = 10;

/// Top padding of the open card: its 36 px header row is centred exactly on
/// the pinned arrow (10 + 32 / 2 = 8 + 36 / 2), like the folded pill.
const double kNetWorthCardTopPadding =
    kNetWorthArrowInset + kNetWorthArrowSize / 2 - 18;

/// Hosts the wealth card and its collapsed pill and pins ONE collapse arrow
/// at the card's physical top-left corner. The arrow lives outside the
/// expand/collapse switch so it never moves between the two states (it only
/// rotates), whatever the text direction.
class NetWorthFrame extends StatelessWidget {
  final bool expanded;
  final VoidCallback onToggle;
  final Widget expandedChild;
  final Widget collapsedChild;
  final String? tooltip;

  const NetWorthFrame({
    super.key,
    required this.expanded,
    required this.onToggle,
    required this.expandedChild,
    required this.collapsedChild,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 340),
          curve: Curves.easeInOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: [...previous, ?current],
            ),
            child: expanded ? expandedChild : collapsedChild,
          ),
        ),
        // Same spot in both states, inside the card / pill, centred on the
        // first row of each (see [kNetWorthCardTopPadding]).
        Positioned(
          left: kNetWorthArrowInset,
          top: kNetWorthArrowInset,
          child: NetWorthToggleArrow(
            key: const ValueKey('netWorthToggleArrow'),
            expanded: expanded,
            onTap: onToggle,
            tooltip: tooltip,
          ),
        ),
      ],
    );
  }
}

/// Solid, high-contrast round button: chevron up while the card is open
/// (tap to fold), down while folded (tap to open).
class NetWorthToggleArrow extends StatelessWidget {
  final bool expanded;
  final VoidCallback onTap;
  final String? tooltip;
  const NetWorthToggleArrow({
    super.key,
    required this.expanded,
    required this.onTap,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    Widget btn = Material(
      color: AppColors.primary,
      shape: const CircleBorder(),
      elevation: 1.5,
      shadowColor: AppColors.primary.withAlpha(90),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: kNetWorthArrowSize,
          height: kNetWorthArrowSize,
          child: AnimatedRotation(
            turns: expanded ? 0.5 : 0.0,
            duration: const Duration(milliseconds: 340),
            curve: Curves.easeInOutCubic,
            child: const Icon(Icons.keyboard_arrow_down_rounded,
                size: 22, color: Colors.white),
          ),
        ),
      ),
    );
    if (tooltip != null && tooltip!.isNotEmpty) {
      btn = Tooltip(message: tooltip!, child: btn);
    }
    return btn;
  }
}
