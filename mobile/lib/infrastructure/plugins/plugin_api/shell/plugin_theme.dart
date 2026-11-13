import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/theme/theme_override.dart';
import 'package:logging/logging.dart';

/// Theme overrides coming from plugins: the merged `contributes.theme` of enabled plugins (set by the kernel when
/// plugins change) plus runtime overrides each plugin sets with the `theme.set` host function.
///
/// Runtime overrides win over manifest ones; among runtime overrides the most recently set wins per key.
/// `immichThemeProvider` applies [effective] to the app theme.
class PluginThemeController extends ChangeNotifier {
  static final _log = Logger('PluginThemeController');

  ThemeOverrideSpec _manifest = ThemeOverrideSpec.empty;
  final Map<String, ThemeOverrideSpec> _runtime = {};
  ThemeOverrideSpec _effective = ThemeOverrideSpec.empty;
  final Set<String> _loadedFonts = {};

  ThemeOverrideSpec get manifest => _manifest;
  Map<String, ThemeOverrideSpec> get runtime => Map.unmodifiable(_runtime);
  ThemeOverrideSpec get effective => _effective;

  /// Replaces the merged manifest override (`kernel.themeOverride`).
  void setManifest(ThemeOverrideSpec spec) {
    if (spec == _manifest) {
      return;
    }
    _manifest = spec;
    _update();
  }

  /// Sets (or with null clears) [plugin]'s runtime override. A set moves the plugin's override to the top.
  void setRuntime(String plugin, ThemeOverrideSpec? spec) {
    final previous = _runtime.remove(plugin);
    if (spec != null && !spec.isEmpty) {
      _runtime[plugin] = spec;
    } else if (previous == null) {
      return;
    }
    _update();
  }

  /// Drops the runtime overrides of plugins that are no longer enabled.
  void retainPlugins(Set<String> enabled) {
    final before = _runtime.length;
    _runtime.removeWhere((plugin, _) => !enabled.contains(plugin));
    if (_runtime.length != before) {
      _update();
    }
  }

  void _update() {
    final next = ThemeOverrideSpec.mergeAll([_manifest, ..._runtime.values]);
    if (next == _effective) {
      return;
    }
    _effective = next;
    notifyListeners();
  }

  /// Loads font files so their family names can be used as `fontFamily`. [files] maps a family name to a file path.
  /// A family is loaded once per app run; failures are logged and the family falls back to the default font.
  Future<void> loadFonts(Map<String, String> files) async {
    for (final MapEntry(key: family, value: path) in files.entries) {
      if (_loadedFonts.contains(family)) {
        continue;
      }
      try {
        final bytes = await File(path).readAsBytes();
        final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
        _loadedFonts.add(family);
      } catch (error, stack) {
        _log.warning('Failed to load font $family from $path', error, stack);
      }
    }
  }

  bool isFontLoaded(String family) => _loadedFonts.contains(family);
}

/// The app-wide controller (also reachable from code without a Riverpod ref, such as host functions).
final pluginThemeController = PluginThemeController();
