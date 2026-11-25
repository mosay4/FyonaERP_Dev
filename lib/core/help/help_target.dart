import 'package:flutter/widgets.dart';

/// Hit-test tag carried by [HelpTarget].
@immutable
class HelpTargetTag {
  final String id;
  const HelpTargetTag(this.id);

  @override
  bool operator ==(Object other) => other is HelpTargetTag && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Explicitly registers [child] for the Information Clicker under [id]
/// (an id listed in a `HelpEntry.ids`).
///
/// Most elements need no wrapper: buttons, menu items, tabs, chips and list
/// actions are found automatically from what they show (label key, tooltip,
/// icon). Use [HelpTarget] only where that is ambiguous — e.g. two identical
/// icon buttons with different jobs on one screen, or a non-button card that
/// deserves an explanation.
///
/// The wrapper adds no gesture of its own: taps, drags and native long
/// presses of [child] are untouched. When [child] contains a button, the
/// ring wraps that button exactly; otherwise it wraps [child].
class HelpTarget extends StatelessWidget {
  final String id;
  final Widget child;
  const HelpTarget({super.key, required this.id, required this.child});

  @override
  Widget build(BuildContext context) {
    return MetaData(
      metaData: HelpTargetTag(id),
      behavior: HitTestBehavior.deferToChild,
      child: child,
    );
  }
}
