import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:jplayer/resources/resources.dart';

abstract class Themes {
  /// Fallback app accent, matching the `AppSetting.accentColor` default.
  static const defaultAccent = Color(0xFFFD2F2F);

  /// Dark surface used for tooltip backgrounds so they don't inherit the
  /// tinted [BottomSheetThemeData] panel color used elsewhere in the app.
  static const tooltipSurface = Color(0xFF1C1518);

  static const tooltipDelay = Duration(milliseconds: 350);

  static const tooltipPadding = EdgeInsets.symmetric(
    horizontal: 10,
    vertical: 6,
  );

  static const tooltipTextStyle = TextStyle(
    color: Colors.white,
    fontSize: 13,
    height: 1.2,
  );

  static final tooltipDecoration = BoxDecoration(
    color: tooltipSurface,
    borderRadius: BorderRadius.circular(6),
    boxShadow: const [
      BoxShadow(
        color: Colors.black54,
        blurRadius: 8,
        offset: Offset(0, 2),
      ),
    ],
  );

  /// Dark, desaturated tone of [color], keeping its hue. Used for sheets,
  /// bars, chips and selected-item pills so surfaces tint toward the accent.
  static Color tone(
    Color color, {
    required double saturation,
    required double value,
  }) => HSVColor.fromColor(color)
      .withSaturation(saturation)
      .withValue(value)
      .toColor();

  static ThemeData? _cachedTheme;
  static Color? _cachedAccent;

  /// App theme built around [accent]; theme colors derived from the accent
  /// retint panels toward its hue. Cached per accent so rebuilds are cheap.
  static ThemeData withAccent(Color accent) {
    final cached = _cachedTheme;
    if (cached != null && _cachedAccent == accent) return cached;
    final panel = tone(accent, saturation: 0.56, value: 0.28);
    final chipBackground = tone(accent, saturation: 0.22, value: 0.21);

    final theme = ThemeData(
      useMaterial3: true,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      brightness: Brightness.dark,
      fontFamily: FontFamily.gilroy,
      colorScheme: ColorScheme.dark(
        primary: accent,
        onPrimary: Colors.white,
      ),
      scaffoldBackgroundColor: Colors.black,
      cupertinoOverrideTheme: NoDefaultCupertinoThemeData(
        primaryColor: Colors.white,
        primaryContrastingColor: accent,
        barBackgroundColor: panel,
        scaffoldBackgroundColor: Colors.black,
      ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Colors.black87,
      contentTextStyle: TextStyle(color: Colors.white),
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 4,
      overlayColor: Colors.transparent,
      thumbColor: Colors.white,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 16),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(38)),
      ),
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: panel,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: panel,
    ),
    chipTheme: ChipThemeData(
      labelPadding: const EdgeInsets.symmetric(horizontal: 11),
      backgroundColor: chipBackground,
      selectedColor: const Color(0xFF0066FF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      side: BorderSide.none,
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        foregroundColor: Colors.white,
        textStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: tooltipDecoration,
      textStyle: tooltipTextStyle,
      padding: tooltipPadding,
      waitDuration: tooltipDelay,
    ),
    );

    _cachedTheme = theme;
    _cachedAccent = accent;
    return theme;
  }
}
