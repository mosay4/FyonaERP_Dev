import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_colors.dart';

/// Requires the user to press the system back button TWICE to leave the app.
///
/// The first press only shows a floating «press back again to exit» warning;
/// a second press within [window] actually exits. Used on the app's entry
/// screens (login, splash, …) so the behaviour is identical on every device
/// and Android version.
class DoubleBackToExit extends StatefulWidget {
  const DoubleBackToExit({
    super.key,
    required this.child,
    this.window = const Duration(seconds: 2),
  });

  final Widget child;
  final Duration window;

  @override
  State<DoubleBackToExit> createState() => _DoubleBackToExitState();
}

class _DoubleBackToExitState extends State<DoubleBackToExit> {
  DateTime? _lastBackPress;

  void _onBack() {
    final now = DateTime.now();
    final last = _lastBackPress;
    if (last != null && now.difference(last) < widget.window) {
      SystemNavigator.pop();
      return;
    }
    _lastBackPress = now;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).pressBackAgainToExit,
              style: const TextStyle(fontFamily: 'Cairo')),
          backgroundColor: AppColors.danger,
          behavior: SnackBarBehavior.floating,
          duration: widget.window,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _onBack();
      },
      child: widget.child,
    );
  }
}
