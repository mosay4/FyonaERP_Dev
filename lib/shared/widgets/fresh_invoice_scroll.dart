import 'package:flutter/material.dart';

/// Post-issue flow of the sale / purchase invoice pages («بيع جديد» /
/// «شراء جديد» must reopen the empty invoice at the TOP, customer/supplier
/// first).
///
/// Why a plain `animateTo(0)` was not enough: the merchant usually types the
/// paid amount in a field at the BOTTOM of the form and then taps «إصدار».
/// That text field keeps focus while the success dialog is open; when the
/// dialog closes the page's focus scope RESTORES it, the field calls
/// `showOnScreen` (caret into view, keyboard back) and that scroll replaces
/// the glide to the top — the fresh invoice ends up scrolled to the end.
///
/// [showIssueResultDialog] drops that focus (and the scope's focus history)
/// before the dialog opens, and [glideFreshInvoiceToTop] glides again whenever
/// a late scroll (focus restore, keyboard inset, extent clamp) interrupts it,
/// so the fresh invoice can never be left at the end.
Future<T?> showIssueResultDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showDialog<T>(
    context: context,
    barrierDismissible: false,
    builder: builder,
  );
}

/// Smoothly returns [controller] to the top of a freshly reset invoice.
void glideFreshInvoiceToTop(
  ScrollController controller, {
  required bool Function() isMounted,
  Duration duration = const Duration(milliseconds: 420),
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  // Frame-driven (no timers): if anything interrupts the glide (a late
  // focus restore, keyboard inset, extent clamp) it simply glides again on
  // the next frame, a few times at most.
  var attempts = 0;
  var gliding = false;
  void glide() {
    if (gliding || !isMounted() || !controller.hasClients || attempts >= 4) {
      return;
    }
    final position = controller.position;
    if (position.pixels <= position.minScrollExtent) return;
    attempts++;
    gliding = true;
    position
        .animateTo(position.minScrollExtent,
            duration: duration, curve: Curves.easeOutCubic)
        .whenComplete(() {
      gliding = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => glide());
    });
  }

  glide();
  // Again once the reset form is laid out / the dialog started leaving.
  WidgetsBinding.instance.addPostFrameCallback((_) => glide());
}
