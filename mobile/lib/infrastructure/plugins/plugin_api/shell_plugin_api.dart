import 'dart:async';
import 'dart:ui';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/plugin_theme.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/shell_host_functions.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_kernel.dart';
import 'package:immich_mobile/pages/common/settings.page.dart';
import 'package:immich_mobile/providers/backup/backup.provider.dart';
import 'package:immich_mobile/providers/backup/backup_album.provider.dart';
import 'package:immich_mobile/providers/locale_provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/theme/theme_override.dart';
import 'package:logging/logging.dart';

/// Plugin API of the **shell** area: navigation, theme, strings, logs, settings pages, app lifecycle and backup
/// (`nav.*`, `theme.*`, `strings.*`, `logs.*`, `app.*`, `backup.*` host functions), plus the plugins' manifest theme
/// and string overrides applied to the app.
void registerShellPluginApi(PluginKernel kernel, Ref ref) {
  StackRouter router() => ref.read(appRouterProvider);

  Future<bool> openSettings(String? page) async {
    if (page == null || page.isEmpty) {
      unawaited(router().push(const SettingsRoute()));
      return true;
    }
    if (page.startsWith('plugin:')) {
      final target = page.substring('plugin:'.length);
      final slash = target.indexOf('/');
      final plugin = slash < 0 ? target : target.substring(0, slash);
      final id = slash < 0 ? '' : target.substring(slash + 1);
      return kernel.openSettingsPage(plugin, id);
    }
    final section = SettingSection.values.where((section) => section.name == page).firstOrNull;
    if (section == null) {
      return false;
    }
    unawaited(router().push(SettingsSubRoute(section: section)));
    return true;
  }

  final functions = ShellHostFunctions(
    router: router,
    themeController: pluginThemeController,
    themeState: () => (
      theme: ref.read(immichThemeProvider),
      mode: ref.read(immichThemeModeProvider),
      platformBrightness: PlatformDispatcher.instance.platformBrightness,
      fontFamily: ref.read(immichFontFamilyProvider),
    ),
    strings: pluginStrings,
    setLocale: (locale) async {
      final context = ref.read(appRouterProvider).navigatorKey.currentContext;
      if (context != null && context.mounted) {
        await context.setLocale(locale);
      }
    },
    openSettings: openSettings,
    settingsPages: () => [
      for (final section in SettingSection.values) {'id': section.name, 'title': section.name},
      for (final page in kernel.settingsPages)
        {'id': 'plugin:${page.plugin}/${page.id}', 'title': page.title, 'plugin': page.plugin},
    ],
    lifecycle: () => WidgetsBinding.instance.lifecycleState,
    backup: () => ref.read(backupProvider.notifier),
    backupAlbums: () => ref.read(backupAlbumProvider.notifier),
    currentUserId: () => ref.read(currentUserProvider)?.id,
  );
  for (final MapEntry(key: name, value: function) in functions.functions.entries) {
    kernel.registerHost(
      name,
      (plugin, args) async {
        try {
          return await function(plugin, args);
        } on ShellHostError catch (error) {
          throw HostFunctionException(400, error.message);
        }
      },
      doc: ShellHostFunctions.docs[name],
      area: 'shell',
    );
  }

  // The plugins' theme (manifest plus `setTheme` at runtime) and string overrides follow the enabled plugins.
  void syncOverrides() {
    pluginThemeController.setManifest(ThemeOverrideSpec.fromJson(kernel.themeOverrideJson));
    pluginStrings.overrides.setManifest(kernel.stringOverrides);
  }

  syncOverrides();
  kernel.addListener(syncOverrides);

  final logs = LogEventForwarder(Logger.root.onRecord, redact: LogService.I.redact);
  ref.onDispose(() {
    kernel.removeListener(syncOverrides);
    unawaited(logs.dispose());
  });
}
