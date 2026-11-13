import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/plugin_strings.dart';

final localeProvider = Provider<Locale>((_) => throw UnimplementedError());

/// Plugin translation overrides of the running app. `main.dart` uses [PluginStrings.loader] as the EasyLocalization
/// asset loader, so overrides apply to every locale load.
final pluginStrings = PluginStrings(
  inner: const CodegenLoader(),
  path: translationsPath,
  fallbackLocale: locales.values.first,
);

final pluginStringsProvider = Provider<PluginStrings>((_) => pluginStrings);
