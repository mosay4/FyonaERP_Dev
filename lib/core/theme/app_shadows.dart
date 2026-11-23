import 'package:flutter/material.dart';

class AppShadows {
  AppShadows._();

  static const BoxShadow card = BoxShadow(
    blurRadius: 20,
    color: Color(0x20000000),
    offset: Offset(0, 6),
  );

  static const BoxShadow elevated = BoxShadow(
    blurRadius: 30,
    color: Color(0x25000000),
    offset: Offset(0, 8),
  );

  static List<BoxShadow> get cardShadowList => [card];
  static List<BoxShadow> get elevatedShadowList => [elevated];
}
