import 'package:flutter/material.dart';

import 'tokens.dart';

abstract final class FlowTheme {
  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);
  static ThemeData _build(Brightness brightness) {
    final colors = ColorScheme.fromSeed(
      seedColor: FlowColors.blue,
      brightness: brightness,
    );
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(FlowRadius.control),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? FlowColors.dark
          : FlowColors.light,
      textTheme: const TextTheme(
        titleLarge: FlowTypography.title,
        bodyLarge: FlowTypography.body,
        labelLarge: FlowTypography.label,
      ),
      inputDecorationTheme: InputDecorationTheme(
        helperMaxLines: 4,
        errorMaxLines: 4,
        filled: true,
        border: border,
        enabledBorder: border.copyWith(
          borderSide: BorderSide(color: colors.outline),
        ),
        contentPadding: const EdgeInsets.all(FlowSpace.md),
      ),
      cardTheme: CardThemeData(
        elevation: 1,
        margin: const EdgeInsets.all(FlowSpace.sm),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(FlowRadius.card),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(FlowRadius.control),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(FlowRadius.control),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(FlowRadius.sheet),
          ),
        ),
      ),
    );
  }
}
