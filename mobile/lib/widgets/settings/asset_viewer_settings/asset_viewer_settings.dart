import 'package:flutter/material.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/shell/shell_ids.dart';
import 'package:immich_mobile/presentation/widgets/shell/shell_list.widget.dart';
import 'package:immich_mobile/widgets/settings/asset_viewer_settings/image_viewer_quality_setting.dart';
import 'package:immich_mobile/widgets/settings/asset_viewer_settings/image_viewer_tap_to_navigate_setting.dart';
import 'package:immich_mobile/widgets/settings/asset_viewer_settings/slideshow_settings.dart';
import 'package:immich_mobile/widgets/settings/asset_viewer_settings/video_viewer_settings.dart';
import 'package:immich_ui/immich_ui.dart';

class AssetViewerSettings extends StatelessWidget {
  const AssetViewerSettings({super.key});

  @override
  Widget build(BuildContext context) {
    const assetViewerSetting = [
      ShellItem('imageQuality', ImageViewerQualitySetting()),
      ShellItem('tapToNavigate', ImageViewerTapToNavigateSetting()),
      ShellItem('video', VideoViewerSettings()),
      ShellItem('slideshow', SlideshowSettings()),
    ];

    return ShellList(
      slot: ShellSlots.settingsItems(SettingsEntryIds.assetViewer),
      items: assetViewerSetting,
      builder: (context, settings) => SettingsSubPageScaffold(settings: settings, showDivider: true),
    );
  }
}
