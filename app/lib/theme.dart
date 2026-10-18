import 'package:flutter/material.dart';

/// Visual system: quiet off-white canvas so products carry the colour, ink-black type and actions,
/// one warm accent for prices and calls to action. Inter covers Kazakh Cyrillic and the ₸ sign.
abstract final class Brand {
  static const ink = Color(0xFF0E0E10);
  static const accent = Color(0xFFFF5A36);

  /// The accent deep enough for white text on it and for accent text on a light canvas (4.6:1 with white).
  /// [accent] stays for icons, badges' dots and other decoration.
  static const accentStrong = Color(0xFFD93A17);
  static const canvasLight = Color(0xFFF5F4F1);
  static const canvasDark = Color(0xFF0C0C0E);
  static const studio = Color(0xFFF3F2EF); // product photo backdrop
  static const radius = 20.0;

  /// What every page stands on in the light theme: soft light from above, fading to a warm grey at the bottom,
  /// like a photo studio. Cards, fields and the tab bar are white on it.
  static const studioCanvas = BoxDecoration(
    gradient: RadialGradient(
      center: Alignment(0, -1.2),
      radius: 1.5,
      colors: [Color(0xFFFFFFFF), Color(0xFFF6F4F0), Color(0xFFEEEBE5)],
      stops: [0, 0.45, 1],
    ),
  );

  /// The dark theme's canvas: near-black with a faint warm light at the top.
  static const nightCanvas = BoxDecoration(
    gradient: RadialGradient(
      center: Alignment(0, -1.2),
      radius: 1.5,
      colors: [Color(0xFF26231F), Color(0xFF141416), canvasDark],
      stops: [0, 0.45, 1],
    ),
  );
}

/// Draws [canvas] behind every page, inside the platform's own page transition, so a page coming in covers the
/// one under it as before while every page shares the same backdrop. Scaffolds and app bars are see-through.
class OnCanvas extends PageTransitionsBuilder {
  const OnCanvas(this.inner, this.canvas);
  final PageTransitionsBuilder inner;
  final Decoration canvas;

  @override
  DelegatedTransitionBuilder? get delegatedTransition => inner.delegatedTransition;
  @override
  Duration get transitionDuration => inner.transitionDuration;
  @override
  Duration get reverseTransitionDuration => inner.reverseTransitionDuration;

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation, Widget child) =>
      inner.buildTransitions(
          route, context, animation, secondaryAnimation, DecoratedBox(decoration: canvas, child: child));
}

/// [canvas] replaces the page backdrop; only for trying other backdrops side by side.
ThemeData buildTheme(Brightness brightness, {Decoration? canvas}) {
  final dark = brightness == Brightness.dark;
  final page = canvas ?? (dark ? Brand.nightCanvas : Brand.studioCanvas);
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
    scaffoldBackgroundColor: Colors.transparent, // the canvas each page stands on shows through
    pageTransitionsTheme: PageTransitionsTheme(builders: {
      for (final e in const PageTransitionsTheme().builders.entries) e.key: OnCanvas(e.value, page),
    }),
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      // Sizes are only merged into the text theme later by MaterialApp, so give the title its full style here.
      titleTextStyle:
          _w(TextStyle(fontFamily: 'Inter', fontSize: 22, color: scheme.onSurface, letterSpacing: -0.4), 700),
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
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: scheme.outlineVariant)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: scheme.outlineVariant)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: scheme.primary, width: 1.5)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primary,
      height: 68,
      iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? scheme.onPrimary : scheme.onSurfaceVariant)),
      // The size is given here: base.textTheme carries no sizes yet (Theme.of adds them later), and without one
      // the labels took the 14 of body text, which split «Избранное» over two lines.
      labelTextStyle: WidgetStateProperty.resolveWith((s) =>
          _w(text.labelSmall!, s.contains(WidgetState.selected) ? 650 : 500).copyWith(fontSize: 12, height: 16 / 12)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor:
            WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.primary : scheme.surface),
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? scheme.onPrimary : scheme.onSurface),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
        minimumSize: const WidgetStatePropertyAll(Size(64, 46)),
        textStyle: WidgetStatePropertyAll(_w(text.labelLarge!, 600)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    popupMenuTheme: PopupMenuThemeData(color: scheme.surface, surfaceTintColor: Colors.transparent),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
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

/// Accent for text: the deeper shade on light screens, the bright one where the canvas is dark.
Color accentText(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? Brand.accent : Brand.accentStrong;

/// Bold weight helper for one-off emphasis (prices, badges).
TextStyle weight(TextStyle s, double w) => _w(s, w);
