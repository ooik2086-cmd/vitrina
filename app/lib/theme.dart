import 'package:flutter/material.dart';

/// Visual system: quiet off-white canvas so products carry the colour, ink-black type and actions,
/// one warm accent for prices and calls to action. Inter covers Kazakh Cyrillic and the ₸ sign.
abstract final class Brand {
  static const ink = Color(0xFF0E0E10);
  static const accent = Color(0xFFFF5A36);
  static const canvasLight = Color(0xFFF5F4F1);
  static const canvasDark = Color(0xFF0C0C0E);
  static const studio = Color(0xFFF3F2EF); // product photo backdrop
  static const radius = 20.0;
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: Brand.accent,
    brightness: brightness,
  ).copyWith(
    primary: dark ? Colors.white : Brand.ink,
    onPrimary: dark ? Brand.ink : Colors.white,
    secondary: Brand.accent,
    onSecondary: Colors.white,
    surface: dark ? const Color(0xFF151518) : Colors.white,
    surfaceContainerLowest: dark ? Brand.canvasDark : Brand.canvasLight,
    surfaceContainerHighest: dark ? const Color(0xFF232327) : const Color(0xFFECEBE7),
    outlineVariant: dark ? const Color(0xFF2A2A2F) : const Color(0xFFE4E2DD),
  );
  final base = ThemeData(useMaterial3: true, brightness: brightness, colorScheme: scheme, fontFamily: 'Inter');
  final text = _withWeights(base.textTheme).copyWith(
    headlineMedium: _w(base.textTheme.headlineMedium!, 750).copyWith(letterSpacing: -0.8),
    headlineSmall: _w(base.textTheme.headlineSmall!, 750).copyWith(letterSpacing: -0.6),
    titleLarge: _w(base.textTheme.titleLarge!, 700).copyWith(letterSpacing: -0.4),
    titleMedium: _w(base.textTheme.titleMedium!, 650).copyWith(letterSpacing: -0.2),
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surfaceContainerLowest,
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surface,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Brand.radius),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 54),
        shape: shape,
        textStyle: _w(text.labelLarge!, 650).copyWith(fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 54),
        shape: shape,
        side: BorderSide(color: scheme.outlineVariant),
        textStyle: _w(text.labelLarge!, 600).copyWith(fontSize: 16),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: scheme.outlineVariant),
      backgroundColor: scheme.surface,
      selectedColor: scheme.primary,
      secondarySelectedColor: scheme.primary,
      checkmarkColor: scheme.onPrimary,
      labelStyle: _w(text.labelLarge!, 550).copyWith(color: scheme.onSurface),
      secondaryLabelStyle: _w(text.labelLarge!, 600).copyWith(color: scheme.onPrimary),
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: scheme.outlineVariant)),
      enabledBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: scheme.outlineVariant)),
      focusedBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: scheme.primary, width: 1.5)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primary,
      height: 68,
      iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? scheme.onPrimary : scheme.onSurfaceVariant)),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => _w(text.labelSmall!, s.contains(WidgetState.selected) ? 650 : 500)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? scheme.primary : scheme.surface),
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? scheme.onPrimary : scheme.onSurface),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
        minimumSize: const WidgetStatePropertyAll(Size(64, 46)),
        textStyle: WidgetStatePropertyAll(_w(text.labelLarge!, 600)),
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      showDragHandle: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 20)),
  );
}

/// Inter ships as one variable font; map each style's weight onto the 'wght' axis.
TextStyle _w(TextStyle s, double weight) => s.copyWith(
      fontWeight: FontWeight.values[((weight / 100).round() - 1).clamp(0, 8)],
      fontVariations: [FontVariation('wght', weight)],
    );

TextTheme _withWeights(TextTheme t) {
  TextStyle? apply(TextStyle? s) => s == null ? null : _w(s, ((s.fontWeight ?? FontWeight.w400).value).toDouble());
  return t.copyWith(
    displayLarge: apply(t.displayLarge),
    displayMedium: apply(t.displayMedium),
    displaySmall: apply(t.displaySmall),
    headlineLarge: apply(t.headlineLarge),
    headlineMedium: apply(t.headlineMedium),
    headlineSmall: apply(t.headlineSmall),
    titleLarge: apply(t.titleLarge),
    titleMedium: apply(t.titleMedium),
    titleSmall: apply(t.titleSmall),
    bodyLarge: apply(t.bodyLarge),
    bodyMedium: apply(t.bodyMedium),
    bodySmall: apply(t.bodySmall),
    labelLarge: apply(t.labelLarge),
    labelMedium: apply(t.labelMedium),
    labelSmall: apply(t.labelSmall),
  );
}

/// Bold weight helper for one-off emphasis (prices, badges).
TextStyle weight(TextStyle s, double w) => _w(s, w);
