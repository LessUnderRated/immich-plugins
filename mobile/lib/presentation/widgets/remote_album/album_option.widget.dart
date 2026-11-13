import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_hooks.dart';
import 'package:immich_mobile/infrastructure/plugins/plugin_api/library/library_ids.dart';
import 'package:immich_mobile/presentation/widgets/action_buttons/base_action_button.widget.dart';

class RemoteAlbumOption extends StatelessWidget {
  const RemoteAlbumOption({
    super.key,
    this.onAddPhotos,
    this.onAddUsers,
    this.onDeleteAlbum,
    this.onLeaveAlbum,
    this.onCreateSharedLink,
    this.onToggleAlbumOrder,
    this.onEditAlbum,
    this.onShowOptions,
    this.iconColor,
    this.iconShadows,
  });

  final VoidCallback? onAddPhotos;
  final VoidCallback? onAddUsers;
  final VoidCallback? onDeleteAlbum;
  final VoidCallback? onLeaveAlbum;
  final VoidCallback? onCreateSharedLink;
  final VoidCallback? onToggleAlbumOrder;
  final VoidCallback? onEditAlbum;
  final VoidCallback? onShowOptions;
  final Color? iconColor;
  final List<Shadow>? iconShadows;

  @override
  Widget build(BuildContext context) {
    final theme = context.themeData;
    final menuChildren = <LibrarySlotItem<Widget>>[];

    if (onEditAlbum != null) {
      menuChildren.add((
        id: 'editAlbum',
        item: BaseActionButton(
          label: context.t.edit_album,
          iconData: Icons.edit,
          onPressed: onEditAlbum,
          menuItem: true,
        ),
      ));
    }

    if (onAddPhotos != null) {
      menuChildren.add((
        id: 'addPhotos',
        item: BaseActionButton(
          label: context.t.add_photos,
          iconData: Icons.add_a_photo,
          onPressed: onAddPhotos,
          menuItem: true,
        ),
      ));
    }

    if (onAddUsers != null) {
      menuChildren.add((
        id: 'addUsers',
        item: BaseActionButton(
          label: context.t.album_viewer_page_share_add_users,
          iconData: Icons.group_add,
          onPressed: onAddUsers,
          menuItem: true,
        ),
      ));
    }

    if (onLeaveAlbum != null) {
      menuChildren.add((
        id: 'leaveAlbum',
        item: BaseActionButton(
          label: context.t.leave_album,
          iconData: Icons.person_remove_rounded,
          onPressed: onLeaveAlbum,
          menuItem: true,
        ),
      ));
    }

    if (onToggleAlbumOrder != null) {
      menuChildren.add((
        id: 'toggleOrder',
        item: BaseActionButton(
          label: context.t.change_display_order,
          iconData: Icons.swap_vert_rounded,
          onPressed: onToggleAlbumOrder,
          menuItem: true,
        ),
      ));
    }

    if (onCreateSharedLink != null) {
      menuChildren.add((
        id: 'createSharedLink',
        item: BaseActionButton(
          label: context.t.create_shared_link,
          iconData: Icons.link,
          onPressed: onCreateSharedLink,
          menuItem: true,
        ),
      ));
    }

    if (onShowOptions != null) {
      menuChildren.add((
        id: 'options',
        item: BaseActionButton(
          label: context.t.options,
          iconData: Icons.settings,
          onPressed: onShowOptions,
          menuItem: true,
        ),
      ));
    }

    if (onDeleteAlbum != null) {
      menuChildren.add((
        id: 'deleteAlbum',
        item: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Divider(height: 1),
            BaseActionButton(
              label: context.t.delete_album,
              iconData: Icons.delete,
              iconColor: context.isDarkTheme ? Colors.red[400] : Colors.red[800],
              onPressed: onDeleteAlbum,
              menuItem: true,
            ),
          ],
        ),
      ));
    }

    return MenuAnchor(
      consumeOutsideTap: true,
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(theme.scaffoldBackgroundColor),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.grey),
        elevation: const WidgetStatePropertyAll(4),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
      ),
      menuChildren: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 150),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: LibraryPluginHooks.arrange(LibrarySlots.appBarMenu(LibraryPages.remoteAlbum), menuChildren),
          ),
        ),
      ],
      builder: (context, controller, child) {
        return IconButton(
          icon: Icon(Icons.more_vert_rounded, color: iconColor ?? Colors.white, shadows: iconShadows),
          onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        );
      },
    );
  }
}
