// Adapted from PiliPlus lib/utils/theme_utils.dart::getThemeData and
// lib/common/style.dart, commit d9e9626f1a3f89cd9ca85e18f61aaba02634e12a.
// Original source: https://github.com/bggRGjQaUbCoE/PiliPlus (GNU GPL v3).
import 'dart:async';

import 'package:flutter/material.dart';

import '../storage/app_storage.dart';

class AppAppearance extends ChangeNotifier {
  static const defaultSeedColor = 0xFFE57373;

  AppAppearance(this.storage) {
    _load();
  }

  final AppStorage storage;
  ThemeMode _themeMode = ThemeMode.system;
  Color _seedColor = const Color(defaultSeedColor);
  double _textScale = 1;
  String? error;

  void reload() {
    _load();
    notifyListeners();
  }

  void _load() {
    final settings = storage.state['settings'] as Map;
    final value = settings['appearance'] as Map? ?? const {};
    final mode = value['themeMode'] ?? 'system';
    _themeMode = ThemeMode.values.firstWhere((item) => item.name == mode);
    final color = value['seedColor'] ?? defaultSeedColor;
    final scale = value['textScale'] ?? 1;
    if (color is! int || color < 0 || color > 0xFFFFFFFF ||
        scale is! num || !scale.isFinite || scale < 0.8 || scale > 1.5) {
      throw const FormatException('外观设置无效，请恢复有效备份');
    }
    _seedColor = Color(color);
    _textScale = scale.toDouble();
  }

  Future<void> _save(Map<String, dynamic> changes) async {
    try {
      await storage.transaction((state) {
        final settings = state['settings'] as Map;
        final appearance = Map<String, dynamic>.from(
          settings['appearance'] as Map? ?? const {},
        );
        settings['appearance'] = appearance..addAll(changes);
      });
      _load();
      error = null;
    } catch (_) {
      error = '设置保存失败，原设置已保留';
    }
    notifyListeners();
  }

  ThemeMode get themeMode => _themeMode;
  Color get seedColor => _seedColor;
  double get textScale => _textScale;

  set themeMode(ThemeMode value) {
    if (_themeMode == value) return;
    unawaited(_save({'themeMode': value.name}));
  }

  set seedColor(Color value) {
    if (_seedColor == value) return;
    unawaited(_save({'seedColor': value.toARGB32()}));
  }

  set textScale(double value) {
    if (!value.isFinite || value < 0.8 || value > 1.5) {
      throw RangeError.value(
        value,
        'textScale',
        'Expected a finite value from 0.8 to 1.5',
      );
    }
    if (_textScale == value) return;
    unawaited(_save({'textScale': value}));
  }
}

ThemeData getThemeData({
  required Color seedColor,
  required Brightness brightness,
}) {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
  );
  final isDark = brightness == Brightness.dark;
  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    appBarTheme: AppBarTheme(
      elevation: 0,
      titleSpacing: 16,
      centerTitle: false,
      scrolledUnderElevation: 0,
      backgroundColor: colorScheme.surface,
      titleTextStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.normal,
        color: colorScheme.onSurface,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      surfaceTintColor: isDark ? colorScheme.surfaceContainerHighest : null,
    ),
    snackBarTheme: SnackBarThemeData(
      elevation: 20,
      actionTextColor: colorScheme.primary,
      closeIconColor: colorScheme.secondary,
      backgroundColor: colorScheme.secondaryContainer,
      contentTextStyle: TextStyle(color: colorScheme.onSecondaryContainer),
    ),
    popupMenuTheme: PopupMenuThemeData(
      surfaceTintColor: isDark ? colorScheme.surfaceContainerHighest : null,
    ),
    cardTheme: CardThemeData(
      elevation: 1,
      margin: EdgeInsets.zero,
      shadowColor: Colors.transparent,
      surfaceTintColor: isDark ? colorScheme.onSurfaceVariant : null,
    ),
    dialogTheme: DialogThemeData(
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.normal,
        color: colorScheme.onSurface,
      ),
      backgroundColor: colorScheme.surface,
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 420),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
    ),
    tooltipTheme: const TooltipThemeData(
      textStyle: TextStyle(fontSize: 14, color: Colors.white),
      decoration: BoxDecoration(
        color: Color(0xE6616161),
        borderRadius: BorderRadius.all(Radius.circular(4)),
      ),
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: Border(),
      collapsedShape: Border(),
    ),
    listTileTheme: const ListTileThemeData(
      controlAffinity: ListTileControlAffinity.leading,
    ),
    filledButtonTheme: const FilledButtonThemeData(
      style: ButtonStyle(
        shadowColor: WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
  );
}
