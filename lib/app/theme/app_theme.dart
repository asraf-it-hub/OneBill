import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

abstract final class OneBillTheme {
  static final light = ThemeData(
    useMaterial3: true,
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
      },
    ),
    splashFactory: InkSparkle.splashFactory,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF126E5D),
      brightness: Brightness.light,
    ),
    scaffoldBackgroundColor: const Color(0xFFF8FAF9),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    cardTheme: const CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
  );
}
