// ignore_for_file: implementation_imports

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:easy_localization/src/translations.dart' as el;
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

/// Translation overrides from plugins: `contributes.strings` (merged by the kernel) and runtime overrides each plugin
/// sets with the `strings.set` host function.
///
/// Overrides are `locale -> key -> text`. A key is any translation key, nested keys with dots
/// (`errors.unable_to_add_album`); a text uses the same placeholders as the original (`{count}`, plural syntax).
/// Locale keys: `*` (every language), a language (`en`), a language with script or country (`zh_Hant`, `pt_BR`,
/// `-` works as well as `_`). More specific locales win; runtime overrides win over manifest ones.
class PluginStringOverrides extends ChangeNotifier {
  Map<String, Map<String, String>> _manifest = const {};
  final Map<String, Map<String, Map<String, String>>> _runtime = {};
  int _revision = 0;

  /// Increments on every change.
  int get revision => _revision;

  bool get isEmpty => _manifest.isEmpty && _runtime.isEmpty;

  Map<String, Map<String, String>> get manifest => _manifest;

  /// Runtime overrides of [plugin] (`locale -> key -> text`).
  Map<String, Map<String, String>> runtimeOf(String plugin) => _runtime[plugin] ?? const {};

  /// Replaces the merged manifest overrides (`kernel.strings`); locales as in the manifest.
  void setManifest(Map<String, Map<String, String>> strings) {
    _manifest = {
      for (final MapEntry(:key, :value) in strings.entries)
        if (value.isNotEmpty) normalizeLocaleKey(key): Map.unmodifiable(value),
    };
    _changed();
  }

  /// Sets [plugin]'s runtime overrides for [locale] (merging into what it set before), or with null clears them.
  void setRuntime(String plugin, String locale, Map<String, String>? strings) {
    final key = normalizeLocaleKey(locale);
    final byLocale = _runtime.putIfAbsent(plugin, () => {});
    if (strings == null) {
      byLocale.remove(key);
    } else {
      byLocale[key] = {...?byLocale[key], ...strings};
    }
    if (byLocale.isEmpty) {
      _runtime.remove(plugin);
    }
    _changed();
  }

  /// Clears every runtime override of [plugin].
  void clearPlugin(String plugin) {
    if (_runtime.remove(plugin) != null) {
      _changed();
    }
  }

  /// Drops the runtime overrides of plugins that are no longer enabled.
  void retainPlugins(Set<String> enabled) {
    final before = _runtime.length;
    _runtime.removeWhere((plugin, _) => !enabled.contains(plugin));
    if (_runtime.length != before) {
      _changed();
    }
  }

  void _changed() {
    _revision++;
    notifyListeners();
  }

  /// The overrides that apply to [locale], least specific first, runtime after manifest.
  Map<String, String> forLocale(Locale locale) {
    if (isEmpty) {
      return const {};
    }
    final keys = localeKeys(locale);
    final result = <String, String>{};
    for (final key in keys) {
      result.addAll(_manifest[key] ?? const {});
    }
    for (final byLocale in _runtime.values) {
      for (final key in keys) {
        result.addAll(byLocale[key] ?? const {});
      }
    }
    return result;
  }

  /// `*`, `en`, `en_Latn`, `en_US`, `en_Latn_US` (only the parts the locale has), least specific first.
  static List<String> localeKeys(Locale locale) {
    final language = locale.languageCode;
    final script = locale.scriptCode;
    final country = locale.countryCode;
    return [
      '*',
      language,
      if (script != null && script.isNotEmpty) '${language}_$script',
      if (country != null && country.isNotEmpty) '${language}_$country',
      if (script != null && script.isNotEmpty && country != null && country.isNotEmpty)
        '${language}_${script}_$country',
    ];
  }

  static String normalizeLocaleKey(String locale) => locale.trim().replaceAll('-', '_');
}

/// Applies [overrides] (flat keys, dots for nesting) on top of easy_localization [base] data without changing
/// [base]: only the maps along overridden paths are copied.
Map<String, dynamic> mergeTranslationOverrides(Map<String, dynamic> base, Map<String, String> overrides) {
  if (overrides.isEmpty) {
    return base;
  }
  final result = Map<String, dynamic>.of(base);
  for (final MapEntry(:key, :value) in overrides.entries) {
    _put(result, key, value);
  }
  return result;
}

void _put(Map<String, dynamic> target, String key, String value) {
  // easy_localization reads a key with dots as a flat key when the map has it, else as a nested path.
  if (target.containsKey(key) || !key.contains('.')) {
    target[key] = value;
    return;
  }
  final dot = key.indexOf('.');
  final head = key.substring(0, dot);
  final rest = key.substring(dot + 1);
  final current = target[head];
  final nested = current is Map ? Map<String, dynamic>.from(current) : <String, dynamic>{};
  _put(nested, rest, value);
  target[head] = nested;
}

/// Wraps the app's translation loader so plugin overrides apply whenever easy_localization loads a locale.
class PluginStringsAssetLoader extends AssetLoader {
  PluginStringsAssetLoader(this.inner, this.overrides);

  final AssetLoader inner;
  final PluginStringOverrides overrides;

  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async {
    final base = await inner.load(path, locale);
    final strings = overrides.forLocale(locale);
    if (strings.isEmpty) {
      return base;
    }
    return mergeTranslationOverrides(base ?? const {}, strings);
  }
}

/// Owns the plugin string overrides of the running app and re-applies them live.
///
/// `main.dart` passes [loader] to `EasyLocalization(assetLoader: ...)` and reports the current locale with
/// [setCurrentLocale]; after the overrides change, [apply] reloads the current locale's translations the same way
/// easy_localization does and rebuilds the widget tree, so new texts show without restarting.
class PluginStrings {
  PluginStrings({required AssetLoader inner, required this.path, required this.fallbackLocale})
    : overrides = PluginStringOverrides() {
    loader = PluginStringsAssetLoader(inner, overrides);
    overrides.addListener(_scheduleApply);
  }

  static final _log = Logger('PluginStrings');

  final PluginStringOverrides overrides;
  final String path;
  final Locale fallbackLocale;
  late final PluginStringsAssetLoader loader;
  Locale? _currentLocale;
  bool _applyScheduled = false;
  int _appliedRevision = 0;

  Locale? get currentLocale => _currentLocale;

  /// Called by the app with `context.locale` whenever it builds.
  void setCurrentLocale(Locale locale) => _currentLocale = locale;

  void _scheduleApply() {
    if (_applyScheduled) {
      return;
    }
    _applyScheduled = true;
    scheduleMicrotask(() {
      _applyScheduled = false;
      unawaited(apply());
    });
  }

  /// Reloads the current locale with the current overrides and rebuilds every widget.
  Future<void> apply() async {
    final locale = _currentLocale;
    final revision = overrides.revision;
    if (locale == null || revision == _appliedRevision) {
      return;
    }
    try {
      final data = await _load(locale);
      Map<String, dynamic>? fallback;
      final country = locale.countryCode;
      final baseLanguage = country != null && country.isNotEmpty ? await _load(Locale(locale.languageCode)) : null;
      fallback = Map<String, dynamic>.of(await _load(fallbackLocale));
      if (baseLanguage != null) {
        fallback.addAll(baseLanguage);
      }
      if (_currentLocale != locale) {
        return;
      }
      Localization.load(locale, translations: el.Translations(data), fallbackTranslations: el.Translations(fallback));
      _appliedRevision = revision;
      rebuildAllWidgets();
    } catch (error, stack) {
      _log.warning('Failed to apply plugin strings', error, stack);
    }
  }

  /// Re-applies after something else (a language change) reloaded the translations without the overrides.
  Future<void> reapply() {
    _appliedRevision = -1;
    return apply();
  }

  Future<Map<String, dynamic>> _load(Locale locale) async =>
      Map<String, dynamic>.of(await loader.load(path, locale) ?? const {});

  /// The text of [key] for [locale] as the app would show it (with overrides), or null when the key is unknown.
  Future<String?> lookup(String key, Locale locale) async {
    final data = await _load(locale);
    final value = el.Translations(data).get(key);
    if (value != null || locale == fallbackLocale) {
      return value;
    }
    return el.Translations(await _load(fallbackLocale)).get(key);
  }
}

/// Marks every element dirty so texts read during build pick up new translations (no state is lost).
void rebuildAllWidgets() {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) {
    return;
  }
  void visit(Element element) {
    element.markNeedsBuild();
    element.visitChildren(visit);
  }

  root.visitChildren(visit);
}
