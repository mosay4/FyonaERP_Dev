import 'package:flutter/material.dart';

class AppRadius {
  AppRadius._();

  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double full = 999;

  // Legacy compat
  static const double cardRadius = 12;
  static const double buttonRadius = 12;
  static const double inputRadius = 8;
  static const double badgeRadius = 8;

  static BorderRadius get smBorder => BorderRadius.circular(sm);
  static BorderRadius get mdBorder => BorderRadius.circular(md);
  static BorderRadius get lgBorder => BorderRadius.circular(lg);
  static BorderRadius get xlBorder => BorderRadius.circular(xl);
  static BorderRadius get fullBorder => BorderRadius.circular(full);
  static BorderRadius get cardBorder => BorderRadius.circular(cardRadius);
  static BorderRadius get buttonBorder => BorderRadius.circular(buttonRadius);
  static BorderRadius get inputBorder => BorderRadius.circular(inputRadius);
}
