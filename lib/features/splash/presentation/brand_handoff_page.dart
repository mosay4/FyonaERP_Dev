import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// One-shot "handoff" signal from the branded entry screens (splash /
/// account entry) to the first app screen they open.
///
/// The entry screen arms it right before navigating; the next
/// [BrandHandoffPage] route created within [_window] consumes it and enters
/// with a calm fade + slight scale crossfade instead of the platform slide.
/// Routes created later (normal in-app navigation) keep the default look.
class BrandEntryHandoff {
  BrandEntryHandoff._();

  static const Duration _window = Duration(milliseconds: 1500);
  static DateTime? _armedAt;

  static void arm() => _armedAt = DateTime.now();

  /// True once (and clears) when armed within the last [_window].
  static bool consume() {
    final at = _armedAt;
    _armedAt = null;
    return at != null && DateTime.now().difference(at) <= _window;
  }

  @visibleForTesting
  static bool get isArmed => _armedAt != null;

  @visibleForTesting
  static void reset() => _armedAt = null;
}

/// Page used by the router for the screens that follow the entry screens
/// (login, re-entry, account entry, the main shell). Identical to a
/// MaterialPage unless [BrandEntryHandoff] was armed when its route is
/// created — then it fades/scales in over the branded entry screen.
class BrandHandoffPage<T> extends Page<T> {
  const BrandHandoffPage({
    required this.child,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
  });

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) =>
      BrandHandoffRoute<T>(this, handoff: BrandEntryHandoff.consume());
}

/// go_router `pageBuilder` helper: same key/name/arguments as go_router's
/// default MaterialPage, so route identity and state are unchanged.
BrandHandoffPage<void> brandHandoffPage(GoRouterState state, Widget child) =>
    BrandHandoffPage<void>(
      key: state.pageKey,
      name: state.name ?? state.path,
      arguments: <String, String>{
        ...state.pathParameters,
        ...state.uri.queryParameters,
      },
      restorationId: state.pageKey.value,
      child: child,
    );

class BrandHandoffRoute<T> extends PageRoute<T>
    with MaterialRouteTransitionMixin<T> {
  BrandHandoffRoute(BrandHandoffPage<T> page, {required this.handoff})
      : super(settings: page, allowSnapshotting: true);

  /// Whether this route entered from the branded entry screen.
  final bool handoff;

  static const Duration handoffDuration = Duration(milliseconds: 520);

  BrandHandoffPage<T> get _page => settings as BrandHandoffPage<T>;

  @override
  Widget buildContent(BuildContext context) => _page.child;

  @override
  bool get maintainState => true;

  @override
  bool get fullscreenDialog => false;

  @override
  Duration get transitionDuration =>
      handoff ? handoffDuration : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration =>
      handoff ? handoffDuration : super.reverseTransitionDuration;

  @override
  String get debugLabel => '${super.debugLabel}(${_page.name})';

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (!handoff) {
      return super.buildTransitions(
          context, animation, secondaryAnimation, child);
    }
    // Keep the platform's behaviour when another page is pushed ON TOP
    // (secondary animation); only the entrance itself is the crossfade.
    final settled = super.buildTransitions(
        context, kAlwaysCompleteAnimation, secondaryAnimation, child);
    final curve = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curve,
      child: ScaleTransition(
        scale: Tween<double>(begin: .97, end: 1).animate(curve),
        child: settled,
      ),
    );
  }
}
