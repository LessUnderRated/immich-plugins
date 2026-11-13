import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/plugin_theme.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/theme/color_scheme.dart';
import 'package:immich_mobile/theme/dynamic_theme.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:immich_mobile/theme/theme_override.dart';

/// Theme overrides from plugins (`contributes.theme` and the `theme.set` host function).
final pluginThemeProvider = ChangeNotifierProvider<PluginThemeController>((ref) => pluginThemeController);

/// The merged plugin theme override; empty while no plugin overrides the theme.
final pluginThemeOverrideProvider = Provider<ThemeOverrideSpec>(
  (ref) => ref.watch(pluginThemeProvider.select((controller) => controller.effective)),
);

// Provider for current selected theme
final immichThemeProvider = StateProvider<ImmichTheme>((ref) {
  final themeConfig = ref.watch(appConfigProvider.select((config) => config.theme));
  final pluginOverride = ref.watch(pluginThemeOverrideProvider);

  final ImmichTheme? dynamicTheme = DynamicTheme.theme;
  final currentTheme = pluginOverride.applySeed(
    (themeConfig.dynamicTheme && dynamicTheme != null) ? dynamicTheme : themeConfig.primaryColor.themeOfPreset,
  );

  return pluginOverride.applyColors(
    themeConfig.colorfulInterface ? currentTheme : decolorizeSurfaces(theme: currentTheme),
  );
});

/// The theme mode: the user's setting unless a plugin forces one.
final immichThemeModeProvider = Provider<ThemeMode>((ref) {
  final mode = ref.watch(pluginThemeOverrideProvider.select((spec) => spec.mode));
  return mode ?? ref.watch(appConfigProvider.select((config) => config.theme.mode));
});

/// The font family a plugin set for the whole app, if any.
final immichFontFamilyProvider = Provider<String?>(
  (ref) => ref.watch(pluginThemeOverrideProvider.select((spec) => spec.fontFamily)),
);
