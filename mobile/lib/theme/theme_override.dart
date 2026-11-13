import 'package:flutter/material.dart';
import 'package:immich_mobile/theme/theme_data.dart';

/// A theme override as plugins describe it (`contributes.theme` and the `theme.set` host function):
///
/// ```json
/// { "seedColor": "#FF4150AF", "variant": "fidelity", "contrast": 0.0,
///   "light": { "primary": "#FF4150AF", "surface": "#FFFFFFFF" }, "dark": { "primary": "#FFACCBFA" },
///   "fontFamily": "Roboto", "mode": "dark" }
/// ```
///
/// Every field is optional. Colors are `#AARRGGBB`, `#RRGGBB`, `#RGB`, `0xAARRGGBB` or an ARGB int. Color keys are
/// [ColorScheme] field names ([colorSchemeTokens]). Pure data: no plugin or kernel dependency.
@immutable
class ThemeOverrideSpec {
  /// Replaces the app's color preset (both brightnesses) with a scheme generated from this color.
  final Color? seedColor;

  /// Scheme generation variant used with [seedColor] (`tonalSpot`, `fidelity`, `neutral`, ...).
  final DynamicSchemeVariant? variant;

  /// Contrast level used with [seedColor], -1.0 to 1.0.
  final double? contrast;

  /// Per-token overrides of the light scheme, applied last.
  final Map<String, Color> light;

  /// Per-token overrides of the dark scheme, applied last.
  final Map<String, Color> dark;

  /// Font family for the whole app (an app font or one loaded from a plugin with [fonts]).
  final String? fontFamily;

  /// Font files to load at runtime: family name -> file path (a plugin path is resolved by the caller).
  final Map<String, String> fonts;

  /// Forces light, dark or system mode.
  final ThemeMode? mode;

  const ThemeOverrideSpec({
    this.seedColor,
    this.variant,
    this.contrast,
    this.light = const {},
    this.dark = const {},
    this.fontFamily,
    this.fonts = const {},
    this.mode,
  });

  static const empty = ThemeOverrideSpec();

  bool get isEmpty =>
      seedColor == null &&
      variant == null &&
      contrast == null &&
      light.isEmpty &&
      dark.isEmpty &&
      fontFamily == null &&
      fonts.isEmpty &&
      mode == null;

  factory ThemeOverrideSpec.fromJson(Object? json) {
    if (json is! Map) {
      return empty;
    }
    final seed = parseThemeColor(json['seedColor']);
    return ThemeOverrideSpec(
      seedColor: seed == null ? null : Color(seed),
      variant: _variant(json['variant']),
      contrast: json['contrast'] is num ? (json['contrast'] as num).toDouble().clamp(-1.0, 1.0) : null,
      light: _colors(json['light']),
      dark: _colors(json['dark']),
      fontFamily: json['fontFamily'] is String && (json['fontFamily'] as String).isNotEmpty
          ? json['fontFamily'] as String
          : null,
      fonts: {
        if (json['fonts'] is Map)
          for (final MapEntry(:key, :value) in (json['fonts'] as Map).entries)
            if (value is String && value.isNotEmpty) '$key': value,
      },
      mode: switch (json['mode']) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => null,
      },
    );
  }

  Map<String, dynamic> toJson() => {
    if (seedColor != null) 'seedColor': themeColorToHex(seedColor!),
    if (variant != null) 'variant': variant!.name,
    if (contrast != null) 'contrast': contrast,
    if (light.isNotEmpty) 'light': {for (final e in light.entries) e.key: themeColorToHex(e.value)},
    if (dark.isNotEmpty) 'dark': {for (final e in dark.entries) e.key: themeColorToHex(e.value)},
    if (fontFamily != null) 'fontFamily': fontFamily,
    if (fonts.isNotEmpty) 'fonts': fonts,
    if (mode != null) 'mode': mode!.name,
  };

  /// [other] wins per key; color maps merge per token.
  ThemeOverrideSpec merge(ThemeOverrideSpec other) {
    if (other.isEmpty) {
      return this;
    }
    if (isEmpty) {
      return other;
    }
    return ThemeOverrideSpec(
      seedColor: other.seedColor ?? seedColor,
      variant: other.variant ?? variant,
      contrast: other.contrast ?? contrast,
      light: {...light, ...other.light},
      dark: {...dark, ...other.dark},
      fontFamily: other.fontFamily ?? fontFamily,
      fonts: {...fonts, ...other.fonts},
      mode: other.mode ?? mode,
    );
  }

  /// Merges in order; later entries win.
  static ThemeOverrideSpec mergeAll(Iterable<ThemeOverrideSpec> specs) =>
      specs.fold(empty, (merged, spec) => merged.merge(spec));

  /// Step 1 (before the app's surface decoloring): replaces the preset with a scheme generated from [seedColor].
  ImmichTheme applySeed(ImmichTheme base) {
    final seed = seedColor;
    if (seed == null) {
      return base;
    }
    final schemeVariant = variant ?? DynamicSchemeVariant.tonalSpot;
    final level = contrast ?? 0.0;
    return ImmichTheme(
      light: ColorScheme.fromSeed(seedColor: seed, dynamicSchemeVariant: schemeVariant, contrastLevel: level),
      dark: ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.dark,
        dynamicSchemeVariant: schemeVariant,
        contrastLevel: level,
      ),
    );
  }

  /// Step 2 (last): per-token color overrides.
  ImmichTheme applyColors(ImmichTheme base) {
    if (light.isEmpty && dark.isEmpty) {
      return base;
    }
    return ImmichTheme(light: applyColorTokens(base.light, light), dark: applyColorTokens(base.dark, dark));
  }

  /// Both steps, for callers that do not decolor surfaces in between.
  ImmichTheme apply(ImmichTheme base) => applyColors(applySeed(base));

  @override
  bool operator ==(Object other) =>
      other is ThemeOverrideSpec &&
      other.seedColor == seedColor &&
      other.variant == variant &&
      other.contrast == contrast &&
      _mapEquals(other.light, light) &&
      _mapEquals(other.dark, dark) &&
      other.fontFamily == fontFamily &&
      _mapEquals(other.fonts, fonts) &&
      other.mode == mode;

  @override
  int get hashCode => Object.hash(
    seedColor,
    variant,
    contrast,
    Object.hashAllUnordered(light.entries.map((e) => Object.hash(e.key, e.value))),
    Object.hashAllUnordered(dark.entries.map((e) => Object.hash(e.key, e.value))),
    fontFamily,
    Object.hashAllUnordered(fonts.entries.map((e) => Object.hash(e.key, e.value))),
    mode,
  );

  static bool _mapEquals<V>(Map<String, V> a, Map<String, V> b) {
    if (a.length != b.length) {
      return false;
    }
    for (final MapEntry(:key, :value) in a.entries) {
      if (!b.containsKey(key) || b[key] != value) {
        return false;
      }
    }
    return true;
  }

  static Map<String, Color> _colors(Object? json) {
    if (json is! Map) {
      return const {};
    }
    final colors = <String, Color>{};
    for (final MapEntry(:key, :value) in json.entries) {
      final color = parseThemeColor(value);
      if (color != null && colorSchemeTokens.contains('$key')) {
        colors['$key'] = Color(color);
      }
    }
    return colors;
  }

  static DynamicSchemeVariant? _variant(Object? value) {
    for (final variant in DynamicSchemeVariant.values) {
      if (variant.name == value) {
        return variant;
      }
    }
    return null;
  }
}

/// Parses `#AARRGGBB`, `#RRGGBB`, `#RGB`, `0xAARRGGBB` or an ARGB int.
int? parseThemeColor(Object? value) {
  if (value is int) {
    return value & 0xFFFFFFFF;
  }
  if (value is! String) {
    return null;
  }
  var text = value.trim();
  if (text.startsWith('#')) {
    text = text.substring(1);
  } else if (text.toLowerCase().startsWith('0x')) {
    text = text.substring(2);
  } else {
    return null;
  }
  if (text.length == 3) {
    text = text.split('').map((c) => '$c$c').join();
  }
  if (text.length == 6) {
    text = 'FF$text';
  }
  return text.length == 8 ? int.tryParse(text, radix: 16) : null;
}

String themeColorToHex(Color color) => '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

/// [ColorScheme] tokens plugins can read and override.
const colorSchemeTokens = {
  'primary',
  'onPrimary',
  'primaryContainer',
  'onPrimaryContainer',
  'primaryFixed',
  'primaryFixedDim',
  'onPrimaryFixed',
  'onPrimaryFixedVariant',
  'secondary',
  'onSecondary',
  'secondaryContainer',
  'onSecondaryContainer',
  'secondaryFixed',
  'secondaryFixedDim',
  'onSecondaryFixed',
  'onSecondaryFixedVariant',
  'tertiary',
  'onTertiary',
  'tertiaryContainer',
  'onTertiaryContainer',
  'tertiaryFixed',
  'tertiaryFixedDim',
  'onTertiaryFixed',
  'onTertiaryFixedVariant',
  'error',
  'onError',
  'errorContainer',
  'onErrorContainer',
  'surface',
  'onSurface',
  'surfaceDim',
  'surfaceBright',
  'surfaceContainerLowest',
  'surfaceContainerLow',
  'surfaceContainer',
  'surfaceContainerHigh',
  'surfaceContainerHighest',
  'onSurfaceVariant',
  'outline',
  'outlineVariant',
  'shadow',
  'scrim',
  'inverseSurface',
  'onInverseSurface',
  'inversePrimary',
  'surfaceTint',
};

/// Applies per-token overrides ([colorSchemeTokens] names) to [scheme].
ColorScheme applyColorTokens(ColorScheme scheme, Map<String, Color> colors) {
  if (colors.isEmpty) {
    return scheme;
  }
  Color? c(String token) => colors[token];
  return scheme.copyWith(
    primary: c('primary'),
    onPrimary: c('onPrimary'),
    primaryContainer: c('primaryContainer'),
    onPrimaryContainer: c('onPrimaryContainer'),
    primaryFixed: c('primaryFixed'),
    primaryFixedDim: c('primaryFixedDim'),
    onPrimaryFixed: c('onPrimaryFixed'),
    onPrimaryFixedVariant: c('onPrimaryFixedVariant'),
    secondary: c('secondary'),
    onSecondary: c('onSecondary'),
    secondaryContainer: c('secondaryContainer'),
    onSecondaryContainer: c('onSecondaryContainer'),
    secondaryFixed: c('secondaryFixed'),
    secondaryFixedDim: c('secondaryFixedDim'),
    onSecondaryFixed: c('onSecondaryFixed'),
    onSecondaryFixedVariant: c('onSecondaryFixedVariant'),
    tertiary: c('tertiary'),
    onTertiary: c('onTertiary'),
    tertiaryContainer: c('tertiaryContainer'),
    onTertiaryContainer: c('onTertiaryContainer'),
    tertiaryFixed: c('tertiaryFixed'),
    tertiaryFixedDim: c('tertiaryFixedDim'),
    onTertiaryFixed: c('onTertiaryFixed'),
    onTertiaryFixedVariant: c('onTertiaryFixedVariant'),
    error: c('error'),
    onError: c('onError'),
    errorContainer: c('errorContainer'),
    onErrorContainer: c('onErrorContainer'),
    surface: c('surface'),
    onSurface: c('onSurface'),
    surfaceDim: c('surfaceDim'),
    surfaceBright: c('surfaceBright'),
    surfaceContainerLowest: c('surfaceContainerLowest'),
    surfaceContainerLow: c('surfaceContainerLow'),
    surfaceContainer: c('surfaceContainer'),
    surfaceContainerHigh: c('surfaceContainerHigh'),
    surfaceContainerHighest: c('surfaceContainerHighest'),
    onSurfaceVariant: c('onSurfaceVariant'),
    outline: c('outline'),
    outlineVariant: c('outlineVariant'),
    shadow: c('shadow'),
    scrim: c('scrim'),
    inverseSurface: c('inverseSurface'),
    onInverseSurface: c('onInverseSurface'),
    inversePrimary: c('inversePrimary'),
    surfaceTint: c('surfaceTint'),
  );
}

/// Every [colorSchemeTokens] value of [scheme] as `#AARRGGBB`, for `theme.get` and native views.
Map<String, String> colorSchemeToJson(ColorScheme s) => {
  'primary': themeColorToHex(s.primary),
  'onPrimary': themeColorToHex(s.onPrimary),
  'primaryContainer': themeColorToHex(s.primaryContainer),
  'onPrimaryContainer': themeColorToHex(s.onPrimaryContainer),
  'primaryFixed': themeColorToHex(s.primaryFixed),
  'primaryFixedDim': themeColorToHex(s.primaryFixedDim),
  'onPrimaryFixed': themeColorToHex(s.onPrimaryFixed),
  'onPrimaryFixedVariant': themeColorToHex(s.onPrimaryFixedVariant),
  'secondary': themeColorToHex(s.secondary),
  'onSecondary': themeColorToHex(s.onSecondary),
  'secondaryContainer': themeColorToHex(s.secondaryContainer),
  'onSecondaryContainer': themeColorToHex(s.onSecondaryContainer),
  'secondaryFixed': themeColorToHex(s.secondaryFixed),
  'secondaryFixedDim': themeColorToHex(s.secondaryFixedDim),
  'onSecondaryFixed': themeColorToHex(s.onSecondaryFixed),
  'onSecondaryFixedVariant': themeColorToHex(s.onSecondaryFixedVariant),
  'tertiary': themeColorToHex(s.tertiary),
  'onTertiary': themeColorToHex(s.onTertiary),
  'tertiaryContainer': themeColorToHex(s.tertiaryContainer),
  'onTertiaryContainer': themeColorToHex(s.onTertiaryContainer),
  'tertiaryFixed': themeColorToHex(s.tertiaryFixed),
  'tertiaryFixedDim': themeColorToHex(s.tertiaryFixedDim),
  'onTertiaryFixed': themeColorToHex(s.onTertiaryFixed),
  'onTertiaryFixedVariant': themeColorToHex(s.onTertiaryFixedVariant),
  'error': themeColorToHex(s.error),
  'onError': themeColorToHex(s.onError),
  'errorContainer': themeColorToHex(s.errorContainer),
  'onErrorContainer': themeColorToHex(s.onErrorContainer),
  'surface': themeColorToHex(s.surface),
  'onSurface': themeColorToHex(s.onSurface),
  'surfaceDim': themeColorToHex(s.surfaceDim),
  'surfaceBright': themeColorToHex(s.surfaceBright),
  'surfaceContainerLowest': themeColorToHex(s.surfaceContainerLowest),
  'surfaceContainerLow': themeColorToHex(s.surfaceContainerLow),
  'surfaceContainer': themeColorToHex(s.surfaceContainer),
  'surfaceContainerHigh': themeColorToHex(s.surfaceContainerHigh),
  'surfaceContainerHighest': themeColorToHex(s.surfaceContainerHighest),
  'onSurfaceVariant': themeColorToHex(s.onSurfaceVariant),
  'outline': themeColorToHex(s.outline),
  'outlineVariant': themeColorToHex(s.outlineVariant),
  'shadow': themeColorToHex(s.shadow),
  'scrim': themeColorToHex(s.scrim),
  'inverseSurface': themeColorToHex(s.inverseSurface),
  'onInverseSurface': themeColorToHex(s.onInverseSurface),
  'inversePrimary': themeColorToHex(s.inversePrimary),
  'surfaceTint': themeColorToHex(s.surfaceTint),
};
