import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart' hide Store;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/shell_ids.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/url_helper.dart';
import 'package:immich_mobile/widgets/common/immich_logo.dart';
import 'package:immich_mobile/widgets/common/search_field.dart';
import 'package:immich_mobile/widgets/settings/advanced_settings.dart';
import 'package:immich_mobile/widgets/settings/asset_list_settings/asset_list_settings.dart';
import 'package:immich_mobile/widgets/settings/asset_viewer_settings/asset_viewer_settings.dart';
import 'package:immich_mobile/widgets/settings/backup_settings/backup_settings.dart';
import 'package:immich_mobile/widgets/settings/beta_sync_settings/sync_status_and_actions.dart';
import 'package:immich_mobile/widgets/settings/free_up_space_settings.dart';
import 'package:immich_mobile/widgets/settings/language_settings.dart';
import 'package:immich_mobile/widgets/settings/networking_settings/networking_settings.dart';
import 'package:immich_mobile/widgets/settings/notification_setting.dart';
import 'package:immich_mobile/widgets/settings/passkey_settings.dart';
import 'package:immich_mobile/widgets/settings/preference_settings/preference_setting.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Built-in settings sub pages (the argument of [SettingsSubRoute]).
enum SettingSection {
  advanced(Icons.build_outlined),
  assetViewer(Icons.image_outlined),
  backup(Icons.cloud_upload_outlined),
  freeUpSpace(Icons.cleaning_services_outlined),
  languages(Icons.language),
  networking(Icons.wifi),
  notifications(Icons.notifications_none_rounded),
  passkeys(Icons.key_outlined),
  preferences(Icons.interests_outlined),
  timeline(Icons.auto_awesome_mosaic_outlined),
  beta(Icons.sync_outlined);

  final IconData icon;

  /// The plugin id of this sub page: its tile id on the Settings page and its `settings.<id>.items` slot.
  String get id => switch (this) {
    SettingSection.beta => SettingsEntryIds.sync,
    _ => name,
  };

  String title(Translations t) => switch (this) {
    SettingSection.advanced => t.advanced,
    SettingSection.assetViewer => t.asset_viewer_settings_title,
    SettingSection.backup => t.backup,
    SettingSection.freeUpSpace => t.free_up_space,
    SettingSection.languages => t.language,
    SettingSection.networking => t.networking_settings,
    SettingSection.notifications => t.notifications,
    SettingSection.passkeys => t.passkeys(count: 2),
    SettingSection.preferences => t.preferences_settings_title,
    SettingSection.timeline => t.asset_list_settings_title,
    SettingSection.beta => t.sync_status,
  };

  String subtitle(Translations t) => switch (this) {
    SettingSection.advanced => t.advanced_settings_tile_subtitle,
    SettingSection.assetViewer => t.asset_viewer_settings_subtitle,
    SettingSection.backup => t.backup_settings_subtitle,
    SettingSection.freeUpSpace => t.free_up_space_settings_subtitle,
    SettingSection.languages => t.setting_languages_subtitle,
    SettingSection.networking => t.networking_subtitle,
    SettingSection.notifications => t.setting_notifications_subtitle,
    SettingSection.passkeys => t.manage_your_passkeys,
    SettingSection.preferences => t.preferences_settings_subtitle,
    SettingSection.timeline => t.asset_list_settings_subtitle,
    SettingSection.beta => t.sync_status_subtitle,
  };

  /// Words of the settings inside the sub page, so the settings search finds the page by them.
  List<String> keywords(Translations t) => switch (this) {
    SettingSection.advanced => [
      t.advanced_settings_troubleshooting_title,
      t.advanced_settings_sync_remote_deletions_title,
      t.advanced_settings_prefer_remote_title,
      t.advanced_settings_proxy_headers_title,
      t.client_cert_title,
      t.advanced_settings_readonly_mode_title,
      t.advanced_settings_clear_image_cache,
      t.logs,
    ],
    SettingSection.assetViewer => [
      t.setting_image_viewer_original_title,
      t.setting_image_navigation_title,
      t.videos,
      t.setting_video_viewer_auto_play_title,
      t.setting_video_viewer_looping_title,
      t.slideshow,
    ],
    SettingSection.backup => [t.network_requirements, t.background_options, t.backup_albums_sync, t.sync_albums],
    SettingSection.freeUpSpace => const [],
    SettingSection.languages => const [],
    SettingSection.networking => [
      t.current_server_address,
      t.automatic_endpoint_switching_title,
      t.local_network,
      t.external_network,
    ],
    SettingSection.notifications => [t.notification_permission_list_tile_title],
    SettingSection.passkeys => [t.passkeys_on_server],
    SettingSection.preferences => [
      t.theme,
      t.theme_setting_system_theme_switch,
      t.map_settings_dark_mode,
      t.theme_setting_primary_color_title,
      t.theme_setting_colorful_interface_title,
      t.haptic_feedback_title,
      t.default_share_quality,
    ],
    SettingSection.timeline => [
      t.theme_setting_asset_list_storage_indicator_title,
      t.theme_setting_asset_list_smooth_scrubbing_title,
      t.asset_list_layout_sub_title,
      t.asset_list_group_by_sub_title,
    ],
    SettingSection.beta => [t.sync_local, t.sync_remote, t.hash_asset, t.clear_file_cache, t.reset_sqlite],
  };

  Widget get widget => switch (this) {
    SettingSection.advanced => const AdvancedSettings(),
    SettingSection.assetViewer => const AssetViewerSettings(),
    SettingSection.backup => const BackupSettings(),
    SettingSection.freeUpSpace => const FreeUpSpaceSettings(),
    SettingSection.languages => const LanguageSettings(),
    SettingSection.networking => const NetworkingSettings(),
    SettingSection.notifications => const NotificationSetting(),
    SettingSection.passkeys => const PasskeySettings(),
    SettingSection.preferences => const PreferenceSetting(),
    SettingSection.timeline => const AssetListSettings(),
    SettingSection.beta => const SyncStatusAndActions(),
  };

  static Iterable<SettingSection> visible(WidgetRef ref) {
    final isLoggedIn = ref.watch(authProvider).isAuthenticated;
    final isPasskeyEnabled = ref.watch(Store.passkeys.enabled()).valueOrNull ?? false;
    return values.where((section) => section != passkeys || (isLoggedIn && isPasskeyEnabled));
  }

  const SettingSection(this.icon);
}

/// One tile of the Settings page. Built-in tiles have the ids of [SettingsEntryIds].
@immutable
class SettingsEntry {
  const SettingsEntry({
    required this.id,
    required this.title,
    this.subtitle,
    this.icon = Icons.settings_outlined,
    this.leading,
    this.section,
    this.onOpen,
    this.keywords = const [],
  });

  final String id;
  final String title;
  final String? subtitle;
  final IconData icon;

  /// Replaces [icon] (plugin icons).
  final Widget? leading;

  /// The built-in sub page the tile opens (shown in the side pane on tablets).
  final SettingSection? section;

  /// What the tile does when it does not open a [section].
  final void Function(BuildContext context)? onOpen;

  /// More words the settings search matches.
  final List<String> keywords;

  bool matches(String query) {
    if (query.isEmpty) {
      return true;
    }
    final needle = query.toLowerCase();
    return title.toLowerCase().contains(needle) ||
        (subtitle?.toLowerCase().contains(needle) ?? false) ||
        keywords.any((keyword) => keyword.toLowerCase().contains(needle));
  }

  void open(BuildContext context) {
    final section = this.section;
    if (section == SettingSection.beta) {
      unawaited(context.pushRoute(const SyncStatusRoute()));
    } else if (section != null) {
      unawaited(context.pushRoute(SettingsSubRoute(section: section)));
    } else {
      onOpen?.call(context);
    }
  }

  factory SettingsEntry.section(SettingSection section, Translations t) => SettingsEntry(
    id: section.id,
    title: section.title(t),
    subtitle: section.subtitle(t),
    icon: section.icon,
    section: section,
    keywords: section.keywords(t),
  );
}

/// A section of the Settings page, with a header. Built-in sections have the ids of [SettingsSectionIds].
@immutable
class SettingsGroup {
  const SettingsGroup({required this.id, required this.title, required this.entries});

  final String id;
  final String title;
  final List<SettingsEntry> entries;

  SettingsGroup filtered(String query) => SettingsGroup(
    id: id,
    title: title,
    entries: [
      for (final entry in entries)
        if (entry.matches(query)) entry,
    ],
  );
}

/// The built-in sections and tiles of the Settings page, as relevant right now: server, backup and sync settings
/// show while signed in to a server or while a server is configured.
List<SettingsGroup> buildSettingsGroups(BuildContext context, WidgetRef ref, {String? appVersion}) {
  final t = context.t;
  final isLoggedIn = ref.watch(authProvider).isAuthenticated;
  final isPasskeyEnabled = ref.watch(Store.passkeys.enabled()).valueOrNull ?? false;
  final hasServer = isLoggedIn || getServerUrl() != null;
  final syncEntry = SettingsEntry.section(SettingSection.beta, t);

  return [
    SettingsGroup(
      id: SettingsSectionIds.general,
      title: t.general,
      entries: [
        SettingsEntry.section(SettingSection.preferences, t),
        SettingsEntry.section(SettingSection.languages, t),
        SettingsEntry.section(SettingSection.notifications, t),
      ],
    ),
    SettingsGroup(
      id: SettingsSectionIds.media,
      title: t.photos_and_videos,
      entries: [
        SettingsEntry.section(SettingSection.timeline, t),
        SettingsEntry.section(SettingSection.assetViewer, t),
        if (hasServer) SettingsEntry.section(SettingSection.freeUpSpace, t),
      ],
    ),
    SettingsGroup(
      id: SettingsSectionIds.plugins,
      title: t.plugins,
      entries: [
        SettingsEntry(
          id: SettingsEntryIds.plugins,
          title: t.plugins,
          icon: Icons.extension_outlined,
          onOpen: (context) => unawaited(context.pushRoute(const PluginsRoute())),
        ),
      ],
    ),
    SettingsGroup(
      id: SettingsSectionIds.privacy,
      title: t.privacy,
      entries: [
        SettingsEntry(
          id: SettingsEntryIds.privateGallery,
          title: 'Private',
          icon: Icons.lock_outline,
          onOpen: (context) => unawaited(context.navigateTo(const TabShellRoute(children: [PrivateGalleryRoute()]))),
        ),
        if (isLoggedIn)
          SettingsEntry(
            id: SettingsEntryIds.lockedFolder,
            title: t.locked_folder,
            icon: Icons.folder_off_outlined,
            onOpen: (context) => unawaited(context.pushRoute(const LockedFolderRoute())),
          ),
      ],
    ),
    if (hasServer)
      SettingsGroup(
        id: SettingsSectionIds.account,
        title: t.account,
        entries: [
          SettingsEntry.section(SettingSection.networking, t),
          SettingsEntry.section(SettingSection.backup, t),
          syncEntry,
          if (isLoggedIn && isPasskeyEnabled) SettingsEntry.section(SettingSection.passkeys, t),
        ],
      ),
    SettingsGroup(
      id: SettingsSectionIds.advanced,
      title: t.advanced,
      entries: [
        SettingsEntry.section(SettingSection.advanced, t),
        SettingsEntry(
          id: SettingsEntryIds.appLogs,
          title: t.profile_drawer_app_logs,
          icon: Icons.assignment_outlined,
          onOpen: (context) => unawaited(context.pushRoute(const AppLogRoute())),
        ),
        if (!hasServer) syncEntry,
      ],
    ),
    SettingsGroup(
      id: SettingsSectionIds.about,
      title: t.about,
      entries: [
        SettingsEntry(
          id: SettingsEntryIds.whatsNew,
          title: t.whats_new,
          subtitle: t.whats_new_settings_subtitle,
          icon: Icons.auto_awesome_outlined,
          onOpen: (context) => unawaited(context.pushRoute(const WhatsNewRoute())),
        ),
        SettingsEntry(
          id: SettingsEntryIds.version,
          title: t.server_info_box_app_version,
          subtitle: appVersion,
          icon: Icons.info_outline,
          onOpen: (context) => _copyVersion(context, appVersion),
        ),
        SettingsEntry(
          id: SettingsEntryIds.licenses,
          title: t.licenses,
          icon: Icons.description_outlined,
          onOpen: (context) => showLicensePage(
            context: context,
            applicationIcon: const Padding(
              padding: EdgeInsetsGeometry.symmetric(vertical: 10),
              child: ImmichLogo(size: 40),
            ),
            applicationVersion: appVersion,
          ),
        ),
      ],
    ),
  ];
}

void _copyVersion(BuildContext context, String? version) {
  if (version == null) {
    return;
  }
  unawaited(
    Clipboard.setData(ClipboardData(text: version)).then((_) {
      if (context.mounted) {
        context.scaffoldMessenger.showSnackBar(SnackBar(content: Text(context.t.copied_to_clipboard)));
      }
    }),
  );
}

/// The app version for the About section.
String? _useAppVersion() {
  final info = useFuture(useMemoized(PackageInfo.fromPlatform));
  return info.data?.version;
}

@RoutePage()
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: false, title: Text(context.t.settings)),
      body: context.isMobile ? const _MobileLayout() : const _TabletLayout(),
    );
  }
}

class _SettingsSearchField extends StatelessWidget {
  const _SettingsSearchField({required this.controller, required this.focusNode, required this.query});

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueNotifier<String> query;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: SearchField(
        controller: controller,
        focusNode: focusNode,
        hintText: context.t.search_settings,
        filled: true,
        contentPadding: const EdgeInsets.all(12),
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: query.value.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear_rounded),
                onPressed: () {
                  controller.clear();
                  query.value = '';
                },
              ),
        onChanged: (value) => query.value = value.trim(),
        onTapOutside: (_) => focusNode.unfocus(),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 6),
      child: Text(
        title,
        style: context.textTheme.labelLarge?.copyWith(color: context.primaryColor, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile(this.entry);

  final SettingsEntry entry;

  @override
  Widget build(BuildContext context) {
    final subtitle = entry.subtitle;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Card(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        color: context.colorScheme.surfaceContainer,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
        margin: const EdgeInsets.symmetric(vertical: 4.0),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16.0),
          leading: Container(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(16)),
              color: context.isDarkTheme ? Colors.black26 : Colors.white.withAlpha(100),
            ),
            padding: const EdgeInsets.all(16.0),
            child: entry.leading ?? Icon(entry.icon, color: context.primaryColor),
          ),
          title: Text(entry.title, style: context.textTheme.titleMedium!.copyWith(color: context.primaryColor)),
          subtitle: subtitle == null || subtitle.isEmpty ? null : Text(subtitle, style: context.textTheme.bodyMedium),
          onTap: () => entry.open(context),
        ),
      ),
    );
  }
}

class _MobileLayout extends HookConsumerWidget {
  const _MobileLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useTextEditingController();
    final focusNode = useFocusNode();
    final query = useState('');
    final groups = [
      for (final group in buildSettingsGroups(context, ref, appVersion: _useAppVersion())) group.filtered(query.value),
    ].where((group) => group.entries.isNotEmpty).toList();

    return ListView(
      padding: const EdgeInsets.only(bottom: 60),
      children: [
        _SettingsSearchField(controller: controller, focusNode: focusNode, query: query),
        if (groups.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(context.t.no_results, textAlign: TextAlign.center, style: context.textTheme.bodyLarge),
          ),
        for (final group in groups) ...[
          _GroupHeader(group.title),
          for (final entry in group.entries) _SettingsTile(entry),
        ],
      ],
    );
  }
}

class _TabletLayout extends HookConsumerWidget {
  const _TabletLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useTextEditingController();
    final focusNode = useFocusNode();
    final query = useState('');
    final allGroups = buildSettingsGroups(context, ref, appVersion: _useAppVersion());
    final groups = [
      for (final group in allGroups) group.filtered(query.value),
    ].where((group) => group.entries.isNotEmpty).toList();
    final firstSection = allGroups.expand((group) => group.entries).map((entry) => entry.section).nonNulls.firstOrNull;
    final selectedSection = useState<SettingSection?>(null);
    final shown = selectedSection.value ?? firstSection;

    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: _SettingsSearchField(controller: controller, focusNode: focusNode, query: query),
              ),
              if (groups.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(context.t.no_results, textAlign: TextAlign.center),
                  ),
                ),
              for (final group in groups) ...[
                SliverToBoxAdapter(child: _GroupHeader(group.title)),
                for (final entry in group.entries)
                  SliverToBoxAdapter(
                    child: ListTile(
                      title: Text(entry.title),
                      leading: entry.leading ?? Icon(entry.icon),
                      selected: entry.section != null && entry.section == shown,
                      selectedColor: context.primaryColor,
                      selectedTileColor: context.themeData.highlightColor,
                      onTap: () {
                        final section = entry.section;
                        if (section != null) {
                          selectedSection.value = section;
                        } else {
                          entry.open(context);
                        }
                      },
                    ),
                  ),
              ],
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(flex: 4, child: shown?.widget ?? const SizedBox.shrink()),
      ],
    );
  }
}

@RoutePage()
class SettingsSubPage extends StatelessWidget {
  const SettingsSubPage(this.section, {super.key});

  final SettingSection section;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: false, title: Text(section.title(context.t))),
      body: section.widget,
    );
  }
}
