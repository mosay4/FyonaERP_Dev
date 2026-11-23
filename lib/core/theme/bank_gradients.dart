import 'package:flutter/material.dart';

const bankGradients = [
  [Color(0xFFA01530), Color(0xFF7A1020)],
  [Color(0xFF7A1020), Color(0xFF5A0A12)],
  [Color(0xFFA01530), Color(0xFF5A0A12)],
  [Color(0xFFB82040), Color(0xFF7A1020)],
  [Color(0xFF8B1525), Color(0xFF5A0A12)],
  [Color(0xFFA01530), Color(0xFF7A1020)],
];

int bankGradientIndex(String name) => name.hashCode.abs() % bankGradients.length;
