import 'package:flutter/material.dart';

/// Curated color palette for the Autonion Agent dark theme.
class AppColors {
  AppColors._();

  // ── Backgrounds ──────────────────────────────────────────
  static const background = Color(0xFF0A0E1A);
  static const surface = Color(0xFF141928);
  static const surfaceVariant = Color(0xFF1C2237);
  static const surfaceElevated = Color(0xFF232940);

  // ── Primary / Accent ─────────────────────────────────────
  static const primary = Color(0xFF4F8CFF);
  static const primaryLight = Color(0xFF7AABFF);
  static const secondary = Color(0xFF00D4FF);
  static const accent = Color(0xFF7C5CFF);

  // ── Status ───────────────────────────────────────────────
  static const success = Color(0xFF00E676);
  static const warning = Color(0xFFFFAB40);
  static const error = Color(0xFFFF5252);

  // ── Text ─────────────────────────────────────────────────
  static const textPrimary = Color(0xFFE8ECF4);
  static const textSecondary = Color(0xFF8B95B0);
  static const textMuted = Color(0xFF5A6380);

  // ── Borders / Dividers ───────────────────────────────────
  static const border = Color(0xFF2A3150);
  static const divider = Color(0xFF1E2540);

  // ── Glassmorphism ────────────────────────────────────────
  static const glassBackground = Color(0x1AFFFFFF); // 10% white
  static const glassBorder = Color(0x33FFFFFF);      // 20% white

  // ── Gradients ────────────────────────────────────────────
  static const gradientStart = Color(0xFF0D1225);
  static const gradientEnd = Color(0xFF1A1040);

  static const LinearGradient backgroundGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [gradientStart, gradientEnd],
  );

  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primary, secondary],
  );

  static const LinearGradient accentGradient = LinearGradient(
    colors: [accent, primary],
  );
}
