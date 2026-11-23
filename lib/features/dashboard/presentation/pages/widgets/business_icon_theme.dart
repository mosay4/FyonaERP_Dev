import 'package:flutter/material.dart';

/// Exact icon colors sampled from the approved PDF design
/// (`FYONA_Main_Screen.pdf`): the crimson glyph fill and the light-pink chip.
/// Kept local to the business widgets so the personal section's palette is
/// never affected. Both adapt to Dark Mode (dark surfaces, lightened glyph)
/// without changing any glyph shapes.
Color bizIconChip(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF3B151D)
    : const Color(0xFFECE7EA);

Color bizIconRed(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFFE79FB0)
    : const Color(0xFF8C162C);
